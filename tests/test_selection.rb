# encoding: UTF-8
# Kiểm: danh sách model chỉ lấy từ selection (không quét cả file, không tách con, không dữ liệu giả).
require_relative 'test_helper'

# Bản giả tối thiểu của SketchUp API, chỉ dùng khi chạy test ngoài SketchUp.
unless defined?(Sketchup::Group)
  module Sketchup
    class Drawingelement; end
    class Group < Drawingelement; end
    class ComponentInstance < Drawingelement; end
    class Edge < Drawingelement; end
    class ComponentDefinition; end
    class Model; end
  end
end
require File.join(ROOT, 'model_scanner')

module Stub
  BBox = Struct.new(:width, :height, :depth)            # API SketchUp: width=X, height=Y, depth=Z (inch)
  class Def < Sketchup::ComponentDefinition
    attr_accessor :name, :bounds, :children

    def initialize(name, bounds, children)
      @name, @bounds, @children = name, bounds, children
    end
  end
  Layer = Struct.new(:name) { def visible?; true; end }
  Tr = Struct.new(:m) { def to_a; m; end }
  @pid = 1000

  def self.ent(klass, name, mm = [1000, 500, 2000], scale = [1, 1, 1], children = [])
    @pid += 1
    e = klass.allocate
    pid = @pid
    bb = BBox.new(mm[0] / 25.4, mm[1] / 25.4, mm[2] / 25.4)
    d = Def.new("#{name}-def", bb, children)
    children.each { |c| c.instance_variable_set(:@parent_ref, d) }
    e.define_singleton_method(:parent) { instance_variable_get(:@parent_ref) || ROOT_MODEL }
    e.define_singleton_method(:valid?) { !instance_variable_get(:@gone) }
    m = [scale[0], 0, 0, 0, 0, scale[1], 0, 0, 0, 0, scale[2], 0, 0, 0, 0, 1]
    e.define_singleton_method(:persistent_id) { pid }
    e.define_singleton_method(:name) { name }
    e.define_singleton_method(:definition) { d }
    e.define_singleton_method(:transformation) { Tr.new(m) }
    e.define_singleton_method(:layer) { Layer.new('Untagged') }
    e.define_singleton_method(:hidden?) { false }
    e.define_singleton_method(:deleted?) { !!instance_variable_get(:@gone) }
    e
  end

  ROOT_MODEL = Object.new # cha của đối tượng ở gốc model (không phải ComponentDefinition)

  # Gộp các đối tượng gốc vào 1 Group cha mới (như lệnh Make Group trong SketchUp).
  def self.make_group(name, kids)
    g = ent(Sketchup::Group, name, [2410, 600, 2698], [1, 1, 1], kids)
    g
  end

  class Model
    attr_reader :entities, :selection, :layers

    def initialize(entities, selection)
      @entities = entities
      @selection = selection
      @layers = [Layer.new('Untagged')]
    end

    def find_entity_by_persistent_id(pid)
      walk = lambda { |list| list.flat_map { |e| [e] + walk.call(e.definition.children) } }
      walk.call(@entities).find { |e| e.persistent_id == pid }
    end
  end
end

