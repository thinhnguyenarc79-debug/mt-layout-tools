# encoding: UTF-8
require_relative 'test_helper'
require 'rexml/document'

class TestProjection < Minitest::Test
  def setup
    @cap = Fake.box(Fake.capture, 0, 0, 0, 2000, 600, 2400)
  end

  def test_kich_thuoc_tung_hinh_chieu
    exp = { 'front' => [2000, 2400], 'back' => [2000, 2400], 'left' => [600, 2400], 'right' => [600, 2400],
            'top' => [2000, 600], 'bottom' => [2000, 600] }
    exp.each do |k, (w, h)|
      v = AL::Geometry.project(@cap, k)
      assert_in_delta w, v[:w], 0.01, k
      assert_in_delta h, v[:h], 0.01, k
    end
  end

  def test_khong_co_canh_trung_lap_va_dung_4_canh_bao
    v = AL::Geometry.project(@cap, 'front')
    assert_equal 4, v[:lines].length, 'mặt đứng của hộp chỉ còn 4 cạnh bao thấy được'
  end

  def test_truc_do_khong_ghi_dim
    refute AL::Geometry.project(@cap, 'iso')[:dims]
  end
end

class TestHiddenLine < Minitest::Test
  def test_hop_phia_sau_bi_che
    cap = Fake.capture
    Fake.box(cap, 0, 0, 0, 1000, 100, 1000)        # tấm trước
    Fake.box(cap, 200, 300, 200, 800, 400, 800)    # hộp nhỏ phía sau, bị che hoàn toàn
    v = AL::Geometry.project(cap, 'front')
    inner = v[:lines].select { |a, b| [a, b].all? { |p| p[0] > 1 && p[0] < 999 && p[1] > 1 && p[1] < 999 } }
    assert_empty inner, 'cạnh của hộp phía sau phải bị khử'
  end

  def test_doan_bi_che_mot_phan
    cap = Fake.capture
    Fake.box(cap, 0, 0, 0, 500, 100, 1000)         # tấm trước che nửa trái
    Fake.box(cap, 0, 300, 400, 1000, 400, 600)     # thanh ngang phía sau dài 1000
    v = AL::Geometry.project(cap, 'front')
    seen = v[:lines].select { |a, b| (a[1] - b[1]).abs < 0.01 && [a[0], b[0]].max > 500 }
    refute_empty seen
    seen.each { |a, b| assert_operator [a[0], b[0]].min, :>=, 499.9, 'phần nằm sau tấm trước không được vẽ' }
  end
end

class TestFrontDirection < Minitest::Test
  def test_xoay_mat_truoc
    f = AL::Geometry::FRONTS
    assert_equal [1, 2], f['-Y'].call(1, 2)
    assert_equal [-1, -2], f['+Y'].call(1, 2)
    # Mặt trước ở -X: điểm (-1, 0) phải về (0, -1) (phía người xem).
    assert_equal [0, -1], f['-X'].call(-1, 0)
    assert_equal [0, -1], f['+X'].call(1, 0)
  end
end

class TestDimension < Minitest::Test
  def test_do_dung_tung_khoang_khong_chia_deu
    v = AL::Geometry.project(Fake.cabinet, 'front')
    xs = AL::DimensionEngine.breaks(v[:lines], 0, v[:w], [v[:h] * 0.3, 150].min, 0)
    segs = xs.each_cons(2).map { |a, b| (b - a).round }
    assert_equal [18, 624, 18, 909, 18, 805, 18], segs # 2410 - 4 ván - 624 - 909 = 805
    assert_equal 2410, segs.sum
  end

  def test_chuoi_dung_theo_ke
    v = AL::Geometry.project(Fake.cabinet, 'front')
    ys = AL::DimensionEngine.breaks(v[:lines], 1, v[:h], [v[:w] * 0.3, 150].min, 0)
    segs = ys.each_cons(2).map { |a, b| (b - a).round }
    assert_equal 2698, segs.sum
    assert_includes segs, 60, 'chân tủ 60'
    assert_operator segs.count(18), :>=, 4, 'có độ dày ván 18'
  end

  def test_gop_khoang_nho
    v = AL::Geometry.project(Fake.cabinet, 'front')
    xs = AL::DimensionEngine.breaks(v[:lines], 0, v[:w], 150, 25)
    segs = xs.each_cons(2).map { |a, b| (b - a).round }
    assert(segs.all? { |s| s >= 25 })
    assert_equal 2410, segs.sum
  end

  def test_lam_tron
    assert_equal '625', AL::DimensionEngine.label(624.6, 1)
    assert_equal '625', AL::DimensionEngine.label(623, 5)
    assert_equal '12.5', AL::DimensionEngine.label(12.4, 0.5)
  end
