# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # Dựng 1 trang bản vẽ thành chuỗi Task cho Job Engine (không Fiber). Mỗi bước nặng là máy trạng thái riêng:
      #   1. Kiểm tra Group cha đã chọn       (nhẹ)
      #   2+3. Thu thập Component lồng nhau + đọc Face/Edge theo lô   (Extractor::CaptureBuilder)
      #   4+5. Từng hình chiếu: chiếu + khử nét khuất theo lô          (Geometry::Projector)
      #   7. Mặt cắt A-A/B-B/C-C: cắt + chiếu theo lô                 (SectionEngine::SectionBuilder)
      #   8a. Nối nét theo lô                                          (Sheet::ChainBuilder)
      #   6+8. DIM + dàn trang + khung tên                             (Sheet.render, sau khi nét đã nối sẵn)
      #   9. Gửi kết quả                                               (job.result)
      # Lỗi của 1 hình chiếu/mặt cắt chỉ ghi chú + log, các hình khác vẫn được vẽ.
      class PageBuild
        # env: đối tượng cung cấp find(pid) -> entity|nil, page_status(pg), capture_builder(entity, exclude, front),
        #      cache (Hash dùng chung giữa các lần dựng), log(msg)
        def initialize(env, project, pg, fmt)
          @env = env
          @project = project
          @pg = pg
          @fmt = fmt
          @views = []
          @notes = []
          @failed = []
          @mats = []
          @extent = nil
        end

        attr_reader :output

        # Trả về danh sách Task (thêm vào Job theo thứ tự).
        def tasks
          [Job.once('kiểm tra') { |job| check(job) },
           capture_task([]),
           Job.once('lập danh sách hình') { |job| plan(job) }]
        end

        def cache
          @env.cache
        end

        def label
          "#{@pg['sheet_no']}"
        end

        # ---------- 1. kiểm tra ----------
        def check(job)
          job.progress("#{label}: kiểm tra đối tượng", 1)
          if @env.page_status(@pg) == 'nested'
            raise ArgumentError, "Trang #{@pg['sheet_no']} là bộ phận nằm bên trong một Group khác (trang cũ từ bản 2.0.0). " \
                                 'Bấm "🧹 Dọn trang lỗi" để xoá, rồi triển khai Group cha.'
          end
          @entity = @env.find(@pg['pid'])
          raise ArgumentError, "Trang #{@pg['sheet_no']}: đối tượng gốc đã bị xoá hoặc thay thế trong SketchUp." unless @entity
        rescue ArgumentError => e
          @fatal = e.message
        end

        # ---------- 2+3. thu thập hình học ----------
        def cap_key(extra)
          exclude = (@project['exclude_tags'] + extra).uniq.sort
          [@pg['pid'], @pg['front'], exclude].to_json
        end

        def capture_task(extra)
          builder = nil
          Job::Task.new('đọc hình học') do |job|
            next true if @fatal

            key = cap_key(extra)
            cache[:caps] ||= {}
            if cache[:caps][key]
              true
            else
              begin
                builder ||= @env.capture_builder(@entity, (@project['exclude_tags'] + extra).uniq, @pg['front'])
                if builder.call(job)
                  cap = builder.result
                  cache[:caps][key] = cap
                  st = cap.stats
                  @env.log("CAPTURE pid=#{@pg['pid']} '#{cap.name}' exclude=#{extra.inspect}: group con=#{st['groups']} " \
                           "component con=#{st['components']} face=#{st['faces']} cạnh nguồn=#{st['edges_src']} -> " \
                           "cạnh=#{st['edges']} tam giác=#{st['triangles']} definition=#{st['defs_cached']} " \
                           "#{st['seconds']}s; nặng nhất: #{Array(st['heaviest']).join('; ')}")
                  true
                else
                  false
                end
              rescue Job::Cancelled
                raise
              rescue ArgumentError => e
                @fatal = e.message if extra.empty?
                @notes << e.message unless extra.empty?
                true
              end
            end
          end
        end

        def cap_for(extra)
          (cache[:caps] || {})[cap_key(extra)]
        end

        # ---------- lập kế hoạch các hình ----------
        def plan(job)
          return job.insert_next([finish_task]) if @fatal

          cap = cap_for([])
          @mats = cap.materials.values
          @extent = cap.stats['extent']
          list = []
          @pg['views'].each do |k|
            if k == 'open'
              door = @project['door_tag'].to_s
              if door.empty?
                @notes << 'Chưa chọn Tag cánh nên bỏ qua "Mặt đứng tháo cánh".'
                next
              end
              list << capture_task([door])
              list << view_task(k, [door])
            else
              list << view_task(k, [])
            end
          end
          list << Job.once('mặt cắt') { |j| plan_sections(j) }
          job.insert_next(list)
        end

        def view_key(k, extra)
          "#{cap_key(extra)}|#{k}"
        end

        # ---------- 4+5. hình chiếu ----------
        def view_task(k, extra)
          pr = nil
          name = Geometry::VIEWS[k][0]
          guarded("hình #{name}", k) do |job|
            cache[:views] ||= {}
            vk = view_key(k, extra)
            if cache[:views][vk]
              @views << cache[:views][vk]
              next true
            end
            cap = cap_for(extra)
            raise ArgumentError, "#{name}: chưa đọc được hình học." unless cap

            pr ||= Geometry::Projector.new(cap, k)
            next false unless pr.call(job)

            v = pr.result
            st = v[:stats]
            @env.log("VIEW #{k} '#{cap.name}': tam giác=#{st['tris']} cạnh vào=#{st['edges_in']} sau lọc=#{st['edges']} " \
                     "nét=#{st['lines']} mức=#{st['level']} #{st['seconds']}s#{v[:notes].empty? ? '' : ' | ' + v[:notes].join(' | ')}")
            cache[:views][vk] = v
            @views << v
            true
          end
        end

        # Bọc Task: lỗi thường -> ghi chú + log, hình khác vẫn tiếp tục. Huỷ -> lan ra ngoài.
        def guarded(what, key)
          Job::Task.new(what) do |job|
            begin
              @fatal ? true : yield(job)
            rescue Job::Cancelled
              raise
            rescue StandardError => e
              @failed << key
              @notes << "#{what}: lỗi – #{e.message}"
              @env.log("#{what} THẤT BẠI pid=#{@pg['pid']}: #{e.class}: #{e.message}\n  #{Array(e.backtrace).first(10).join("\n  ")}")
              true
            end
          end
        end

        # ---------- 7. mặt cắt ----------
        def plan_sections(job)
          list = []
          if @pg['sections'].nil?
            front = @views.find { |v| v[:key] == 'front' }
            if front
              suggest(front)
            else
              # cần mặt đứng để đề xuất vị trí cắt
              list << view_task('front', []).tap { |_t| @want_front_only = true }
              list << Job.once('đề xuất mặt cắt') { |j| suggest_from_cache(j) }
            end
          end
          list << Job.once('lập mặt cắt') { |j| j.insert_next(section_tasks + [Job.once('chi tiết') { |jj| details(jj) }]) }
          job.insert_next(list)
        end

        def suggest_from_cache(_job)
          front = @views.find { |v| v[:key] == 'front' }
          # mặt đứng dựng chỉ để đề xuất: không đưa lên giấy nếu người dùng không chọn
          @views.delete(front) if front && @want_front_only && !@pg['views'].include?('front')
          suggest(front) if front
          @pg['sections'] ||= []
        end

        def suggest(front)
          @pg['sections'] = SectionEngine.suggest(front)
          @env.log("SECTIONS đề xuất #{@pg['sheet_no']}: #{@pg['sections'].inspect}")
        rescue StandardError => e
          @pg['sections'] = []
          @notes << "Không đề xuất được vị trí cắt: #{e.message}"
          @env.log("SECTIONS lỗi #{@pg['sheet_no']}: #{e.class}: #{e.message}")
        end

        def section_tasks
          Array(@pg['sections']).map do |sec|
            sb = nil
            name = "MẶT CẮT #{sec['label']}-#{sec['label']}"
            guarded(name, SectionEngine.key(sec)) do |job|
              cache[:views] ||= {}
              vk = "#{cap_key([])}|sec|#{sec['axis']}|#{sec['pos']}|#{sec['dir']}|#{sec['label']}"
              if cache[:views][vk]
                @views << cache[:views][vk]
                next true
              end
              sb ||= SectionEngine::SectionBuilder.new(cap_for([]), sec)
              next false unless sb.call(job)

              v = sb.result
              st = v[:stats]
              @env.log("SECTION #{sec['label']} #{sec['axis']}=#{sec['pos']} dir=#{sec['dir']}: nét cắt=#{st['cut_segments']} " \
                       "vòng kín=#{st['cut_loops']} nét=#{st['lines']} mức=#{st['level']} #{st['seconds']}s")
              cache[:views][vk] = v
              @views << v
              true
            end
          end
        end

        # ---------- chi tiết phóng to ----------
        def details(job)
          Array(@pg['details']).each do |det|
            src = @views.find { |vv| vv[:key] == det['src'] }
            unless src
              @notes << "CHI TIẾT #{det['n']}: hình nguồn #{det['src']} không còn trên trang."
              next
            end
            begin
              @views << DetailEngine.build(src, det)
            rescue StandardError => e
              @failed << DetailEngine.key(det)
              @notes << e.message
            end
          end
          job.insert_next(chain_tasks + [finish_task])
        end

        # ---------- 8a. nối nét theo lô ----------
        def chain_tasks
          list = @views.reject { |v| v[:detail] || v[:chains] }.map do |v|
            cb = Sheet::ChainBuilder.new(v[:lines])
            Job::Task.new("nối nét #{v[:name]}") do |job|
              job.progress("#{label}: chuẩn bị nét #{v[:name].downcase}", 98)
              if cb.call(job)
                v[:chains] = cb.result
                true
              else
                false
              end
            end
          end
          # Mốc DIM (quét toàn bộ nét) tính trước, mỗi hình 1 bước, để bước dàn trang nhẹ.
          gap = @pg['min_gap'].to_f
          @views.select { |v| v[:dims] && !v[:detail] }.each do |v|
            list << Job.once("mốc DIM #{v[:name]}") { DimensionEngine.view_breaks(v, gap) }
          end
          list
        end

        # ---------- 6+8. DIM + dàn trang: xếp chỗ -> vẽ từng hình (mỗi hình 1 lô) -> ghép ----------
        def finish_task
          Job.once('xếp chỗ') do |job|
            job.progress("#{label}: dàn trang", 99)
            @notes.unshift(@fatal) if @fatal
            @pw, @ph = Sheet.paper(@project['paper'])
            @ctx = Sheet.prepare(@views, @mats, @pg, @pw, @ph)
            @frags = []
            steps = @ctx[:placements].map do |pl|
              Job.once("vẽ #{pl[0][:name]}") do |j|
                j.progress("#{label}: vẽ #{pl[0][:name].downcase}, ghi kích thước", 99)
                sub = Canvas.new(@fmt, @pw, @ph)
                Sheet.draw_placement(sub, @ctx, pl, @pg)
                @frags << sub.parts
              end
            end
            job.insert_next(steps + [assemble_task])
          end
        end

        def assemble_task
          Job.once('ghép trang') do
            cv = Canvas.new(@fmt, @pw, @ph)
            tb = @project['tb'].merge('sheet_name' => @pg['name'], 'sheet_no' => @pg['sheet_no'])
            info = Sheet.assemble(cv, @ctx, @frags, @pg, tb, @notes)
            info['note'] = @notes.empty? ? info['note'] : [info['note'], *@notes].compact.uniq.join(' ')
            info['failed'] = @failed
            info['complete'] = !@views.empty? && @failed.empty? && @views.all? { |v| v[:level].to_i <= 1 }
            info['levels'] = @views.map { |v| [v[:key], v[:level]] }.to_h
            info['sections'] = @pg['sections']
            info['materials'] = @mats.map { |m| m['name'] }
            info['extent'] = @extent ? { 'x' => @extent[0], 'y' => @extent[1], 'z' => @extent[2] } : nil
            @output = [@fmt == :svg ? cv.svg : cv.content, info]
            @ctx = @frags = nil
          end
        end
      end
    end
  end
end
