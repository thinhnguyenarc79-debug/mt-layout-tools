# encoding: UTF-8
require 'sketchup.rb'
require 'json'
require_relative 'pdf'
require_relative 'geometry'
require_relative 'sheet'

module MTDesign
  module LayoutTools
    # "Triển khai chi tiết A3": form khung tên -> xuất PDF hình chiếu + kích thước cho đối tượng đang chọn.
    module Detail
      DICT = 'MTDesign_LayoutTools_Detail'.freeze
      FIELDS = %w[client project location company company_info lead designer checker drafter
                  sheet_name date sheet_no].freeze
      VIEW_KEYS = %w[front open left right back top iso].freeze
      DEFAULTS = {
        'company' => 'MT DESIGN', 'company_info' => 'Kiến trúc & Nội thất Mạnh Trường',
        'sheet_no' => 'A-01', 'views' => %w[front open left top iso], 'scale' => 0, 'min_gap' => 0, 'fill' => true, 'door_tag' => ''
      }.freeze

      class << self
        def show
          if @dialog && @dialog.visible?
            @dialog.bring_to_front
            return
          end
          d = UI::HtmlDialog.new(dialog_title: 'Triển khai chi tiết A3', preferences_key: 'MTDesign_LayoutTools_Detail',
                                 width: 460, height: 720, resizable: true, scrollable: true,
                                 style: UI::HtmlDialog::STYLE_DIALOG)
          d.set_file(File.join(__dir__, 'ui', 'detail.html'))
          d.add_action_callback('ready') { |_c| push(d, 'load', load_opts(Sketchup.active_model)) }
          d.add_action_callback('export') { |_c, json| export(d, json) }
          @dialog = d
          d.show
        end

        def load_opts(model)
          saved = model.get_attribute(DICT, 'opts')
          opts = DEFAULTS.merge(saved ? JSON.parse(saved) : {})
          sel = model.selection.first
          if sel.is_a?(Sketchup::Group) || sel.is_a?(Sketchup::ComponentInstance)
            opts['sheet_name'] = Geometry.instance_name(sel)
          end
          opts['date'] = Time.now.strftime('%d.%m.%Y')
          opts['tags'] = model.layers.map(&:name)
          if opts['door_tag'].to_s.empty?
            guess = opts['tags'].find { |n| n =~ /c[aá]nh|door/i }
            opts['door_tag'] = guess.to_s
          end
          opts
        rescue JSON::ParserError
          DEFAULTS.dup
        end

        def clean(raw)
          o = {}
          FIELDS.each { |k| o[k] = raw[k].to_s.strip[0, 200] }
          o['views'] = Array(raw['views']).map(&:to_s) & VIEW_KEYS
          o['scale'] = raw['scale'].to_i.clamp(0, 200)
          o['min_gap'] = raw['min_gap'].to_f.clamp(0, 500)
          o['fill'] = raw['fill'] == true
          o['door_tag'] = raw['door_tag'].to_s[0, 200]
          o
        end

        def export(dialog, json)
          model = Sketchup.active_model
          opts = clean(JSON.parse(json.to_s))
          raise ArgumentError, 'Chọn ít nhất 1 hình chiếu.' if opts['views'].empty?

          keep = opts.reject { |k, _| %w[sheet_name date].include?(k) }
          model.set_attribute(DICT, 'opts', JSON.generate(keep))
          Sketchup.status_text = 'MT Layout Tools: đang dựng hình chiếu...'
          caps = { 'all' => Geometry.capture(model) }
          if opts['views'].include?('open')
            raise ArgumentError, 'Hình "Mặt đứng tháo cánh" cần chọn Tag cánh.' if opts['door_tag'].empty?

            caps['open'] = Geometry.capture(model, [opts['door_tag']])
          end
          bytes = Sheet.build(caps, opts)
          Sketchup.status_text = ''
          path = save(model, "#{opts['sheet_no']} #{opts['sheet_name']}", bytes)
          push(dialog, 'done', path ? "Đã xuất #{File.basename(path)}" : 'Đã hủy lưu.')
          UI.openURL("file:///#{path.tr('\\', '/')}") if path
        rescue ArgumentError, JSON::ParserError => e
          Sketchup.status_text = ''
          push(dialog, 'error', e.message)
        rescue StandardError => e
          Sketchup.status_text = ''
          warn("[MT Layout Tools] #{e.class}: #{e.message}\n#{e.backtrace.first(6).join("\n")}")
          push(dialog, 'error', "Lỗi: #{e.message}")
        end

        def save(model, title, bytes)
          name = title.gsub(/[<>:"\/\\|?*\x00-\x1f]/, ' ').strip[0, 90]
          name = 'MT Chi tiet' if name.empty?
          dir = model.path.to_s.empty? ? nil : File.dirname(model.path)
          path = UI.savepanel('Lưu PDF', dir, "#{name}.pdf")
          return nil unless path

          path += '.pdf' unless File.extname(path).downcase == '.pdf'
          File.binwrite(path, bytes)
          path
        end

        def push(dialog, kind, data)
          json = JSON.generate(data).gsub("\u2028", '\\u2028').gsub("\u2029", '\\u2029')
          dialog.execute_script("window.MTD && MTD.#{kind}(#{json});")
        end
      end
    end
  end
end
