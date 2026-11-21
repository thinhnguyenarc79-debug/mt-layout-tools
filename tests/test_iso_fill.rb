# encoding: UTF-8
# v2.7: tô mặt có che khuất chính xác (BSP) – sửa lỗi tam giác nâu/trắng đè lên cánh ở phối cảnh trục đo.
# Cách kiểm: lấy mẫu dày trên hình chiếu, so mặt "trên cùng" theo thứ tự tô với mặt gần nhất thật (z-buffer
# tính trực tiếp từ tam giác). Sai lệch phải ~0 (chỉ cho phép điểm rơi đúng trên mép mặt).
require_relative 'test_helper'
require_relative 'test_doors'
require_relative 'test_view_scale'
require_relative 'test_parts'

module IsoCheck
  module_function

  HF = AL::Geometry::HiddenFill

  def inside?(pts, x, y)
    sign = 0
    pts.each_with_index do |a, i|
      b = pts[(i + 1) % pts.length]
      c = (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0])
      next if c.abs < 1.0e-9

      s = c.positive? ? 1 : -1
      return false if sign != 0 && s != sign

      sign = s
    end
    true
  end

  def depth_at(p3, x, y)
    a, b, c = p3
    den = (b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1])
    return nil if den.abs < 1.0e-9

    u = ((x - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (y - a[1])) / den
    v = ((b[0] - a[0]) * (y - a[1]) - (x - a[0]) * (b[1] - a[1])) / den
    a[2] + u * (b[2] - a[2]) + v * (c[2] - a[2])
  end

  # Thứ tự tô của BSP: [[điểm chiếu], tam giác gốc]
  def bsp_order(cap, fn)
    tree = HF::Builder.new(cap.triangles)
    nil until tree.step(AL::Geometry::NO_JOB)
    raise 'cây BSP vượt giới hạn' if tree.failed?

    out = []
    HF::Walker.new(tree.nodes, HF.viewer_dir(fn)).each_piece(AL::Geometry::NO_JOB) do |pl|
      out << [pl[0].map { |p| fn.call(p) }, pl[5]]
    end
    out
  end

  # Cách cũ (đã bỏ): sắp theo độ sâu tâm tam giác.
  def centroid_order(cap, fn)
    cap.triangles.map { |t| [t[0, 3].map { |p| fn.call(p) }, t] }.sort_by { |p3, _| p3.sum { |p| p[2] } }
  end

  # Số điểm mẫu mà mặt vẽ sau cùng KHÔNG phải mặt gần người xem nhất.
  def mismatches(cap, order, fn, n = 90)
    proj = cap.triangles.map { |t| [t[0, 3].map { |p| fn.call(p) }, t] }
    xs = proj.flat_map { |p3, _| p3.map { |p| p[0] } }
    ys = proj.flat_map { |p3, _| p3.map { |p| p[1] } }
    bad = 0
    total = 0
    (0...n).each do |i|
      (0...n).each do |j|
        x = xs.min + (xs.max - xs.min) * (i + 0.5) / n
        y = ys.min + (ys.max - ys.min) * (j + 0.5) / n
        truth = nil
        proj.each do |p3, _t|
          next unless inside?(p3, x, y)

          z = depth_at(p3, x, y)
          truth = z if z && (truth.nil? || z > truth)
        end
        next unless truth

        total += 1
        top = order.reverse_each.find { |pts, _| inside?(pts, x, y) && depth_at(pts[0, 3], x, y) }
        z = top && depth_at(top[0][0, 3], x, y)
        bad += 1 if z.nil? || (z - truth).abs > 0.5
      end
    end
    [bad, total]
  end

  def rotate(cap, ax, ay, az)
    r = lambda do |p|
      x, y, z = p
      y, z = y * Math.cos(ax) - z * Math.sin(ax), y * Math.sin(ax) + z * Math.cos(ax)
      x, z = x * Math.cos(ay) + z * Math.sin(ay), -x * Math.sin(ay) + z * Math.cos(ay)
      x, y = x * Math.cos(az) - y * Math.sin(az), x * Math.sin(az) + y * Math.cos(az)
      [x, y, z]
    end
    AL::Geometry::Capture.new(cap.name, cap.edges.map { |a, b| [r.call(a), r.call(b)] },
                              cap.triangles.map { |a, b, c, m| [r.call(a), r.call(b), r.call(c), m] }, cap.materials)
  end

  # Tủ thật hơn: hông, nóc, đáy, hậu, 3 đợt, 2 cánh trắng, tay nắm, 1 đợt xuyên vào hông (mặt giao cắt).
  def cabinet
    cap = DoorFake.cabinet_with_doors
    Fake.box(cap, 18, 330, 78, 2392, 348, 2680, 'Gỗ')           # hậu
    Fake.box(cap, 0, 100, 1500, 640, 330, 1518, 'Gỗ')           # đợt xuyên qua hông trái
    [[300, 1300], [1100, 1300], [1900, 1300]].each { |x, z| Fake.box(cap, x, -60, z, x + 22, -20, z + 160, 'Inox') }
    cap.materials['Inox'] = { 'name' => 'Inox', 'color' => '#9AA0A6' }
    cap
  end
end

class TestIsoFill < Minitest::Test
  ISO = AL::Geometry::VIEWS['iso'][1]

  def check(cap, fn = ISO, label = '')
    bad, total = IsoCheck.mismatches(cap, IsoCheck.bsp_order(cap, fn), fn)
    assert_operator total, :>, 1000
    assert_operator bad.fdiv(total), :<=, 0.004, "#{label}: #{bad}/#{total} điểm tô sai che khuất"
    [bad, total]
  end

  def test_1_khong_con_tam_giac_de_len_canh
    cap = IsoCheck.cabinet
    bad, total = check(cap, ISO, 'trục đo')
    old_bad, = IsoCheck.mismatches(cap, IsoCheck.centroid_order(cap, ISO), ISO)
    puts "\n  [trục đo] BSP sai #{bad}/#{total} điểm; cách cũ (sắp theo tâm) sai #{old_bad}/#{total}"
    assert_operator old_bad, :>, bad * 5 + 20, 'phép thử phải bắt được lỗi của cách cũ'
  end

  def test_2_moi_huong_nhin_va_model_xoay
    cap = IsoCheck.cabinet
    %w[front left top back].each { |k| check(cap, AL::Geometry::VIEWS[k][1], k) }
    check(IsoCheck.rotate(cap, 0.0, 0.0, 0.52), ISO, 'xoay 30° quanh Z')
    check(IsoCheck.rotate(cap, 0.31, -0.2, 1.1), ISO, 'xoay lệch 3 trục')
  end

  def test_3_mat_dao_va_mirror_khong_anh_huong
    cap = IsoCheck.cabinet
    flipped = AL::Geometry::Capture.new('đảo', cap.edges, cap.triangles.map { |a, b, c, m| [a, c, b, m] }, cap.materials)
    check(flipped, ISO, 'mặt đảo')
    mir = AL::Geometry::Capture.new('mirror', cap.edges.map { |a, b| [[-a[0], a[1], a[2]], [-b[0], b[1], b[2]]] },
                                    cap.triangles.map { |a, b, c, m| [[-a[0], a[1], a[2]], [-b[0], b[1], b[2]], [-c[0], c[1], c[2]], m] },
                                    cap.materials)
    check(mir, ISO, 'mirror (scale -1)')
  end

  def test_4_extractor_scale_am_dung_vi_tri
    hong = PX.box_def('Tấm đứng', 18, 600, 2000)
    m = [-1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 500 * PX::IN, 0, 0, 1].map(&:to_f)
    mirrored = X.inst(hong, X::T.new(m), Sketchup::ComponentInstance)
    mirrored.define_singleton_method(:name) { 'hông mirror' }
    root = X.inst(X::Def.new('Tủ', [mirrored]), X.tr(0, 0, 0))
    cap = PX.extractor.capture(PX.model, root, [], '-Y')
    xs = cap.edges.flatten(1).map { |p| p[0].round(3) }.uniq.sort
    assert_equal [482.0, 500.0], xs, 'Component scale âm: tấm nằm đúng 482..500 mm'
  end

  def test_5_pipeline_che_do_truc_do
    outs = VS.build('scale' => 0, 'views' => %w[iso], 'iso_mode' => 'material', 'fill' => true)
    svg = outs[0][0]
    refute_match(/BẢN XEM TRƯỚC|sắp theo độ sâu/, outs[0][1]['notes'].to_s)
    fills = ->(s, k) { REXML::XPath.match(REXML::Document.new(s), "//g[@class='view'][@data-key='#{k}']//path[@fill!='none']") }
    mat = fills.call(svg, 'iso')
    refute_empty mat
    none = VS.build('scale' => 0, 'views' => %w[iso], 'iso_mode' => 'none', 'fill' => true)
    assert_empty fills.call(none[0][0], 'iso').reject { |p| p.attributes['fill'] == 'transparent' }, 'không tô mặt'
    mono = VS.build('scale' => 0, 'views' => %w[iso], 'iso_mode' => 'mono', 'fill' => true)
    grays = fills.call(mono[0][0], 'iso').map { |p| p.attributes['fill'] }.uniq
    assert(grays.all? { |c| c =~ /\A#(\h\h)\1\1\z/ }, "đơn sắc: chỉ màu xám #{grays.first(3)}")
    assert_equal mat.length, fills.call(mono[0][0], 'iso').length, 'cùng hình học, chỉ khác màu'
    hid = VS.build('scale' => 0, 'views' => %w[iso], 'iso_hidden' => true)
    refute_includes svg, 'stroke="#8A8F8B" stroke-width="0.13"'
    assert_includes hid[0][0], 'stroke="#8A8F8B" stroke-width="0.13"', 'bật nét khuất'
    st = AL::ProjectStore.clean_page('iso_mode' => 'xyz', 'iso_hidden' => 'yes')
    assert_equal ['material', false], [st['iso_mode'], st['iso_hidden']]
  end

  def test_6_hieu_nang_nhieu_mat
    cap = Fake.capture('Nhiều tủ')
    cap.materials['Gỗ'] = { 'name' => 'Gỗ', 'color' => '#8B6B4A' }
    20.times do |k|
      x = k * 620
      Fake.box(cap, x, 0, 0, x + 18, 600, 2000, 'Gỗ')
      Fake.box(cap, x + 582, 0, 0, x + 600, 600, 2000, 'Gỗ')
      (0..8).each { |z| Fake.box(cap, x + 18, 0, z * 240, x + 582, 600, z * 240 + 18, 'Gỗ') }
      Fake.box(cap, x, -20, 0, x + 600, -2, 2000, 'Gỗ')
      6.times { |h| Fake.box(cap, x + 500, -60, 900 + h * 30, x + 520, -20, 920 + h * 30, 'Gỗ') }
    end
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    v = AL::Geometry.project(cap, 'iso')
    dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    puts "\n  [trục đo #{cap.triangles.length} tam giác] #{v[:fills].length} mảnh tô, #{dt.round(2)} s"
    refute_match(/sắp theo độ sâu/, v[:notes].join)
    assert_operator dt, :<, 30
  end
end
