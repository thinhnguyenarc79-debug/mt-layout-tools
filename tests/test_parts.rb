# encoding: UTF-8
require 'rexml/document'
# v2.5 – Nhận diện bộ phận tủ + DIM theo bộ phận + giữ gán tay.
require_relative 'test_helper'
require File.join(ROOT, 'extractor')
require_relative 'test_large' unless defined?(X)
require_relative 'test_doors' unless defined?(TestDoorPages)

module PX
  IN = 1.0 / 25.4
  Col = Struct.new(:red, :green, :blue)
  Mat = Struct.new(:display_name) { def color; Col.new(200, 220, 230); end }
  Mesh = Struct.new(:points, :polygons)

  # Definition hình hộp (mm) gồm 12 cạnh + 1 mặt (để có vật liệu).
  def self.box_def(name, dx, dy, dz, mat = nil)
    c = [[0, 0, 0], [dx, 0, 0], [dx, dy, 0], [0, dy, 0], [0, 0, dz], [dx, 0, dz], [dx, dy, dz], [0, dy, dz]].map { |p| p.map { |v| v * IN } }
    ents = [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]].map { |a, b| X.edge(c[a], c[b]) }
    f = Sketchup::Face.allocate
    pts = [c[0], c[1], c[5]].map { |p| X::P.new(*p) }
    f.define_singleton_method(:mesh) { |_| Mesh.new(pts, [[1, 2, 3]]) }
    f.define_singleton_method(:material) { mat && Mat.new(mat) }
    f.define_singleton_method(:back_material) { nil }
    f.define_singleton_method(:hidden?) { false }
    f.define_singleton_method(:layer) { X::L.new('Untagged') }
    X::Def.new(name, ents + [f])
  end

  def self.at(defn, x, y, z, name = '', tag = 'Untagged')
    i = X.inst(defn, X.tr(x * IN, y * IN, z * IN), Sketchup::ComponentInstance, tag)
    i.define_singleton_method(:name) { name }
    i
  end

  def self.extractor
    ex = AL::Extractor.new
    ident = [AL::Extractor::MM, 0, 0, 0, 0, AL::Extractor::MM, 0, 0, 0, 0, AL::Extractor::MM, 0]
    ex.define_singleton_method(:root_matrix) { |_w, _f| ident }
    ex
  end

  def self.model
    m = Object.new
    m.define_singleton_method(:layers) { [X::L.new('Untagged'), X::L.new('1. Canh')] }
    AL::Geometry.define_singleton_method(:world_transform) { |_m, _i| nil }
    m
  end

  # Tủ 1200 x 600 x 2000: 2 hông (cùng definition "Tấm 18"), nóc, đáy, 1 đợt, hậu, 2 cánh ở mặt trước
  # (cánh KHÔNG tên, dùng chung definition với... ván cánh riêng), tay nắm nhỏ, kính, ngăn kéo lồng 2 cấp.
  def self.cabinet(cfg = {}, built = nil)
    root, parts = built || build
    [extractor.capture(model, root, [], '-Y', nil, cfg), root, parts]
  end

  def self.build
    hong = box_def('Tấm đứng', 18, 600, 2000)
    ngang = box_def('Tấm ngang', 1164, 600, 18)
    hau = box_def('Tấm H', 1164, 8, 1964)
    canh = box_def('Tấm M', 597, 18, 2000)
    tay = box_def('', 20, 30, 150)
    kinh = box_def('Tấm X', 500, 5, 400, 'Kính trắng 5ly')
    hk_mat = box_def('Mặt hộc', 1160, 18, 200)
    hk = X::Def.new('Ngăn kéo 1', [at(hk_mat, 0, 0, 0)])
    parts = [
      at(hong, 0, 0, 0), at(hong, 1182, 0, 0),
      at(ngang, 18, 0, 1982), at(ngang, 18, 0, 0), at(ngang, 18, 0, 1000),
      at(hau, 18, 592, 18),
      at(canh, 0, -20, 0), at(canh, 603, -20, 0),
      at(tay, 560, -50, 900),
      at(kinh, 300, 300, 1300),
      at(X::Def.new('Cụm', [at(hk, 0, 0, 0)]), 20, 0, 200)
    ]
    root = X.inst(X::Def.new('Tủ', parts), X.tr(0, 0, 0))
    [root, parts]
  end

  def self.roles(cap)
    cap.parts.map { |p| [p['name'], p['role'], p['sure']] }
  end
