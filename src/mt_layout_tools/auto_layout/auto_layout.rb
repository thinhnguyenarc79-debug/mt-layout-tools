# encoding: UTF-8
require 'sketchup.rb'
require 'json'
require 'tmpdir'
require_relative 'core/pdf'
require_relative 'core/job'
require_relative 'core/geometry'
require_relative 'core/extractor'
require_relative 'core/canvas'
require_relative 'core/dimension_engine'
require_relative 'core/section_engine'
require_relative 'core/annotation_engine'
require_relative 'core/detail_engine'
require_relative 'core/sheet'
require_relative 'core/model_scanner'
require_relative 'core/project_store'

module MTDesign
  module LayoutTools
    # AUTO LAYOUT PRO – cửa sổ biên tập dàn trang. Ruby đọc model và dựng bản vẽ; giao diện HTML hiển thị/biên tập.
    module AutoLayout
      LOG = File.join(Dir.tmpdir, 'mt_auto_layout.log')

      class << self
        def log(msg)
          File.open(LOG, 'a') { |f| f.puts("#{Time.now.strftime('%F %T')} #{msg}") }
        rescue StandardError
          nil
        end

        def show
          if @dialog && @dialog.visible?
            @dialog.bring_to_front
            guard(@dialog, 'scan') { on_scan(@dialog, nil) } # bấm lại nút = lấy đối tượng vừa chọn
            return
          end
          reset_cache
          d = UI::HtmlDialog.new(dialog_title: 'AUTO LAYOUT PRO – MT Layout Tools', preferences_key: 'MTDesign_AutoLayout',
                                 width: 1400, height: 860, min_width: 1000, min_height: 620,
                                 resizable: true, scrollable: false, style: UI::HtmlDialog::STYLE_DIALOG)
          d.set_file(File.join(__dir__, 'ui', 'index.html'))
          {
            'ready' => :on_ready, 'scan' => :on_scan, 'generate' => :on_generate, 'render' => :on_render,
            'refresh' => :on_refresh, 'save' => :on_save, 'export_pdf' => :on_export_pdf,
            'export_svg' => :on_export_svg, 'save_json' => :on_save_json, 'open_json' => :on_open_json,
            'pick' => :on_pick, 'cancel' => :on_cancel
          }.each do |name, handler|
            d.add_action_callback(name) do |_ctx, arg|
              guard(d, name) { send(handler, d, arg) }
            end
          end
          d.set_on_closed do
            @job&.cancel!
            reset_cache
          end
          @dialog = d
          d.show
        end

        def guard(d, name)
          yield
        rescue ArgumentError, JSON::ParserError => e
          push(d, 'error', { 'cmd' => name, 'message' => e.message })
        rescue StandardError => e
          log("#{name}: #{e.class}: #{e.message}\n  #{e.backtrace.first(8).join("\n  ")}")
          push(d, 'error', { 'cmd' => name, 'message' => "Lỗi #{e.class}: #{e.message} (chi tiết: #{LOG})" })
        end

        def reset_cache
          @caps = {}       # khoá (pid, hướng, tag loại) -> Capture
          @views = {}      # khoá capture + hình chiếu -> hình chiếu đã khử nét
          @extractor = Extractor.new
        end

        def push(d, kind, data)
          json = JSON.generate(data).gsub("\u2028", '\\u2028').gsub("\u2029", '\\u2029')
          d.execute_script("window.ALP && ALP.on(#{kind.to_json}, #{json});")
        end

        def model
          Sketchup.active_model
        end

        def parse(arg)
          JSON.parse(arg.to_s)
        end

        # ---------------- callbacks ----------------
        # Danh sách model = selection hiện tại (thay thế danh sách cũ). Kèm trạng thái các trang của dự án.
        def selection_payload(project = nil)
          models = ModelScanner.models(model)
          out = { 'models' => models, 'tags' => ModelScanner.tags(model),
                  'notice' => models.empty? ? ModelScanner::NO_SELECTION : nil }
          out['status'] = ModelScanner.statuses(model, project) if project
          out
        end

        def on_ready(d, _arg)
          project = ProjectStore.load(model)
          sel = selection_payload(project)
          push(d, 'init', { 'project' => project, 'models' => sel['models'], 'notice' => sel['notice'], 'status' => sel['status'],
                            'tags' => sel['tags'], 'views' => Geometry::VIEWS.transform_values(&:first),
                            'papers' => Sheet::PAPERS.keys, 'scales' => Sheet::SCALES })
        end

        # "Lấy đối tượng đang chọn" / "Quét lại": chỉ đọc selection hiện tại, không quét cả file.
        def on_scan(d, arg)
          raw = arg.to_s.empty? || arg.to_s == 'null' ? nil : parse(arg)
          push(d, 'models', selection_payload(raw ? ProjectStore.clean(raw) : nil))
        end

        # Tạo trang cho các model được chọn. arg: { project, pids }.
        def on_generate(d, arg)
          data = parse(arg)
          project = ProjectStore.clean(data['project'])
          pids = Array(data['pids']).map(&:to_i).uniq
          raise ArgumentError, 'Chưa chọn model nào để triển khai.' if pids.empty?

          res = ProjectStore.add_pages(project, pids, lambda do |pid|
            e = ModelScanner.find(model, pid)
            e && { 'name' => Geometry.instance_name(e), 'root' => !ModelScanner.nested?(e) }
          end, data['replace'] != false)
          done = res['created'] + res['replaced']
          if done.empty?
            raise ArgumentError, 'Không tìm thấy model đã tick (có thể đã bị xoá).' if res['skipped'].empty?

            msg = "#{res['skipped'].length} model đã có trang, không tạo trùng (bật \"Thay thế trang cũ\" để dựng lại)."
          else
            msg = "Tạo #{res['created'].length} trang, thay thế #{res['replaced'].length} trang."
            msg += " Bỏ qua #{res['skipped'].length} model đã có trang." unless res['skipped'].empty?
          end
          bad = ModelScanner.statuses(model, project).count { |_, st| st != 'ok' }
          msg += " Có #{bad} trang cũ không hợp lệ (bộ phận con/đã xoá) – bấm \"🧹 Dọn trang lỗi\"." if bad.positive?
          push(d, 'project', { 'project' => project, 'open' => (done.first || res['skipped'].first),
                               'status' => ModelScanner.statuses(model, project), 'message' => msg })
        end

        # ---------------- tác vụ dài (chia lát, có tiến trình & huỷ) ----------------
        # Chỉ 1 tác vụ chạy tại một thời điểm; tác vụ mới huỷ tác vụ cũ.
        def start_job(d, name, &work)
          @job&.cancel!
          job = Job.new(name, &work)
          @job = job
          last = nil
          job.run_async(
            on_step: lambda do |j|
              cur = [j.progress_text, j.progress_pct]
              push(d, 'progress', { 'text' => cur[0], 'pct' => cur[1] }) if cur != last
              last = cur
            end,
            on_done: lambda do |result|
              @job = nil if @job.equal?(job)
              push(d, 'progress', { 'done' => true })
              result&.call
            end,
            on_error: lambda do |e|
              @job = nil if @job.equal?(job)
              push(d, 'progress', { 'done' => true })
              if e.is_a?(Job::Cancelled)
                push(d, 'saved', { 'message' => 'Đã huỷ tác vụ.' }) unless job.cancelled? && !@job.nil?
              elsif e.is_a?(ArgumentError)
                push(d, 'error', { 'cmd' => name, 'message' => e.message })
              else
                log("#{name}: #{e.class}: #{e.message}\n  #{Array(e.backtrace).first(12).join("\n  ")}")
                push(d, 'error', { 'cmd' => name, 'message' => "Lỗi #{e.class}: #{e.message} (chi tiết: #{LOG})" })
              end
            end
          )
        end

        def on_cancel(d, _arg)
          if @job
            @job.cancel!
          else
            push(d, 'progress', { 'done' => true })
          end
        end

        # Dựng 1 trang để xem/biên tập. arg: { project, page_id }.
        def on_render(d, arg)
          data = parse(arg)
          project = ProjectStore.clean(data['project'])
          page = project['pages'].find { |p| p['id'] == data['page_id'] }
          raise ArgumentError, 'Không tìm thấy trang.' unless page

          start_job(d, 'render') do |job|
            t = Time.now
            svg, info = page_output(project, page, :svg, job)
            info['ms'] = ((Time.now - t) * 1000).round
            -> { push(d, 'page', { 'page_id' => page['id'], 'svg' => svg, 'info' => info }) }
          end
        end

        # "Cập nhật bản vẽ": đọc lại hình học từ SketchUp (bỏ cache) rồi dựng lại.
        def on_refresh(d, arg)
          reset_cache
          on_render(d, arg)
        end

        def on_save(d, arg)
          project = ProjectStore.clean(parse(arg))
          ProjectStore.save(model, project)
          push(d, 'saved', { 'message' => 'Đã lưu dự án vào file SketchUp (nhấn Ctrl+S trong SketchUp để ghi file SKP).' })
        end

        def on_export_pdf(d, arg)
          data = parse(arg)
          project = ProjectStore.clean(data['project'])
          ids = Array(data['page_ids'])
          pages = ids.empty? ? project['pages'] : project['pages'].select { |p| ids.include?(p['id']) }
          raise ArgumentError, 'Không có trang nào để xuất.' if pages.empty?

          pw, ph = Sheet.paper(project['paper'])
          start_job(d, 'export_pdf') do |job|
            contents = []
            notes = []
            pages.each_with_index do |pg, i|
              job.progress("Xuất PDF: trang #{i + 1}/#{pages.length} (#{pg['sheet_no']})", 100.0 * i / pages.length)
              content, info = page_output(project, pg, :pdf, job)
              contents << content
              notes << "#{pg['sheet_no']}: #{info['note']}" if info['note']
            end
            bytes = Pdf.pdf_pages(contents, [pw * Pdf::MM_TO_PT, ph * Pdf::MM_TO_PT])
            lambda do
              name = pages.length == 1 ? "#{pages[0]['sheet_no']} #{pages[0]['name']}" : project['name']
              path = save_file(name, 'pdf', bytes)
              msg = path ? "Đã xuất #{pages.length} trang: #{File.basename(path)}" : 'Đã huỷ lưu.'
              msg += " Lưu ý – #{notes.join(' | ')}" unless notes.empty?
              push(d, notes.empty? ? 'saved' : 'warn', { 'message' => msg })
              UI.openURL("file:///#{path.tr('\\', '/')}") if path
            end
          end
        end

        def on_export_svg(d, arg)
          data = parse(arg)
          project = ProjectStore.clean(data['project'])
          page = project['pages'].find { |p| p['id'] == data['page_id'] }
          raise ArgumentError, 'Không tìm thấy trang.' unless page

          start_job(d, 'export_svg') do |job|
            svg, = page_output(project, page, :svg, job)
            lambda do
              path = save_file("#{page['sheet_no']} #{page['name']}", 'svg', svg)
              push(d, 'saved', { 'message' => path ? "Đã xuất #{File.basename(path)}" : 'Đã huỷ lưu.' })
            end
          end
        end

        def on_save_json(d, arg)
          project = ProjectStore.clean(parse(arg))
          path = save_file(project['name'], 'json', JSON.pretty_generate(project))
          push(d, 'saved', { 'message' => path ? "Đã lưu #{File.basename(path)}" : 'Đã huỷ.' })
        end

        def on_open_json(d, _arg)
          path = UI.openpanel('Mở dự án AUTO LAYOUT', folder, 'Dự án JSON|*.json||')
          return unless path

          project = ProjectStore.read_file(path)
          push(d, 'project', { 'project' => project, 'status' => ModelScanner.statuses(model, project),
                               'message' => "Đã mở #{File.basename(path)}" })
        end

        # Chọn đối tượng trong SketchUp (không sửa model) để người dùng thấy đang triển khai cái gì.
        def on_pick(d, arg)
          e = ModelScanner.find(model, arg.to_i)
          raise ArgumentError, 'Đối tượng không còn trong model.' unless e

          model.selection.clear
          model.selection.add(e)
          model.active_view.zoom(e)
          push(d, 'saved', { 'message' => "Đang chọn: #{Geometry.instance_name(e)}" })
        end

        # ---------------- dựng trang ----------------
        def capture_for(pg, project, job, extra = [])
          e = ModelScanner.find(model, pg['pid'])
          raise ArgumentError, "Trang #{pg['sheet_no']}: đối tượng gốc đã bị xoá hoặc thay thế trong SketchUp." unless e

          exclude = (project['exclude_tags'] + extra).uniq
          key = [pg['pid'], pg['front'], exclude.sort].to_json
          @caps ||= {}
          @extractor ||= Extractor.new
          return [@caps[key], key] if @caps[key]

          cap = @extractor.capture(model, e, exclude, pg['front'], job)
          st = cap.stats
          log("CAPTURE pid=#{pg['pid']} '#{cap.name}' front=#{pg['front']} exclude=#{exclude.inspect}: " \
              "group con=#{st['groups']} component con=#{st['components']} face=#{st['faces']} " \
              "cạnh nguồn=#{st['edges_src']} -> cạnh=#{st['edges']} tam giác=#{st['triangles']} " \
              "definition đã cache=#{st['defs_cached']} thời gian=#{st['seconds']}s; nặng nhất: #{st['heaviest'].join('; ')}")
          @caps[key] = cap
          [cap, key]
        end

        # Dựng 1 hình chiếu; lỗi của hình này không ảnh hưởng hình khác.
        def view_for(cap, cap_key, k, job)
          @views ||= {}
          vkey = "#{cap_key}|#{k}"
          return @views[vkey] if @views[vkey]

          v = Geometry.project(cap, k, job)
          st = v[:stats]
          log("VIEW #{k} '#{cap.name}': tam giác=#{st['tris']} cạnh vào=#{st['edges_in']} cạnh sau lọc trùng=#{st['edges']} " \
              "nét ra=#{st['lines']} mức=#{st['level']} thời gian=#{st['seconds']}s#{v[:notes].empty? ? '' : ' | ' + v[:notes].join(' | ')}")
          @views[vkey] = v
        end

        def page_output(project, pg, fmt, job)
          @views ||= {}
          pw, ph = Sheet.paper(project['paper'])
          cv = Canvas.new(fmt, pw, ph)
          tb = project['tb'].merge('sheet_name' => pg['name'], 'sheet_no' => pg['sheet_no'])
          notes = []
          failed = []
          extent = nil
          views = []
          mats = []
          begin
            if ModelScanner.page_status(model, pg) == 'nested'
              raise ArgumentError, "Trang #{pg['sheet_no']} là bộ phận nằm bên trong một Group khác (trang cũ từ bản 2.0.0). " \
                                   'Bấm "🧹 Dọn trang lỗi" để xoá, rồi triển khai Group cha.'
            end
            cap, ckey = capture_for(pg, project, job)
            mats = cap.materials.values
            extent = cap.stats['extent'] ||= begin
              pts = cap.edges.flatten(1)
              (0..2).map { |k| pts.map { |p| p[k] }.minmax.map { |n| n.round(1) } }
            end
            pg['views'].each do |k|
              job.progress("#{pg['sheet_no']}: dựng #{Geometry::VIEWS[k][0].downcase}", nil)
              begin
                if k == 'open'
                  door = project['door_tag'].to_s
                  if door.empty?
                    notes << 'Chưa chọn Tag cánh nên bỏ qua "Mặt đứng tháo cánh".'
                    next
                  end
                  c2, k2 = capture_for(pg, project, job, [door])
                  views << view_for(c2, k2, k, job)
                else
                  views << view_for(cap, ckey, k, job)
                end
                notes.concat(views.last[:notes])
              rescue Job::Cancelled
                raise
              rescue StandardError => e
                failed << k
                notes << "#{Geometry::VIEWS[k][0]}: lỗi – #{e.message}"
                log("VIEW #{k} THẤT BẠI pid=#{pg['pid']}: #{e.class}: #{e.message}\n  #{Array(e.backtrace).first(10).join("\n  ")}")
              end
            end
            # Mặt cắt: lần dựng đầu (sections = nil) tự đề xuất từ cấu tạo đo được trên mặt đứng.
            if pg['sections'].nil?
              begin
                pg['sections'] = SectionEngine.suggest(view_for(cap, ckey, 'front', job))
                log("SECTIONS đề xuất #{pg['sheet_no']}: #{pg['sections'].inspect}")
              rescue Job::Cancelled
                raise
              rescue StandardError => e
                pg['sections'] = []
                notes << "Không đề xuất được vị trí cắt: #{e.message}"
                log("SECTIONS lỗi #{pg['sheet_no']}: #{e.class}: #{e.message}\n  #{Array(e.backtrace).first(8).join("\n  ")}")
              end
            end
            pg['sections'].each do |sec|
              job.progress("#{pg['sheet_no']}: dựng mặt cắt #{sec['label']}-#{sec['label']}", nil)
              begin
                vkey = "#{ckey}|sec|#{sec['axis']}|#{sec['pos']}|#{sec['dir']}|#{sec['label']}"
                @views[vkey] ||= begin
                  sv = SectionEngine.project(cap, sec, job)
                  st = sv[:stats]
                  log("SECTION #{sec['label']} #{sec['axis']}=#{sec['pos']} dir=#{sec['dir']}: nét cắt=#{st['cut_segments']} " \
                      "vòng kín=#{st['cut_loops']} nét=#{st['lines']} mức=#{st['level']} #{st['seconds']}s")
                  sv
                end
                views << @views[vkey]
                notes.concat(@views[vkey][:notes])
              rescue Job::Cancelled
                raise
              rescue StandardError => e
                failed << SectionEngine.key(sec)
                notes << "MẶT CẮT #{sec['label']}-#{sec['label']}: lỗi – #{e.message}"
                log("SECTION #{sec['label']} THẤT BẠI: #{e.class}: #{e.message}\n  #{Array(e.backtrace).first(10).join("\n  ")}")
              end
            end
            # Chi tiết phóng to: dựng từ hình nguồn đã có trên trang.
            pg['details'].each do |det|
              src = views.find { |vv| vv[:key] == det['src'] }
              unless src
                notes << "CHI TIẾT #{det['n']}: hình nguồn #{det['src']} không còn trên trang."
                next
              end
              begin
                views << DetailEngine.build(src, det)
              rescue StandardError => e
                failed << DetailEngine.key(det)
                notes << e.message
                log("DETAIL #{det['n']} lỗi: #{e.class}: #{e.message}")
              end
            end
          rescue Job::Cancelled
            raise
          rescue ArgumentError => e
            notes << e.message
            log("PAGE #{pg['sheet_no']} pid=#{pg['pid']}: #{e.message}")
          end
          info = Sheet.render(cv, views, mats, pg, tb, pw, ph, notes)
          info['note'] = notes.empty? ? info['note'] : [info['note'], *notes].compact.uniq.join(' ')
          info['failed'] = failed
          info['complete'] = !views.empty? && failed.empty? && views.all? { |v| v[:level] == 1 }
          info['levels'] = views.map { |v| [v[:key], v[:level]] }.to_h
          info['sections'] = pg['sections']
          info['materials'] = mats.map { |m| m['name'] }
          info['extent'] = extent ? { 'x' => extent[0], 'y' => extent[1], 'z' => extent[2] } : nil
          [fmt == :svg ? cv.svg : cv.content, info]
        end

        def folder
          model.path.to_s.empty? ? nil : File.dirname(model.path)
        end

        def save_file(title, ext, bytes)
          name = title.to_s.gsub(/[<>:"\/\\|?*\x00-\x1f]/, ' ').strip[0, 90]
          name = 'AUTO LAYOUT' if name.empty?
          path = UI.savepanel("Lưu #{ext.upcase}", folder, "#{name}.#{ext}")
          return nil unless path

          path += ".#{ext}" unless File.extname(path).downcase == ".#{ext}"
          File.binwrite(path, bytes)
          path
        end
      end
    end
  end
end
