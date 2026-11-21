# encoding: UTF-8
require 'sketchup.rb'
require 'json'
require 'tempfile'
require 'csv'
require_relative 'schema'
require_relative 'drawing'
require_relative 'model'
require_relative 'views'

module MTDesign
  module MatBang
    MAX_BYTES = 10 * 1024 * 1024 unless defined?(MAX_BYTES)
    @dialogs ||= {}

    def self.show
      model = Sketchup.active_model
      unless defined?(UI::HtmlDialog) && Sketchup.version.to_i >= 21
        UI.messagebox('MT Mặt Bằng cần SketchUp Desktop 2021 hoặc mới hơn.')
        return
      end
      if @dialogs[model]
        @dialogs[model].bring_to_front
        return
      end

      dialog = UI::HtmlDialog.new(
        dialog_title: 'MT Mặt Bằng',
        preferences_key: 'MTDesign.MatBang',
        scrollable: false, resizable: true,
        width: 1210, height: 810,
        min_width: 680, min_height: 470,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dialog.set_file(File.join(__dir__, 'ui', 'index.html'))
      dialog.set_on_closed { @dialogs.delete(model) }
      dialog.add_action_callback('mt_ready') do
        respond(dialog) { saved_project(model) }
      end
      dialog.add_action_callback('mt_request') do |_context, cmd, json|
        respond(dialog) do
          unless Sketchup.active_model == model
            raise ArgumentError, 'Chuyển về model SketchUp đang liên kết với cửa sổ này.'
          end
          raise ArgumentError, 'Dữ liệu mặt bằng quá lớn.' if json.bytesize > MAX_BYTES

          dispatch(model, cmd, Schema.object(JSON.parse(json)))
        end
      end
      @dialogs[model] = dialog
      dialog.show
    end

    def self.saved_project(model)
      json = model.get_attribute(Model3D::DICT, 'project')
      return {} unless json

      { plan: Schema.project(JSON.parse(json)), saved: true }
    end

    def self.respond(dialog)
      result = yield || {}
      script(dialog, result)
    rescue ArgumentError, JSON::ParserError => e
      script(dialog, { message: e.is_a?(JSON::ParserError) ? 'File JSON không hợp lệ.' : e.message, error: true })
    rescue StandardError => e
      warn("[MT Mặt Bằng] #{e.class}: #{e.message}\n#{e.backtrace.first(6).join("\n")}")
      script(dialog, { message: 'Không thực hiện được lệnh: ' + e.message.to_s, error: true })
    end

    def self.script(dialog, result)
      json = JSON.generate(result).gsub("\u2028", '\\u2028').gsub("\u2029", '\\u2029')
      dialog.execute_script("window.MT && window.MT.receive(#{json});")
    end

    def self.store_project(model, plan)
      model.start_operation('MT Mặt Bằng – Lưu mặt bằng', true)
      begin
        model.set_attribute(Model3D::DICT, 'project', JSON.generate(plan))
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      end
    end

    def self.dispatch(model, cmd, raw)
      case cmd
      when 'save'
        store_project(model, Schema.project(raw['plan']))
        { saved: true, message: 'Đã lưu mặt bằng trong model. Nhấn Ctrl+S / Cmd+S bên SketchUp để lưu file SKP.' }
      when 'build'
        plan = Schema.project(raw['plan'])
        root, changed = Model3D.build(model, plan, Schema.boxes(raw['parts'], plan))
        model.selection.clear
        model.selection.add(root)
        model.active_view.zoom(model.selection)
        { saved: true, message: "Đã đồng bộ 3D. #{changed} nhóm được tạo, cập nhật hoặc xóa." }
      when 'save_file'
        plan = Schema.project(raw['plan'])
        save_as(model, plan['name'], 'json', JSON.pretty_generate(plan))
      when 'load_file'
        path = UI.openpanel('Mở mặt bằng JSON', project_folder(model))
        return {} unless path
        raise ArgumentError, 'File mặt bằng quá lớn.' if File.size(path) > MAX_BYTES

        { plan: Schema.project(JSON.parse(File.binread(path))), replace: true, message: 'Đã nhập mặt bằng JSON.' }
      when 'csv'
        plan = Schema.project(raw['plan'])
        save_as(model, plan['name'] + ' - Thong ke', 'csv', quantity_csv(plan))
      when 'pdf', 'dxf', 'views_pdf', 'views_dxf'
        options = Schema.settings(raw)
        if cmd.start_with?('views_')
          name, geometry = Views.capture(model)
          options['name'] = name
          format = cmd.sub('views_', '')
          suffix = ' - Hinh chieu'
        else
          geometry = Schema.scene(raw['scene'])
          format = cmd
          suffix = ' - Mat bang'
        end
        content = format == 'pdf' ? Drawing.pdf(geometry, options) : Drawing.dxf(geometry)
        save_as(model, options['name'] + suffix, format, content)
      else
        raise ArgumentError, 'Lệnh plugin không hợp lệ.'
      end
    end

    def self.project_folder(model)
      model.path.to_s.empty? ? nil : File.dirname(model.path)
    end

    def self.quantity_csv(plan)
      floors = plan['items'].select { |o| o['type'] == 'floor' }
      furniture = plan['items'].select { |o| o['type'] == 'furniture' }
      raise ArgumentError, 'Cần ít nhất một sàn hoặc một nhóm nội thất để thống kê.' if floors.empty? && furniture.empty?

      rows = [['Hạng mục', 'Tên', 'Số lượng', 'Rộng (mm)', 'Sâu (mm)', 'Cao hoặc dày (mm)', 'Diện tích (m²)', 'Màu']]
      floors.each do |o|
        p = o['p']
        area = p.each_index.sum { |i| a, b = p[i], p[(i + 1) % p.length]; a[0] * b[1] - a[1] * b[0] }.abs / 2_000_000
        rows << ['Sàn', csv_name(o['name']), 1, nil, nil, o['t'].round(2), area.round(3), o['c']]
      end
      furniture.group_by { |o| o.values_at('kind', 'name', 'w', 'd', 'h', 'c') }.each do |(_, name, w, d, h, color), matching|
        rows << ['Nội thất', csv_name(name), matching.length, w.round(2), d.round(2), h.round(2), nil, color]
      end
      "\uFEFF" + CSV.generate(row_sep: "\r\n") { |csv| rows.each { |row| csv << row } }
    end

    def self.csv_name(name)
      name.lstrip.match?(/\A[=+@-]/) ? "'" + name : name
    end

    def self.save_as(model, title, format, bytes)
      filename = title.gsub(/[<>:"\/\\|?*\x00-\x1f]/, ' ').strip[0, 92]
      filename = 'MT Mat Bang' if filename.empty?
      path = UI.savepanel("Lưu #{format.upcase}", project_folder(model), filename + '.' + format)
      return {} unless path

      unless File.extname(path).downcase == '.' + format
        path += '.' + format
        if File.exist?(path) && UI.messagebox('Tệp đã tồn tại. Ghi đè tệp này?', MB_YESNO) != IDYES
          return {}
        end
      end
      Tempfile.create(['.mt-mat-bang-', '.tmp'], File.dirname(path)) do |file|
        file.binmode
        file.write(bytes)
        file.close
        File.rename(file.path, path)
      end
      { message: 'Đã xuất ' + File.basename(path) }
    end

    # Menu/nút được đăng ký trong MT Layout Tools (mt_layout_tools/main.rb).
  end
end
