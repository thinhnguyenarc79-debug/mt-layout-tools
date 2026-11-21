require 'sketchup.rb'

module MTDesign
  module LayoutTools
    PLUGIN_DIR = File.dirname(__FILE__) unless defined?(PLUGIN_DIR)

    require File.join(PLUGIN_DIR, 'version')
    require File.join(PLUGIN_DIR, 'updater')
    require File.join(PLUGIN_DIR, 'panel')
    require File.join(PLUGIN_DIR, 'mat_bang', 'main')

    def self.icon(name)
      File.join(PLUGIN_DIR, 'icons', "#{name}.svg")
    end

    def self.show_about
      UI.messagebox("MT Layout Tools\nPhiên bản: #{VERSION}\nMT Design")
    end

    unless file_loaded?(__FILE__)
      # Nút chính trên thanh công cụ: mở bảng MT Layout Tools.
      cmd_panel = UI::Command.new('MT Layout Tools') { Panel.show }
      cmd_panel.tooltip         = 'MT Layout Tools'
      cmd_panel.status_bar_text = 'Mở bảng MT Layout Tools.'
      cmd_panel.small_icon      = icon('mt_layout')
      cmd_panel.large_icon      = icon('mt_layout')

      cmd_matbang = UI::Command.new('Dàn trang – MT Mặt Bằng') { MatBang.show }
      cmd_matbang.status_bar_text = 'Vẽ mặt bằng, triển khai hình chiếu, xuất PDF/DXF.'

      cmd_update = UI::Command.new('Cập nhật') { Updater.check(silent: false) }
      cmd_update.status_bar_text = 'Kiểm tra và cài bản mới nhất từ GitHub.'

      cmd_about = UI::Command.new('Thông tin phiên bản') { show_about }

      menu = UI.menu('Extensions').add_submenu('MT Layout Tools')
      menu.add_item(cmd_panel)
      menu.add_item(cmd_matbang)
      menu.add_item(cmd_update)
      menu.add_separator
      menu.add_item(cmd_about)

      tb = UI::Toolbar.new('MT Layout Tools')
      tb.add_item(cmd_panel)
      tb.restore

      # Tự kiểm tra bản mới khi mở SketchUp (tối đa 1 lần/ngày, không làm phiền nếu không có bản mới).
      UI.start_timer(5, false) { Updater.check(silent: true) if Updater.due_for_auto_check? }

      file_loaded(__FILE__)
    end
  end
end
