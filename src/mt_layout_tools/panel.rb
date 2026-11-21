require 'sketchup.rb'

module MTDesign
  module LayoutTools
    # Bảng điều khiển mở ra khi bấm biểu tượng MT Layout Tools trên thanh công cụ.
    module Panel
      HTML_FILE = File.join(File.dirname(__FILE__), 'ui', 'panel.html')

      class << self
        def show
          if @dialog && @dialog.visible?
            @dialog.bring_to_front
            return
          end
          @dialog = build
          @dialog.show
        end

        def set_status(text)
          return unless @dialog && @dialog.visible?
          @dialog.execute_script("setStatus(#{text.to_s.inspect})")
        end

        def refresh_version
          return unless @dialog && @dialog.visible?
          @dialog.execute_script("setVersion(#{LayoutTools::VERSION.inspect})")
        end

        private

        def build
          d = UI::HtmlDialog.new(
            dialog_title:    'MT Layout Tools',
            preferences_key: 'MTDesign_LayoutTools_Panel',
            scrollable:      false,
            resizable:       true,
            width:           300,
            height:          260,
            style:           UI::HtmlDialog::STYLE_UTILITY
          )
          d.set_file(HTML_FILE)
          d.add_action_callback('ready') do |_ctx|
            d.execute_script("setVersion(#{VERSION.inspect})")
          end
          d.add_action_callback('update') do |_ctx|
            set_status('Đang kiểm tra cập nhật...')
            Updater.check(silent: false)
          end
          d.add_action_callback('about') { |_ctx| LayoutTools.show_about }
          d
        end
      end
    end
  end
end
