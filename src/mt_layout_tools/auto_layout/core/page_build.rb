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
        # numbering: lambda(page, số tờ) -> mã tờ đầu (xuất PDF nhiều trang đánh số liên tiếp); mặc định page['sheet_no'].
        def initialize(env, project, pg, fmt, numbering = nil)
          @numbering = numbering || ->(page, _n) { page['sheet_no'].to_s.empty? ? 'A-01' : page['sheet_no'] }
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
        # Cấu hình nhận diện cánh cho trang: chọn tay (đường dẫn instance) + Tag cánh của dự án.
        # Cấu hình nhận diện bộ phận: vai trò gán tay theo đường dẫn instance (+ cánh chọn tay bản 2.4) và Tag cánh.
        def door_cfg
          { roles: (@pg['roles'] || {}), manual: Array(@pg['doors']), tags: [@project['door_tag'].to_s].reject(&:empty?) }
        end

        # variant :all = đủ hình học; :nodoor = đã bỏ các phần được xác định là cánh.
        def cap_key(variant = :all)
          [@pg['pid'], @pg['front'], @project['exclude_tags'].uniq.sort, door_cfg[:manual].sort, door_cfg[:tags],
           door_cfg[:roles].sort, variant.to_s].to_json
        end

        def capture_task(_variant = :all)
          builder = nil
          Job::Task.new('đọc hình học') do |job|
            next true if @fatal

            key = cap_key(:all)
            cache[:caps] ||= {}
            if cache[:caps][key]
              true
            else
              begin
                builder ||= @env.capture_builder(@entity, @project['exclude_tags'].uniq, @pg['front'], door_cfg)
                if builder.call(job)
                  cap = builder.result
                  cache[:caps][key] = cap
                  st = cap.stats
                  @env.log("CAPTURE pid=#{@pg['pid']} '#{cap.name}': group con=#{st['groups']} " \
                           "component con=#{st['components']} face=#{st['faces']} cạnh nguồn=#{st['edges_src']} -> " \
                           "cạnh=#{st['edges']} tam giác=#{st['triangles']} definition=#{st['defs_cached']} " \
                           "bộ phận=#{st['parts']} [#{Array(cap.parts).group_by { |pt| pt['role'] }.map { |r, l| "#{r}:#{l.length}" }.join(' ')}] " \
                           "cánh=#{st['doors']} (#{Array(cap.doors).map { |d| "#{d['name']}: #{d['reason']}" }.join('; ')}) " \
                           "gán tay không còn hợp lệ=#{Array(st['missing_roles']).length} " \
                           "#{st['seconds']}s; nặng nhất: #{Array(st['heaviest']).join('; ')}")
                  true
                else
                  false
                end
              rescue Job::Cancelled
                raise
              rescue ArgumentError => e
                @fatal = e.message
                true
              end
            end
          end
        end

        def cap_for(variant = :all)
          caps = (cache[:caps] ||= {})
          return caps[cap_key(:all)] if variant == :all

          base = caps[cap_key(:all)]
          return nil unless base

          caps[cap_key(:nodoor)] ||= base.without_doors
        end

        # ---------- lập kế hoạch các hình ----------
        def plan(job)
          return job.insert_next([finish_task]) if @fatal

          cap = cap_for(:all)
          @mats = cap.materials.values
          @extent = cap.stats['extent']
          @doors = Array(cap.doors)
          @parts = Array(cap.parts)
          @clusters = (cap.stats || {})['clusters'] || {}
          @missing = Array(cap.stats['missing_roles'])
          unless @missing.empty?
            @notes << "#{@missing.length} bộ phận đã gán tay không còn trong model (đã xoá hoặc thay thế) – xem mục CẤU TẠO TỦ."
          end
          list = []
          @pg['views'].each do |k|
            if k == 'open'
              if @doors.empty?
                @notes << 'Chưa xác định được cánh tủ nên KHÔNG tạo "Mặt đứng tháo cánh" (không ẩn đoán). ' \
                          'Bấm "CHỌN CÁNH TRONG SKETCHUP" hoặc chọn Tag cánh.'
                next
              end
              list << view_task(k, :nodoor)
            else
              list << view_task(k, :all)
            end
          end
          list << Job.once('mặt cắt') { |j| plan_sections(j) }
          job.insert_next(list)
        end

        def view_key(k, variant)
          "#{cap_key(variant)}|#{k}"
        end

        # Bộ DIM cho từng loại hình (Dimension Engine nhận cả loại hình + đối tượng hiển thị).
        def dim_mode_for(k)
          case k
          when 'front'
            fd = @pg['front_dims'].to_s
            if fd == 'interior' then :interior
            elsif fd == 'exterior' then :exterior
            else @doors.empty? ? :exterior : :door
            end
          when 'open' then :interior
          when 'iso' then :none
          else :exterior
          end
        end

        # ---------- 4+5. hình chiếu ----------
        def view_task(k, variant)
          pr = nil
          name = Geometry::VIEWS[k][0]
          guarded("hình #{name}", k) do |job|
            cache[:views] ||= {}
            vk = view_key(k, variant)
            unless cache[:views][vk]
              cap = cap_for(variant)
              raise ArgumentError, "#{name}: chưa đọc được hình học." unless cap

              pr ||= Geometry::Projector.new(cap, k)
              next false unless pr.call(job)

              v = pr.result
              l, t = v[:origin]
              v[:part_rects] = part_rects(cap, v[:fn], l, t, variant) unless k == 'iso'
              if variant == :all && @doors.any? && %w[front back].include?(k)
                db = cap.door_boxes(v[:fn])
                v[:door_boxes] = db.map { |d| b = d['box']; [b[0] - l, b[1] - l, b[2] - t, b[3] - t] }
                # cánh kèm đường dẫn instance ổn định – để vẽ ký hiệu hướng mở & bấm chọn trên giấy
                v[:door_items] = db.map do |d|
                  b = d['box']
                  { 'path' => cap.doors[d['id']]['path'], 'name' => d['name'],
                    'box' => [b[0] - l, b[1] - l, b[2] - t, b[3] - t].map { |n| n.round(2) } }
                end
              end
              if %w[front open].include?(k)
                # mốc DIM theo bộ phận đã phân loại (chỉ bộ phận còn hiện trong hình này)
                visible = @parts.reject { |pt| variant == :nodoor && pt['role'] == 'door' }
                sides = visible.select { |pt| pt['role'] == 'side' }
                horiz = visible.select { |pt| %w[shelf top bottom drawer].include?(pt['role']) }
                if !sides.empty? && !horiz.empty?
                  xs = sides.flat_map { |pt| pt['bounds'][0].map { |x| x - l } }
                  ys = horiz.flat_map { |pt| pt['bounds'][2].map { |z| -z - t } }
                  v[:part_breaks] = [xs, ys]
                end
                handles = @parts.select { |pt| pt['role'] == 'handle' && pt['sure'] }
                v[:handle_ys] = handles.map { |pt| -(pt['bounds'][2].sum / 2.0) - t } unless handles.empty?
              end
              st = v[:stats]
              @env.log("VIEW #{k} '#{cap.name}': tam giác=#{st['tris']} cạnh vào=#{st['edges_in']} sau lọc=#{st['edges']} " \
                       "nét=#{st['lines']} mức=#{st['level']} #{st['seconds']}s#{v[:notes].empty? ? '' : ' | ' + v[:notes].join(' | ')}")
              cache[:views][vk] = v
            end
            v = cache[:views][vk]
            v[:dim_mode] = dim_mode_for(k)
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
            # đề xuất vị trí cắt từ cấu tạo bên trong: dùng hình tháo cánh nếu có cánh, không thì mặt đứng
            src_key = @doors.empty? ? 'front' : 'open'
            src = @views.find { |v| v[:key] == src_key }
            if src
              suggest(src)
            else
              list << view_task(src_key, @doors.empty? ? :all : :nodoor).tap { |_t| @want_front_only = src_key }
              list << Job.once('đề xuất mặt cắt') { |j| suggest_from_cache(j) }
            end
          end
          list << Job.once('lập mặt cắt') { |j| j.insert_next(section_tasks + [Job.once('chi tiết') { |jj| details(jj) }]) }
          job.insert_next(list)
        end

        def suggest_from_cache(_job)
          key = @want_front_only || 'front'
          front = @views.find { |v| v[:key] == key }
          # hình dựng chỉ để đề xuất: không đưa lên giấy nếu người dùng không chọn
          @views.delete(front) if front && @want_front_only && !@pg['views'].include?(key)
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
              vk = "#{cap_key(:all)}|sec|#{sec['axis']}|#{sec['pos']}|#{sec['dir']}|#{sec['label']}"
              if cache[:views][vk]
                cache[:views][vk][:dim_mode] = :section
                @views << cache[:views][vk]
                next true
              end
              sb ||= SectionEngine::SectionBuilder.new(cap_for(:all), sec)
              next false unless sb.call(job)

              v = sb.result
              st = v[:stats]
              @env.log("SECTION #{sec['label']} #{sec['axis']}=#{sec['pos']} dir=#{sec['dir']}: nét cắt=#{st['cut_segments']} " \
                       "vòng kín=#{st['cut_loops']} nét=#{st['lines']} mức=#{st['level']} #{st['seconds']}s")
              v[:dim_mode] = :section
              cache[:views][vk] = v
              @views << v
              true
            end
          end
        end

        # Khung chiếu của từng bộ phận trên hình (để bấm chuột phải gán bộ phận ngay trên bản vẽ 2D):
        # [đường dẫn instance, x0, x1, y0, y1, độ sâu mặt trước] – độ sâu lớn = gần người xem.
        def part_rects(cap, fn, l, t, variant)
          Array(cap.parts).first(4000).filter_map do |pt|
            next if variant == :nodoor && pt['role'] == 'door'

            b = pt['bounds']
            next unless b && b.all? { |lo, hi| lo.finite? && hi.finite? }

            pts = b[0].product(b[1], b[2]).map { |c| fn.call(c) }
            us = pts.map { |p| p[0] }
            vs = pts.map { |p| p[1] }
            next if us.max - us.min < 0.5 && vs.max - vs.min < 0.5

            [pt['path'], (us.min - l).round(1), (us.max - l).round(1), (vs.min - t).round(1), (vs.max - t).round(1), pts.map { |p| p[2] }.max.round(1)]
          end
        end

        # ---------- chi tiết phóng to ----------
        def details(job)
          cons = []
          Array(@pg['details']).each do |det|
            src = @views.find { |vv| vv[:key] == det['src'] }
            if det['type'] == 'section' && src
              cons << [det, src]
              next
            end
            unless src
              @notes << "CHI TIẾT #{det['n']}: hình nguồn #{det['src']} không còn trên trang."
              next
            end
            begin
              dv = DetailEngine.build(src, det)
              dv[:dim_mode] = :interior
              @views << dv
            rescue StandardError => e
              @failed << DetailEngine.key(det)
              @notes << e.message
            end
          end
          job.insert_next(construction_tasks(cons) + [Job.once('bản sao') { |jj| copies; jj.insert_next(chain_tasks + [finish_task]) }])
        end

        # ---------- chi tiết cấu tạo: mặt cắt thật qua hình học 3D (theo lô) ----------
        def construction_tasks(list)
          list.map do |det, src|
            key = DetailEngine.key(det)
            st = {}
            guarded(DetailEngine.label(det), key) do |job|
              cache[:views] ||= {}
              ck = "#{cap_key(:all)}|cdet|#{src[:key]}|#{det.values_at('rect', 'cut', 'depth', 'labels').to_json}"
              v = cache[:views][ck]
              unless v
                st[:plan] ||= ConstructionDetail.plan(src, det)
                pl = st[:plan]
                cap = cap_for(:all)
                if pl[:depth] && !st[:limited]
                  st[:far] ||= SectionEngine::SectionBuilder.new(cap, ConstructionDetail.far_plane(pl, pl[:depth]))
                  next false unless st[:far].clip_step(job)

                  st[:limited] = st[:far].clipped
                end
                st[:sb] ||= SectionEngine::SectionBuilder.new(st[:limited] || cap, pl)
                next false unless st[:sb].call(job)

                v = ConstructionDetail.crop(st[:sb].result, pl, det)
                cache[:views][ck] = v
              end
              dv = v.dup
              dv[:fixed_scale] = det['scale']
              dv[:name] = DetailEngine.label(det)
              dv.delete(:own_scale)
              @views << dv
              true
            end
          end
        end

        # ---------- bản sao hình chiếu (cùng hình học, vị trí / tỉ lệ / tờ riêng) ----------
        def copies
          Array(@pg['copies']).each do |c|
            src = @views.find { |vv| vv[:key] == c['src'] }
            unless src
              @notes << "Bản sao của #{c['src']}: hình gốc không còn trên trang."
              next
            end
            cp = src.dup
            cp.delete(:own_scale)
            cp.delete(:chains)
            cp[:key] = "cp:#{c['n']}"
            cp[:copy_of] = c['src']
            cp[:fixed_scale] = src[:detail] ? src[:fixed_scale] : nil
            @views << cp
          end
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
          @views.select { |v| v[:dims] && !v[:detail] && v[:dim_mode] != :exterior }.each do |v|
            list << Job.once("mốc DIM #{v[:name]}") { DimensionEngine.view_breaks(v, gap) }
          end
          list
        end

        # ---------- 6+8. DIM + dàn trang: chia tờ -> xếp chỗ -> vẽ từng hình (mỗi hình 1 lô) -> ghép ----------
        attr_reader :outputs

        def finish_task
          Job.once('chia tờ') do |job|
            job.progress("#{label}: dàn trang", 99)
            @notes.unshift(@fatal) if @fatal
            @pw, @ph = Sheet.paper(@project['paper'])
            @pg['has_detail_view'] = @views.any? { |v| v[:key] == 'open' || v[:cut] }
            apply_view_props
            apply_swings
            sheets = Sheet.paginate(@views, @mats, @pg, @pw, @ph)
            @outputs = Array.new(sheets.length)
            @base_code = @numbering.call(@pg, sheets.length)
            steps = sheets.each_with_index.flat_map { |(group, forced, note), i| sheet_tasks(i, sheets.length, group, forced, note) }
            job.insert_next(steps)
          end
        end

        # Tỉ lệ riêng từng hình (page['view_props']): gán v[:fixed_scale] trước khi chia tờ.
        # Hình đã lưu trong cache được gán lại mỗi lần dựng (bỏ tỉ lệ riêng -> về tỉ lệ trang / tỉ lệ chi tiết).
        def apply_view_props
          props = @pg['view_props'] || {}
          @views.each do |v|
            v[:own_scale] = v[:fixed_scale] unless v.key?(:own_scale)
            vp = props[v[:key]]
            v[:fixed_scale] = (vp && vp['scale_override']) || v[:own_scale]
            v[:scale_locked] = vp ? vp['scale_locked'] == true : false
            v[:position_locked] = vp ? vp['position_locked'] == true : false
            # tỉ lệ theo trang đã chốt lúc dàn trang (để thêm hình / đổi trang không làm tỉ lệ hình cũ nhảy)
            v[:base_scale] = vp && !vp['scale_override'] && vp['base_scale'] ? vp['base_scale'] : nil
            # có toạ độ đã chốt (tự động hoặc chỉnh tay) -> đặt đúng chỗ đó, không tính lại bố cục
            v[:pin] = vp && vp['x_mm'] && vp['y_mm'] ? { x: vp['x_mm'], y: vp['y_mm'], sheet: vp['sheet'].to_i, manual: vp['placement_mode'] == 'manual' } : nil
            # chưa có toạ độ nhưng đã định tờ -> đặt vào chỗ trống của ĐÚNG tờ đó (không tự đưa về A-01)
            v[:want_sheet] = !v[:pin] && vp && vp['sheet'] ? vp['sheet'].to_i : nil
          end
        end

        # Ký hiệu cánh mở nhìn từ trên: tính lại mỗi lần dựng từ dữ liệu ký hiệu cánh chung (không lưu riêng từng hình)
        def apply_swings
          syms = @pg['door_symbols'] || {}
          if syms.none? { |_, s| DoorSwing::HINGED.include?(s['type'].to_s) && s['visible'] != false }
            @views.each { |v| v[:swings] = v[:swing_pad] = nil }
            return
          end
          cap = cap_for(:all)
          fr = ((cache[:swing_frames] ||= {})[cap_key(:all)] ||= DoorSwing.frames(cap))
          cs = fr.values.flat_map(&:corners)
          centre = cs.empty? ? [0.0, 0.0, 0.0] : (0..2).map { |k| cs.sum { |c| c[k] } / cs.length }
          front_g = Geometry::HiddenFill.viewer_dir(Geometry::VIEWS['front'][1])
          st = DoorSwing.clean(@pg['swing'])
          @views.each { |v| DoorSwing.apply(v, fr, syms, st, front_g, centre) }
        end

        def sheet_tasks(idx, total, group, forced, note)
          st = { frags: [] }
          prep = Job.once("xếp chỗ tờ #{idx + 1}") do |job|
            # chú thích/leader của tờ này: để hình chờ đặt né ra
            st[:ctx] = Sheet.prepare(group, @mats, @pg.merge('notes' => Array(@pg['notes']).select { |n| n['sheet'].to_i == idx }),
                                     @pw, @ph, forced)
            draws = st[:ctx][:placements].map do |pl|
              Job.once("vẽ #{pl[0][:name]}") do |j|
                j.progress("#{label}: vẽ #{pl[0][:name].downcase}, ghi kích thước (tờ #{idx + 1}/#{total})", 99)
                sub = Canvas.new(@fmt, @pw, @ph)
                Sheet.draw_placement(sub, st[:ctx], pl, @pg)
                st[:frags] << sub.parts
              end
            end
            job.insert_next(draws + [assemble_task(idx, total, group, st, note)])
          end
          [prep]
        end

        def assemble_task(idx, total, group, st, note)
          Job.once("ghép tờ #{idx + 1}") do
            cv = Canvas.new(@fmt, @pw, @ph)
            no = ProjectStore.increment(@base_code, idx)
            tb = @project['tb'].merge('sheet_name' => @pg['name'], 'sheet_no' => no)
            tb['sheet_of'] = "Tờ #{idx + 1}/#{total}" if total > 1
            notes = idx.zero? ? @notes.dup : []
            notes << note if note
            # mỗi tờ chỉ vẽ chú thích của chính nó
            pg = @pg.merge('notes' => Array(@pg['notes']).select { |n| n['sheet'].to_i == idx })
            info = Sheet.assemble(cv, st[:ctx], st[:frags], pg, tb, notes)
            info['note'] = notes.empty? ? info['note'] : [info['note'], *notes].compact.uniq.join(' ')
            info['failed'] = @failed
            info['complete'] = !@views.empty? && @failed.empty? && @views.all? { |v| v[:level].to_i <= 1 }
            info['levels'] = group.map { |v| [v[:key], v[:level]] }.to_h
            info['sections'] = @pg['sections']
            info['materials'] = @mats.map { |m| m['name'] }
            info['extent'] = @extent ? { 'x' => @extent[0], 'y' => @extent[1], 'z' => @extent[2] } : nil
            info['doors'] = Array(@doors).map { |d| { 'name' => d['name'], 'reason' => d['reason'], 'path' => d['path'], 'sure' => d['sure'] } }
            info['parts'] = Array(@parts).first(5000).map do |pt|
              { 'path' => pt['path'], 'name' => pt['name'], 'role' => pt['role'], 'source' => pt['source'], 'sure' => pt['sure'],
                'confidence' => pt['confidence'], 'cluster' => pt['path'].to_s.split('/').first,
                'size' => pt['bounds'].map { |lo, hi| (hi - lo).round } }
            end
            info['clusters'] = @clusters || {}
            info['parts_total'] = Array(@parts).length
            info['missing_roles'] = Array(@missing)
            info['door_items'] = group.select { |v| v[:door_items] }.map { |v| [v[:key], v[:door_items]] }.to_h
            info['part_hits'] = group.select { |v| v[:part_rects] && !v[:detail] }.map { |v| [v[:key], v[:part_rects]] }.to_h
            info['view_props'] = @pg['view_props'] || {}
            info['view_keys'] = group.map { |v| v[:key] }
            info['sheet'] = idx
            info['sheets'] = total
            info['code'] = no
            @outputs[idx] = [@fmt == :svg ? cv.svg : cv.content, info]
            st.clear
          end
        end

        # Tờ đầu (tương thích chỗ gọi cũ).
        def output
          @outputs && @outputs[0]
        end
      end
    end
  end
end