end

class TestPartRecognition < Minitest::Test
  def by(cap, role)
    cap.parts.select { |p| p['role'] == role }
  end

  def test_nhan_dien_tung_loai
    cap, = PX.cabinet
    assert_equal 2, by(cap, 'side').length, 'hai hông'
    assert_equal 1, by(cap, 'top').length
    assert_equal 1, by(cap, 'bottom').length
    assert_equal 1, by(cap, 'shelf').length
    assert_equal 1, by(cap, 'back').length
    assert_equal 2, by(cap, 'door').length, 'tấm đứng ở mặt trước (không tên) -> đề xuất cánh'
    assert_equal 1, by(cap, 'handle').length
    assert_equal 1, by(cap, 'glass').length, 'vật liệu kính'
    assert_equal 1, by(cap, 'drawer').length, 'ngăn kéo lồng 2 cấp nhận theo tên cụm'
    by(cap, 'door').each { |p| refute p['sure'], 'cánh theo hình học chỉ là đề xuất' }
    assert by(cap, 'drawer')[0]['sure'], 'theo tên -> chắc chắn'
  end

  def test_tam_dung_khong_mac_dinh_la_canh
    cap, = PX.cabinet
    hong = by(cap, 'side')
    assert_equal 2, hong.length
    hau = by(cap, 'back')[0]
    assert_match(/mặt sau/, hau['source'])
  end

  def test_gan_tay_uu_tien_va_dung_chung_definition
    built = PX.build
    _cap, _root, parts = PX.cabinet({}, built)
    hong2 = parts[1].persistent_id.to_s # hông phải, dùng chung definition với hông trái
    cap2, = PX.cabinet({ roles: { hong2 => 'door' } }, built)
    p = cap2.parts.find { |x| x['path'] == hong2 }
    assert_equal 'door', p['role']
    assert p['sure']
    assert_equal 'gán tay', p['source']
    left = cap2.parts.find { |x| x['path'] == parts[0].persistent_id.to_s }
    assert_equal 'side', left['role'], 'bản sao cùng definition không bị gán theo'
    assert_empty cap2.stats['missing_roles']
    # đặt lại về chưa xác định -> không tự đoán lại
    cap3, = PX.cabinet({ roles: { parts[6].persistent_id.to_s => 'unknown' } }, built)
    assert_equal 'unknown', cap3.parts.find { |x| x['path'] == parts[6].persistent_id.to_s }['role']
    assert_equal 1, cap3.doors.length
  end

  def test_phat_hien_gan_tay_da_mat
    cap, = PX.cabinet(roles: { '999999/1' => 'door' })
    assert_equal ['999999/1'], cap.stats['missing_roles']
  end

  def test_khong_ten_khong_du_du_lieu_la_chua_xac_dinh
    r = AL::PartClassifier.geometric([[0, 300], [100, 400], [500, 800]], [[0, 1200], [0, 600], [0, 2000]])
    assert_equal 'unknown', r[0], 'khối dày, không phải tấm'
    r2 = AL::PartClassifier.geometric([[0, 600], [300, 318], [0, 2000]], [[0, 1200], [0, 600], [0, 2000]])
    assert_equal 'unknown', r2[0], 'tấm đứng ở giữa chiều sâu không phải cánh/hậu'
  end

  def test_ten_va_thuoc_tinh
    pc = AL::PartClassifier
    assert_equal 'side', pc.by_text('Vách giữa')
    assert_equal 'shelf', pc.by_text('Đợt 2')
    assert_equal 'top', pc.by_text('Nóc tủ')
    assert_equal 'bottom', pc.by_text('Đáy')
    assert_equal 'back', pc.by_text('Hậu tủ')
    assert_equal 'handle', pc.by_text('Tay nắm âm')
    assert_equal 'drawer', pc.by_text('Ngăn kéo')
    assert_equal 'door', pc.by_text('Cánh lùa')
    assert_nil pc.by_text('Cạnh dán')
    assert_nil pc.by_text('Group#165')
  end
