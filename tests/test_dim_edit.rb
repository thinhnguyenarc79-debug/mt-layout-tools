# encoding: UTF-8
# v2.15: chỉnh sửa chính DIM tự động (từng đoạn) + chữ trên bản vẽ (tên hình, dòng tỉ lệ, số DIM).
require_relative 'test_helper'
require_relative 'test_manual_dim'

module DE
  module_function

  def run(extra = {}, fmt = :svg)
    pb, = MD.run(extra.delete('manual_dims') || {}, extra, fmt)
    pb
  end

  def dims(pb, key = 'front')
    MD.info(pb)['dims'][key]
  end

  def seg(pb, id, key = 'front')
    dims(pb, key).find { |d| d['id'] == id }
  end

  def groups(svg, cls = 'dim')
    svg.scan(%r{<g class="#{cls}" data-key="front" data-id="([^"]+)"[^>]*>(.*?)</g>}m)
  end

  def svg_of(pb)
    pb.outputs[0][0]
  end

  ID350 = 'right:1232.0-1582.0' # đoạn thông thủy giữa đợt 768 và đợt 400 của chuỗi DIM phải
end

class TestDimEdit < Minitest::Test
  # Test 1: DIM tự động là đối tượng riêng, id ổn định, đủ trường dữ liệu, có hình học giấy cho grip
  def test_1_moi_doan_dim_tu_dong_la_doi_tuong
    pb = DE.run
    d = DE.seg(pb, DE::ID350)
    assert d, 'đoạn 350 của chuỗi phải có id ổn định'
    %w[id view origin type a b off text text_override hidden locked user_modified geo value].each { |k| assert d.key?(k), k }
    assert_equal 'auto', d['origin']
    assert_equal 350.0, d['value']
    %w[pa pb la lb tc].each { |k| assert d['geo'][k], "grip #{k}" }
    assert_includes DE.groups(DE.svg_of(pb)).map(&:first), DE::ID350, 'nhóm SVG riêng để bấm chọn'
    assert_equal DE::ID350, DE.seg(DE.run, DE::ID350)['id'], 'dựng lại: cùng id'
  end

  # Test 2: kéo điểm bám sang mép đợt khác -> số cập nhật; đoạn kề không bị đổi
  def test_2_doi_diem_bam_doan_tu_dong
    over = { 'front' => { DE::ID350 => { 'a' => [1200, 1232], 'b' => [1200, 1600] } } }
    pb = DE.run('dim_over' => over)
    d = DE.seg(pb, DE::ID350)
    assert_equal 368.0, d['value']
    assert d['custom_anchor']
    assert d['rb'], 'điểm bám mới gắn liên kết bộ phận'
    assert_equal 18.0, DE.seg(pb, 'right:1582.0-1600.0')['value'], 'đoạn kề dùng chung mốc không bị đổi'
    assert_includes DE.groups(DE.svg_of(pb)).find { |i, _| i == DE::ID350 }[1], '>368<'
  end

  # Test 3: kéo cả chuỗi sang phải -> số không đổi, đường DIM dời
  def test_3_keo_ca_chuoi
    a = DE.run
    b = DE.run('dimoff' => { 'front' => { 'right' => 15 } })
    assert_equal DE.dims(a).map { |d| d['value'] }, DE.dims(b).map { |d| d['value'] }
    assert_in_delta DE.seg(a, DE::ID350)['geo']['la'][0] + 15, DE.seg(b, DE::ID350)['geo']['la'][0], 0.01
  end

  # Test 4: xóa 1 đoạn tự động -> dựng lại (cập nhật hình) không tạo lại; ẩn cũng vậy
  def test_4_xoa_doan_khong_tao_lai
    over = { 'front' => { DE::ID350 => { 'deleted' => true }, 'right:1600.0-1982.0' => { 'hidden' => true } } }
    pb = nil
    3.times { pb = DE.run('dim_over' => over) }
    ids = DE.groups(DE.svg_of(pb)).map(&:first)
    refute_includes ids, DE::ID350
    refute_includes ids, 'right:1600.0-1982.0'
    assert DE.seg(pb, DE::ID350)['deleted'], 'vẫn báo về giao diện để khôi phục'
    assert_includes ids, 'right:1214.0-1232.0'
  end

  # Tách 1 đoạn khỏi chuỗi: chỉ đoạn đó dời; chuỗi kéo đi thì đoạn đã tách đứng yên
  def test_tach_khoi_chuoi
    over = { 'front' => { DE::ID350 => { 'off' => 20 } } }
    pb = DE.run('dim_over' => over, 'dimoff' => { 'front' => { 'right' => 5 } })
    f = MD.info(pb)['frames']['front']
    edge = f[0] + f[3] / f[2]
    assert_in_delta edge + 20, DE.seg(pb, DE::ID350)['geo']['la'][0], 0.01
    assert_in_delta edge + 11, DE.seg(pb, 'right:1582.0-1600.0')['geo']['la'][0], 0.01
    assert DE.seg(pb, DE::ID350)['detached']
    assert_equal 350.0, DE.seg(pb, DE::ID350)['value']
  end

  # Test 5: chuỗi ngang kéo xuống dưới hình chạm tên hình -> cảnh báo; kéo xa hơn -> hết cảnh báo, không dời gì khác
  def test_5_dim_duoi_hinh_va_ten_hinh
    base = DE.run
    f = MD.info(base)['frames']['front']
    cap = MD.info(base)['captions']['front']
    vh = f[4] / f[2]
    # top1 ở oy - 5.5 + top: đặt đúng giữa hộp tên hình
    top = (cap[1] + cap[3]) / 2 - (f[1] - 5.5)
    # v2.18: tên hình CHƯA dời tay -> tự xuống dưới chuỗi DIM (không chồng)
    auto = DE.run('dimoff' => { 'front' => { 'top' => top } })
    assert_nil MD.info(auto)['dim_caption_hits'], 'tên mặc định tự tránh DIM dưới hình'
    assert MD.info(auto)['captions']['front'][1] > cap[1], 'tên hình được đặt thấp hơn chuỗi DIM'
    # tên đã được người dùng đặt (dx/dy) -> giữ nguyên chỗ, chỉ cảnh báo chồng
    hit = DE.run('dimoff' => { 'front' => { 'top' => top } }, 'captions' => { 'front' => { 'dy' => 0.0 } })
    assert MD.info(hit)['dim_caption_hits'], 'báo DIM chồng tên hình'
    assert_match(/DIM CHỒNG TÊN HÌNH/, MD.info(hit)['note'].to_s)
    assert_equal MD.info(base)['frames']['front'], MD.info(hit)['frames']['front'], 'không tự dời hình'
    g = DE.seg(hit, 'top1:18.0-1182.0')['geo']
    assert g['la'][1] > f[1] + vh, 'chuỗi nằm dưới hình'
    # đường gióng đi từ mép DƯỚI hình
    grp = DE.svg_of(hit)[/<g class="dimset" data-key="front" data-side="top" data-chain="top1">.*?<\/g>/m]
    ys = grp.scan(/d="M[\d.]+ ([\d.]+)L/).flatten.map(&:to_f)
    assert ys.any? { |y| (y - (f[1] + vh + 1)).abs < 0.05 }, 'gióng từ mép dưới'
    far = DE.run('dimoff' => { 'front' => { 'top' => top + 22 } }, 'captions' => { 'front' => { 'dy' => 0.0 } })
    assert_nil MD.info(far)['dim_caption_hits']
  end

  # Test 6, 7: sửa tên hình hiển thị + kéo tên hình; loại hình nội bộ giữ nguyên; dòng tỉ lệ bám tỉ lệ thật
  def test_6_7_ten_hinh_tuy_chinh
    a = DE.run
    b = DE.run('captions' => { 'front' => { 'text' => 'MẶT ĐỨNG TỦ ÁO', 'dx' => 12, 'dy' => 4 } })
    svg = DE.svg_of(b)
    grp = svg.scan(%r{<g class="vcap" data-key="front" data-part="[a-z]+">.*?</g>}m).join
    assert_includes grp, '>MẶT ĐỨNG TỦ ÁO<'
    assert_includes grp, '>TL 1:20<'
    assert_includes MD.info(b)['view_keys'], 'front', 'key hình nội bộ không đổi'
    ca = MD.info(a)['captions']['front']
    cb = MD.info(b)['captions']['front']
    assert_in_delta ca[1] + 4, cb[1], 0.01
    assert_equal MD.info(a)['frames']['front'], MD.info(b)['frames']['front'], 'kéo chữ: hình không đổi'
    assert_equal DE.dims(a).map { |d| d['geo'] }, DE.dims(b).map { |d| d['geo'] }, 'kéo chữ: DIM không đổi'
  end

  def test_dong_ti_le_khong_in_sai
    assert_equal 'TL 1:20', AL::DimEdit.scale_line(nil, 20)
    assert_equal 'TỶ LỆ 1:20', AL::DimEdit.scale_line('TỶ LỆ {TL}', 20)
    assert_equal 'TL 1:20', AL::DimEdit.scale_line('TL 1:50', 20), 'gõ cứng tỉ lệ khác -> thay bằng tỉ lệ thật'
    pb = DE.run('scale' => 10, 'captions' => { 'front' => { 'scale_text' => 'Tỷ lệ {TL}' } })
    assert_includes DE.svg_of(pb), '>Tỷ lệ 1:10<'
  end

  # Test 8: sửa chữ DIM (override) – số đo thật giữ nguyên, khôi phục được
  def test_8_text_override_dim
    pb = DE.run('dim_over' => { 'front' => { DE::ID350 => { 'text' => '<> TT', 'tdx' => 3, 'size' => 3.0 } } })
    d = DE.seg(pb, DE::ID350)
    assert_equal 350.0, d['value'], 'số đo thật không đổi'
    assert_equal '350 TT', d['text']
    assert_equal '<> TT', d['text_override']
    assert d['user_modified']
    g = DE.groups(DE.svg_of(pb)).find { |i, _| i == DE::ID350 }[1]
    assert_includes g, '>350 TT<'
    base = DE.seg(DE.run, DE::ID350)
    assert_in_delta base['geo']['tc'][0] + 3, d['geo']['tc'][0], 0.01
    assert_equal '350', base['text'], 'không override -> số thật'
  end

  # Test 9: đổi tỉ lệ -> chỉnh sửa vẫn áp, vị trí tương đối (mm giấy) giữ
  def test_9_doi_ti_le
    o = { 'dim_over' => { 'front' => { DE::ID350 => { 'text' => '<> TT', 'off' => 14 } } },
          'captions' => { 'front' => { 'text' => 'MẶT ĐỨNG TỦ ÁO', 'dy' => 3 } } }
    p20 = DE.run(Marshal.load(Marshal.dump(o)).merge('scale' => 20))
    p10 = DE.run(Marshal.load(Marshal.dump(o)).merge('scale' => 10))
    [p20, p10].each do |pb|
      d = DE.seg(pb, DE::ID350)
      f = MD.info(pb)['frames']['front']
      assert_equal '350 TT', d['text']
      assert_in_delta f[0] + f[3] / f[2] + 14, d['geo']['la'][0], 0.01
      assert_includes DE.svg_of(pb), '>MẶT ĐỨNG TỦ ÁO<'
    end
  end

  # Test 10: lưu / mở lại / triển khai lại trang giữ toàn bộ chỉnh sửa
  def test_10_luu_mo_lai
    project, = MD.page({}, 'dim_over' => { 'front' => { DE::ID350 => { 'a' => [1200, 1232], 'b' => [1200, 1600], 'locked' => true, 'text' => 'X' },
                                                       'left:0.0-2000.0' => { 'hidden' => true }, 'bad id' => { 'hidden' => true } } },
                           'captions' => { 'front' => { 'text' => 'MẶT ĐỨNG TỦ ÁO', 'dx' => 5, 'locked' => true, 'color' => '#AA0000', 'align' => 'left' } },
                           'notes' => [{ 'id' => 'n1', 'type' => 'text', 'x' => 50, 'y' => 50, 'text' => 'Ghi chú', 'locked' => true, 'align' => 'right', 'bold' => true }])
    back = AL::ProjectStore.import_doc(JSON.parse(JSON.generate(AL::ProjectStore.export_doc(project))))
    pg = back['pages'][0]
    assert_equal %w[left:0.0-2000.0 right:1232.0-1582.0], pg['dim_over']['front'].keys.sort, 'id rác bị loại'
    o = pg['dim_over']['front'][DE::ID350]
    assert_equal [1200.0, 1600.0], o['b']
    assert o['locked']
    assert_equal 'MẶT ĐỨNG TỦ ÁO', pg['captions']['front']['text']
    assert pg['captions']['front']['locked']
    n = pg['notes'][0]
    assert n['locked']
    assert_equal 'right', n['align']
    assert n['bold']
    AL::ProjectStore.add_pages(back, [101], ->(_pid) { { 'name' => 'Tủ', 'root' => true } }, true)
    assert_equal 2, back['pages'][0]['dim_over']['front'].length, 'triển khai lại / cập nhật model giữ chỉnh sửa'
    assert back['pages'][0]['captions']['front']
  end

  # Test 11: xuất PDF có chữ tùy chỉnh (chạy được, dung lượng khác bản gốc) – SVG giống giao diện vì cùng 1 bộ vẽ
  def test_11_pdf
    a = DE.run({}, :pdf)
    b = DE.run({ 'captions' => { 'front' => { 'text' => 'MẶT ĐỨNG TỦ ÁO', 'bold' => true } },
                 'dim_over' => { 'front' => { DE::ID350 => { 'hidden' => true } } } }, :pdf)
    refute_equal a.outputs[0][0], b.outputs[0][0]
    assert_match(/2 Tr/, b.outputs[0][0], 'chữ đậm trong PDF')
  end

  # Test 12: dự án bản cũ (chỉ có dimtext/dimoff) -> DIM có id, sửa được; dời chữ cũ vẫn áp dụng
  def test_12_du_an_cu
    old = DE.run('dimtext' => { 'front|r|10|5' => [4.0, 0] })
    d = DE.seg(old, DE::ID350)
    base = DE.seg(DE.run, DE::ID350)
    assert_in_delta base['geo']['tc'][0] + 4, d['geo']['tc'][0], 0.01, 'dời chữ của bản cũ'
    newer = DE.run('dimtext' => { 'front|r|10|5' => [4.0, 0] }, 'dim_over' => { 'front' => { DE::ID350 => { 'tdx' => 1 } } })
    assert_in_delta base['geo']['tc'][0] + 1, DE.seg(newer, DE::ID350)['geo']['tc'][0], 0.01, 'chỉnh sửa mới thay dời cũ'
  end

  # Mất mốc đo (model đổi): đoạn chỉ sửa chữ/ẩn -> báo "không còn khớp"; đoạn có điểm bám riêng -> vẫn vẽ, kiểm liên kết
  def test_mat_moc_bao_loi
    built = MD.build(768)
    over = { 'front' => { DE::ID350 => { 'text' => 'TT' }, 'right:1600.0-1982.0' => { 'a' => [1200, 1600], 'b' => [1200, 1982] } } }
    built[1][4].define_singleton_method(:transformation) { X.tr(18 * PX::IN, 0, 800 * PX::IN) } # đợt 768 -> 800
    pb, = MD.run({}, { 'dim_over' => over }, :svg, built)
    info = MD.info(pb)
    assert_includes info['dim_orphans']['front'], DE::ID350
    d = DE.seg(pb, 'right:1600.0-1982.0')
    assert_equal 'ok', d['status']
    assert_equal 382.0, d['value']
    gone = { 'front' => { 'right:5.0-77.0' => { 'a' => [600, 5], 'b' => [600, 77], 'ra' => false, 'rb' => false } } }
    pb2 = DE.run('dim_over' => gone)
    assert_equal 'broken', DE.seg(pb2, 'right:5.0-77.0')['status'], 'không âm thầm đo sang cạnh khác'
  end

  def test_dim_thu_cong_dung_chung_truong_chu
    pb = DE.run('manual_dims' => { 'front' => [MD.clear_dim('text' => 'TT <>', 'tdy' => 2, 'locked' => true)] })
    m = DE.dims(pb).find { |d| d['origin'] == 'manual' }
    assert_equal 350.0, m['value']
    assert m['locked']
    assert m['geo']['tc']
    assert_includes DE.svg_of(pb), '>TT 350<'
  end
end
