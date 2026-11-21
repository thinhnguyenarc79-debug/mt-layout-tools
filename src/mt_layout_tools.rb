# MT Layout Tools - loader
# Đặt file này cùng thư mục mt_layout_tools/ trong thư mục Plugins của SketchUp.
require 'sketchup.rb'
require 'extensions.rb'

module MTDesign
  module LayoutTools
    PLUGIN_ID   = 'mt_layout_tools'.freeze
    PLUGIN_NAME = 'MT Layout Tools'.freeze
    PLUGIN_DIR  = File.join(File.dirname(__FILE__), PLUGIN_ID).freeze

    require File.join(PLUGIN_DIR, 'version')

    unless file_loaded?(__FILE__)
      ext = SketchupExtension.new(PLUGIN_NAME, File.join(PLUGIN_DIR, 'main'))
      ext.description = 'Dàn trang bản vẽ nội thất - MT Design.'
      ext.version     = VERSION
      ext.creator     = 'MT Design (Kiến trúc & Nội thất Mạnh Trường)'
      ext.copyright   = "#{Time.now.year} MT Design"
      Sketchup.register_extension(ext, true)
      file_loaded(__FILE__)
    end
  end
end
