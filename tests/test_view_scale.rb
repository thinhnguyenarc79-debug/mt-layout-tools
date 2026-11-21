# encoding: UTF-8
# v2.6: tỉ lệ riêng từng hình chiếu, khóa tỉ lệ / khóa vị trí, ký hiệu hướng mở cánh.
require_relative 'test_helper'
require_relative 'test_doors'
require 'rexml/document'

module VS
  module_function

  def page(extra = {})
    project = AL::ProjectStore.default_project
    pg = AL::ProjectStore.clean_page(project['defaults'].merge('id' => 'p1', 'pid' => 1, 'name' => 'Tủ', 'sheet_no' => 'A-01',
                                                               'views' => %w[front top], 'sections' => []).merge(extra))
    project['pages'] = [pg]
    [project, pg]
  end

  def build(extra = {}, fmt = :svg, cap = DoorFake.cabinet_with_doors)
    project, pg = page(extra)
    pb = AL::PageBuild.new(TestDoorPages::Env.new(cap), project, pg, fmt,
                           ->(p, n) { AL::ProjectStore.sheet_codes(project, { p['id'] => n })[p['id']].first })
    job = AL::Job.new('t', timer: ->(_b) {})
    pb.tasks.each { |t| job.add(t) }
    job.run_sync
    pb.outputs
  end

  def scale_of(outs, key)
    outs.each { |_, info| return info['view_scales'][key] if info['view_scales'].key?(key) }
    nil
  end

  def sheet_of(outs, key)
    outs.index { |_, info| info['view_keys'].include?(key) }
  end

  # Số DIM (mm thật) in trên hình – không phụ thuộc tỉ lệ.
  def dim_values(svg, key)
    doc = REXML::Document.new(svg)
    g = REXML::XPath.first(doc, "//g[@class='view'][@data-key='#{key}']")
    REXML::XPath.match(g, ".//g[@class='dimtxt']//text").map(&:text).sort
  end

  LOCK15 = { 'front' => { 'scale_override' => 15, 'scale_locked' => true, 'position_locked' => false } }.freeze
end

