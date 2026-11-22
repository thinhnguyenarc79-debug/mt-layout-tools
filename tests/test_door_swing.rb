# encoding: UTF-8
# v2.13: ký hiệu cánh mở nhìn từ trên (mặt bằng + mặt cắt nhìn từ trên) đồng bộ từ ký hiệu cánh trên mặt đứng.
require_relative 'test_helper'
require_relative 'test_parts'
require_relative 'test_recognition_bench'

module SW
  module_function

  def build(syms, extra = {}, fmt = :svg)
    built = (@built ||= PX.build)
    cap, _r, parts = PX.cabinet({}, built)
    doors = [parts[6], parts[7]].map { |x| x.persistent_id.to_s }
    project = AL::ProjectStore.default_project
    pg = AL::ProjectStore.clean_page(project['defaults'].merge(
      'id' => 'p1', 'pid' => 101, 'name' => 'Tủ', 'views' => %w[front top], 'sections' => [], 'scale' => 20,
      'door_symbols' => AL::DoorSymbols.clean(syms.call(doors))
    ).merge(extra))
    project['pages'] = [pg]
    pb = AL::PageBuild.new(TestDoorPages::Env.new(cap), project, pg, fmt)
    job = AL::Job.new('t', timer: ->(_b) {})
    pb.tasks.each { |t| job.add(t) }
    job.run_sync
    [pb, doors]
  end

  def view(pb, key)
    pb.instance_variable_get(:@views).find { |v| v[:key] == key }
  end

  def swings(pb, key, path = nil)
    Array((view(pb, key) || {})[:swings]).select { |s| path.nil? || s[:path] == path }
  end
end

