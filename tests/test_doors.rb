# encoding: UTF-8
# Phân biệt DIM có cánh / tháo cánh; nhận diện cánh chỉ từ dữ liệu (thuộc tính, Tag, tên, chọn tay).
require_relative 'test_helper'
require File.join(ROOT, 'extractor')
require_relative 'test_large' unless defined?(X)

module DoorFake
  module_function

  # Tủ 2410 (Fake.cabinet) + 3 cánh phủ mặt trước (y -20..-2), khe 3 mm, cánh là phần tử được gắn mã cánh.
  def cabinet_with_doors
    cap = Fake.cabinet
    cap.edge_door = Array.new(cap.edges.length)
    cap.tri_door = Array.new(cap.triangles.length)
    cap.doors = []
    [[0, 800], [803, 1606], [1609, 2410]].each_with_index do |(x0, x1), id|
      ne = cap.edges.length
      nt = cap.triangles.length
      Fake.box(cap, x0, -20, 60, x1, -2, 2698, 'Trắng')
      cap.edge_door.concat([id] * (cap.edges.length - ne))
      cap.tri_door.concat([id] * (cap.triangles.length - nt))
      cap.doors << { 'id' => id, 'path' => "9/#{id}", 'name' => "Cánh #{id + 1}", 'reason' => 'tên' }
    end
    cap.materials['Trắng'] = { 'name' => 'Trắng', 'color' => '#F2F2F2' }
    cap
  end

  def door_view(cap)
    v = AL::Geometry.project(cap, 'front')
    l, t = v[:origin]
    v[:door_boxes] = cap.door_boxes(v[:fn]).map { |d| b = d['box']; [b[0] - l, b[1] - l, b[2] - t, b[3] - t] }
    v[:dim_mode] = :door
    v
  end

  def segs(xs)
    xs.each_cons(2).map { |a, b| (b - a).round }
  end
end

class TestDoorDims < Minitest::Test
  def test_1_tu_dong_canh_mat_dung_chinh_chi_dim_canh
    cap = DoorFake.cabinet_with_doors
    v = DoorFake.door_view(cap)
    xs, ys = AL::DimensionEngine.view_breaks(v, 0)
    assert_equal [800, 3, 803, 3, 801], DoorFake.segs(xs), 'bề rộng từng cánh + khe 3 mm'
    refute_includes DoorFake.segs(xs), 624, 'không có khoang 624 nằm sau cánh'
    refute_includes DoorFake.segs(xs), 909
    assert_equal [2638, 60], DoorFake.segs(ys), 'chiều cao cánh + chân'
  end

  def test_2_thao_canh_hien_vach_dot_va_dim_tung_khoang
    cap = DoorFake.cabinet_with_doors
    open = cap.without_doors
    assert_equal Fake.cabinet.triangles.length, open.triangles.length, 'chỉ bỏ đúng tam giác của cánh'
    v = AL::Geometry.project(open, 'open')
    v[:dim_mode] = :interior
    xs, = AL::DimensionEngine.view_breaks(v, 0)
    assert_equal [18, 624, 18, 909, 18, 805, 18], DoorFake.segs(xs)
  end

  def test_mat_dung_chua_xac_dinh_canh_chi_dim_ngoai
    v = AL::Geometry.project(Fake.cabinet, 'front')
    v[:dim_mode] = :exterior
    xs, ys = AL::DimensionEngine.view_breaks(v, 0)
    assert_equal [2410], DoorFake.segs(xs)
    assert_equal [2698], DoorFake.segs(ys)
  end

  def test_chu_dim_khong_de_nhau
    v = AL::Geometry.project(Fake.cabinet, 'front')
    v[:dim_mode] = :interior
    pw, ph = AL::Sheet.paper('A3')
    cv = AL::Canvas.new(:svg, pw, ph)
    # tỉ lệ nhỏ 1:50 khiến nhiều khoảng 18 mm rất hẹp (v2.15: từng đoạn DIM là 1 đối tượng, có hộp chữ riêng)
    r = AL::DimensionEngine.draw(cv, v, 50, 50, 50, {})
    placed = r['segs'].map { |g| g['geo'] && g['geo']['tbox'] }.compact
    assert placed.length > 4
    placed.combination(2).each do |a, b|
      overlap = a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3]
      refute overlap, "chữ DIM đè nhau: #{a.inspect} #{b.inspect}"
    end
  end