class TestViewScale < Minitest::Test
  def test_1_ti_le_rieng_va_ti_le_trang
    outs = VS.build('scale' => 40, 'view_props' => { 'front' => { 'scale_override' => 15 } })
    assert_equal 15, VS.scale_of(outs, 'front')
    assert_equal 40, VS.scale_of(outs, 'top'), 'hình không có tỉ lệ riêng theo tỉ lệ trang'
    svg = outs[VS.sheet_of(outs, 'front')][0]
    assert_includes svg, '>TL 1:15<'
    f = outs[VS.sheet_of(outs, 'front')][1]['frames']['front']
    assert_equal 15, f[2], 'khung hình dùng đúng tỉ lệ in thật'
  end

  def test_2_doi_ti_le_trang_khong_anh_huong_hinh_khoa
    [40, 20, 50].each do |pg_scale|
      outs = VS.build('scale' => pg_scale, 'view_props' => VS::LOCK15)
      assert_equal 15, VS.scale_of(outs, 'front'), "trang 1:#{pg_scale} -> mặt đứng vẫn 1:15"
      assert_equal pg_scale, VS.scale_of(outs, 'top')
    end
  end

  def test_3_khung_ten_theo_hinh_khi_nhieu_ti_le
    outs = VS.build('scale' => 40, 'view_props' => { 'front' => { 'scale_override' => 40 } })
    assert_includes outs[0][0], '>1:40<'
    outs = VS.build('scale' => 50, 'view_props' => { 'front' => { 'scale_override' => 40 } })
    assert(outs.any? { |svg, _| svg.include?('>THEO HÌNH<') } || outs.length > 1)
  end

  def test_4_khong_vua_thi_sang_to_khac_khong_thu_nho
    # mặt đứng 2410 x 2698 ở 1:10 không vừa cùng mặt bằng trên A3 -> sang tờ khác, giữ 1:10
    outs = VS.build('scale' => 40, 'view_props' => { 'front' => { 'scale_override' => 10, 'scale_locked' => true } })
    assert_equal 10, VS.scale_of(outs, 'front')
    assert_equal 40, VS.scale_of(outs, 'top')
    outs.each { |_, info| assert_equal info['view_keys'].uniq, info['view_keys'] }
    assert_equal 2, outs.map { |_, i| i['view_keys'] }.flatten.length, 'không mất / không lặp hình'
  end

  def test_5_mot_hinh_qua_lon_bao_xung_dot_giu_ti_le
    outs = VS.build('scale' => 40, 'view_props' => { 'front' => { 'scale_override' => 5, 'scale_locked' => true } })
    assert_equal 5, VS.scale_of(outs, 'front'), 'không tự thu nhỏ hình đã khóa'
    notes = outs.map { |_, i| i['note'].to_s }.join(' ')
    assert_includes notes, 'XUNG ĐỘT TỈ LỆ'
    assert_includes notes, 'đã khóa'
  end

  def test_6_ti_le_tu_dong_van_giu_hinh_khoa
    outs = VS.build('scale' => 0, 'view_props' => VS::LOCK15)
    assert_equal 15, VS.scale_of(outs, 'front')
  end

  def test_7_dim_giu_gia_tri_that
    a = VS.build('scale' => 40)
    b = VS.build('scale' => 40, 'view_props' => VS::LOCK15)
    va = VS.dim_values(a[VS.sheet_of(a, 'front')][0], 'front')
    vb = VS.dim_values(b[VS.sheet_of(b, 'front')][0], 'front')
    refute_empty va
    assert_equal va, vb, 'đổi tỉ lệ hình không đổi số DIM'
  end

  def test_8_luu_mo_lai_giu_khoa
    project, pg = VS.page('scale' => 40, 'view_props' => VS::LOCK15.merge('top' => { 'position_locked' => true }),
                          'offsets' => { 'top' => [5, 3] })
    again = AL::ProjectStore.clean_page(JSON.parse(JSON.generate(pg)))
    assert_equal({ 'scale_override' => 15, 'scale_locked' => true, 'position_locked' => false, 'placement_mode' => 'auto', 'x_mm' => nil, 'y_mm' => nil, 'sheet' => nil }, again['view_props']['front'])
    assert_equal({ 'scale_override' => nil, 'scale_locked' => false, 'position_locked' => true, 'placement_mode' => 'auto', 'x_mm' => nil, 'y_mm' => nil, 'sheet' => nil }, again['view_props']['top'])
    # dựng lại trang (Tạo trang, thay thế): khóa không tự mất
    finder = ->(_pid) { { 'name' => 'Tủ', 'root' => true } }
    AL::ProjectStore.add_pages(project, [1], finder, true)
    fresh = project['pages'][0]
    assert_equal 15, fresh['view_props']['front']['scale_override']
    assert fresh['view_props']['front']['scale_locked']
    assert_equal [5.0, 3.0], fresh['offsets']['top'], 'hình khóa vị trí giữ chỗ'
  end

  def test_9_lam_sach_du_lieu
    vp = AL::ProjectStore.clean_view_props('front' => { 'scale_locked' => true }, 'bad key' => { 'scale_override' => 5 },
                                           'sec:A' => { 'scale_override' => '20', 'scale_locked' => true },
                                           'det:1' => { 'scale_override' => 9999 })
    assert_equal ['sec:A'], vp.keys, 'khóa mà không có tỉ lệ / khoá sai / tỉ lệ sai bị bỏ'
    assert_equal 20, vp['sec:A']['scale_override']
    pg = { 'scale' => 40, 'view_props' => vp }
    assert_equal 20, AL::ProjectStore.effective_scale(pg, 'sec:A')
    assert_equal 40, AL::ProjectStore.effective_scale(pg, 'front')
  end

  def test_10_pdf_in_dung_ti_le_tung_hinh
    outs = VS.build({ 'scale' => 40, 'view_props' => VS::LOCK15 }, :pdf)
    assert_equal 15, VS.scale_of(outs, 'front')
    assert_equal 40, VS.scale_of(outs, 'top')
    pw, ph = AL::Sheet.paper('A3')
    pdf = AL::Pdf.pdf_pages(outs.map(&:first), [pw * AL::Pdf::MM_TO_PT, ph * AL::Pdf::MM_TO_PT])
    assert pdf.start_with?('%PDF')
  end
end

