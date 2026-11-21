# encoding: UTF-8
require 'sketchup.rb'
require 'json'
require 'tmpdir'
require_relative 'core/pdf'
require_relative 'core/job'
require_relative 'core/geometry'
require_relative 'core/door_detector'
require_relative 'core/extractor'
require_relative 'core/canvas'
require_relative 'core/dimension_engine'
require_relative 'core/section_engine'
require_relative 'core/annotation_engine'
require_relative 'core/detail_engine'
require_relative 'core/sheet'
require_relative 'core/page_build'
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
            'pick' => :on_pick, 'cancel' => :on_cancel, 'pick_doors' => :on_pick_doors
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

        # Cache dùng chung giữa các lần dựng (bị xoá khi bấm "Cập nhật bản vẽ" hoặc đóng cửa sổ):
        #  :caps  khoá (pid, hướng, tag loại) -> Capture ;  :views khoá capture + hình -> hình đã khử nét
        def reset_cache
          @cache = {}
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

        # ---------------- tác vụ dài: Job Engine (máy trạng thái, không Fiber) ----------------
        # Môi trường cho PageBuild: tra đối tượng, cache, dựng CaptureBuilder, ghi log.
        class Env
          attr_reader :cache

          def initialize(cache, extractor)
            @cache = cache
            @extractor = extractor
          end

          def model
            Sketchup.active_model
          end

          def find(pid)
            ModelScanner.find(model, pid)
          end

          def page_status(pg)
            ModelScanner.page_status(model, pg)
          end

          def capture_builder(entity, exclude, front, doors = {})
            @extractor.builder(model, entity, exclude, front, doors)
          end

          def log(msg)
            AutoLayout.log(msg)
          end
        end

        def env
          @cache ||= {}
          @extractor ||= Extractor.new
          Env.new(@cache, @extractor)
        end

        # Chỉ 1 Job tại một thời điểm; Job mới huỷ Job cũ. tasks: mảng Task; on_ok: lambda chạy khi xong.
        def start_job(d, name, tasks, on_ok)
          @job&.cancel!
          job = nil
          job = Job.new(name,
                        log: ->(m) { log(m) },
                        on_progress: ->(j) { push(d, 'progress', { 'text' => j.progress_text, 'pct' => j.progress_pct }) },
                        on_done: lambda do |_r|
                          @job = nil if @job.equal?(job)
                          push(d, 'progress', { 'done' => true })
                          begin
                            on_ok.call
                          rescue StandardError => e
                            log("#{name} (hoàn tất): #{e.class}: #{e.message}\n  #{Array(e.backtrace).first(8).join("\n  ")}")
                            push(d, 'error', { 'cmd' => name, 'message' => "Lỗi #{e.class}: #{e.message} (chi tiết: #{LOG})" })
                          end
                        end,
                        on_error: lambda do |e|
                          replaced = !@job.equal?(job)
                          @job = nil unless replaced
                          push(d, 'progress', { 'done' => true }) unless replaced
                          if e.is_a?(Job::Cancelled)
                            push(d, 'saved', { 'message' => 'Đã huỷ tác vụ.' }) unless replaced
                          elsif e.is_a?(ArgumentError)
                            push(d, 'error', { 'cmd' => name, 'message' => e.message })
                          else
                            push(d, 'error', { 'cmd' => name, 'message' => "Lỗi #{e.class}: #{e.message} (chi tiết: #{LOG})" })
                          end
                        end)
          tasks.each { |t| job.add(t) }
          @job = job
          job.start
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

          t0 = Time.now
          pb = PageBuild.new(env, project, page, :svg, lambda { |p, n|
            ProjectStore.sheet_codes(project, { p['id'] => n })[p['id']].first
          })
          want = data['sheet'].to_i
          start_job(d, 'render', pb.tasks, lambda do
            outs = pb.outputs
            svg, info = outs[want.clamp(0, outs.length - 1)]
            info['ms'] = ((Time.now - t0) * 1000).round
            push(d, 'page', { 'page_id' => page['id'], 'svg' => svg, 'info' => info })
          end)
        end

        # "Cập nhật bản vẽ": đọc lại hình học từ SketchUp (bỏ cache) rồi dựng lại.
        def on_refresh(d, arg)
          @job&.cancel!
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
          only = data['sheet'] # xuất riêng 1 tờ (nút "PDF tờ này")
          # Mã tờ: như danh sách TRANG GIẤY; khi xuất tất cả thì đánh liên tiếp theo số tờ THỰC dựng được lúc xuất.
          codes0 = ProjectStore.sheet_codes(project)
          prev = nil
          numbering = lambda do |pg, n|
            base = ids.empty? && pg['auto_no'] && prev ? ProjectStore.increment(prev, 1) : codes0[pg['id']].first
            prev = ProjectStore.increment(base, n - 1)
            base
          end
          builds = pages.map { |pg| PageBuild.new(env, project, pg, :pdf, numbering) }
          tasks = builds.each_with_index.flat_map do |pb, i|
            [Job.once('trang') { |j| j.progress("Xuất PDF: trang #{i + 1}/#{pages.length} (#{pages[i]['sheet_no']})", 100.0 * i / pages.length) }] + pb.tasks
          end
          start_job(d, 'export_pdf', tasks, lambda do
            contents = builds.flat_map { |pb| pb.outputs.map(&:first) }
            contents = [builds[0].outputs[only.to_i.clamp(0, builds[0].outputs.length - 1)][0]] if !only.nil? && builds.length == 1
            notes = builds.each_with_index.filter_map { |pb, i| "#{pages[i]['sheet_no']}: #{pb.output[1]['note']}" if pb.output[1]['note'] }
            bytes = Pdf.pdf_pages(contents, [pw * Pdf::MM_TO_PT, ph * Pdf::MM_TO_PT])
            name = if !only.nil? && builds.length == 1
                     "#{builds[0].outputs[only.to_i.clamp(0, builds[0].outputs.length - 1)][1]['code']} #{pages[0]['name']}"
                   elsif pages.length == 1 then "#{pages[0]['sheet_no']} #{pages[0]['name']}"
                   else project['name']
                   end
            path = save_file(name, 'pdf', bytes)
            push(d, 'sheets', builds.each_with_index.to_h { |pb, i| [pages[i]['id'], pb.outputs.length] })
            msg = path ? "Đã xuất #{contents.length} tờ: #{File.basename(path)}" : 'Đã huỷ lưu.'
            msg += " Lưu ý – #{notes.join(' | ')}" unless notes.empty?
            push(d, notes.empty? ? 'saved' : 'warn', { 'message' => msg })
            UI.openURL("file:///#{path.tr('\\', '/')}") if path
          end)
        end

        def on_export_svg(d, arg)
          data = parse(arg)
          project = ProjectStore.clean(data['project'])
          page = project['pages'].find { |p| p['id'] == data['page_id'] }
          raise ArgumentError, 'Không tìm thấy trang.' unless page

          pb = PageBuild.new(env, project, page, :svg, lambda { |p, n|
            ProjectStore.sheet_codes(project, { p['id'] => n })[p['id']].first
          })
          start_job(d, 'export_svg', pb.tasks, lambda do
            idx = data['sheet'].to_i.clamp(0, pb.outputs.length - 1)
            path = save_file("#{pb.outputs[idx][1]['code']} #{page['name']}", 'svg', pb.outputs[idx][0])
            push(d, 'saved', { 'message' => path ? "Đã xuất #{File.basename(path)}" : 'Đã huỷ lưu.' })
          end)
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

        # CHỌN CÁNH TRONG SKETCHUP: người dùng mở Group tủ (bấm đúp), chọn các Group/Component cánh rồi bấm nút.
        # Lưu đường dẫn persistent_id tính từ Group tủ -> nhận diện đúng cả cánh lồng nhiều cấp. Không sửa model.
        def on_pick_doors(d, arg)
          root_pid = arg.to_i
          path = model.active_path || []
          idx = path.index { |e| e.persistent_id == root_pid }
          sel = model.selection.select { |e| ModelScanner.model_like?(e) }
          if idx.nil?
            raise ArgumentError, 'Hãy bấm đúp để mở Group tủ của trang này, chọn các cánh bên trong rồi bấm lại "CHỌN CÁNH TRONG SKETCHUP".'
          end
          raise ArgumentError, 'Chưa chọn Group/Component cánh nào (đang mở Group tủ nhưng chưa chọn cánh).' if sel.empty?

          prefix = path[(idx + 1)..-1].map(&:persistent_id)
          paths = sel.map { |e| (prefix + [e.persistent_id]).join('/') }
          names = sel.map { |e| Geometry.instance_name(e) }
          push(d, 'doors', { 'pid' => root_pid, 'paths' => paths, 'names' => names })
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