end

class TestPartDims < Minitest::Test
  def test_thao_canh_do_theo_bo_phan
    cap, = PX.cabinet
    env = TestDoorPages::Env.new(cap)
    project = AL::ProjectStore.default_project
    pg = AL::ProjectStore.clean_page(project['defaults'].merge('pid' => 1, 'sheet_no' => 'A-01', 'views' => %w[front open], 'sections' => []))
    pb = AL::PageBuild.new(env, project, pg, :svg)
    job = AL::Job.new('t', timer: ->(_b) {})
    pb.tasks.each { |t| job.add(t) }
    job.run_sync
    svg, info = pb.output
    assert_equal %w[front open], info['boxes'].keys
    assert_equal 11, info['parts_total']
    texts = svg.scan(%r{<text[^>]*>([^<]*)</text>}).flatten
    %w[1164 18 964].each { |t| assert_includes texts, t, "hình tháo cánh có #{t}" }
  end
end

class TestSmartDim < Minitest::Test
  def cv
    AL::Canvas.new(:svg, 420.0, 297.0)
  end

  def view
    v = AL::Geometry.project(Fake.cabinet, 'front')
    v[:dim_mode] = :interior
    v
  end

  def test_chu_dim_ne_ky_hieu_mat_cat_va_chu_thich
    c = cv
    v = view
    s = 30.0
    # chướng ngại phủ đúng chỗ mặc định của số "2410" (giữa hàng DIM tổng)
    cx = 50 + v[:w] / 2 / s
    obstacle = [cx - 6, 50 - 11.5 - 4, cx + 6, 50 - 11.5 + 1]
    AL::DimensionEngine.draw(c, v, s, 50, 50, { 'obstacles' => [obstacle] })
    doc = REXML::Document.new(c.svg)
    t = REXML::XPath.match(doc, '//text').find { |e| e.text == '2410' }
    x = t.attributes['x'].to_f
    y = t.attributes['y'].to_f
    inside = x > obstacle[0] && x < obstacle[2] && y - 1 > obstacle[1] && y - 1 < obstacle[3]
    refute inside, 'số 2410 phải dời khỏi ký hiệu'
  end

  def test_keo_tung_so_dim
    c = cv
    v = view
    AL::DimensionEngine.draw(c, v, 30.0, 50, 50, {})
    g = REXML::XPath.match(REXML::Document.new(c.svg), "//g[@class='dimtxt']").first
    id = g.attributes['data-id']
    x0 = REXML::XPath.first(g, 'text').attributes['x'].to_f
    c2 = cv
    AL::DimensionEngine.draw(c2, v, 30.0, 50, 50, { 'dimtext' => { id => [7.5, 0] } })
    g2 = REXML::XPath.match(REXML::Document.new(c2.svg), "//g[@class='dimtxt'][@data-id='#{id}']").first
    assert_in_delta x0 + 7.5, REXML::XPath.first(g2, 'text').attributes['x'].to_f, 0.01
    assert_equal({ id => [7.5, 0.0] }, AL::ProjectStore.clean_page('pid' => 1, 'dimtext' => { id => [7.5, 0] })['dimtext'])
  end

  def test_qua_day_thi_chuyen_dim_chi_tiet
    v = view
    v[:key] = 'front'
    r = AL::DimensionEngine.draw(cv, v, 100.0, 50, 50, { 'has_detail_view' => true })
    assert r['moved'], 'tỉ lệ 1:100: các ván 18 quá hẹp -> mặt đứng chỉ giữ kích thước tổng'
    assert_equal [0.0, v[:w]], r['x']
    r2 = AL::DimensionEngine.draw(cv, v, 100.0, 50, 50, {})
    refute r2['moved'], 'không có hình tháo cánh/mặt cắt thì không chuyển'
  end
end
