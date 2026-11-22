# encoding: UTF-8
# v2.14: DIM thủ công 2 điểm – đo thông thủy giữa các đợt kệ, lưu theo hình, không bị Auto DIM ghi đè.
require_relative 'test_helper'
require_relative 'test_parts'

module MD
  module_function

  # Tủ 1200 x 600 x 2000 nhiều đợt (không cánh): đáy z 0..18, đợt 400..418, 768..786, 1200..1218, nóc 1982..2000.
  # Khoảng thông thủy giữa đợt 400 và đợt 768: 768 - 418 = 350 mm.
  def build(shelf2 = 768)
    hong = PX.box_def('Hông', 18, 600, 2000)
    ngang = PX.box_def('Đợt', 1164, 600, 18)
    parts = [PX.at(hong, 0, 0, 0), PX.at(hong, 1182, 0, 0),
             PX.at(ngang, 18, 0, 0), PX.at(ngang, 18, 0, 400), PX.at(ngang, 18, 0, shelf2),
             PX.at(ngang, 18, 0, 1200), PX.at(ngang, 18, 0, 1982)]
    root = X.inst(X::Def.new('Tủ nhiều đợt', parts), X.tr(0, 0, 0))
    [root, parts]
  end

  def page(dims, extra = {})
    project = AL::ProjectStore.default_project
    pg = AL::ProjectStore.clean_page(project['defaults'].merge(
      'id' => 'p1', 'pid' => 101, 'name' => 'Tủ', 'views' => %w[front], 'scale' => 20, 'front_dims' => 'interior',
      'sections' => [], 'manual_dims' => dims
    ).merge(extra))
    project['pages'] = [pg]
    [project, pg]
  end

  def run(dims, extra = {}, fmt = :svg, built = nil)
    built ||= (@built ||= build)
    cap = PX.extractor.capture(PX.model, built[0], [], '-Y', nil, {})
    project, pg = page(dims, extra)
    pb = AL::PageBuild.new(TestDoorPages::Env.new(cap), project, pg, fmt)
    job = AL::Job.new('t', timer: ->(_b) {})
    pb.tasks.each { |t| job.add(t) }
    job.run_sync
    [pb, built]
  end

  def info(pb)
    pb.outputs[0][1]
  end

  # Đợt 400 trên hình đứng: v = 2000 - z -> mặt trên v = 1582; đợt 768: mặt dưới v = 1232.
  def clear_dim(extra = {})
    { 'id' => 'md1', 'a' => [600, 1232], 'b' => [600, 1582], 'axis' => 'v', 'kind' => 'clear', 'side' => 'l', 'off' => 4.5 }.merge(extra)
  end

  # toạ độ x của các đoạn thẳng trong nhóm DIM thủ công (SVG: path d="Mx yLx y")
  def xs(g)
    g.scan(/d="M([\d.]+) [\d.]+L([\d.]+) /).flatten.map(&:to_f)
  end

  def mdim_svg(svg)
    svg.scan(%r{<g class="mdim"[^>]*>(.*?)</g>}m).map(&:first)
  end
end

class TestManualDim < Minitest::Test
  def test_1_do_thong_thuy_hai_dot_ke_350
    pb, built = MD.run('front' => [MD.clear_dim])
    d = MD.info(pb)['manual_dims']['front'][0]
    assert_equal 350.0, d['value']
    assert_equal 'ok', d['status']
    assert d['ra'], 'điểm đầu bám vào bộ phận'
    assert_equal built[1][4].persistent_id.to_s, d['ra']['p'].split('/').last, 'điểm đầu bám đợt 768'
    assert_equal 'y1', d['ra']['y'], 'mặt DƯỚI của đợt phía trên'
    assert_equal built[1][3].persistent_id.to_s, d['rb']['p'].split('/').last, 'điểm cuối bám đợt 400'
    assert_equal 'y0', d['rb']['y'], 'mặt TRÊN của đợt phía dưới'
    svg = pb.outputs[0][0]
    g = MD.mdim_svg(svg)
    assert_equal 1, g.length
    assert_includes g[0], '>350<'
  end

  def test_2_dat_ben_trai_hinh
    pb, = MD.run('front' => [MD.clear_dim])
    fr = MD.info(pb)['frames']['front']
    xs = MD.xs(MD.mdim_svg(pb.outputs[0][0])[0])
    ox = fr[0]
    assert xs.any? { |x| (x - (ox - 4.5)).abs < 0.05 }, 'đường DIM cách mép trái 4.5 mm giấy'
    assert xs.all? { |x| x <= ox + 600 / fr[2] + 0.01 }
  end

  def test_3_snap_chi_gom_hinh_hoc_thuc
    pb, = MD.run('front' => [MD.clear_dim])
    sn = MD.info(pb)['snap']['front']
    assert sn['segs'].length.positive?
    # mặt dưới đợt 768 (v = 1232) và mặt trên đợt 400 (v = 1582) có trong dữ liệu bắt điểm
    [1232.0, 1582.0].each do |vv|
      assert sn['segs'].any? { |s| (s[1] - vv).abs < 0.05 && (s[3] - vv).abs < 0.05 && (s[2] - s[0]).abs > 1000 }, "cạnh ngang v=#{vv}"
    end
    refute MD.info(pb)['snap'].key?('iso')
  end

  def test_5_doi_ti_le_khong_doi_so_do
    p20, = MD.run('front' => [MD.clear_dim], 'scale' => 20)
    p10, = MD.run('front' => [MD.clear_dim], 'scale' => 10)
    assert_equal 350.0, MD.info(p20)['manual_dims']['front'][0]['value']
    assert_equal 350.0, MD.info(p10)['manual_dims']['front'][0]['value']
    assert_includes MD.mdim_svg(p10.outputs[0][0])[0], '>350<'
    f10 = MD.info(p10)['frames']['front']
    xs = MD.xs(MD.mdim_svg(p10.outputs[0][0])[0])
    assert xs.any? { |x| (x - (f10[0] - 4.5)).abs < 0.05 }, 'vẫn cách mép trái 4.5 mm giấy ở 1:10'
  end

  def test_6_keo_duong_dim_chi_doi_vi_tri
    a, = MD.run('front' => [MD.clear_dim('off' => 4.5)])
    b, = MD.run('front' => [MD.clear_dim('off' => 12.0)])
    assert_equal MD.info(a)['manual_dims']['front'][0]['value'], MD.info(b)['manual_dims']['front'][0]['value']
    fr = MD.info(b)['frames']['front']
    xs = MD.xs(MD.mdim_svg(b.outputs[0][0])[0])
    assert xs.any? { |x| (x - (fr[0] - 12)).abs < 0.05 }
  end

  def test_7_doi_diem_bam_cap_nhat_gia_tri
    pb, = MD.run('front' => [MD.clear_dim('b' => [600, 1982], 'rb' => nil)]) # mặt trên đáy z=18
    d = MD.info(pb)['manual_dims']['front'][0]
    assert_equal 750.0, d['value']
    assert_equal 'y0', d['rb']['y']
  end

  def test_8_luu_mo_lai_va_trien_khai_lai_giu_dim
    project, = MD.page('front' => [MD.clear_dim, MD.clear_dim('id' => 'md2', 'b' => [600, 1982])])
    doc = AL::ProjectStore.export_doc(project)
    back = AL::ProjectStore.import_doc(JSON.parse(JSON.generate(doc)))
    dims = back['pages'][0]['manual_dims']['front']
    assert_equal %w[md1 md2], dims.map { |d| d['id'] }
    assert_equal [600.0, 1232.0], dims[0]['a']
    # triển khai lại trang (cập nhật model) không xoá DIM thủ công
    AL::ProjectStore.add_pages(back, [101], ->(_pid) { { 'name' => 'Tủ', 'root' => true } }, true)
    assert_equal 2, back['pages'][0]['manual_dims']['front'].length
    assert_equal 'clear', back['mdim']['kind']
    assert_equal 'l', back['mdim']['side']
    assert back['mdim']['snap']
  end

  def test_9_xuat_pdf_co_dim_thu_cong
    pdf, = MD.run({ 'front' => [MD.clear_dim] }, {}, :pdf)
    pdf0, = MD.run({}, {}, :pdf)
    assert pdf.outputs[0][0].bytesize > pdf0.outputs[0][0].bytesize, 'PDF có thêm nét/chữ của DIM thủ công'
    assert_equal 350.0, MD.info(pdf)['manual_dims']['front'][0]['value']
  end

  def test_10_auto_dim_van_giu_va_khong_ghi_de
    pb, = MD.run('front' => [MD.clear_dim])
    svg = pb.outputs[0][0]
    assert_match(/class="dimset"/, svg, 'Auto DIM vẫn còn')
    3.times { pb, = MD.run('front' => [MD.clear_dim]) }
    assert_equal 1, MD.mdim_svg(pb.outputs[0][0]).length, 'không nhân bản DIM thủ công khi dựng lại'
    off, = MD.run({ 'front' => [MD.clear_dim] }, 'dims' => false)
    refute_match(/class="dimset"/, off.outputs[0][0])
    assert_equal 1, MD.mdim_svg(off.outputs[0][0]).length, 'tắt Auto DIM: DIM thủ công vẫn hiện'
  end

  def test_an_dim
    pb, = MD.run('front' => [MD.clear_dim('hidden' => true)])
    assert_empty MD.mdim_svg(pb.outputs[0][0])
    assert_equal 1, MD.info(pb)['manual_dims']['front'].length, 'DIM ẩn vẫn còn trong danh sách'
  end

  def test_cap_nhat_model_diem_di_theo_dot
    built = MD.build(768)
    first, = MD.run({ 'front' => [MD.clear_dim] }, {}, :svg, built)
    d = MD.info(first)['manual_dims']['front'][0]
    # model đổi: đợt 768 dời lên 800 (cùng instance) -> điểm đầu đi theo mặt dưới đợt, thông thủy = 382
    built[1][4].define_singleton_method(:transformation) { X.tr(18 * PX::IN, 0, 800 * PX::IN) }
    pb, = MD.run({ 'front' => [d] }, {}, :svg, built)
    nd = MD.info(pb)['manual_dims']['front'][0]
    assert_equal 'ok', nd['status']
    assert_equal 382.0, nd['value']
  end

  def test_mat_lien_ket
    v = { key: 'front', w: 1200.0, h: 2000.0, lines: [[[0, 100], [1200, 100]]], part_rects: [] }
    ok = AL::ManualDim.resolve(v, { 'a' => [500, 100], 'b' => [500, 400], 'axis' => 'v', 'ra' => false, 'rb' => false })
    assert_equal 'broken', ok['status'], 'điểm cuối không nằm trên nét nào'
    good = AL::ManualDim.resolve({ key: 'front', w: 1200.0, h: 2000.0, lines: [[[0, 100], [1200, 100]], [[0, 400], [1200, 400]]], part_rects: [] },
                                 { 'a' => [500, 100], 'b' => [500, 400], 'axis' => 'v', 'ra' => false, 'rb' => false })
    assert_equal 'ok', good['status']
    gone = AL::ManualDim.resolve(v, { 'a' => [500, 100], 'b' => [500, 400], 'axis' => 'v', 'ra' => false,
                                      'rb' => { 'p' => '9/9', 'x' => 0.5, 'y' => 'y0' } })
    assert_equal 'broken', gone['status'], 'bộ phận bị xoá khỏi model'
  end

  def test_phuong_do_khong_lay_duong_cheo
    d = { 'a' => [100, 1232], 'b' => [700, 1582] }
    assert_equal 350.0, AL::ManualDim.value(d.merge('axis' => 'v'))
    assert_equal 600.0, AL::ManualDim.value(d.merge('axis' => 'h'))
    assert_in_delta Math.hypot(600, 350), AL::ManualDim.value(d.merge('axis' => 'a')), 1e-6
  end

  def test_clean_bo_trung_va_rac
    raw = { 'front' => [MD.clear_dim, MD.clear_dim('id' => 'x2'), { 'a' => 'xx' }, MD.clear_dim('id' => 'x3', 'a' => [600, 1582], 'b' => [600, 1232])],
            'bad key!' => [MD.clear_dim], 'sec:A' => [MD.clear_dim], 'cp:3' => [] }
    c = AL::ManualDim.clean(raw)
    assert_equal ['front', 'sec:A'], c.keys
    assert_equal 1, c['front'].length, 'cùng 2 điểm + cùng phương đo = trùng'
  end

  def test_mat_cat_bat_net_cat
    v = { key: 'sec:A', w: 1200.0, h: 2000.0, lines: [], cut: { segs: [[[18, 1232], [1182, 1232]], [[18, 1582], [1182, 1582]]] } }
    r = AL::ManualDim.resolve(v, MD.clear_dim.merge('ra' => nil, 'rb' => nil))
    assert_equal 'ok', r['status']
    assert_equal false, r['ra'], 'mặt cắt không có khung bộ phận -> bám theo nét cắt'
    cv = AL::Canvas.new(:svg, 420, 297)
    AL::ManualDim.draw(cv, v, 20, 50, 30, [MD.clear_dim], 1)
    assert_match(/>350</, cv.svg)
  end

  # Hàm bắt điểm / đo thông thủy phía giao diện (ui/mdim.js) – chạy bằng Node nếu máy có.
  def test_js_bat_diem_va_thong_thuy
    skip 'không có node' unless system('node --version > /dev/null 2>&1')
    out = `node #{File.join(__dir__, 'js', 'test_mdim.js')} 2>&1`
    assert $?.success?, out
  end
end
