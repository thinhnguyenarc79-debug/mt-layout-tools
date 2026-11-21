require 'sketchup.rb'

module MTDesign
  module LayoutTools
    PLUGIN_DIR = File.dirname(__FILE__) unless defined?(PLUGIN_DIR)

    require File.join(PLUGIN_DIR, 'version')
    require File.join(PLUGIN_DIR, 'updater')

    def self.icon(name)
      File.join(PLUGIN_DIR, 'icons', "#{name}.svg")
    end

    def self.show_about
      UI.messagebox("MT Layout Tools\nPhiên bản: #{VERSION}\nMT Design")
    end

    unless file_loaded?(__FILE__)
      cmd_update = UI::Command.new('Cập nhật') { Updater.check(silent: false) }
      cmd_update.tooltip         = 'Cập nhật MT Layout Tools'
      cmd_update.status_bar_text = 'Kiểm tra và cài bản mới nhất từ GitHub.'
      cmd_update.small_icon      = icon('update')
      cmd_update.large_icon      = icon('update')

      cmd_about = UI::Command.new('Thông tin phiên bản') { show_about }

      menu = UI.menu('Extensions').add_submenu('MT Layout Tools')
      menu.add_item(cmd_update)
      menu.add_separator
      menu.add_item(cmd_about)

      tb = UI::Toolbar.new('MT Layout Tools')
      tb.add_item(cmd_update)
      tb.restore

      # Tự kiểm tra bản mới khi mở SketchUp (tối đa 1 lần/ngày, không làm phiền nếu không có bản mới).
      UI.start_timer(5, false) { Updater.check(silent: true) if Updater.due_for_auto_check? }

      file_loaded(__FILE__)
    end
  end
end