end

# ---- PageBuild: mặt đứng chính / tháo cánh / chưa xác định cánh ----
class TestDoorPages < Minitest::Test
  class Env
    attr_reader :cache, :logs

    def initialize(cap)
      @cap = cap
      @cache = {}
      @logs = []
    end

    def find(_pid) = :e
    def page_status(_pg) = 'ok'
    def log(m) = (@logs << m)

    def capture_builder(_e, _x, _f, _d = {})
      Struct.new(:result) { def call(_j) = true }.new(@cap)
    end
  end

  def build(cap, views, extra = {})
    project = AL::ProjectStore.default_project
    pg = AL::ProjectStore.clean_page(project['defaults'].merge('pid' => 1, 'sheet_no' => 'A-01', 'views' => views, 'sections' => []).merge(extra))
    pb = AL::PageBuild.new(Env.new(cap), project, pg, :svg)
    job = AL::Job.new('t', timer: ->(_b) {})
    pb.tasks.each { |t| job.add(t) }
    job.run_sync
    pb.output
  end

  def test_trang_co_canh_va_thao_canh_dung_bo_dim
    svg, info = build(DoorFake.cabinet_with_doors, %w[front open])
    assert_equal %w[front open], info['boxes'].keys
    assert_equal 3, info['doors'].length
    texts = svg.scan(%r{<text[^>]*>([^<]*)</text>}).flatten
    # mặt đứng chính: có khe 3; hình tháo cánh: có 624 và 909
    assert_includes texts, '3'
    assert_includes texts, '624'
    assert_includes texts, '909'
  end

  def test_3_khong_xac_dinh_canh_khong_tao_thao_canh_gia
    svg, info = build(Fake.cabinet, %w[front open])
    assert_equal ['front'], info['boxes'].keys, 'không có hình tháo cánh giả'
    assert_match(/Chưa xác định được cánh/, info['note'])
    texts = svg.scan(%r{<text[^>]*>([^<]*)</text>}).flatten
    refute_includes texts, '624', 'mặt đứng chính không DIM khoang khi chưa rõ cánh'
  end

  def test_chon_che_do_tu_khong_canh
    svg, = build(Fake.cabinet, %w[front], 'front_dims' => 'interior')
    assert_includes svg.scan(%r{<text[^>]*>([^<]*)</text>}).flatten, '624'
  end
end

