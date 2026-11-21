# encoding: UTF-8
require 'sketchup.rb'
require 'json'
require 'tmpdir'
require_relative 'core/pdf'
require_relative 'core/geometry'
require_relative 'core/canvas'
require_relative 'core/dimension_engine'
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
            return
          end
          @cache = {}
          d = UI::HtmlDialog.new(dialog_title: 'AUTO LAYOUT PRO – MT Layout Tools', preferences_key: 'MTDesign_AutoLayout',
                                 width: 1400, height: 860, min_width: 1000, min_height: 620,
                                 resizable: true, scrollable: false, style: UI::HtmlDialog::STYLE_DIALOG)
          d.set_file(File.join(__dir__, 'ui', 'index.html'))
          {
            'ready' => :on_ready, 'scan' => :on_scan, 'generate' => :on_generate, 'render' => :on_render,
            'refresh' => :on_refresh, 'save' => :on_save, 'export_pdf' => :on_export_pdf,
            'export_svg' => :on_export_svg, 'save_json' => :on_save_json, 'open_json' => :on_open_json,
            'pick' => :on_pick
          }.each do |name, handler|
            d.add_action_callback(name) do |_ctx, arg|
              guard(d, name) { send(handler, d, arg) }
            end
          end
          d.set_on_closed { @cache = {} }
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
        def on_ready(d, _arg)
          push(d, 'init', { 'project' => ProjectStore.load(model), 'models' => ModelScanner.models(model),
                            'tags' => ModelScanner.tags(model), 'views' => Geometry::VIEWS.transform_values(&:first),
                            'papers' => Sheet::PAPERS.keys, 'scales' => Sheet::SCALES })
        end

        def on_scan(d, _arg)
          push(d, 'models', { 'models' => ModelScanner.models(model), 'tags' => ModelScanner.tags(model) })
        end

        # Tạo trang cho các model được chọn. arg: { project, pids }.
        def on_generate(d, arg)
          data = parse(arg)
          project = ProjectStore.clean(data['project'])
          pids = Array(data['pids']).map(&:to_i).uniq
          raise ArgumentError, 'Chưa chọn model nào để triển khai.' if pids.empty?

          created = []
          pids.each do |pid|
            e = ModelScanner.find(model, pid)
            next unless e

            no = format('A-%02d', project['pages'].length + 1)
            page = ProjectStore.clean_page(project['defaults'].merge('pid' => pid, 'name' => Geometry.instance_name(e),
                                                                     'sheet_no' => no, 'offsets' => {}))
            project['pages'] << page
            created << page['id']
          end
          raise ArgumentError, 'Không tìm thấy model đã chọn (có thể đã bị xoá).' if created.empty?

          push(d, 'project', { 'project' => project, 'open' => created.first,
                               'message' => "Đã tạo #{created.length} trang." })
        end

        # Dựng 1 trang để xem/biên tập. arg: { project, page_id }.
        def on_render(d, arg)
          data = parse(arg)
          project = ProjectStore.clean(data['project'])
          page = project['pages'].find { |p| p['id'] == data['page_id'] }
          raise ArgumentError, 'Không tìm thấy trang.' unless page

          t = Time.now
          svg, info = page_output(project, page, :svg)
          info['ms'] = ((Time.now - t) * 1000).round
          push(d, 'page', { 'page_id' => page['id'], 'svg' => svg, 'info' => info })
        end

        def on_refresh(d, arg)
          @cache = {}
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
          contents = []
          notes = []
          pages.each_with_index do |pg, i|
            Sketchup.status_text = "AUTO LAYOUT PRO: dựng trang #{i + 1}/#{pages.length}..."
            content, info = page_output(project, pg, :pdf)
            contents << content
            notes << "#{pg['sheet_no']}: #{info['note']}" if info['note']
          end
          Sketchup.status_text = ''
          bytes = Pdf.pdf_pages(contents, [pw * Pdf::MM_TO_PT, ph * Pdf::MM_TO_PT])
          name = pages.length == 1 ? "#{pages[0]['sheet_no']} #{pages[0]['name']}" : project['name']
          path = save_file(name, 'pdf', bytes)
          msg = path ? "Đã xuất #{pages.length} trang: #{File.basename(path)}" : 'Đã huỷ.'
          msg += " Lưu ý – #{notes.join('; ')}" unless notes.empty?
          push(d, 'saved', { 'message' => msg })
          UI.openURL("file:///#{path.tr('\\', '/')}") if path
        end

        def on_export_svg(d, arg)
          data = parse(arg)
          project = ProjectStore.clean(data['project'])
          page = project['pages'].find { |p| p['id'] == data['page_id'] }
          raise ArgumentError, 'Không tìm thấy trang.' unless page

          svg, = page_output(project, page, :svg)
          path = save_file("#{page['sheet_no']} #{page['name']}", 'svg', svg)
          push(d, 'saved', { 'message' => path ? "Đã xuất #{File.basename(path)}" : 'Đã huỷ.' })
        end

        def on_save_json(d, arg)
          project = ProjectStore.clean(parse(arg))
          path = save_file(project['name'], 'json', JSON.pretty_generate(project))
          push(d, 'saved', { 'message' => path ? "Đã lưu #{File.basename(path)}" : 'Đã huỷ.' })
        end

        def on_open_json(d, _arg)
          path = UI.openpanel('Mở dự án AUTO LAYOUT', folder, 'Dự án JSON|*.json||')
          return unless path

          push(d, 'project', { 'project' => ProjectStore.read_file(path), 'message' => "Đã mở #{File.basename(path)}" })
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
        def capture_for(pg, project, extra = [])
          e = ModelScanner.find(model, pg['pid'])
          raise ArgumentError, "Trang #{pg['sheet_no']}: đối tượng gốc đã bị xoá hoặc thay thế trong SketchUp." unless e

          exclude = (project['exclude_tags'] + extra).uniq
          key = [pg['pid'], pg['front'], exclude.sort].to_json
          @cache ||= {}
          @cache[key] ||= Geometry.capture(model, e, exclude, pg['front'])
        end

        def page_output(project, pg, fmt)
          pw, ph = Sheet.paper(project['paper'])
          cv = Canvas.new(fmt, pw, ph)
          tb = project['tb'].merge('sheet_name' => pg['name'], 'sheet_no' => pg['sheet_no'])
          begin
            cap = capture_for(pg, project)
            views = pg['views'].map do |k|
              if k == 'open'
                door = project['door_tag'].to_s
                next nil if door.empty?

                Geometry.project(capture_for(pg, project, [door]), k)
              else
                Geometry.project(cap, k)
              end
            end.compact
            info = Sheet.render(cv, views, cap.materials.values, pg, tb, pw, ph)
            if pg['views'].include?('open') && project['door_tag'].to_s.empty?
              info['note'] = [info['note'], 'Chưa chọn Tag cánh nên bỏ qua "Mặt đứng tháo cánh".'].compact.join(' ')
            end
          rescue ArgumentError => e
            info = Sheet.render(cv, [], [], pg, tb, pw, ph)
            info['note'] = e.message
          end
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