class TestSelectionOnly < Minitest::Test
  SC = AL::ModelScanner

  def file_with_50_groups
    (1..50).map { |i| Stub.ent(Sketchup::Group, "Tủ #{i}") }
  end

  def test_1_file_50_group_chon_1_tu
    all = file_with_50_groups
    m = Stub::Model.new(all, [all[7]])
    list = SC.models(m)
    assert_equal 1, list.length
    assert_equal 'Tủ 8', list[0]['name']
  end

  def test_2_chon_3_group
    all = file_with_50_groups
    m = Stub::Model.new(all, [all[1], all[20], all[49]])
    assert_equal ['Tủ 2', 'Tủ 21', 'Tủ 50'], SC.models(m).map { |x| x['name'] }
  end

  def test_3_group_cha_chua_20_component_con
    kids = (1..20).map { |i| Stub.ent(Sketchup::ComponentInstance, "Cánh #{i}") }
    parent = Stub.ent(Sketchup::Group, 'Tủ bếp', [3000, 600, 900], [1, 1, 1], kids)
    m = Stub::Model.new([parent] + file_with_50_groups, [parent])
    list = SC.models(m)
    assert_equal 1, list.length
    assert_equal 'Tủ bếp', list[0]['name']
  end

  def test_4_khong_chon_gi
    m = Stub::Model.new(file_with_50_groups, [])
    assert_empty SC.models(m)
    m2 = Stub::Model.new(file_with_50_groups, [Sketchup::Edge.new]) # chỉ chọn cạnh
    assert_empty SC.models(m2)
    assert_match(/chưa chọn Group hoặc Component/, SC::NO_SELECTION)
  end

  def test_5_chi_tao_trang_cho_model_duoc_tick
    all = file_with_50_groups
    m = Stub::Model.new(all, [all[0], all[1], all[2]])
    picked = SC.models(m).first(2).map { |x| x['pid'] } # bỏ tick model thứ 3
    project = AL::ProjectStore.default_project
    res = AL::ProjectStore.add_pages(project, picked, ->(pid) { e = SC.find(m, pid); e && e.name })
    assert_equal 2, res['created'].length
    assert_equal picked, project['pages'].map { |p| p['pid'] }
    assert_equal %w[A-01 A-02], project['pages'].map { |p| p['sheet_no'] }
  end

  def test_khong_tao_trang_cho_doi_tuong_da_xoa
    project = AL::ProjectStore.default_project
    res = AL::ProjectStore.add_pages(project, [999_999], ->(_pid) { nil })
    assert_empty res['created']
    assert_empty project['pages']
  end

  def test_kich_thuoc_rong_cao_sau_dung_truc
    e = Stub.ent(Sketchup::Group, 'Tủ', [2410, 350, 2698]) # X=2410, Y(sâu)=350, Z(cao)=2698
    assert_equal [2410, 2698, 350], SC.size_mm(e)
    e2 = Stub.ent(Sketchup::Group, 'Tủ x2', [1000, 400, 800], [2, 1, 1]) # bị scale 2 lần theo X
    assert_equal [2000, 800, 400], SC.size_mm(e2)
  end

  def test_khong_trung_lap
    all = file_with_50_groups
    m = Stub::Model.new(all, [all[3], all[3]])
    assert_equal 1, SC.models(m).length
  end
end

