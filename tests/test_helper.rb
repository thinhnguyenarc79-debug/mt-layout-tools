# encoding: UTF-8
# Chạy test ngoài SketchUp:  ruby tests/run_all.rb
# Kiểm phần lõi không phụ thuộc SketchUp API: chiếu, khử nét khuất, DIM, dàn trang, xuất PDF/SVG, dự án.
require 'minitest/autorun'
require 'json'
ROOT = File.expand_path('../src/mt_layout_tools/auto_layout/core', __dir__)
%w[pdf geometry canvas dimension_engine sheet project_store].each { |f| require File.join(ROOT, f) }

AL = MTDesign::LayoutTools::AutoLayout

module Fake
  module_function

  # Hộp chữ nhật (mm) thêm vào capture: 12 cạnh + 12 tam giác.
  def box(cap, x0, y0, z0, x1, y1, z1, mat = nil)
    c = [[x0, y0, z0], [x1, y0, z0], [x1, y1, z0], [x0, y1, z0], [x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]]
    [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]].each { |a, b| cap.edges << [c[a], c[b]] }
    [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]].each do |q|
      cap.triangles << [c[q[0]], c[q[1]], c[q[2]], mat]
      cap.triangles << [c[q[0]], c[q[2]], c[q[3]], mat]
    end
    cap
  end

  def capture(name = 'Test')
    AL::Geometry::Capture.new(name, [], [], {})
  end

  # Tủ 2410 x 350 x 2698, ván 18, khoang KHÔNG đều: 624 | 909 | 787 (giống ví dụ trong yêu cầu).
  def cabinet
    cap = capture('Tủ 2410')
    cap.materials['Gỗ'] = { 'name' => 'Gỗ', 'color' => '#8B6B4A' }
    t = 18
    w, d, h = 2410, 350, 2698
    box(cap, 0, 0, 0, t, d, h, 'Gỗ')
    box(cap, w - t, 0, 0, w, d, h, 'Gỗ')
    box(cap, t, 0, h - t, w - t, d, h, 'Gỗ')
    box(cap, t, 0, 60, w - t, d, 60 + t, 'Gỗ')
    x = t + 624
    box(cap, x, 0, 78, x + t, d, h - t, 'Gỗ')
    x2 = x + t + 909
    box(cap, x2, 0, 78, x2 + t, d, h - t, 'Gỗ')
    [500, 1000].each { |z| box(cap, x + t, 0, z, x2, d, z + t, 'Gỗ') }
    cap
  end
end
