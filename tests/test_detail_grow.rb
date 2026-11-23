# encoding: UTF-8
# v2.18.2 – DIM kéo ra ngoài vùng hình: không báo đỏ sai, vùng khoanh chi tiết tự nới, vùng hình gồm cả DIM.
require_relative 'test_manual_dim'

class TestDetailGrow < Minitest::Test
  DET = { 'n' => 1, 'src' => 'front', 'rect' => [0, 1150, 300, 1350], 'scale' => 5 }.freeze

  def det(extra = {})
    [JSON.parse(JSON.generate(DET)).merge(extra)]
  end

  def dims_of(info, key)
    Array(info['dims'][key])
  end

  # Lỗi gốc: điểm đặt tự do (không trên nét) lần dựng đầu "ok", lần sau thành "broken" (đỏ, "(!)").
  def test_diem_tu_do_khong_bao_do_lan_dung_sau
    md = { 'front' => [{ 'id' => 'f1', 'a' => [600, 950], 'b' => [600, 1100], 'axis' => 'v', 'side' => 'l', 'off' => 5 }] }
    2.times do
      pb, = MD.run(md)
      d = MD.info(pb)['manual_dims']['front'][0]
      assert_equal 'ok', d['status']
      assert_equal 'free', d['ra']
      md = { 'front' => MD.info(pb)['manual_dims']['front'] }
    end
    svg = MD.run(md)[0].outputs[0][0]
    refute_includes svg, '(!)'
  end

  def test_ref_free_qua_lam_sach
    assert_equal 'free', AL::ManualDim.clean_ref('free')
    assert_nil AL::ManualDim.clean_ref('rác')
  end

  # Điểm bám DIM thủ công kéo ra ngoài vùng khoanh -> vùng tự nới, gốc dời, DIM không đỏ, dựng lại ổn định.
  def test_vung_khoanh_tu_noi_theo_dim
    # hông trái mép trong u = 18 chạy suốt chiều cao: điểm b ở v nguồn 800 (ngoài vùng 1150..1350)
    md = { 'det:1' => [{ 'id' => 'm1', 'a' => [18, 64], 'b' => [18, -350], 'axis' => 'v', 'side' => 'l', 'off' => 5 }] }
    pb, = MD.run(md, 'details' => det)
    i = MD.info(pb)
    g = i['detail_grow']
    refute_nil g, 'phải nới vùng khoanh'
    assert_equal 1, g[0]['n']
    rect = g[0]['rect']
    assert_operator rect[1], :<, 800
    assert_operator rect[1], :>=, 0
    assert_equal [0.0, 1150.0, 300.0, 1350.0], g[0]['old'].map(&:to_f)
    dy = g[0]['shift'][1]
    assert_operator dy, :>, 0
    d = i['manual_dims']['det:1'][0]
    assert_equal 'ok', d['status']
    assert_in_delta 64 + dy, d['a'][1], 0.01
    assert_in_delta(-350 + dy, d['b'][1], 0.01)
    assert_in_delta 414.0, d['value'], 0.01 # số đo không đổi
    patch = i['page_patch']
    assert_equal rect, patch['details'][0]['rect']
    v = pb.views.find { |x| x[:key] == 'det:1' }
    assert_in_delta rect[3] - rect[1], v[:h], 0.01
    # dựng lại với dữ liệu đã nhận: không nới thêm, vẫn ok
    pb2, = MD.run(patch['manual_dims'], 'details' => patch['details'])
    i2 = MD.info(pb2)
    assert_nil i2['detail_grow']
    assert_equal 'ok', i2['manual_dims']['det:1'][0]['status']
    refute_includes pb2.outputs[0][0], '(!)'
  end

  def test_khong_noi_khi_diem_trong_vung
    md = { 'det:1' => [{ 'id' => 'm1', 'a' => [18, 64], 'b' => [18, 82], 'axis' => 'v', 'side' => 'l', 'off' => 5 }] }
    pb, = MD.run(md, 'details' => det)
    assert_nil MD.info(pb)['detail_grow']
  end

  # Không nới quá hình nguồn
  def test_noi_khong_vuot_hinh_nguon
    md = { 'det:1' => [{ 'id' => 'm1', 'a' => [18, 64], 'b' => [18, -5000], 'axis' => 'v', 'side' => 'l', 'off' => 5 }] }
    pb, = MD.run(md, 'details' => det)
    g = MD.info(pb)['detail_grow'][0]
    assert_equal 0.0, g['rect'][1]
  end

  # Vị trí đã chốt: lùi theo phần nới để nét cũ đứng yên trên giấy
  def test_vi_tri_chot_lui_theo
    md = { 'det:1' => [{ 'id' => 'm1', 'a' => [18, 64], 'b' => [18, -350], 'axis' => 'v', 'side' => 'l', 'off' => 5 }] }
    vp = { 'det:1' => { 'x_mm' => 200.0, 'y_mm' => 150.0, 'sheet' => 0, 'placement_mode' => 'manual' } }
    pb, = MD.run(md, 'details' => det, 'view_props' => vp)
    i = MD.info(pb)
    dy = i['detail_grow'][0]['shift'][1]
    assert_in_delta 150.0 - dy / 5.0, i['page_patch']['view_props']['det:1']['y_mm'], 0.01
    assert_in_delta 200.0, i['page_patch']['view_props']['det:1']['x_mm'], 0.01
  end

  # DIM tự động đã đổi điểm bám trong chi tiết: id và điểm bám dời theo gốc mới
  def test_dim_tu_dong_doi_id_theo_goc
    pb, = MD.run({}, 'details' => det)
    seg = dims_of(MD.info(pb), 'det:1').find { |d| d['origin'] == 'auto' && d['chain'] == 'left' }
    skip 'chi tiết không có chuỗi DIM trái' unless seg
    over = { 'det:1' => { seg['id'] => { 'a' => seg['a'], 'b' => [seg['b'][0], -350.0], 'text' => 'X' } } }
    pb2, = MD.run({}, 'details' => det, 'dim_over' => over)
    i = MD.info(pb2)
    g = i['detail_grow']
    refute_nil g
    dy = g[0]['shift'][1]
    m = AL::DetailEngine::SEG_ID.match(seg['id'])
    nid = "left:#{(m[2].to_f + dy).round(1)}-#{(m[3].to_f + dy).round(1)}"
    o = i['page_patch']['dim_over']['det:1'][nid]
    refute_nil o, "id mới #{nid}"
    assert_in_delta(-350.0 + dy, o['b'][1], 0.01)
    d = dims_of(i, 'det:1').find { |x| x['id'] == nid }
    refute_nil d
    assert_equal 'ok', d['status']
  end

  # Vùng của hình nới theo DIM kéo ra xa (khung chiếm chỗ giữ nguyên)
  def test_vung_hinh_gom_dim_keo_xa
    md = { 'front' => [{ 'id' => 'f1', 'a' => [0, 2000], 'b' => [1200, 2000], 'axis' => 'h', 'side' => 'b', 'off' => 40 }] }
    pb, = MD.run(md)
    i = MD.info(pb)
    box = i['boxes']['front']
    reg = i['regions']['front']
    assert_operator reg[1] + reg[3], :>, box[1] + box[3] + 20
    assert_operator reg[0], :<=, box[0]
    # không kéo xa -> vùng = khung
    pb2, = MD.run({})
    i2 = MD.info(pb2)
    assert_equal i2['boxes']['front'], i2['regions']['front']
  end
end
