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
  end
end
require File.join(ROOT, 'model_scanner')

module Stub
  BBox = Struct.new(:width, :height, :depth)            # API SketchUp: width=X, height=Y, depth=Z (inch)
  Def = Struct.new(:name, :bounds, :children)
  Layer = Struct.new(:name) { def visible?; true; end }
  Tr = Struct.new(:m) { def to_a; m; end }
  @pid = 1000

  def self.ent(klass, name, mm = [1000, 500, 2000], scale = [1, 1, 1], children = [])
    @pid += 1
    e = klass.allocate
    pid = @pid
    bb = BBox.new(mm[0] / 25.4, mm[1] / 25.4, mm[2] / 25.4)
    d = Def.new("#{name}-def", bb, children)
    m = [scale[0], 0, 0, 0, 0, scale[1], 0, 0, 0, 0, scale[2], 0, 0, 0, 0, 1]
    e.define_singleton_method(:persistent_id) { pid }
    e.define_singleton_method(:name) { name }
    e.define_singleton_method(:definition) { d }
    e.define_singleton_method(:transformation) { Tr.new(m) }
    e.define_singleton_method(:layer) { Layer.new('Untagged') }
    e.define_singleton_method(:hidden?) { false }
    e.define_singleton_method(:deleted?) { false }
    e
  end

  class Model
    attr_reader :entities, :selection, :layers

    def initialize(entities, selection)
      @entities = entities
      @selection = selection
      @layers = [Layer.new('Untagged')]
    end

    def find_entity_by_persistent_id(pid)
      all = @entities.flat_map { |e| [e] + (e.respond_to?(:definition) ? e.definition.children : []) }
      all.find { |e| e.persistent_id == pid }
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
    ids = AL::ProjectStore.add_pages(project, picked, ->(pid) { e = SC.find(m, pid); e && e.name })
    assert_equal 2, ids.length
    assert_equal picked, project['pages'].map { |p| p['pid'] }
    assert_equal %w[A-01 A-02], project['pages'].map { |p| p['sheet_no'] }
  end

  def test_khong_tao_trang_cho_doi_tuong_da_xoa
    project = AL::ProjectStore.default_project
    ids = AL::ProjectStore.add_pages(project, [999_999], ->(_pid) { nil })
    assert_empty ids
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
