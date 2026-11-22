# encoding: UTF-8
# v2.10: chi tiết nằm đúng tờ trích, kiểu marker chi tiết, chuyển / bản sao hình chiếu sang tờ khác.
require_relative 'test_helper'
require_relative 'test_project_save'

module DS
  module_function

  # Trang 2+ tờ (1:15), bố cục đã chốt như sau lần dựng đầu.
  def project
    project = AL::ProjectStore.default_project
    PS.add_models(project, [11])
    pg = project['pages'][0]
    pg['scale'] = 15
    pg['views'] = %w[front top left]
    pg['sections'] = []
    pg['view_props'] = {}
    PS.freeze(pg, PS.build(project, pg))
    [project, pg]
  end

  def where(outs, key)
    outs.each_with_index { |(_, i), s| return [s, i['boxes'][key]] if i['boxes'][key] }
    nil
  end

  def overlap?(a, b)
    a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3]
  end
end

class TestDetailOnSheet < Minitest::Test
  def add_detail(pg, sheet, extra = {})
    src = pg['view_props'].find { |_k, v| v['sheet'] == sheet }&.first
    assert src, "có hình nguồn trên tờ #{sheet}"
    pg['details'] = AL::DetailEngine.clean([{ 'n' => 1, 'src' => src, 'rect' => [0, 0, 300, 300], 'scale' => 5,
                                              'src_sheet' => sheet, 'sheet' => sheet }.merge(extra)])
    pg['view_props'] = AL::ProjectStore.clean_view_props(pg['view_props'].merge('det:1' => { 'sheet' => sheet }))
    src
  end

  def test_1_trich_o_to_nao_nam_o_to_do
    project, pg = DS.project
    outs = PS.build(project, pg)
    assert_operator outs.length, :>=, 2
    add_detail(pg, 1)
    outs = PS.build(project, pg)
    s, box = DS.where(outs, 'det:1')
    assert_equal 1, s, 'chi tiết trích trên A-02 phải nằm ở A-02 (không về A-01)'
    others = outs[1][1]['boxes'].reject { |k, _| k == 'det:1' }
    others.each_value { |b| refute DS.overlap?(box, b), 'đặt vào chỗ trống, không chồng hình' }
    assert_nil outs[1][1]['no_room']
  end

  def test_2_luu_mo_lai_van_o_to_do
    project, pg = DS.project
    add_detail(pg, 1, 'label' => 'CHI TIẾT BẢN LỀ', 'marker' => { 'shape' => 'circle', 'arrow' => true })
    PS.freeze(pg, PS.build(project, pg))
    again = AL::ProjectStore.clean(JSON.parse(JSON.generate(project)))
    p2 = again['pages'][0]
    d = p2['details'][0]
    assert_equal [1, 1, 'CHI TIẾT BẢN LỀ', 'circle', true], [d['src_sheet'], d['sheet'], d['label'], d['marker']['shape'], d['marker']['arrow']]
    s, = DS.where(PS.build(again, p2), 'det:1')
    assert_equal 1, s
  end

  def test_3_kieu_marker
    project, pg = DS.project
    src = add_detail(pg, 0)
    { 'rect' => 5, 'circle' => 73, 'ellipse' => 73 }.each do |shape, npts|
      pg['details'][0]['marker'] = { 'shape' => shape, 'arrow' => shape != 'rect', 'bubble' => shape != 'ellipse' }
      outs = PS.build(project, pg)
      svg = outs[DS.where(outs, src)[0]][0]
      g = svg[/<g class="detmark" data-det="1">.*?<\/g>/m]
      assert g, shape
      outline = g.scan(/<path d="([^"]+)" fill="none"[^>]*stroke-dasharray/).first.first
      assert_equal npts, outline.split('L').length, "#{shape}: số điểm đường bao"
      assert_equal shape != 'rect', g.scan('<path').length > 1, "#{shape}: mũi tên"
      assert_equal shape == 'ellipse', g.include?('CHI TIẾT 1'), "#{shape}: nhãn chữ khi không dùng bóng số"
    end
  end

  def test_doi_ten_chi_tiet_doi_ten_hinh
    project, pg = DS.project
    add_detail(pg, 0, 'label' => 'CHI TIẾT CHÂN TỦ')
    outs = PS.build(project, pg)
    assert(outs.any? { |svg, _| svg.include?('CHI TIẾT CHÂN TỦ') })
  end

  def test_cat_theo_elip
    src = { lines: [[[0, 50], [100, 50]], [[0, 0], [5, 5]]], cut: false, level: 1 }
    det = AL::DetailEngine.clean([{ 'n' => 1, 'src' => 'front', 'rect' => [0, 0, 100, 100], 'marker' => { 'shape' => 'circle' } }])[0]
    v = AL::DetailEngine.build(src, det)
    assert_equal 1, v[:lines].length, 'nét ngoài hình tròn bị cắt bỏ'
    assert_in_delta 0.0, v[:lines][0][0][0], 0.01
    assert_in_delta 100.0, v[:lines][0][1][0], 0.01
    refute_nil v[:border]
  end

  def test_khong_du_cho_bao_ro_khong_doi_to
    project, pg = DS.project
    add_detail(pg, 0)
    pg['details'][0]['rect'] = [0, 0, 2000, 2000]
    pg['details'][0]['scale'] = 8
    outs = PS.build(project, pg)
    s, = DS.where(outs, 'det:1')
    assert_equal 0, s, 'không tự chuyển sang tờ khác'
    assert_includes outs[0][1]['no_room'].to_a, 'det:1'
    assert_match(/KHÔNG ĐỦ CHỖ/, outs[0][1]['note'].to_s)
  end
