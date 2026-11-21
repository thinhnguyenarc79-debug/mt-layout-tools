# encoding: UTF-8
# Lỗi: Group tủ nhiều chi tiết -> "Đối tượng quá phức tạp" -> trang A-01 trắng.
# Kiểm: không còn giới hạn cứng; model lớn vẫn ra hình; 3 mức dự phòng; trích hình học theo definition + ma trận.
require_relative 'test_helper'
require File.join(ROOT, 'job')
require File.join(ROOT, 'extractor')

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
module Sketchup
  class Face < Drawingelement; end unless const_defined?(:Face)
end

module Big
  module_function

  # Tay nắm trụ tròn nhiều mặt: sinh rất nhiều tam giác như model thật.
  # Tay nắm thanh tròn nằm ngang (trục X) trước mặt tủ.
  def handle(cap, cx, cz, y, r, len, seg)
    ring = ->(xx) { (0...seg).map { |i| a = 2 * Math::PI * i / seg; [xx, y + r * Math.cos(a), cz + r * Math.sin(a)] } }
    a = ring.call(cx)
    b = ring.call(cx + len)
    seg.times do |i|
      j = (i + 1) % seg
      cap.triangles << [a[i], a[j], b[j], nil]
      cap.triangles << [a[i], b[j], b[i], nil]
      cap.edges << [b[i], b[j]]
      cap.edges << [a[i], a[j]]
    end
  end

  # Tủ ~120.000 tam giác: khung + 40 đợt + 300 tay nắm 200 cạnh.
  def cabinet
    cap = Fake.cabinet
    40.times { |k| Fake.box(cap, 18, 0, 100 + k * 60, 642, 350, 118 + k * 60) }
    300.times { |k| handle(cap, 40 + (k % 20) * 115, 200 + (k / 20) * 160, -20, 6, 90, 200) }
    cap
  end
end