class TestDoorSymbols < Minitest::Test
  def syms(map)
    AL::DoorSymbols.clean(map.transform_values { |t| { 'type' => t } })
  end

  def groups(svg, key)
    doc = REXML::Document.new(svg)
    g = REXML::XPath.first(doc, "//g[@class='view'][@data-key='#{key}']")
    REXML::XPath.match(g, ".//g[@class='doorsym']")
  end

  def test_chi_ve_canh_nguoi_dung_chon
    outs = VS.build('scale' => 40, 'views' => %w[front], 'door_symbols' => syms('9/0' => 'left', '9/1' => 'none'))
    gs = groups(outs[0][0], 'front')
    assert_equal ['9/0'], gs.map { |g| g.attributes['data-path'] }, 'cánh chưa chọn / "không ký hiệu" không vẽ'
    assert_equal 2, gs[0].elements.to_a.length, 'mở trái = 2 nét'
    items = outs[0][1]['door_items']['front']
    assert_equal %w[9/0 9/1 9/2], items.map { |i| i['path'] }.sort, 'gửi hộp cánh để bấm chọn trên giấy'
  end

  def test_khong_tu_doan_ban_le
    outs = VS.build('scale' => 40, 'views' => %w[front])
    assert_empty groups(outs[0][0], 'front')
  end

  def test_so_net_tung_loai
    { 'left' => 2, 'right' => 2, 'double' => 4, 'up' => 2, 'down' => 2, 'slide_left' => 3, 'slide_right' => 3, 'drawer' => 3, 'none' => 0 }.each do |t, n|
      assert_equal n, AL::DoorSymbols.segments(t, 0, 0, 40, 60).length, t
    end
    # mở trái: đỉnh tam giác nằm ở cạnh bản lề (trái)
    apex = AL::DoorSymbols.segments('left', 0, 0, 40, 60).map(&:last).uniq
    assert_equal [[0, 30.0]], apex
  end

  def test_theo_hinh_khi_doi_ti_le_va_mat_sau_dao_chieu
    a = VS.build('scale' => 40, 'views' => %w[front], 'door_symbols' => syms('9/0' => 'left'))
    b = VS.build('scale' => 40, 'views' => %w[front], 'door_symbols' => syms('9/0' => 'left'),
                 'view_props' => { 'front' => { 'scale_override' => 20 } })
    len = lambda do |outs|
      d = groups(outs[0][0], 'front')[0].elements.to_a[0].attributes['d']
      x0, y0, x1, y1 = d.scan(/-?[\d.]+/).map(&:to_f)
      Math.hypot(x1 - x0, y1 - y0)
    end
    assert_in_delta len.call(a) * 2, len.call(b), 0.6, 'ký hiệu co giãn đúng theo tỉ lệ hình'
    v = { key: 'back', door_items: [{ 'path' => '9/0', 'box' => [0, 40, 0, 60] }] }
    cv = AL::Canvas.new(:svg, 420, 297)
    AL::DoorSymbols.draw(cv, v, ->(p) { p }, syms('9/0' => 'left'))
    assert_includes cv.svg, 'M0 0L40 30', 'mặt sau: bản lề trái thành phải'
  end

  def test_kieu_net_va_an_hien
    st = { '9/0' => { 'type' => 'right', 'style' => { 'w' => 0.35, 'color' => '#ff0000', 'dash' => 'solid' } },
           '9/1' => { 'type' => 'left', 'visible' => false } }
    outs = VS.build('scale' => 40, 'views' => %w[front], 'door_symbols' => AL::DoorSymbols.clean(st))
    gs = groups(outs[0][0], 'front')
    assert_equal ['9/0'], gs.map { |g| g.attributes['data-path'] }
    path = gs[0].elements.to_a[0]
    assert_equal '#FF0000', path.attributes['stroke']
    assert_nil path.attributes['stroke-dasharray']
    pdf_outs = VS.build({ 'scale' => 40, 'views' => %w[front], 'door_symbols' => AL::DoorSymbols.clean(st) }, :pdf)
    assert_includes pdf_outs[0][0], ' RG '
  end

  def test_luu_mo_lai
    raw = { '9/0' => { 'type' => 'double', 'open' => 'in' }, '../x' => { 'type' => 'left' }, '9/2' => { 'type' => 'bay' } }
    c = AL::DoorSymbols.clean(JSON.parse(JSON.generate(raw)))
    assert_equal %w[9/0 9/2], c.keys.sort
    assert_equal 'both', c['9/0']['hinge']
    assert_equal 'in', c['9/0']['open']
    assert_equal 'none', c['9/2']['type']
  end
end