# ---- Nhận diện cánh trong cây Group/Component thật (API SketchUp giả lập) ----
class TestDoorDetect < Minitest::Test
  DD = AL::DoorDetector

  def info(name, tag = 'Untagged', attr = false, def_name = '')
    { name: name, def_name: def_name, tag: tag, attr: attr }
  end

  def test_quy_tac
    assert_equal 'tên', DD.reason(info('Cánh trái'), '1', [], [])
    assert_equal 'tên', DD.reason(info('', 'x', false, 'DOOR_600'), '1', [], [])
    assert_equal 'Tag "1. Canh"', DD.reason(info('Group#12', '1. Canh'), '1', [], ['1. Canh'])
    assert_equal 'thuộc tính', DD.reason(info('Group#5', 'x', true), '1', [], [])
    assert_equal 'chọn tay', DD.reason(info('Group#7'), '3/7', ['3/7'], [])
    assert_equal 'tên', DD.reason(info("Ca\u0301nh pha\u0309i"), '1', [], []), 'tên dạng dấu tách rời'
    %w[Vách Hậu Đợt Nóc Đáy Group#165 Mesh_801991499 Cạnh Canhgia].each do |n|
      assert_nil DD.reason(info(n), '1', [], []), "#{n} không được coi là cánh"
    end
  end

  def test_extractor_gan_ma_canh_theo_duong_dan
    inch = 1.0 / 25.4
    tam = X::Def.new('Tấm', [X.edge([0, 0, 0], [100 * inch, 0, 0])])
    canh = X.inst(tam, X.tr(0, 0, 0), Sketchup::ComponentInstance)
    vach = X.inst(tam, X.tr(0, 0, 500 * inch), Sketchup::ComponentInstance)
    cum = X::Def.new('Cụm 1', [canh])
    cum_i = X.inst(cum, X.tr(0, 0, 0))
    tu = X::Def.new('Tủ', [cum_i, vach])
    root = X.inst(tu, X.tr(0, 0, 0))
    ex = AL::Extractor.new
    ident = [AL::Extractor::MM, 0, 0, 0, 0, AL::Extractor::MM, 0, 0, 0, 0, AL::Extractor::MM, 0]
    ex.define_singleton_method(:root_matrix) { |_w, _f| ident }
    model = Object.new
    model.define_singleton_method(:layers) { [X::L.new('Untagged')] }
    AL::Geometry.define_singleton_method(:world_transform) { |_m, _i| nil }
    path = "#{cum_i.persistent_id}/#{canh.persistent_id}"
    cap = ex.capture(model, root, [], '-Y', nil, { manual: [path] })
    assert_equal 1, cap.doors.length
    assert_equal 'gán tay', cap.doors[0]['reason']
    door_z = cap.edges.each_with_index.select { |_, i| cap.edge_door[i] }.map { |(a, _), _| a[2].round }
    assert_equal [0], door_z, 'chỉ tấm trong cụm cánh được gắn là cánh'
    assert_equal 1, cap.without_doors.edges.length, 'vách (cùng definition) vẫn còn khi tháo cánh'
    cap2 = AL::Extractor.new.tap { |e| e.define_singleton_method(:root_matrix) { |_w, _f| ident } }.capture(model, root, [], '-Y')
    assert_empty cap2.doors, 'không có dữ liệu -> không đoán cánh'
  end
end

class TestPaginate < Minitest::Test
  def test_4_ti_le_1_15_chia_them_to_khong_ep_nho
    cap = DoorFake.cabinet_with_doors
    env = TestDoorPages::Env.new(cap)
    project = AL::ProjectStore.default_project
    pg = AL::ProjectStore.clean_page(project['defaults'].merge('pid' => 1, 'sheet_no' => 'A-01', 'scale' => 15,
                                                               'views' => %w[front open top iso], 'sections' => nil))
    pb = AL::PageBuild.new(env, project, pg, :pdf)
    job = AL::Job.new('t', timer: ->(_b) {})
    pb.tasks.each { |t| job.add(t) }
    job.run_sync
    outs = pb.outputs
    assert_operator outs.length, :>, 1, 'không vừa 1 tờ ở 1:15 -> nhiều tờ'
    outs.each { |_, info| assert_equal 15, info['scale'], 'mọi tờ giữ đúng 1:15' }
    keys = outs.flat_map { |_, info| info['boxes'].keys }
    %w[front open top iso sec:A sec:B].each { |k| assert_includes keys, k }
    assert_equal keys.uniq.length, keys.length, 'mỗi hình chỉ xuất hiện 1 lần'
    pw, ph = AL::Sheet.paper('A3')
    pdf = AL::Pdf.pdf_pages(outs.map(&:first), [pw * AL::Pdf::MM_TO_PT, ph * AL::Pdf::MM_TO_PT])
    assert_includes pdf, "/Count #{outs.length}"
    File.binwrite(File.join(Dir.tmpdir, 'alp_doors_115.pdf'), pdf)
    # tỉ lệ tự động -> 1 tờ
    pg2 = pg.merge('scale' => 0)
    pb2 = AL::PageBuild.new(env, project, pg2, :svg)
    job2 = AL::Job.new('t', timer: ->(_b) {})
    pb2.tasks.each { |t| job2.add(t) }
    job2.run_sync
    assert_equal 1, pb2.outputs.length
  end
end
