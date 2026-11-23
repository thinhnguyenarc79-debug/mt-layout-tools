# encoding: UTF-8
# v2.18: bảng chú thích vật liệu (ẩn/hiện, sửa, dời, khóa) + tên hình / dòng tỉ lệ dời độc lập.
require_relative 'test_helper'
require_relative 'test_perf'

module LG
  module_function

  def cap
    @cap ||= Chair.build(Fake.capture('Ghế'), hard: :smooth, seg: 8, multi: true)
  end

  def run(extra = {}, fmt = :svg)
    pb, = PF.build(cap, %w[front iso], extra)
    pb
  end

  def svg(pb)
    pb.outputs[0][0]
  end

  def info(pb)
    pb.outputs[0][1]
  end

  def legend_g(svg)
    svg[%r{<g class="legend"[^>]*>(.*?)</g>}m, 1]
  end
end

class TestLegendCaption < Minitest::Test
  def test_1_2_an_hien_khong_doi_vat_lieu_model
    before = Marshal.dump(LG.cap.materials)
    hid = LG.run('legend' => { 'hidden_sheets' => [0] })
    assert_nil LG.legend_g(LG.svg(hid)), 'bảng biến mất'
    assert LG.info(hid)['legend']['hidden']
    assert_equal 4, LG.info(hid)['legend']['rows'].length, 'dữ liệu dòng vẫn còn'
    assert_equal before, Marshal.dump(LG.cap.materials), 'material của model không đổi'
    shown = LG.run('legend' => {})
    g = LG.legend_g(LG.svg(shown))
    refute_nil g
    %w[MAT-01 MAT-02 MAT-03 MAT-04].each { |c| assert_includes g, c }
  end

  def test_3_doi_ten_ma_va_luu_mo
    cfg = { 'rows' => { 'Gỗ sồi' => { 'code' => 'GO-01', 'name' => 'Gỗ sồi Mỹ ghép', 'note' => 'sơn PU mờ', 'color' => '#aa7744' } } }
    pb = LG.run('legend' => cfg)
    g = LG.legend_g(LG.svg(pb))
    assert_includes g, 'GO-01: Gỗ sồi Mỹ ghép – sơn PU mờ'
    assert_includes g, 'fill="#AA7744"'
    project, = [AL::ProjectStore.default_project]
    project['pages'] = [AL::ProjectStore.clean_page(project['defaults'].merge('pid' => 1, 'legend' => cfg))]
    back = AL::ProjectStore.import_doc(JSON.parse(JSON.generate(AL::ProjectStore.export_doc(project))))
    assert_equal 'GO-01', back['pages'][0]['legend']['rows']['Gỗ sồi']['code']
    assert_equal 'Gỗ sồi Mỹ ghép', back['pages'][0]['legend']['rows']['Gỗ sồi']['name']
    r = LG.info(pb)['legend']['rows'].find { |x| x['key'] == 'Gỗ sồi' }
    assert_equal 'Gỗ sồi', r['orig_name'], 'vẫn biết tên gốc trong SketchUp để khôi phục'
  end

  def test_4_an_rieng_mot_dong
    pb = LG.run('legend' => { 'rows' => { 'Gỗ óc chó' => { 'hidden' => true } } })
    g = LG.legend_g(LG.svg(pb))
    rows = LG.info(pb)['legend']['rows']
    hid = rows.find { |r| r['key'] == 'Gỗ óc chó' }
    refute_includes g, "#{hid['code']}:"
    (rows - [hid]).each { |r| assert_includes g, "#{r['code']}: #{r['name']}" }
    assert_equal %w[MAT-01 MAT-02 MAT-03 MAT-04], rows.map { |r| r['code'] }, 'ẩn 1 dòng không làm đổi mã dòng khác'
  end

  def test_thu_tu_va_ma_trung
    rows = AL::Legend.rows([{ 'name' => 'A', 'color' => '#111111' }, { 'name' => 'B', 'color' => '#222222' }, { 'name' => 'C', 'color' => '#333333' }],
                           'order' => %w[C A], 'rows' => { 'A' => { 'code' => 'X1' }, 'B' => { 'code' => 'x1' } })
    assert_equal %w[C A B], rows.map { |r| r['key'] }
    codes = rows.map { |r| r['code'].upcase }
    assert_equal codes.uniq, codes, 'không bao giờ có 2 dòng trùng mã'
  end

  def test_5_doi_vi_tri_va_khong_nhay_lai
    pb = LG.run('legend' => { 'x' => 30, 'y' => 40, 'locked' => true, 'cols' => 2 })
    lg = LG.info(pb)['legend']
    assert_equal [30.0, 40.0], lg['box'].first(2)
    assert lg['custom']
    assert_equal 2, lg['cols']
    again = LG.run('legend' => { 'x' => 30, 'y' => 40, 'locked' => true, 'cols' => 2 }, 'scale' => 5)
    assert_equal [30.0, 40.0], LG.info(again)['legend']['box'].first(2), 'cập nhật / đổi tỉ lệ: bảng giữ chỗ'
  end

  def test_tu_dong_khong_che_hinh
    area = [10, 10, 400, 280]
    boxes = { 'iso' => [300, 200, 100, 80] } # hình trục đo ở góc dưới-phải
    x, y, blocked = AL::Legend.place({}, 62, 20, area, boxes)
    refute blocked
    refute AL::Legend.overlap?([x, y, 62, 20], boxes['iso']), 'bảng tự né hình trục đo'
    # người dùng đặt đè lên hình -> giữ nguyên chỗ nhưng báo
    pb = LG.run('legend' => { 'x' => LG.info(LG.run)['frames']['front'][0], 'y' => LG.info(LG.run)['frames']['front'][1] })
    assert_match(/BẢNG VẬT LIỆU CHE/, LG.info(pb)['note'].to_s)
  end

  def test_6_7_ten_hinh_va_dong_ti_le_doc_lap
    a = LG.run
    b = LG.run('captions' => { 'front' => { 'dx' => 0, 'dy' => 12 } })
    c = LG.run('captions' => { 'front' => { 'sdx' => 20, 'sdy' => 3 } })
    pa = LG.info(a)['caption_parts']['front']
    pb = LG.info(b)['caption_parts']['front']
    pc = LG.info(c)['caption_parts']['front']
    assert_in_delta pa['name'][1] + 12, pb['name'][1], 0.01, 'kéo tên: tên xuống'
    assert_in_delta pa['scale'][1] + 12, pb['scale'][1], 0.01, 'kéo tên: dòng tỉ lệ đi theo'
    assert_in_delta pa['name'][1], pc['name'][1], 0.01, 'kéo dòng tỉ lệ: tên đứng yên'
    assert_in_delta pa['scale'][0] + 20, pc['scale'][0], 0.01
    [b, c].each do |x|
      assert_equal LG.info(a)['frames'], LG.info(x)['frames'], 'hình chiếu không di chuyển, tỉ lệ không đổi'
      assert_equal LG.info(a)['dims'], LG.info(x)['dims'], 'DIM không di chuyển'
    end
    assert_match(%r{<g class="vcap" data-key="front" data-part="scale">.*>TL 1:10<}m, LG.svg(c))
  end

  def test_chu_ti_le_tu_nhap_co_canh_bao
    real = LG.run('captions' => { 'front' => { 'scale_text' => 'TL 1:20' } })
    assert_includes LG.svg(real), '>TL 1:10<', 'mặc định: luôn theo tỉ lệ thật'
    fixed = LG.run('captions' => { 'front' => { 'scale_text' => 'TL 1:20', 'scale_fixed' => true } })
    assert_includes LG.svg(fixed), '>TL 1:20<'
    assert_match(/CHỮ TỰ NHẬP/, LG.info(fixed)['note'].to_s, 'đánh dấu rõ')
  end

  def test_10_pdf_va_luu
    on = LG.run({}, :pdf)
    off = LG.run({ 'legend' => { 'hidden_sheets' => [0] } }, :pdf)
    assert on.outputs[0][0].bytesize > off.outputs[0][0].bytesize
    pg = AL::ProjectStore.clean_page('legend' => { 'hidden_sheets' => [0, 'x'], 'x' => 5, 'cols' => 9, 'rows' => { 'A' => { 'code' => 'Z' } } },
                                     'captions' => { 'front' => { 'sdx' => 3, 'sdy' => 1 } })
    assert_equal [0], pg['legend']['hidden_sheets']
    refute pg['legend'].key?('x'), 'chỉ x mà không có y -> bỏ'
    assert_equal 4, pg['legend']['cols']
    assert_equal 3.0, pg['captions']['front']['sdx']
  end

  # v2.18.1: ẩn hàng loạt – mọi tờ của trang; trang mới theo mặc định dự án; triển khai lại giữ trạng thái
  def test_an_hang_loat
    pb = LG.run('legend_hidden' => true)
    assert_nil LG.legend_g(LG.svg(pb))
    assert LG.info(pb)['legend']['hidden_all']
    pb.outputs.each { |s, _| assert_nil LG.legend_g(s), 'ẩn trên mọi tờ' }
    project = AL::ProjectStore.default_project
    project['defaults']['legend_hidden'] = true
    project = AL::ProjectStore.clean(JSON.parse(JSON.generate(project)))
    assert project['defaults']['legend_hidden'], 'mặc định dự án được lưu'
    AL::ProjectStore.add_pages(project, [7], ->(_pid) { { 'name' => 'Tủ mới', 'root' => true } }, false)
    assert project['pages'][0]['legend_hidden'], 'trang thêm sau cũng ẩn bảng'
    project['defaults']['legend_hidden'] = false
    AL::ProjectStore.add_pages(project, [7], ->(_pid) { { 'name' => 'Tủ mới', 'root' => true } }, true)
    assert project['pages'][0]['legend_hidden'], 'triển khai lại giữ trạng thái ẩn của trang'
  end
end
