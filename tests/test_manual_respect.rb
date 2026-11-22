# encoding: UTF-8
# v2.11: tôn trọng thao tác tay – vùng trích chính xác, đổi tỉ lệ chỉ hình đó, thêm hình không làm nhảy hình cũ,
# gán bộ phận ngay trên bản vẽ 2D.
require_relative 'test_helper'
require_relative 'test_detail_sheet'
require_relative 'test_parts'

module MR
  module_function

  def scales(outs)
    outs.each_with_object({}) { |(_, i), h| h.merge!(i['view_scales']) }
  end

  def boxes(outs)
    outs.each_with_index.each_with_object({}) { |((_, i), s), h| i['boxes'].each { |k, b| h[k] = [s] + b } }
  end
end

class TestDetailRegion < Minitest::Test
  def test_1_vung_100x80_chinh_xac_va_cat_dung_mep
    src = { lines: [[[0, 90], [500, 90]], [[150, 0], [150, 400]], [[0, 0], [20, 20]]], cut: nil, level: 1, fills: [] }
    det = AL::DetailEngine.clean([{ 'n' => 1, 'src' => 'front', 'rect' => [100, 50, 200, 130] }])[0]
    v = AL::DetailEngine.build(src, det)
    assert_equal [100.0, 80.0], [v[:w], v[:h]], 'kích thước vùng trích = đúng vùng đã quét'
    assert_equal 2, v[:lines].length, 'nét ngoài vùng bị bỏ'
    h, vv = v[:lines]
    assert_equal [[0.0, 40.0], [100.0, 40.0]], h.map { |p| p.map { |x| x.round(3) } }, 'cắt đúng mép trái/phải'
    assert_equal [[50.0, 0.0], [50.0, 80.0]], vv.map { |p| p.map { |x| x.round(3) } }, 'cắt đúng mép trên/dưới'
  end

  def detail_project(shape = 'rect', scale = 20)
    project, pg = DS.project
    pg['details'] = AL::DetailEngine.clean([{ 'n' => 1, 'src' => 'front', 'rect' => [200, 300, 900, 1000], 'scale' => scale,
                                              'sheet' => 0, 'marker' => { 'shape' => shape } }])
    pg['view_props'] = AL::ProjectStore.clean_view_props(pg['view_props'].merge('det:1' => { 'sheet' => 0 }))
    PS.freeze(pg, PS.build(project, pg))
    [project, pg]
  end

  def test_3_chi_tiet_tron_chi_hien_ben_trong
    project, pg = detail_project('circle')
    outs = PS.build(project, pg)
    s = DS.where(outs, 'det:1')[0]
    g = outs[s][0][/<g class="view" data-key="det:1">.*?<\/g>\s*<\/g>/m] || outs[s][0]
    assert_includes g, '<ellipse', 'cắt theo hình tròn (clipPath ellipse)'
    pb = AL::PageBuild.new(TestDoorPages::Env.new(DoorFake.cabinet_with_doors), project, pg, :pdf)
    job = AL::Job.new('t', timer: ->(_b) {})
    pb.tasks.each { |t| job.add(t) }
    job.run_sync
    assert_match(/ c .* h W n/m, pb.outputs[s][0], 'PDF: đường cắt elip thật')
  end

  def test_5_doi_ti_le_chi_tiet_khong_doi_vung_trich
    project, pg = detail_project('rect', 20)
    a = PS.build(project, pg)
    rect0 = pg['details'][0]['rect'].dup
    mark0 = a[0][0][/<g class="detmark" data-det="1">.*?<\/g>/m]
    pg['details'][0]['scale'] = 5
    b = PS.build(project, pg)
    assert_equal rect0, pg['details'][0]['rect']
    assert_equal mark0, b[0][0][/<g class="detmark" data-det="1">.*?<\/g>/m], 'khung trích trên hình nguồn không dịch'
    ba = MR.boxes(a)
    bb = MR.boxes(b)
    (ba.keys - ['det:1']).each { |k| assert_equal ba[k], bb[k], "#{k} không đổi" }
    assert_equal ba['det:1'][1, 2], bb['det:1'][1, 2], 'điểm neo chi tiết giữ nguyên'
    assert_in_delta 700.0 / 5 - 700.0 / 20, bb['det:1'][3] - ba['det:1'][3], 0.6, 'chỉ kích thước trên giấy tăng (đúng theo tỉ lệ)'
  end
