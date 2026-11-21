require 'sketchup.rb'

module MTDesign
  module LayoutTools
    PLUGIN_DIR = File.dirname(__FILE__) unless defined?(PLUGIN_DIR)

    require File.join(PLUGIN_DIR, 'version')
    require File.join(PLUGIN_DIR, 'updater')
    require File.join(PLUGIN_DIR, 'panel')
    # Dọn thư mục của các bản cũ (chỉ trong thư mục plugin này).
    OBSOLETE_DIRS = %w[mat_bang detail].freeze unless defined?(OBSOLETE_DIRS)
    def self.remove_obsolete
      OBSOLETE_DIRS.each do |d|
        path = File.join(PLUGIN_DIR, d)
        FileUtils.rm_rf(path) if File.directory?(path)
      end
    rescue StandardError => e
      puts "MT Layout Tools: không dọn được thư mục cũ: #{e.message}"
    end

    require 'fileutils'
    remove_obsolete
    require File.join(PLUGIN_DIR, 'auto_layout', 'auto_layout')

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

      cmd_matbang = UI::Command.new('AUTO LAYOUT PRO – Tự động triển khai') { AutoLayout.show }
      cmd_matbang.status_bar_text = 'Mở trình dàn trang: chọn model, tự động triển khai hình chiếu, DIM, khung tên, xuất PDF.'

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
