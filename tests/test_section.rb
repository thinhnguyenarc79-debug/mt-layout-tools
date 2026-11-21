# encoding: UTF-8
# Mặt cắt thật: giao mặt phẳng với hình học, vòng kín, hatch, đề xuất vị trí, ký hiệu trên mặt đứng.
require_relative 'test_helper'
require 'rexml/document'

class TestSection < Minitest::Test
  SE = AL::SectionEngine

  def sec(axis, pos, dir, label = 'A')
    { 'label' => label, 'axis' => axis, 'pos' => pos, 'dir' => dir }
  end

  def test_cat_doc_qua_tu_ra_tiet_dien_that_cua_tung_tam
    cap = Fake.cabinet # 2410 x 350 x 2698, ván 18, vách tại x=642..660 và 1569..1587, 2 đợt trong khoang giữa
    v = SE.project(cap, sec('x', 1100, 1)) # cắt qua khoang giữa (có 2 đợt)
    assert_equal 'MẶT CẮT A-A', v[:name]
    assert_in_delta 350, v[:w], 0.5, 'bề rộng mặt cắt = chiều sâu tủ'
    assert_in_delta 2698, v[:h], 0.5
    # Mỗi tấm bị cắt là 1 vòng kín: nóc, đáy, 2 đợt = 4 tiết diện
    loops = v[:cut][:loops]
    assert_equal 4, loops.length
    ths = loops.map { |lp| ys = lp.map { |p| p[1] }; (ys.max - ys.min).round }
    assert_equal [18, 18, 18, 18], ths, 'chiều dày tiết diện đúng 18 mm'
    deps = loops.map { |lp| xs = lp.map { |p| p[0] }; (xs.max - xs.min).round }
    assert_equal [350] * 4, deps
  end

  def test_cat_ngang_ra_tiet_dien_vach
    v = SE.project(Fake.cabinet, sec('z', 1500, -1, 'B'))
    assert_equal 'MẶT CẮT B-B', v[:name]
    widths = v[:cut][:loops].map { |lp| xs = lp.map { |p| p[0] }; (xs.max - xs.min).round }.sort
    assert_equal [18, 18, 18, 18], widths, '2 hông + 2 vách bị cắt'
  end

  def test_chi_giu_phan_phia_huong_nhin
    cap = Fake.capture
    Fake.box(cap, 0, 0, 0, 100, 100, 100)
    Fake.box(cap, 300, 0, 0, 400, 100, 100) # nằm hoàn toàn phía bị bỏ
    v = SE.project(cap, sec('x', 50, -1)) # nhìn về -X, giữ x <= 50
    assert_in_delta 100, v[:w], 0.01
    assert_equal 1, v[:cut][:loops].length
  end

  def test_mat_phang_ngoai_vat_the
    cap = Fake.box(Fake.capture, 0, 0, 0, 100, 100, 100)
    assert_raises(ArgumentError) { SE.project(cap, sec('x', 500, 1)) }
  end

  def test_hatch_nam_trong_vong
    sq = [[0, 0], [10, 0], [10, 10], [0, 10]]
    lines = SE.hatch([sq], 1.0)
    refute_empty lines
    lines.flatten(1).each { |x, y| assert(x >= -1e-6 && x <= 10 + 1e-6 && y >= -1e-6 && y <= 10 + 1e-6) }
    hole = [[3, 3], [7, 3], [7, 7], [3, 7]]
    with_hole = SE.hatch([sq, hole], 1.0)
    mid = with_hole.select { |a, b| [a, b].any? { |x, y| x > 3.2 && x < 6.8 && y > 3.2 && y < 6.8 } }
    assert_empty mid, 'không hatch vào lỗ'
  end

  def test_de_xuat_tu_cau_tao_do_duoc
    front = AL::Geometry.project(Fake.cabinet, 'front')
    s = SE.suggest(front)
    assert_equal %w[A B C], s.map { |x| x['label'] }
    a = s[0]
    assert_equal 'x', a['axis']
    assert_in_delta 660 + 909 / 2.0, a['pos'], 1.0, 'A-A cắt giữa khoang rộng nhất (909)'
    assert_equal 'z', s[1]['axis']
    assert s.all? { |x| x['auto'] }
  end

  def test_trang_co_ky_hieu_va_ban_cat_tuong_ung
    cap = Fake.cabinet
    front = AL::Geometry.project(cap, 'front')
    secs = SE.suggest(front)
    views = [front] + secs.map { |x| SE.project(cap, x) }
    page = AL::ProjectStore.default_page_settings.merge('offsets' => {}, 'sections' => secs)
    pw, ph = AL::Sheet.paper('A3')
    cv = AL::Canvas.new(:svg, pw, ph)
    info = AL::Sheet.render(cv, views, [], page, {}, pw, ph)
    doc = REXML::Document.new(cv.svg)
    marks = REXML::XPath.match(doc, "//g[@class='secmark']").map { |g| g.attributes['data-sec'] }
    assert_equal %w[A B C], marks, 'mặt đứng có ký hiệu A, B, C'
    assert_equal %w[front sec:A sec:B sec:C].sort, info['boxes'].keys.sort, 'mỗi ký hiệu có 1 bản vẽ mặt cắt'
    pdf = AL::Canvas.new(:pdf, pw, ph)
    AL::Sheet.render(pdf, views, [], page, {}, pw, ph)
    out = AL::Pdf.pdf_pages([pdf.content], [pw * AL::Pdf::MM_TO_PT, ph * AL::Pdf::MM_TO_PT])
    File.binwrite(File.join(Dir.tmpdir, 'alp_section.pdf'), out)
    File.write(File.join(Dir.tmpdir, 'alp_section.svg'), cv.svg)
  end

  def test_luu_du_an_giu_mat_cat
    pg = AL::ProjectStore.clean_page('pid' => 1, 'sections' => [sec('x', 10, 1), sec('q', 1, 1, 'B'), sec('z', 5, -1, 'A')],
                                     'offsets' => { 'sec:A' => [1, 2], 'sec:a' => [0, 0] })
    assert_equal [['A', 'x']], pg['sections'].map { |x| [x['label'], x['axis']] }
    assert_equal({ 'sec:A' => [1.0, 2.0] }, pg['offsets'])
    assert_nil AL::ProjectStore.clean_page('pid' => 1)['sections'], 'chưa có -> để plugin đề xuất'
    assert_equal [], AL::ProjectStore.clean_page('pid' => 1, 'sections' => [])['sections'], 'đã xoá hết thì giữ rỗng'
  end
end
