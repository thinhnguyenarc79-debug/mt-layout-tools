# encoding: UTF-8
require 'sketchup.rb'
require 'json'
require 'tmpdir'
require_relative 'core/pdf'
require_relative 'core/job'
require_relative 'core/geometry'
require_relative 'core/hidden_fill'
require_relative 'core/part_classifier'
require_relative 'core/cabinet_recognizer'
require_relative 'core/extractor'
require_relative 'core/canvas'
require_relative 'core/dimension_engine'
require_relative 'core/section_engine'
require_relative 'core/annotation_engine'
require_relative 'core/detail_engine'
require_relative 'core/door_symbols'
require_relative 'core/sheet'
require_relative 'core/page_build'
require_relative 'core/model_scanner'
require_relative 'core/project_store'
require_relative 'core/draft_store'

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
            'pick' => :on_pick, 'cancel' => :on_cancel, 'pick_doors' => :on_pick_doors,
            'assign_parts' => :on_assign_parts, 'highlight_parts' => :on_highlight_parts, 'scan_parts' => :on_scan_parts,
            'highlight_part' => :on_highlight_part, 'add_models' => :on_add_models, 'autosave' => :on_autosave,
            'discard_draft' => :on_discard_draft
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

        # Bản dự án đang biên tập (chưa bấm Lưu) giữ trong bộ nhớ theo từng file SKP: đóng/mở lại cửa sổ
        # plugin không mất vị trí/khóa vừa chỉnh. Không ghi vào file SKP cho tới khi người dùng bấm 💾 Lưu.
        # (guid đổi mỗi lần lưu SKP -> dùng object_id của model đang mở trong phiên SketchUp này)
        def session_key
          model.object_id.to_s
        end

        def draft_dir
          @draft_dir || DraftStore.default_dir
        end

        def plugin_version
          defined?(LayoutTools::VERSION) ? LayoutTools::VERSION : ''
        end

        def remember(project)
          (@session ||= {})[session_key] = project
        end

        # MỞ DỰ ÁN: bản đang sửa trong phiên này (đóng/mở lại cửa sổ) > bản lưu chính trong SKP.
        # Nếu có bản nháp tự động mới hơn bản chính (vd. SketchUp tắt đột ngột) -> gửi kèm để người dùng chọn.
        # Không chạy lại dàn trang: vị trí từng hình đã lưu trong dữ liệu dự án.
        def on_ready(d, _arg)
          session = (@session ||= {})[session_key]
          main = ProjectStore.load(model)
          project = session || main
          draft = nil
          unless session
            dr = DraftStore.find(draft_dir, main['project_id'], model.path.to_s)
            if DraftStore.newer?(dr, main)
              draft = { 'draft_at' => dr['draft_at'], 'base_saved_at' => dr['base_saved_at'], 'skp_path' => dr['skp_path'],
                        'pages' => dr['pages'], 'project' => ProjectStore.clean(dr['project']),
                        'main_saved_at' => main['saved_at'], 'main_pages' => main['pages'].length }
            end
          end
          sel = selection_payload(project)
          push(d, 'init', { 'project' => project, 'models' => sel['models'], 'notice' => sel['notice'], 'status' => sel['status'],
                            'tags' => sel['tags'], 'views' => Geometry::VIEWS.transform_values(&:first),
                            'papers' => Sheet::PAPERS.keys, 'scales' => Sheet::SCALES, 'draft' => draft,
                            'skp_saved' => !model.path.to_s.empty?, 'unsaved_session' => !session.nil? && session != main })
        end

        # Tự lưu BẢN NHÁP (debounce phía giao diện). Không đụng bản lưu chính, không đụng file SKP.
        def on_autosave(d, arg)
          project = ProjectStore.clean(parse(arg))
          remember(project)
          at = DraftStore.write(draft_dir, project, 'skp_path' => model.path.to_s, 'model_title' => model.title.to_s,
                                                    'plugin_version' => plugin_version)
          push(d, 'autosaved', { 'at' => at })
        rescue StandardError => e
          log("autosave: #{e.class}: #{e.message}")
          push(d, 'autosave_error', { 'message' => "Lỗi lưu bản nháp: #{e.message}" })
        end

        # Người dùng chọn "Mở bản lưu chính": cất bản nháp làm dự phòng, không hỏi lại.
        def on_discard_draft(d, arg)
          DraftStore.dismiss(draft_dir, parse(arg)['project_id'])
          push(d, 'saved', { 'message' => 'Đang dùng bản lưu chính. Bản nháp đã được cất làm bản dự phòng.' })
        end

        # "Lấy đối tượng đang chọn" / "Quét lại": chỉ đọc selection hiện tại, không quét cả file.
        def on_scan(d, arg)
          raw = arg.to_s.empty? || arg.to_s == 'null' ? nil : parse(arg)
          push(d, 'models', selection_payload(raw ? ProjectStore.clean(raw) : nil))
        end

        # Tạo trang cho các model được chọn. arg: { project, pids }.
        # THÊM MODEL VÀO DỰ ÁN (giao dịch): chỉ dựng model MỚI vào vùng tạm; thành công mới gửi trang mới để ghép vào
        # cuối dự án. Trang cũ không bị đọc lại, dựng lại hay đổi bất kỳ dữ liệu nào. Lỗi/Hủy -> không thêm gì.
        # Model đã có trang -> báo lại để người dùng chọn Cập nhật hoặc Bỏ qua (không tạo trang trùng).
        def on_add_models(d, arg)
          data = parse(arg)
          project = ProjectStore.clean(data['project'])
          pids = Array(data['pids']).map(&:to_i).uniq
          raise ArgumentError, 'Chưa chọn model nào để thêm.' if pids.empty?

          res = ProjectStore.new_pages(project, pids, lambda do |pid|
            e = ModelScanner.find(model, pid)
            e && { 'name' => Geometry.instance_name(e), 'root' => !ModelScanner.nested?(e) }
          end)
          if res['pages'].empty?
            push(d, 'models_added', { 'pages' => [], 'existing' => res['existing'], 'missing' => res['missing'], 'failed' => [] })
            return
          end
          tmp = Marshal.load(Marshal.dump(project))
          ProjectStore.append_pages(tmp, res['pages'])
          build_next(d, tmp, res, 0, [], [])
        end

        # Dựng lần lượt từng trang mới (mỗi trang 1 Job, lỗi trang nào bỏ trang đó, Hủy -> bỏ hết).
        def build_next(d, tmp, res, i, ok, failed)
          if i >= res['pages'].length
            push(d, 'progress', { 'done' => true })
            push(d, 'models_added', { 'pages' => ok, 'existing' => res['existing'], 'missing' => res['missing'], 'failed' => failed })
            return
          end
          pg = tmp['pages'].find { |x| x['id'] == res['pages'][i]['id'] }
          pb = PageBuild.new(env, tmp, pg, :svg, ->(p, n) { ProjectStore.sheet_codes(tmp, { p['id'] => n })[p['id']].first })
          @job&.cancel!
          job = nil
          job = Job.new('add_model', log: ->(m) { log(m) },
                                     on_progress: lambda { |j|
                                       push(d, 'progress', { 'text' => "Thêm model #{i + 1}/#{res['pages'].length} – #{j.progress_text}",
                                                             'pct' => j.progress_pct })
                                     },
                                     on_done: lambda do |_r|
                                       @job = nil if @job.equal?(job)
                                       outs = pb.outputs
                                       if outs.empty? || outs.all? { |_, inf| Array(inf['view_keys']).empty? }
                                         failed << { 'pid' => pg['pid'], 'name' => pg['name'], 'message' => 'không dựng được hình chiếu nào' }
                                       else
                                         layout = Sheet.layout_of(outs)
                                         vp = pg['view_props'] || {}
                                         layout.each do |k, (x, y, sh, _w, _h, sc)|
                                           vp[k] = (vp[k] || {}).merge('placement_mode' => 'auto', 'x_mm' => x, 'y_mm' => y, 'sheet' => sh)
                                           vp[k]['base_scale'] = sc unless vp[k]['scale_override']
                                         end
                                         pg['view_props'] = ProjectStore.clean_view_props(vp)
                                         pg['sheet_count'] = outs.length
                                         ok << pg
                                       end
                                       build_next(d, tmp, res, i + 1, ok, failed)
                                     end,
                                     on_error: lambda do |e|
                                       @job = nil if @job.equal?(job)
                                       if e.is_a?(Job::Cancelled)
                                         push(d, 'progress', { 'done' => true })
                                         push(d, 'saved', { 'message' => 'Đã huỷ thêm model – dự án giữ nguyên như trước.' })
                                       else
                                         log("add_model #{pg['name']}: #{e.class}: #{e.message}")
                                         failed << { 'pid' => pg['pid'], 'name' => pg['name'], 'message' => e.message }
                                         build_next(d, tmp, res, i + 1, ok, failed)
                                       end
                                     end)
          pb.tasks.each { |t| job.add(t) }
          @job = job
          job.start
        end

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
          remember(project)
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
            info['layout'] = Sheet.layout_of(outs)
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

        # LƯU DỰ ÁN chính thức vào dữ liệu của file SKP (kiểm tra đọc lại). Không dàn trang lại.
        def on_save(d, arg)
          project = ProjectStore.save(model, ProjectStore.clean(parse(arg)))
          remember(project)
          begin
            DraftStore.clear(draft_dir, project['project_id'])
          rescue StandardError => e
            log("xoá bản nháp: #{e.message}")
          end
          skp = !model.path.to_s.empty?
          msg = if skp
                  'Đã lưu dự án vào dữ liệu file SKP. Nhấn Ctrl+S trong SketchUp để ghi file .skp xuống ổ đĩa.'
                else
                  'Đã lưu dự án vào model đang mở – NHƯNG file SketchUp chưa từng được lưu: hãy File > Save (Ctrl+S) ' \
                    'để đặt tên và ghi file .skp, nếu không dự án sẽ mất khi đóng SketchUp.'
                end
          push(d, 'project_saved', { 'saved_at' => project['saved_at'], 'project_id' => project['project_id'],
                                     'skp_saved' => skp, 'message' => msg })
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

        # XUẤT BẢN SAO .JSON: tệp dự phòng độc lập (schema + phiên bản + thời điểm), hỏi trước khi ghi đè.
        def on_save_json(d, arg)
          project = ProjectStore.clean(parse(arg))
          doc = ProjectStore.export_doc(project, 'plugin_version' => plugin_version, 'skp_path' => model.path.to_s)
          stamp = Time.now.strftime('%Y%m%d-%H%M')
          path = save_file("#{project['name']} - ban sao #{stamp}", 'json', JSON.pretty_generate(doc), true)
          push(d, 'saved', { 'message' => path ? "Đã xuất bản sao #{File.basename(path)}" : 'Đã huỷ – chưa xuất bản sao.' })
        end

        # MỞ DỰ ÁN từ bản sao .json: mở nguyên trạng (không dàn trang lại); model nguồn mất -> giữ trang, báo mất liên kết.
        def on_open_json(d, _arg)
          path = UI.openpanel('Mở dự án AUTO LAYOUT', folder, 'Dự án JSON|*.json||')
          return unless path

          project = ProjectStore.read_file(path)
          st = ModelScanner.statuses(model, project)
          lost = st.count { |_, v| v != 'ok' }
          msg = "Đã mở #{File.basename(path)} (#{project['pages'].length} trang)."
          msg += " #{lost} trang mất liên kết với model nguồn – vẫn giữ trang." if lost.positive?
          push(d, 'project', { 'project' => project, 'status' => st, 'message' => msg })
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

        # Gán cấu tạo: người dùng mở Group tủ, chọn 1 hoặc nhiều bộ phận rồi bấm "Gán" -> trả đường dẫn instance.
        def on_assign_parts(d, arg)
          data = parse(arg)
          root_pid = data['pid'].to_i
          path = model.active_path || []
          idx = path.index { |e| e.persistent_id == root_pid }
          raise ArgumentError, 'Hãy bấm đúp mở Group tủ của trang này, chọn các bộ phận bên trong rồi bấm "Gán".' if idx.nil?

          sel = model.selection.select { |e| ModelScanner.model_like?(e) }
          raise ArgumentError, 'Chưa chọn Group/Component bộ phận nào.' if sel.empty?

          prefix = path[(idx + 1)..-1].map(&:persistent_id)
          paths = sel.map { |e| (prefix + [e.persistent_id]).join('/') }
          push(d, 'assigned', { 'pid' => root_pid, 'paths' => paths, 'role' => data['role'].to_s,
                                'names' => sel.map { |e| Geometry.instance_name(e) } })
        end

        # Tô sáng 1 bộ phận: mở đúng ngữ cảnh (active_path) và CHỌN nó – không đổi vật liệu, Tag hay hình học.
        def on_highlight_part(d, arg)
          data = parse(arg)
          root = ModelScanner.find(model, data['pid'])
          raise ArgumentError, 'Không tìm thấy Group tủ.' unless root

          chain = data['path'].to_s.split('/').map { |x| model.find_entity_by_persistent_id(x.to_i) }
          raise ArgumentError, 'Bộ phận không còn trong model (đã xoá hoặc thay thế).' if chain.empty? || chain.any?(&:nil?)

          target = chain.last
          begin
            model.active_path = [root] + chain[0..-2]
          rescue StandardError => e
            log("highlight active_path: #{e.message}")
          end
          model.selection.clear
          model.selection.add(target)
          model.active_view.zoom(target)
          push(d, 'saved', { 'message' => "Đang chọn trong SketchUp: #{Geometry.instance_name(target)}" })
        end

        # Tô sáng NHIỀU bộ phận (vd. các cánh đề xuất) bằng khung màu vẽ tạm trên màn hình – không đổi vật liệu,
        # Tag hay hình học của model. Bấm Esc hoặc chọn công cụ khác để tắt.
        def on_highlight_parts(d, arg)
          data = parse(arg)
          root = ModelScanner.find(model, data['pid'])
          raise ArgumentError, 'Không tìm thấy Group tủ.' unless root

          ap = Array(model.active_path)
          if ap.include?(root)
            k = ap.index(root)
            model.active_path = k.zero? ? nil : ap[0...k]
          end
          base = Geometry.world_transform(model, root)
          boxes = []
          missing = 0
          Array(data['paths']).first(3000).each do |pth|
            chain = pth.to_s.split('/').map { |x| model.find_entity_by_persistent_id(x.to_i) }
            if chain.empty? || chain.any?(&:nil?)
              missing += 1
              next
            end
            tr = chain.inject(base) { |m, e| m * e.transformation }
            bb = chain.last.definition.bounds
            boxes << (0..7).map { |i| bb.corner(i).transform(tr) }
          end
          raise ArgumentError, 'Không còn bộ phận nào trong model để tô sáng.' if boxes.empty?

          model.select_tool(HighlightTool.new(boxes, data['label'].to_s))
          msg = "Đang tô sáng #{boxes.length} bộ phận (khung cam) – bấm Esc để tắt."
          msg += " #{missing} bộ phận không còn trong model." if missing.positive?
          push(d, 'saved', { 'message' => msg })
        end

        # QUÉT VÀ NHẬN DIỆN CẤU TẠO: đọc lại hình học từ SketchUp và chạy nhận diện cho trang đang mở.
        def on_scan_parts(d, arg)
          on_refresh(d, arg)
        end

        # Công cụ vẽ tạm (không sửa model)
        class HighlightTool
          EDGES = [[0, 1], [1, 3], [3, 2], [2, 0], [4, 5], [5, 7], [7, 6], [6, 4], [0, 4], [1, 5], [2, 6], [3, 7]].freeze

          def initialize(boxes, label)
            @boxes = boxes
            @label = label
          end

          def activate
            bb = Geom::BoundingBox.new
            @boxes.each { |c| c.each { |p| bb.add(p) } }
            @bb = bb
            Sketchup.active_model.active_view.invalidate
            Sketchup.status_text = "AUTO LAYOUT PRO: #{@label} #{@boxes.length} bộ phận – Esc để tắt"
          end

          def deactivate(view)
            view.invalidate
          end

          def getExtents
            @bb
          end

          def onKeyDown(key, _r, _f, _view)
            Sketchup.active_model.select_tool(nil) if key == 27
            false
          end

          def draw(view)
            view.line_width = 3
            view.drawing_color = Sketchup::Color.new(255, 140, 0)
            pts = []
            @boxes.each { |c| EDGES.each { |a, b| pts << c[a] << c[b] } }
            view.draw(GL_LINES, pts) unless pts.empty?
          end
        end

        def folder
          model.path.to_s.empty? ? nil : File.dirname(model.path)
        end

        def save_file(title, ext, bytes, confirm_overwrite = false)
          name = title.to_s.gsub(/[<>:"\/\\|?*\x00-\x1f]/, ' ').strip[0, 90]
          name = 'AUTO LAYOUT' if name.empty?
          path = UI.savepanel("Lưu #{ext.upcase}", folder, "#{name}.#{ext}")
          return nil unless path

          path += ".#{ext}" unless File.extname(path).downcase == ".#{ext}"
          if confirm_overwrite && File.exist?(path) &&
             UI.messagebox("Tệp #{File.basename(path)} đã có. Ghi đè?", MB_YESNO) != IDYES
            return nil
          end
          tmp = "#{path}.tmp"
          File.binwrite(tmp, bytes)
          File.rename(tmp, path)
          path
        end
      end
    end
  end
end