class TestDoorSwingPlan < Minitest::Test
  # Mặt bằng: u = x - l, v = -y - t (mặt trước tủ ở phía dưới hình). Cánh trái x 0..597, phải 603..1200, mặt ngoài y = -20.
  def test_1_2_mo_trai_roi_doi_sang_mo_phai
    pb, doors = SW.build(->(d) { { d[0] => { 'type' => 'left' } } })
    s = SW.swings(pb, 'top', doors[0])
    assert_equal 1, s.length, 'mặt bằng có ký hiệu mở cho cánh đã gán trên mặt đứng'
    top = SW.view(pb, 'top')
    l, = top[:origin]
    hinge_u = -l + 0 # mép trái cánh x = 0
    arc_end = s[0][:arc].last
    assert_in_delta hinge_u, arc_end[0], 1.0, 'mở trái: mép tự do quay về phía bản lề trái'
    assert_operator arc_end[1], :>, top[:h] + 500, 'mở ra ngoài (phía trước tủ, dưới hình)'
    assert_in_delta 597 + 18, s[0][:arc].first[0] - hinge_u + 18, 1.0, 'cung bắt đầu ở mép tự do (phải) của cánh đóng'
    refute_nil top[:swing_pad]
    assert_operator top[:swing_pad][3], :>, 500, 'chừa chỗ phía dưới cho cung mở'

    pb2, = SW.build(->(d) { { d[0] => { 'type' => 'right' } } })
    s2 = SW.swings(pb2, 'top', doors[0])[0]
    assert_in_delta(-l + 597, s2[:arc].last[0], 1.0, 'mở phải: bản lề phía phải')
  end

  def test_3_canh_doi_hai_truc
    pb, doors = SW.build(->(d) { { d[1] => { 'type' => 'double' } } })
    s = SW.swings(pb, 'top', doors[1])
    assert_equal 2, s.length
    l, = SW.view(pb, 'top')[:origin]
    ends = s.map { |x| (x[:arc].last[0] + l).round }.sort
    assert_equal [603, 1200], ends, 'hai lá quay quanh hai mép ngoài'
  end

  def test_15_lua_ngan_keo_khong_co_cung
    pb, doors = SW.build(->(d) { { d[0] => { 'type' => 'slide_left' }, d[1] => { 'type' => 'drawer' } } })
    assert_empty SW.swings(pb, 'top')
  end

  def test_lat_len_khong_dung_cung_ban_le_dung
    pb, doors = SW.build(->(d) { { d[0] => { 'type' => 'up' } } })
    s = SW.swings(pb, 'top', doors[0])[0]
    xs = s[:arc].map { |p| p[0].round(1) }.uniq
    assert_equal 1, xs.length, 'trục quay nằm ngang: trên mặt bằng quỹ đạo là đoạn thẳng, không phải cung quay đứng'
  end

  def test_9_hai_canh_cung_definition_huong_rieng
    pb, doors = SW.build(->(d) { { d[0] => { 'type' => 'left' }, d[1] => { 'type' => 'right' } } })
    l, = SW.view(pb, 'top')[:origin]
    assert_in_delta 0, SW.swings(pb, 'top', doors[0])[0][:arc].last[0] + l, 1.0
    assert_in_delta 1200, SW.swings(pb, 'top', doors[1])[0][:arc].last[0] + l, 1.0
  end

  def test_10_doi_ti_le_khong_lech
    a, d = SW.build(->(dd) { { dd[0] => { 'type' => 'left' } } })
    b, = SW.build(->(dd) { { dd[0] => { 'type' => 'left' } } }, 'scale' => 5)
    assert_equal SW.swings(a, 'top', d[0]).map { |x| x[:arc] }, SW.swings(b, 'top', d[0]).map { |x| x[:arc] }, 'toạ độ hình (mm thật) giữ nguyên'
  end

  def test_tat_tren_mat_bang
    pb, = SW.build(->(d) { { d[0] => { 'type' => 'left' } } }, 'swing' => { 'plan' => false })
    assert_empty SW.swings(pb, 'top')
  end

  def test_goc_mo_45_va_mo_vao
    pb, d = SW.build(->(dd) { { dd[0] => { 'type' => 'left', 'angle' => 45, 'open' => 'in' } } })
    s = SW.swings(pb, 'top', d[0])[0]
    top = SW.view(pb, 'top')
    assert_operator s[:arc].last[1], :<, s[:arc].first[1], 'mở vào trong: quay về phía thân tủ'
    a0 = s[:arc].first
    a1 = s[:arc].last
    l, = top[:origin]
    hx = -l
    ang = Math.atan2((a1[1] - a0[1]).abs, a1[0] - hx) * 180 / Math::PI
    assert_in_delta 45, ang, 1.5
  end
end