end

class TestScaleOnlyThatView < Minitest::Test
  def test_6_7_doi_ti_le_mot_hinh
    project, pg = DS.project
    a = PS.build(project, pg)
    pg['view_props']['left']['scale_override'] = 5
    b = PS.build(project, pg)
    sa = MR.scales(a)
    sb = MR.scales(b)
    assert_equal 5, sb['left']
    (sa.keys - ['left']).each { |k| assert_equal sa[k], sb[k], "tỉ lệ #{k} giữ nguyên" }
    ba = MR.boxes(a)
    bb = MR.boxes(b)
    (ba.keys - ['left']).each { |k| assert_equal ba[k], bb[k], "vị trí #{k} giữ nguyên" }
    assert_equal ba['left'][0, 3], bb['left'][0, 3], 'điểm neo hình đổi tỉ lệ giữ nguyên'
    cs = b.flat_map { |_, i| Array(i['conflicts']) }
    refute_empty cs, 'hình to ra gây chồng/tràn -> có xung đột'
    assert(cs.all? { |c| c['a'] == 'left' || c['b'] == 'left' })
  end

  def test_khong_tu_giam_ti_le_khi_bo_cuc_da_chot
    project, pg = DS.project
    before = MR.scales(PS.build(project, pg))
    pg['views'] += %w[right back iso]
    after = MR.scales(PS.build(project, pg))
    before.each { |k, sc| assert_equal sc, after[k], "thêm hình không đổi tỉ lệ #{k}" }
  end
end

class TestAddViewAtPoint < Minitest::Test
  def test_8_9_them_mat_bang_vao_cho_trong
    project, pg = DS.project
    a = PS.build(project, pg)
    s_top = DS.where(a, 'top')[0]
    other = s_top.zero? ? 1 : 0
    pg['copies'] = [{ 'n' => 1, 'src' => 'top' }]
    pg['view_props']['cp:1'] = { 'placement_mode' => 'manual', 'x_mm' => 30.0, 'y_mm' => 200.0, 'sheet' => other }
    pg['view_props'] = AL::ProjectStore.clean_view_props(pg['view_props'])
    pg = AL::ProjectStore.clean_page(pg)
    project['pages'][0] = pg
    b = PS.build(project, pg)
    ba = MR.boxes(a)
    bb = MR.boxes(b)
    ba.each { |k, v| assert_equal v, bb[k], "#{k} giữ nguyên tờ, vị trí, kích thước" }
    MR.scales(a).each { |k, sc| assert_equal sc, MR.scales(b)[k] }
    assert_equal [other, 30.0, 200.0], bb['cp:1'][0, 3], 'hình mới đúng tờ và đúng điểm chọn'
  end
end

class TestAssignOn2D < Minitest::Test
  def test_12_bam_vao_canh_nhan_dung_instance
    built = PX.build
    cap, _r, parts = PX.cabinet({}, built)
    project = AL::ProjectStore.default_project
    pg = AL::ProjectStore.clean_page(project['defaults'].merge('id' => 'p1', 'pid' => 101, 'name' => 'Tủ', 'views' => %w[front], 'sections' => []))
    project['pages'] = [pg]
    pb = AL::PageBuild.new(TestDoorPages::Env.new(cap), project, pg, :svg)
    job = AL::Job.new('t', timer: ->(_b) {})
    pb.tasks.each { |t| job.add(t) }
    job.run_sync
    hits = pb.outputs[0][1]['part_hits']['front']
    door = parts[6].persistent_id.to_s
    r = hits.find { |h| h[0] == door }
    assert r, 'cánh có vùng bấm trên mặt đứng'
    u = (r[1] + r[2]) / 2
    v = (r[3] + r[4]) / 2
    under = hits.select { |h| u >= h[1] && u <= h[2] && v >= h[3] && v <= h[4] }.sort_by { |h| -h[5] }
    assert_operator under.length, :>, 1, 'có bộ phận phía sau chồng lên -> giao diện hiện danh sách ứng viên'
    assert_equal door, under[0][0], 'ứng viên đầu = bộ phận phía trước (cánh), không phải vách/đợt phía sau'
    other = parts[7].persistent_id.to_s
    refute_equal other, under[0][0], 'không nhầm sang instance khác cùng definition'
  end
end
