# encoding: UTF-8
# Chú thích (Text, nhiều dòng, Leader, vật liệu) và CHI TIẾT phóng to.
require_relative 'test_helper'
require 'rexml/document'

class TestAnnotationDetail < Minitest::Test
  def page(extra = {})
    AL::ProjectStore.default_page_settings.merge('offsets' => {}, 'sections' => []).merge(extra)
  end

  def render(fmt, views, pg)
    pw, ph = AL::Sheet.paper('A3')
    cv = AL::Canvas.new(fmt, pw, ph)
    info = AL::Sheet.render(cv, views, [{ 'name' => 'Gỗ óc chó', 'color' => '#6B5643' }], pg, {}, pw, ph)
    [cv, info]
  end

  def test_lam_sach_chu_thich
    list = AL::AnnotationEngine.clean([
      { 'type' => 'leader', 'x' => 100, 'y' => 50, 'tx' => 90, 'ty' => 70, 'text' => 'LẮP LED', 'color' => 'red' },
      { 'type' => 'hack' }, { 'type' => 'text', 'size' => 999, 'layer' => '' }
    ])
    assert_equal %w[leader text], list.map { |n| n['type'] }
    assert_equal '#1E1E1E', list[0]['color'], 'màu sai định dạng -> mặc định'
    assert_equal 20.0, list[1]['size']
    assert_equal 'GHI CHÚ', list[1]['layer']
  end

  def test_chu_thich_ra_svg_va_pdf_dung_chu_tieng_viet
    notes = [
      { 'id' => 'a', 'type' => 'text', 'x' => 40, 'y' => 30, 'text' => 'LƯU Ý: KIỂM TRA KÍCH THƯỚC THỰC TẾ', 'size' => 2.5 },
      { 'id' => 'b', 'type' => 'mtext', 'x' => 40, 'y' => 40, 'text' => "Dòng một\nDòng hai", 'size' => 2.5 },
      { 'id' => 'c', 'type' => 'leader', 'x' => 120, 'y' => 60, 'tx' => 100, 'ty' => 80, 'text' => 'LẮP LED', 'arrow' => 'arrow' },
      { 'id' => 'd', 'type' => 'material', 'x' => 120, 'y' => 90, 'tx' => 100, 'ty' => 100, 'text' => 'MAT-01: Gỗ óc chó', 'layer' => 'VẬT LIỆU' }
    ]
    pg = page('notes' => AL::AnnotationEngine.clean(notes))
    v = AL::Geometry.project(Fake.cabinet, 'front')
    cv, = render(:svg, [v], pg)
    doc = REXML::Document.new(cv.svg)
    assert_equal %w[a b c d], REXML::XPath.match(doc, "//g[@class='note']").map { |g| g.attributes['data-id'] }
    texts = REXML::XPath.match(doc, '//text').map(&:text)
    ['LƯU Ý: KIỂM TRA KÍCH THƯỚC THỰC TẾ', 'Dòng một', 'Dòng hai', 'LẮP LED', 'MAT-01: Gỗ óc chó'].each { |t| assert_includes texts, t }
    # layer ẩn: không vẽ
    cv2, = render(:svg, [v], pg.merge('hidden_layers' => ['VẬT LIỆU']))
    ids = REXML::XPath.match(REXML::Document.new(cv2.svg), "//g[@class='note']").map { |g| g.attributes['data-id'] }
    assert_equal %w[a b c], ids, 'chú thích trên layer ẩn không được vẽ'
    # PDF: chữ được nhúng qua ToUnicode -> tìm lại được bằng pdftotext nếu có
    pdf_cv, = render(:pdf, [v], pg)
    pw, ph = AL::Sheet.paper('A3')
    path = File.join(Dir.tmpdir, 'alp_notes.pdf')
    File.binwrite(path, AL::Pdf.pdf_pages([pdf_cv.content], [pw * AL::Pdf::MM_TO_PT, ph * AL::Pdf::MM_TO_PT]))
    if system('which pdftotext > /dev/null 2>&1')
      txt = `pdftotext -enc UTF-8 #{path} -`.force_encoding("UTF-8")
      assert_includes txt, 'LẮP LED'
      assert_includes txt, 'MAT-01: Gỗ óc chó'
    end
  end

  def test_chi_tiet_phong_to_lay_hinh_hoc_that
    cap = Fake.cabinet
    sec = AL::SectionEngine.project(cap, { 'label' => 'A', 'axis' => 'x', 'pos' => 1100, 'dir' => 1 })
    # khoanh góc dưới của mặt cắt A-A: vùng chứa tấm đáy (cao độ 60..78 => v = 2698-78 .. 2698-60)
    det = AL::DetailEngine.clean([{ 'n' => 1, 'src' => 'sec:A', 'rect' => [0, 2560, 120, 2698], 'scale' => 4 }]).first
    d = AL::DetailEngine.build(sec, det)
    assert_equal 'CHI TIẾT 1', d[:name]
    assert_equal 4, d[:fixed_scale]
    refute_empty d[:lines]
    d[:lines].flatten(1).each { |x, y| assert(x.between?(-1e-6, 120 + 1e-6) && y.between?(-1e-6, 138 + 1e-6)) }
    # DIM trong chi tiết đo được chiều dày tấm đáy 18 và chân 60
    ys = AL::DimensionEngine.breaks(d[:lines], 1, d[:h], 50, 0)
    segs = ys.each_cons(2).map { |a, b| (b - a).round }
    assert_includes segs, 18
    assert_includes segs, 60
    pg = page('sections' => [], 'details' => [det])
    cv, info = render(:svg, [sec, d], pg)
    assert_equal 4, info['frames']['det:1'][2], 'chi tiết dùng tỉ lệ riêng 1:4'
    doc = REXML::Document.new(cv.svg)
    assert_equal ['1'], REXML::XPath.match(doc, "//g[@class='detmark']").map { |g| g.attributes['data-det'] }
    assert_includes REXML::XPath.match(doc, '//text').map(&:text), 'TL 1:4'
  end

  def test_vung_khoanh_trong_rong_bao_loi_ro
    v = AL::Geometry.project(Fake.box(Fake.capture, 0, 0, 0, 100, 100, 100), 'front')
    det = { 'n' => 2, 'src' => 'front', 'rect' => [500, 500, 600, 600], 'scale' => 2 }
    assert_raises(ArgumentError) { AL::DetailEngine.build(v, det) }
  end

  def test_luu_trang_giu_chu_thich_chi_tiet
    pg = AL::ProjectStore.clean_page('pid' => 3, 'notes' => [{ 'type' => 'text', 'text' => 'A' }],
                                     'details' => [{ 'n' => 1, 'src' => 'front', 'rect' => [0, 0, 10, 10], 'scale' => 5 }],
                                     'offsets' => { 'det:1' => [3, 4] })
    assert_equal 1, pg['notes'].length
    assert_equal 1, pg['details'].length
    assert_equal({ 'det:1' => [3.0, 4.0] }, pg['offsets'])
  end
end