class TestDoorSwingSections < Minitest::Test
  def sec(label, axis, pos, dir)
    [{ 'label' => label, 'axis' => axis, 'pos' => pos, 'dir' => dir, 'auto' => false }]
  end

  def test_4_5_mat_cat_nhin_tu_tren_khong_phu_thuoc_ten
    a, d = SW.build(->(dd) { { dd[0] => { 'type' => 'left' } } }, 'sections' => sec('A', 'z', 900, -1))
    b, = SW.build(->(dd) { { dd[0] => { 'type' => 'left' } } }, 'sections' => sec('C', 'z', 900, -1))
    sa = SW.swings(a, 'sec:A', d[0])
    refute_empty sa, 'mặt cắt nhìn từ trên đi qua cánh có ký hiệu'
    assert_equal sa.map { |x| x[:arc] }, SW.swings(b, 'sec:C', d[0]).map { |x| x[:arc] }, 'đổi tên A-A -> C-C: kết quả không đổi'
  end

  def test_6_mat_cat_dung_khong_co
    pb, = SW.build(->(dd) { { dd[0] => { 'type' => 'left' } } }, 'sections' => sec('A', 'x', 300, 1))
    assert_empty SW.swings(pb, 'sec:A')
  end

  def test_7_cat_tren_cao_khong_qua_canh
    pb, = SW.build(->(dd) { { dd[0] => { 'type' => 'left' } } }, 'sections' => sec('A', 'z', 2100, -1))
    assert_empty SW.swings(pb, 'sec:A')
  end

  def test_nhin_tu_duoi_len_khong_ap_dung
    pb, = SW.build(->(dd) { { dd[0] => { 'type' => 'left' } } }, 'sections' => sec('A', 'z', 900, 1))
    assert_empty SW.swings(pb, 'sec:A')
  end

  def test_13_pdf_va_svg
    pb, d = SW.build(->(dd) { { dd[0] => { 'type' => 'left' } } }, {}, :svg)
    assert(pb.outputs.any? { |svg, _| svg.include?(%(class="doorswing" data-path="#{d[0]}")) })
    pdf, = SW.build(->(dd) { { dd[0] => { 'type' => 'left' } } }, {}, :pdf)
    pw, ph = AL::Sheet.paper('A3')
    assert AL::Pdf.pdf_pages(pdf.outputs.map(&:first), [pw * AL::Pdf::MM_TO_PT, ph * AL::Pdf::MM_TO_PT]).start_with?('%PDF')
  end

  def test_12_luu_mo_lai
    pg = AL::ProjectStore.clean_page('swing' => { 'plan' => true, 'section' => false, 'angle' => 60, 'open' => 'in', 'arc' => 'solid' },
                                     'door_symbols' => { '1/2' => { 'type' => 'left', 'open' => 'in', 'angle' => 30 } })
    again = AL::ProjectStore.clean_page(JSON.parse(JSON.generate(pg)))
    assert_equal({ 'plan' => true, 'section' => false, 'angle' => 60.0, 'open' => 'in', 'arc' => 'solid', 'leaf' => 'solid' }, again['swing'])
    assert_equal ['left', 'in', 30.0], again['door_symbols']['1/2'].values_at('type', 'open', 'angle')
  end
end

class TestDoorSwingRotation < Minitest::Test
  # Cánh 600 x 18 x 700 trước thân tủ, xoay quanh Z / mirror: bản lề "trái" luôn ở bên trái khi nhìn mặt ngoài cánh.
  def check(deg, mirror)
    t = Bench.tf(500, 300, deg, mirror)
    pts, tris = Bench.box(0, -20, 0, 600, -2, 700, t)
    inf = AL::CabinetRecognizer.info(0, pts, tris)
    bp, bt = Bench.box(0, 0, 0, 18, 560, 700, t)         # hông tủ phía sau cánh
    tp, tt = Bench.box(0, 0, 682, 600, 560, 700, t)       # nóc
    body = [AL::CabinetRecognizer.info(1, bp, bt), AL::CabinetRecognizer.info(2, tp, tt)]
    st = AL::DoorSwing.clean({})
    e = AL::DoorSwing.exterior(inf, [inf] + body, [0.0, -1.0, 0.0]) # mặt ngoài theo thân tủ, không theo hướng mặt đứng
    lf = AL::DoorSwing.leaves(inf, { 'type' => 'left' }, st, e)[0]
    out = t.call([0, -1, 0]).zip(t.call([0, 0, 0])).map { |a, b| a - b } # hướng ra ngoài (mặt trước cục bộ)
    right = AL::DoorSwing.cross(out.map(&:-@), [0, 0, 1.0]).then { |v| AL::DoorSwing.unit(v) }
    mid = t.call([300, -11, 350])
    hinge = lf[:o]
    side = AL::DoorSwing.vdot(hinge.zip(mid).map { |a, b| a - b }, right)
    assert_operator side, :<, -250, "xoay #{deg}° mirror=#{mirror}: bản lề phải ở bên trái khi nhìn mặt ngoài"
    tip = AL::DoorSwing.rotate(lf[:free], lf[:o], lf[:k], lf[:t])
    assert_operator AL::DoorSwing.vdot(tip.zip(hinge).map { |a, b| a - b }, out), :>, 500, 'mở ra ngoài'
  end

  def test_8_xoay_va_mirror
    [0, 90, 137, 180, 270].each { |d| check(d, false) }
    [0, 90].each { |d| check(d, true) }
  end
end