end

class TestMoveCopyView < Minitest::Test
  def test_4_chuyen_sang_to_khac
    project, pg = DS.project
    outs = PS.build(project, pg)
    s0, = DS.where(outs, 'top')
    target = s0.zero? ? 1 : 0
    pg['view_props']['top'] = { 'sheet' => target } # chuyển: bỏ toạ độ cũ, định tờ mới
    pg['view_props'] = AL::ProjectStore.clean_view_props(pg['view_props'])
    outs = PS.build(project, pg)
    s1, = DS.where(outs, 'top')
    assert_equal target, s1
    assert_equal 1, outs.sum { |_, i| i['boxes'].key?('top') ? 1 : 0 }, 'không tạo trùng'
  end

  def test_5_ban_sao_giu_goc
    project, pg = DS.project
    s0, b0 = DS.where(PS.build(project, pg), 'top')
    target = s0.zero? ? 1 : 0
    pg['copies'] = [{ 'n' => 1, 'src' => 'top' }]
    pg['view_props'] = AL::ProjectStore.clean_view_props(pg['view_props'].merge('cp:1' => { 'sheet' => target }))
    pg = AL::ProjectStore.clean_page(pg)
    project['pages'][0] = pg
    outs = PS.build(project, pg)
    assert_equal [s0, b0], DS.where(outs, 'top'), 'hình gốc giữ nguyên tờ & vị trí'
    s1, b1 = DS.where(outs, 'cp:1')
    assert_equal target, s1
    f0 = outs[s0][1]['frames']['top']
    f1 = outs[s1][1]['frames']['cp:1']
    assert_equal f0[3, 2], f1[3, 2], 'bản sao cùng hình học (kích thước thật)'
    refute_nil b1
    svg = outs[target][0]
    assert_includes svg, 'data-key="cp:1"'
    again = AL::ProjectStore.clean(JSON.parse(JSON.generate(project)))
    assert_equal [{ 'n' => 1, 'src' => 'top' }], again['pages'][0]['copies']
  end

  def test_7_pdf_tat_ca
    project, pg = DS.project
    pg['details'] = AL::DetailEngine.clean([{ 'n' => 1, 'src' => 'front', 'rect' => [0, 0, 300, 300], 'scale' => 5, 'sheet' => 1,
                                              'marker' => { 'shape' => 'ellipse', 'arrow' => true } }])
    pg['view_props'] = AL::ProjectStore.clean_view_props(pg['view_props'].merge('det:1' => { 'sheet' => 1 }))
    pb = AL::PageBuild.new(TestDoorPages::Env.new(DoorFake.cabinet_with_doors), project, pg, :pdf)
    job = AL::Job.new('t', timer: ->(_b) {})
    pb.tasks.each { |t| job.add(t) }
    job.run_sync
    assert_equal 1, pb.outputs.index { |_, i| i['boxes'].key?('det:1') }
    pw, ph = AL::Sheet.paper('A3')
    assert AL::Pdf.pdf_pages(pb.outputs.map(&:first), [pw * AL::Pdf::MM_TO_PT, ph * AL::Pdf::MM_TO_PT]).start_with?('%PDF')
  end
end