# Lỗi: gộp cả tủ thành 1 Group cha nhưng vẫn ra nhiều trang A-01, A-02... cho Group con / Mesh.
class TestRegressionGroupCha < Minitest::Test
  SC = AL::ModelScanner

  def finder(m)
    lambda do |pid|
      e = SC.find(m, pid)
      e && { 'name' => e.name, 'root' => !SC.nested?(e) }
    end
  end

  def test_group_cha_100_con_chi_1_model_1_trang
    kids = (1..100).map { |i| Stub.ent(Sketchup::ComponentInstance, i == 1 ? 'Mesh_801991499' : "Group##{i}") }
    tu = Stub.make_group('Tủ áo', kids)
    m = Stub::Model.new([tu], [tu])
    list = SC.models(m)
    assert_equal ['Tủ áo'], list.map { |x| x['name'] }
    project = AL::ProjectStore.default_project
    AL::ProjectStore.add_pages(project, list.map { |x| x['pid'] }, finder(m))
    assert_equal 1, project['pages'].length
    assert_equal ['A-01', 'Tủ áo'], [project['pages'][0]['sheet_no'], project['pages'][0]['name']]
    assert_equal 'ok', SC.page_status(m, project['pages'][0])
  end

  def test_bam_trien_khai_nhieu_lan_khong_tao_trung
    tu = Stub.make_group('Tủ áo', [Stub.ent(Sketchup::Group, 'Cánh')])
    m = Stub::Model.new([tu], [tu])
    project = AL::ProjectStore.default_project
    3.times { AL::ProjectStore.add_pages(project, [tu.persistent_id], finder(m)) }
    assert_equal 1, project['pages'].length, 'chế độ thay thế: vẫn 1 trang'
    id = project['pages'][0]['id']
    res = AL::ProjectStore.add_pages(project, [tu.persistent_id], finder(m), false)
    assert_equal [id], res['skipped']
    assert_equal 1, project['pages'].length, 'chế độ không thay thế: bỏ qua, không tạo trùng'
  end

  def test_thay_the_giu_id_ky_hieu_va_khong_xoa_trang_khac
    a = Stub.ent(Sketchup::Group, 'Tủ A')
    b = Stub.ent(Sketchup::Group, 'Tủ B')
    m = Stub::Model.new([a, b], [a, b])
    project = AL::ProjectStore.default_project
    AL::ProjectStore.add_pages(project, [a.persistent_id, b.persistent_id], finder(m))
    project['pages'][0]['offsets'] = { 'front' => [10.0, 5.0] }
    before = project['pages'].map { |p| [p['id'], p['sheet_no']] }
    res = AL::ProjectStore.add_pages(project, [a.persistent_id], finder(m))
    assert_equal 1, res['replaced'].length
    assert_equal before, project['pages'].map { |p| [p['id'], p['sheet_no']] }
    assert_equal({}, project['pages'][0]['offsets'], 'trang thay thế được dàn lại')
  end

  def test_migration_trang_cu_cua_bo_phan_con
    # Bản 2.0.0: file có 3 Group rời ở gốc, mỗi Group được tạo 1 trang (dữ liệu cũ không có 'root').
    parts = [Stub.ent(Sketchup::Group, 'Group#165'), Stub.ent(Sketchup::Group, 'Group#217'),
             Stub.ent(Sketchup::ComponentInstance, 'Mesh_801991499')]
    old = { 'version' => 1, 'pages' => parts.each_with_index.map do |e, i|
      { 'id' => "old#{i}", 'pid' => e.persistent_id, 'name' => e.name, 'sheet_no' => format('A-%02d', i + 1) }
    end }
    project = AL::ProjectStore.clean(JSON.parse(JSON.generate(old)))
    m0 = Stub::Model.new(parts, [])
    assert_equal %w[ok ok ok], project['pages'].map { |p| SC.page_status(m0, p) }
    # Người dùng gộp cả 3 vào Group cha "Tủ áo".
    tu = Stub.make_group('Tủ áo', parts)
    m = Stub::Model.new([tu], [tu])
    assert_equal %w[nested nested nested], project['pages'].map { |p| SC.page_status(m, p) }
    AL::ProjectStore.add_pages(project, [tu.persistent_id], finder(m))
    st = SC.statuses(m, project)
    assert_equal 1, st.values.count('ok'), 'chỉ trang Group cha hợp lệ'
    assert_equal 3, st.values.count('nested'), 'các trang cũ được đánh dấu để dọn'
  end

  def test_doi_tuong_da_xoa
    a = Stub.ent(Sketchup::Group, 'Tủ')
    m = Stub::Model.new([a], [a])
    project = AL::ProjectStore.default_project
    AL::ProjectStore.add_pages(project, [a.persistent_id], finder(m))
    a.instance_variable_set(:@gone, true)
    assert_equal 'deleted', SC.page_status(m, project['pages'][0])
    assert_empty SC.models(m), 'đối tượng đã xoá không vào danh sách'
  end

  def test_trang_tao_khi_dang_mo_group_cha_van_hop_le
    canh = Stub.ent(Sketchup::Group, 'Cánh')
    tu = Stub.make_group('Tủ', [canh])
    m = Stub::Model.new([tu], [canh]) # người dùng mở Group cha và chọn trực tiếp Group con
    project = AL::ProjectStore.default_project
    AL::ProjectStore.add_pages(project, [canh.persistent_id], finder(m))
    assert_equal false, project['pages'][0]['root']
    assert_equal 'ok', SC.page_status(m, project['pages'][0])
  end

  def test_du_lieu_cu_trung_pid_duoc_gop
    raw = { 'pages' => [{ 'id' => 'a', 'pid' => 5 }, { 'id' => 'b', 'pid' => 5 }, { 'id' => 'c', 'pid' => 6 }] }
    assert_equal %w[a c], AL::ProjectStore.clean(raw)['pages'].map { |p| p['id'] }
  end
end
