# encoding: UTF-8
# v2.17.1: CHI TIẾT 2, 3... bị trống hình học do trùng id clipPath giữa các hình vẽ trên canvas con.
require_relative 'test_helper'
require_relative 'test_manual_dim'

module DM
  module_function

  # vùng (mm thật, hệ hình MẶT ĐỨNG tủ nhiều đợt) đều có nét
  RECTS = [[0, 1150, 300, 1350], [800, 1500, 1200, 1700], [0, 1900, 400, 2000], [500, 1180, 700, 1260], [0, 0, 200, 100],
           [1000, 0, 1200, 120], [300, 760, 600, 840], [900, 760, 1200, 840], [0, 1550, 150, 1650], [1050, 1950, 1200, 2000]].freeze

  def dets(n, extra = {})
    RECTS.first(n).each_with_index.map { |r, i| { 'n' => i + 1, 'src' => 'front', 'rect' => r, 'scale' => 5 }.merge(extra) }
  end

  def run(details, extra = {}, fmt = :svg)
    pb, = MD.run({}, { 'details' => details, 'views' => %w[front top] }.merge(extra), fmt)
    pb
  end

  def all_svg(pb)
    pb.outputs.map(&:first).join
  end

  # mỗi chi tiết: clipPath riêng, khung cắt trùng khung hình trên giấy, bên trong có nét vẽ
  def check(t, pb)
    svg = all_svg(pb)
    ids = svg.scan(/<clipPath id="([^"]+)"/).flatten
    t.assert_equal ids.uniq.length, ids.length, "id clipPath trùng: #{ids.inspect}"
    pb.outputs.each do |s, info|
      (info['detail_stats'] || {}).each do |k, st|
        g = s[%r{<g class="view" data-key="#{Regexp.escape(k)}">(.*?)<g class="dimset}m, 1] || s[%r{<g class="view" data-key="#{Regexp.escape(k)}">(.*)}m, 1]
        cid = g[/<clipPath id="([^"]+)">/, 1]
        t.refute_nil cid, "#{k} có clipPath"
        x, y, w, h = g[/<clipPath id="#{cid}"><rect x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)"/, 0] &&
                     Regexp.last_match.captures.map(&:to_f)
        fr = info['frames'][k]
        t.assert_in_delta fr[0], x, 0.01, "#{k}: vùng cắt đúng chỗ hình trên giấy"
        t.assert_in_delta fr[1], y, 0.01
        t.assert_in_delta fr[3] / fr[2], w, 0.01
        t.assert_in_delta fr[4] / fr[2], h, 0.01
        inside = g[%r{clip-path="url\(##{cid}\)">(.*?)</g>}m, 1]
        t.assert inside && inside.scan('<path').length.positive?, "#{k}: có nét bên trong vùng cắt"
        t.assert st['elements'].positive?, "#{k}: số phần tử vẽ > 0"
      end
    end
    svg
  end
end

class TestDetailMulti < Minitest::Test
  def test_1_2_3_ba_chi_tiet_deu_co_hinh_hoc
    pb = DM.run(DM.dets(3))
    DM.check(self, pb)
    st = MD.info(pb)['detail_stats']
    assert_equal %w[det:1 det:2 det:3], st.keys.sort
    st.each_value { |s| assert s['lines_in'].positive? }
    assert_equal [800, 1500, 1200, 1700], st['det:2']['rect'], 'không nhầm vùng của chi tiết khác'
  end

  def test_4_mười_chi_tiet_lien_tiep
    pb = DM.run(DM.dets(10))
    DM.check(self, pb)
    n = pb.outputs.sum { |_, i| (i['detail_stats'] || {}).length }
    assert_equal 10, n
  end

  def test_5_cung_nguon_khac_vung
    pb = DM.run(DM.dets(5))
    st = pb.outputs.map { |_, i| i['detail_stats'] || {} }.reduce({}, :merge)
    rects = st.values.map { |s| s['rect'] }
    assert_equal rects.uniq.length, rects.length
    st.each { |k, s| assert_equal DM::RECTS[k.split(':').last.to_i - 1], s['rect'] }
  end

  def test_6_nguon_khac_nhau
    d = [{ 'n' => 1, 'src' => 'front', 'rect' => [0, 1150, 300, 1350], 'scale' => 5 },
         { 'n' => 2, 'src' => 'top', 'rect' => [0, 0, 300, 200], 'scale' => 5 }]
    pb = DM.run(d)
    DM.check(self, pb)
    st = MD.info(pb)['detail_stats']
    assert_equal 'front', st['det:1']['src']
    assert_equal 'top', st['det:2']['src']
  end

  def test_7_di_chuyen_chi_tiet
    base = DM.run(DM.dets(3))
    vp = { 'det:2' => { 'x_mm' => 40, 'y_mm' => 150, 'sheet' => 0, 'placement_mode' => 'manual' },
           'det:3' => { 'x_mm' => 200, 'y_mm' => 200, 'sheet' => 0, 'placement_mode' => 'manual' } }
    moved = DM.run(DM.dets(3), 'view_props' => vp)
    DM.check(self, moved)
    refute_equal MD.info(base)['frames']['det:2'], MD.info(moved)['frames']['det:2']
    %w[det:2 det:3].each do |k|
      a = MD.info(base)['detail_stats'][k]
      b = MD.info(moved)['detail_stats'][k]
      assert_equal a['rect'], b['rect'], 'dời chỉ đổi vị trí, không đổi vùng trích'
      assert_equal a['lines_in'], b['lines_in']
      assert_equal a['polylines'], b['polylines']
    end
  end

  def test_8_doi_ti_le_tung_chi_tiet
    a = DM.run(DM.dets(3))
    b = DM.run(DM.dets(3).each { |d| d['scale'] = 10 if d['n'] == 2 })
    DM.check(self, b)
    sa = MD.info(a)['detail_stats']['det:2']
    sb = MD.info(b)['detail_stats']['det:2']
    assert_equal 10, sb['scale']
    assert_equal sa['rect'], sb['rect']
    assert_equal sa['lines_in'], sb['lines_in']
    assert_equal MD.info(a)['detail_stats']['det:1']['scale'], MD.info(b)['detail_stats']['det:1']['scale'], 'chi tiết khác giữ tỉ lệ'
  end

  def test_10_nhieu_to_va_dung_lai
    # chi tiết trên 2 tờ (tờ 2 do người dùng chọn)
    d = DM.dets(4).each { |x| x['sheet'] = x['n'] > 2 ? 1 : 0 }
    vp = { 'det:3' => { 'sheet' => 1 }, 'det:4' => { 'sheet' => 1 } }
    pb = DM.run(d, 'view_props' => vp)
    DM.check(self, pb)
    assert pb.outputs.length >= 2
    2.times { DM.check(self, DM.run(d, 'view_props' => vp)) } # dựng lại (chuyển tờ / quay lại) vẫn đủ
  end

  def test_11_luu_mo_lai
    project, = MD.page({}, 'details' => DM.dets(3))
    back = AL::ProjectStore.import_doc(JSON.parse(JSON.generate(AL::ProjectStore.export_doc(project))))
    assert_equal DM.dets(3).map { |d| d['rect'].map(&:to_f) }, back['pages'][0]['details'].map { |d| d['rect'] }
    assert_equal [1, 2, 3], back['pages'][0]['details'].map { |d| d['n'] }
  end

  def test_12_pdf_moi_chi_tiet_co_vung_cat_va_net
    pb = DM.run(DM.dets(3), {}, :pdf)
    body = pb.outputs[0][0]
    clips = body.scan(/re W n(.*?)\nQ/m)
    assert clips.length >= 3, 'mỗi chi tiết có vùng cắt riêng trong PDF'
    assert clips.last(3).all? { |c| c[0].scan(/ l\b/).length.positive? }, 'có nét bên trong vùng cắt'
  end

  def test_vung_trong_bao_loi_khong_tao_chi_tiet_rong
    pb = DM.run([{ 'n' => 1, 'src' => 'front', 'rect' => [300, 100, 500, 300], 'scale' => 5 }])
    info = MD.info(pb)
    refute info['frames'].key?('det:1'), 'không tạo chi tiết trống'
    assert_match(/CHI TIẾT 1: vùng khoanh trên .* không chứa hình học nào/, info['note'].to_s)
  end

  def test_id_clip_khong_trung_giua_cac_lan_dung
    a = DM.all_svg(DM.run(DM.dets(2))).scan(/<clipPath id="([^"]+)"/).flatten
    b = DM.all_svg(DM.run(DM.dets(2))).scan(/<clipPath id="([^"]+)"/).flatten
    assert_empty a & b
  end

  # Chi tiết cấu tạo (mặt cắt thật trong vùng gọi) – pipeline riêng: 3 chi tiết đều có nét cắt / nét
  def test_chi_tiet_cau_tao_nhieu_cai
    d = DM.dets(3).each { |x| x['type'] = 'section'; x['cut'] = { 'orient' => 'h', 'at' => (x['rect'][1] + x['rect'][3]) / 2.0 } }
    pb = DM.run(d)
    svg = DM.all_svg(pb)
    ids = svg.scan(/<clipPath id="([^"]+)"/).flatten
    assert_equal ids.uniq.length, ids.length
    views = pb.views.select { |v| v[:key].to_s.start_with?('det:') }
    assert_equal 3, views.length
    views.each { |v| assert v[:lines].length + Array(v[:cut] && v[:cut][:segs]).length > 0, "#{v[:key]} có hình học" }
  end
end