end

class TestSheet < Minitest::Test
  def views(keys)
    cap = Fake.cabinet
    keys.map { |k| AL::Geometry.project(cap, k) }
  end

  def page(extra = {})
    AL::ProjectStore.default_page_settings.merge('offsets' => {}).merge(extra)
  end

  def render(fmt, keys, pg = page)
    pw, ph = AL::Sheet.paper('A3')
    cv = AL::Canvas.new(fmt, pw, ph)
    info = AL::Sheet.render(cv, views(keys), [{ 'name' => 'Gỗ', 'color' => '#8B6B4A' }], pg,
                            { 'sheet_name' => 'TỦ ÁO', 'sheet_no' => 'A-01', 'date' => '21.11.2026' }, pw, ph)
    [cv, info]
  end

  def test_hinh_nam_trong_vung_ve_khong_de_khung_ten
    _, info = render(:svg, %w[front left top iso])
    _, tb_x, area = AL::Sheet.frames(420.0, 297.0)
    assert_equal 4, info['boxes'].length
    info['boxes'].each do |k, (x, y, w, h)|
      assert_operator x, :>=, area[0] - 0.01, k
      assert_operator y, :>=, area[1] - 0.01, k
      assert_operator x + w, :<=, tb_x, "#{k} không được đè khung tên"
      assert_operator y + h, :<=, area[3] + 0.01, k
    end
  end

  def test_cac_hinh_khong_chong_nhau
    _, info = render(:svg, %w[front open left top iso])
    boxes = info['boxes'].values
    boxes.combination(2).each do |a, b|
      overlap = a[0] < b[0] + b[2] - 0.01 && b[0] < a[0] + a[2] - 0.01 && a[1] < b[1] + b[3] - 0.01 && b[1] < a[1] + a[3] - 0.01
      refute overlap, "chồng nhau: #{a.inspect} #{b.inspect}"
    end
  end

  def test_ti_le_khong_vua_thi_tu_doi
    _, info = render(:svg, %w[front left top iso], page('scale' => 5))
    assert_operator info['scale'], :>, 5
    assert_match(/không vừa/, info['note'])
  end

  def test_keo_hinh_bi_kep_trong_vung_ve
    _, info = render(:svg, %w[front], page('offsets' => { 'front' => [5000, 5000] }))
    _, tb_x, area = AL::Sheet.frames(420.0, 297.0)
    x, y, w, h = info['boxes']['front']
    assert_operator x + w, :<=, tb_x + 0.01
    assert_operator y + h, :<=, area[3] + 0.01
  end

  def test_svg_hop_le
    cv, = render(:svg, %w[front left])
    doc = REXML::Document.new(cv.svg)
    assert_equal 'svg', doc.root.name
    assert_equal 2, REXML::XPath.match(doc, "//g[@class='view']").length
  end

  def test_pdf_nhieu_trang
    pw, ph = AL::Sheet.paper('A3')
    contents = 3.times.map { render(:pdf, %w[front top]).first.content }
    pdf = AL::Pdf.pdf_pages(contents, [pw * AL::Pdf::MM_TO_PT, ph * AL::Pdf::MM_TO_PT])
    assert pdf.start_with?('%PDF-1.4')
    assert_includes pdf, '/Count 3'
    assert_includes pdf, '/MediaBox [0 0 1190.55118 841.88976]', 'đúng khổ A3 (pt)'
    File.binwrite(File.join(Dir.tmpdir, 'alp_test.pdf'), pdf)
  end
end

class TestProjectStore < Minitest::Test
  def test_lam_sach_du_lieu
    raw = { 'name' => 'X' * 500, 'paper' => 'B9', 'exclude_tags' => ['a', 'a'],
            'pages' => [{ 'pid' => '12', 'views' => %w[front hack], 'scale' => 99_999, 'front' => 'zz',
                          'offsets' => { 'front' => [1, 2], 'evil' => [0, 0], 'left' => 'x' } }] }
    p = AL::ProjectStore.clean(raw)
    assert_equal 200, p['name'].length
    assert_equal 'A3', p['paper']
    assert_equal ['a'], p['exclude_tags']
    pg = p['pages'][0]
    assert_equal 12, pg['pid']
    assert_equal ['front'], pg['views']
    assert_equal 500, pg['scale']
    assert_equal '-Y', pg['front']
    assert_equal({ 'front' => [1.0, 2.0] }, pg['offsets'])
    refute_empty pg['id']
  end

  def test_tu_choi_du_lieu_sai
    assert_raises(ArgumentError) { AL::ProjectStore.clean('abc') }
  end
end
