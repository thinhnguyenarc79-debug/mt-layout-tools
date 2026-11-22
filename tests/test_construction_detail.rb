# encoding: UTF-8
# v2.12: CHI TIẾT CẤU TẠO – mặt cắt thật qua hình học 3D (khác phóng to 2D).
require_relative 'test_helper'
require_relative 'test_project_save'

module CD
  module_function

  # Góc tủ: hông 18 mm (gỗ) + lớp laminate 1 mm dán ngoài, đáy 18 mm, đợt lùi sâu 300 mm, cánh 18 mm.
  def cap
    c = Fake.capture('Góc tủ')
    c.materials['Gỗ'] = { 'name' => 'MDF chống ẩm', 'color' => '#C8A57A' }
    c.materials['Lam'] = { 'name' => 'Laminate trắng', 'color' => '#F2F2F2' }
    c.materials['Kinh'] = { 'name' => 'Kính cường lực', 'color' => '#BFD8E2' }
    Fake.box(c, 0, 0, 0, 18, 560, 720, 'Gỗ')         # hông trái
    Fake.box(c, -1, 0, 0, 0, 560, 720, 'Lam')        # lớp laminate ngoài hông
    Fake.box(c, 18, 0, 0, 600, 560, 18, 'Gỗ')        # đáy
    Fake.box(c, 18, 300, 360, 600, 560, 378, 'Gỗ')   # đợt nằm sâu phía sau
    Fake.box(c, 0, -20, 2, 300, -2, 718, 'Kinh')     # cánh kính
    c
  end

  def page(details)
    project = AL::ProjectStore.default_project
    pg = AL::ProjectStore.clean_page(project['defaults'].merge('id' => 'p1', 'pid' => 1, 'name' => 'Góc tủ', 'views' => %w[front],
                                                               'sections' => [], 'scale' => 10,
                                                               'details' => AL::DetailEngine.clean(details),
                                                               'view_props' => { 'det:1' => { 'sheet' => 0 } }))
    project['pages'] = [pg]
    [project, pg]
  end

  def build(details, fmt = :svg, c = cap)
    project, pg = page(details)
    pb = AL::PageBuild.new(TestDoorPages::Env.new(c), project, pg, fmt)
    job = AL::Job.new('t', timer: ->(_b) {})
    pb.tasks.each { |t| job.add(t) }
    job.run_sync
    [pb, pb.outputs]
  end

  def view(pb, key)
    pb.instance_variable_get(:@views).find { |v| v[:key] == key }
  end

  # vùng khoanh quanh góc dưới-trái của mặt đứng (toạ độ hình nguồn): x -1..100, z 0..120
  def corner(extra = {})
    { 'n' => 1, 'src' => 'front', 'type' => 'section', 'rect' => [0, 600, 101, 721], 'scale' => 5,
      'cut' => { 'orient' => 'h', 'at' => 660 } }.merge(extra)
  end
end