class TestLargeModel < Minitest::Test
  def test_khong_con_gioi_han_cung
    src = File.read(File.join(ROOT, 'geometry.rb'), encoding: 'UTF-8') + File.read(File.join(ROOT, 'extractor.rb'), encoding: 'UTF-8')
    refute_match(/MAX_EDGES|MAX_TRIANGLES|quá phức tạp/, src)
  end

  def test_model_120k_tam_giac_van_ra_hinh_day_du
    cap = Big.cabinet
    assert_operator cap.triangles.length, :>, 120_000
    t = Time.now
    v = AL::Geometry.project(cap, 'front')
    dt = Time.now - t
    assert_equal 1, v[:level], 'đủ thời gian thì khử nét đầy đủ'
    assert_operator v[:lines].length, :>, 1000
    assert_in_delta 2410, v[:w], 30
    puts "\n  [model lớn] #{cap.triangles.length} tam giác, #{cap.edges.length} cạnh -> mặt đứng #{v[:lines].length} nét trong #{dt.round(2)}s"
    # mặt bằng & trục đo cũng phải ra hình
    %w[top iso].each { |k| refute_empty AL::Geometry.project(cap, k)[:lines], k }
  end

  def test_muc_2_khi_muc_1_het_gio
    v = AL::Geometry.project(Big.cabinet, 'front', nil, [0.0, 1000])
    assert_equal 2, v[:level]
    refute_empty v[:lines]
    assert_match(/mặt lớn/, v[:notes].join)
  end

  def test_muc_3_van_co_net_that_va_ghi_ro_chua_day_du
    v = AL::Geometry.project(Big.cabinet, 'front', nil, [0.0, 0.0])
    assert_equal 3, v[:level]
    refute_empty v[:lines], 'không bao giờ trả hình trống'
    assert_match(/CHƯA ĐẦY ĐỦ/, v[:notes].join)
  end

  def test_qua_nhieu_tam_giac_thi_khong_to_mau_nhung_van_ve_net
    v = AL::Geometry.project(Big.cabinet, 'front')
    assert_empty v[:fills]
    assert_match(/không tô màu/, v[:notes].join)
  end

  def test_canh_trung_bi_loai_sau_khi_chieu
    cap = Fake.capture
    Fake.box(cap, 0, 0, 0, 100, 100, 100)
    Fake.box(cap, 0, 0, 0, 100, 100, 100) # trùng hệt
    assert_equal 4, AL::Geometry.project(cap, 'front')[:lines].length
  end

  def test_job_engine_khong_dung_fiber
    src = Dir[File.join(ROOT, '**', '*.rb')].map { |f| File.read(f, encoding: 'UTF-8') }.join
    refute_match(/Fiber|Thread\.new/, src.gsub(/#.*$/, ''), 'không còn Fiber/Thread trong mã chạy')
  end
end

# ---- Trích hình học từ cây Group/Component (API SketchUp giả lập tối thiểu) ----
module X
  P = Struct.new(:x, :y, :z)
  V = Struct.new(:position)
  L = Struct.new(:name) { def visible?; name != 'Ẩn'; end }
  T = Struct.new(:m) { def to_a; m; end }

  def self.tr(dx, dy, dz)
    T.new([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, dx, dy, dz, 1].map(&:to_f))
  end

  def self.edge(a, b, tag = 'Untagged')
    e = Sketchup::Edge.allocate
    e.define_singleton_method(:start) { V.new(P.new(*a)) }
    e.define_singleton_method(:end) { V.new(P.new(*b)) }
    e.define_singleton_method(:soft?) { false }
    e.define_singleton_method(:smooth?) { false }
    e.define_singleton_method(:hidden?) { false }
    e.define_singleton_method(:layer) { L.new(tag) }
    e
  end

  Def = Struct.new(:name, :entities)

  def self.inst(defn, t, klass = Sketchup::Group, tag = 'Untagged')
    i = klass.allocate
    i.define_singleton_method(:definition) { defn }
    i.define_singleton_method(:transformation) { t }
    i.define_singleton_method(:material) { nil }
    i.define_singleton_method(:hidden?) { false }
    i.define_singleton_method(:layer) { L.new(tag) }
    i.define_singleton_method(:name) { defn.name }
    pid = (@pid = (@pid || 5000) + 1)
    i.define_singleton_method(:persistent_id) { pid }
    i
  end
end

class TestExtractor < Minitest::Test
  def setup
    @ex = AL::Extractor.new
  end

  def test_compose_va_apply
    a = [1.0, 0, 0, 10, 0, 1.0, 0, 20, 0, 0, 1.0, 30]
    m = @ex.compose(a, X.tr(1, 2, 3).to_a)
    assert_equal [11.0, 22.0, 33.0], @ex.apply(m, 0, 0, 0)
  end

  def test_group_long_nhau_dung_ma_tran_tich_luy_va_cache_definition
    inch = 1.0 / 25.4
    tam = X::Def.new('Tấm', [X.edge([0, 0, 0], [100 * inch, 0, 0])])
    # 1 definition dùng cho 10 instance, lồng trong 1 cụm, cụm lồng trong tủ
    cum = X::Def.new('Cụm', (0...10).map { |k| X.inst(tam, X.tr(0, 0, k * 50 * inch), Sketchup::ComponentInstance) })
    tu = X::Def.new('Tủ', [X.inst(cum, X.tr(1000 * inch, 0, 0)), X.edge([0, 0, 0], [0, 0, 10 * inch], 'Ẩn')])
    root = X.inst(tu, X.tr(0, 0, 0))
    calls = 0
    orig = @ex.method(:def_data)
    @ex.define_singleton_method(:def_data) { |d, j| calls += 1; orig.call(d, j) }
    ident = [AL::Extractor::MM, 0, 0, 0, 0, AL::Extractor::MM, 0, 0, 0, 0, AL::Extractor::MM, 0]
    @ex.define_singleton_method(:root_matrix) { |_w, _f| ident }
    model = Object.new
    model.define_singleton_method(:layers) { [X::L.new('Untagged'), X::L.new('Ẩn')] }
    AL::Geometry.define_singleton_method(:world_transform) { |_m, _i| nil }
    cap = @ex.capture(model, root, [], '-Y')
    assert_equal 10, cap.edges.length, 'cạnh trên Tag ẩn bị bỏ'
    xs = cap.edges.map { |a, b| [a[0].round(3), b[0].round(3)] }.uniq
    assert_equal [[1000.0, 1100.0]], xs, 'cộng dồn dịch chuyển của Group cha'
    assert_equal (0...10).map { |k| (k * 50.0).round(3) }, cap.edges.map { |a, _| a[2].round(3) }.sort
    assert_equal 1, cap.stats['groups']
    assert_equal 10, cap.stats['components']
    assert_equal 3, @ex.instance_variable_get(:@defs).length, 'mỗi definition chỉ đọc 1 lần'
  end
end