class TestConstructionDetail < Minitest::Test
  def bbox(lp)
    xs = lp.map(&:first)
    ys = lp.map(&:last)
    [xs.max - xs.min, ys.max - ys.min]
  end

  def test_3_cat_qua_vach_18mm_dung_chieu_day
    pb, outs = CD.build([CD.corner])
    v = CD.view(pb, 'det:1')
    refute_nil v, outs[0][1]['notes'].inspect
    assert v[:construction]
    dims = v[:cut][:loops].map { |lp| bbox(lp).map { |x| x.round(1) } }
    assert_includes dims.map(&:first), 18.0, 'tiết diện hông đúng 18 mm'
    assert_includes dims.map(&:first), 1.0, 'lớp laminate 1 mm'
  end

  def test_4_hai_lop_vat_lieu_va_hatch_theo_vat_lieu
    pb, outs = CD.build([CD.corner])
    v = CD.view(pb, 'det:1')
    assert_equal ['Kính cường lực', 'Laminate trắng', 'MDF chống ẩm'], v[:cut][:loop_mats].compact.uniq.sort
    names = v[:mat_labels].map(&:first)
    assert_includes names, 'MDF chống ẩm'
    assert_includes names, 'Laminate trắng'
    svg = outs[0][0]
    assert_includes svg, 'MDF chống ẩm', 'chú thích vật liệu tự động trên giấy'
    kinh = v[:cut][:loops].each_index.select { |i| v[:cut][:loop_mats][i] == 'Kính cường lực' }.map { |i| v[:cut][:loops][i] }
    assert_empty AL::SectionEngine.hatch_by_material(kinh, ['Kính cường lực'] * kinh.length), 'kính không hatch'
    refute_empty AL::SectionEngine.hatch_by_material([[[0, 0], [10, 0], [10, 10], [0, 10]]], ['Inox 304']), 'kim loại có hatch'
  end

  def test_1_chi_lay_dung_vung_khoanh
    pb, = CD.build([CD.corner])
    v = CD.view(pb, 'det:1')
    assert_in_delta 101.0, v[:w], 0.6, 'rộng = đúng bề rộng vùng khoanh'
    v[:cut][:loops].each { |lp| lp.each { |x, _| assert_operator x, :<=, 101.01 } }
    v[:lines].flatten(1).each { |x, _| assert_operator x, :<=, 101.01 }
  end

  def test_gioi_han_chieu_sau_the_hien
    full, = CD.build([CD.corner('cut' => { 'orient' => 'v', 'at' => 50 }, 'rect' => [0, 300, 101, 721])])
    lim, = CD.build([CD.corner('cut' => { 'orient' => 'v', 'at' => 50 }, 'rect' => [0, 300, 101, 721], 'depth' => 20)])
    assert_operator CD.view(lim, 'det:1')[:lines].length, :<, CD.view(full, 'det:1')[:lines].length,
                    'độ sâu 20 mm: bỏ nét của bộ phận xa hơn (hông, đợt phía sau)'
  end

  def test_khong_tu_ve_cau_tao_khong_co
    pb, = CD.build([CD.corner])
    v = CD.view(pb, 'det:1')
    assert_equal 0, v[:cut][:loop_mats].count(nil), 'mọi tiết diện đều từ hình học có vật liệu của model'
    assert_operator v[:cut][:loops].length, :<=, 6, 'không sinh thêm lớp/chi tiết không có trong model'
  end

  def test_2_7_doi_ti_le_va_marker_nguon
    project, pg = CD.page([CD.corner('scale' => 20)])
    env = TestDoorPages::Env.new(CD.cap)
    run = lambda do
      pb = AL::PageBuild.new(env, project, pg, :svg)
      job = AL::Job.new('t', timer: ->(_b) {})
      pb.tasks.each { |t| job.add(t) }
      job.run_sync
      pb.outputs
    end
    a = run.call
    PS.freeze(pg, a) # bố cục đã chốt như trong plugin
    a = run.call
    pg['details'][0]['scale'] = 5
    b = run.call
    mk = ->(o) { o[0][0][%r{<g class="detmark" data-det="1">.*?</g>}m] }
    assert_equal mk.call(a), mk.call(b), 'marker + đường cắt trên hình nguồn không đổi khi đổi tỉ lệ chi tiết'
    assert_includes mk.call(a), 'stroke-dasharray="3 0.8 0.6 0.8"', 'có đường cắt gạch chấm trong vùng gọi'
    assert_equal a[0][1]['boxes']['front'], b[0][1]['boxes']['front']
    assert_equal a[0][1]['boxes']['det:1'][0, 2], b[0][1]['boxes']['det:1'][0, 2], 'điểm neo chi tiết giữ nguyên'
  end

  def test_6_doi_marker_tron_khong_mat_chi_tiet
    pb, = CD.build([CD.corner('marker' => { 'shape' => 'circle', 'arrow' => true })])
    refute_nil CD.view(pb, 'det:1')
  end

  def test_8_luu_mo_lai
    d = AL::DetailEngine.clean(JSON.parse(JSON.generate(AL::DetailEngine.clean([CD.corner('depth' => 50, 'labels' => false)]))))[0]
    assert_equal ['section', { 'orient' => 'h', 'at' => 660.0, 'dir' => nil }, 50.0, false], d.values_at('type', 'cut', 'depth', 'labels')
  end

  def test_9_pdf
    _pb, outs = CD.build([CD.corner], :pdf)
    pw, ph = AL::Sheet.paper('A3')
    assert AL::Pdf.pdf_pages(outs.map(&:first), [pw * AL::Pdf::MM_TO_PT, ph * AL::Pdf::MM_TO_PT]).start_with?('%PDF')
  end

  def test_phong_to_2d_van_nhu_cu
    pb, = CD.build([CD.corner('type' => 'enlarge')])
    v = CD.view(pb, 'det:1')
    assert v[:detail], 'loại phóng to vẫn dùng DetailEngine 2D'
    refute v[:construction]
  end
end
