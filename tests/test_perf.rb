# encoding: UTF-8
# v2.16: tối ưu hiệu năng (model nhiều mặt cong) – kết quả phải giữ nguyên độ chính xác.
require_relative 'test_helper'
require_relative 'test_doors'
require_relative 'bench/chair'

module PF
  module_function

  def chair(seg = 12)
    @chairs ||= {}
    @chairs[seg] ||= Chair.build(Fake.capture('Ghế'), hard: :smooth, seg: seg)
  end

  def build(cap, views, extra = {})
    project = AL::ProjectStore.default_project
    pg = AL::ProjectStore.clean_page(project['defaults'].merge('pid' => 1, 'sheet_no' => 'A-01', 'views' => views, 'scale' => 10,
                                                               'sections' => []).merge(extra))
    project['pages'] = [pg]
    pb = AL::PageBuild.new(TestDoorPages::Env.new(cap), project, pg, :svg)
    job = AL::Job.new('t', timer: ->(_b) {})
    pb.tasks.each { |t| job.add(t) }
    job.run_sync
    [pb, job]
  end

  def area(pts)
    a = 0.0
    pts.each_with_index { |p, i| q = pts[(i + 1) % pts.length]; a += p[0] * q[1] - q[0] * p[1] }
    a / 2
  end
end

class TestPerf < Minitest::Test
  # Gộp mảng tô cùng màu liền nhau: ít phần tử, cùng chiều quay (nonzero = hợp, không thủng), đúng thứ tự màu
  def test_gop_mang_to_cung_mau
    cv = AL::Canvas.new(:svg, 100, 100)
    items = [[[[0, 0], [10, 0], [0, 10]], '#AA0000'], [[[0, 0], [0, 10], [10, 10]], '#AA0000'], # 2 chiều quay khác nhau
             [[[5, 5], [8, 5], [5, 8]], '#00AA00'], [[[1, 1], [2, 1], [1, 2]], '#AA0000']]
    cv.fill_runs(items)
    paths = cv.svg.scan(/<path d="([^"]+)" fill="(#[0-9A-F]+)"/)
    assert_equal %w[#AA0000 #00AA00 #AA0000], paths.map(&:last), 'giữ thứ tự vẽ sau->trước giữa các màu'
    rings = paths[0][0].scan(/M([^Z]+)Z/).map { |r| r[0].split('L').map { |p| p.split.map(&:to_f) } }
    assert_equal 2, rings.length
    assert rings.all? { |r| PF.area(r) >= 0 }, 'mọi vòng cùng chiều quay'
    pdf = AL::Canvas.new(:pdf, 100, 100)
    pdf.fill_runs(items)
    assert_equal 3, pdf.instance_variable_get(:@out).join("\n").scan(/ B\b/).length
  end

  def test_so_phan_tu_svg_giam_manh_ma_hinh_nhu_cu
    pb, = PF.build(PF.chair, %w[front left top])
    svg = pb.outputs[0][0]
    fills = pb.views.sum { |v| Array(v[:fills]).length }
    assert fills > 5000, "ghế cong có nhiều mảng tô (#{fills})"
    assert svg.scan('<path').length < fills / 20, 'gộp: số <path> nhỏ hơn rất nhiều số mảng tô'
  end

  # Mặt cắt dùng lại cây BSP của bản trích gốc: mảng tô chỉ ở phía được giữ, không dựng cây lần 2
  def test_mat_cat_dung_lai_cay_bsp
    cap = Chair.build(Fake.capture('Ghế'), hard: :smooth, seg: 12) # bản riêng: chưa có cây
    sec = { 'label' => 'A', 'axis' => 'x', 'pos' => 250, 'dir' => 1, 'auto' => false }
    made = []
    bk = AL::Geometry::HiddenFill::Builder
    bk.singleton_class.send(:alias_method, :__new_orig, :new)
    bk.define_singleton_method(:new) { |tris| made << tris.length; __new_orig(tris) }
    begin
      pb, job = PF.build(cap, %w[front iso], 'sections' => [sec])
    ensure
      bk.singleton_class.send(:alias_method, :new, :__new_orig)
    end
    v = pb.views.find { |x| x[:key] == 'sec:A' }
    refute_empty v[:fills]
    assert cap.fill_tree?, 'cây của bản gốc đã dựng (cho mặt đứng / trục đo)'
    assert_equal [cap.triangles.length], made, 'chỉ dựng 1 cây (bản gốc), không dựng cây riêng cho phần đã cắt'
    assert job.timings.key?('MẶT CẮT A-A')
  end

  def test_mat_cat_khong_lay_manh_phia_bi_cat
    cap = PF.chair
    sec = { 'label' => 'A', 'axis' => 'x', 'pos' => 250, 'dir' => 1 }
    sb = AL::SectionEngine::SectionBuilder.new(cap, sec)
    job = AL::Job.new('t', timer: ->(_b) {})
    job.add(sb)
    job.run_sync
    cl = sb.result
    assert cl[:fills].length.positive?
    # mọi mảnh tô nằm trong khung của mặt cắt (đã bỏ phần x < 250)
    w = cl[:w]
    h = cl[:h]
    assert cl[:fills].all? { |pts, _| pts.all? { |p| p[0] > -0.5 && p[0] < w + 0.5 && p[1] > -0.5 && p[1] < h + 0.5 } }
  end

  def test_cay_bsp_van_dung_thu_tu
    # 2 tấm chồng nhau nhìn từ trước: tấm gần (y nhỏ) phải vẽ SAU tấm xa
    cap = Fake.capture
    Fake.box(cap, 0, 100, 0, 100, 110, 100, 'xa')
    Fake.box(cap, 20, 0, 20, 80, 10, 80, 'gan')
    cap.materials['xa'] = { 'color' => '#111111' }
    cap.materials['gan'] = { 'color' => '#EEEEEE' }
    v = AL::Geometry.project(cap, 'front')
    order = v[:fills].map { |_, c| c }
    assert_operator order.rindex('#111111'), :<, order.rindex('#EEEEEE')
  end

  def test_job_do_thoi_gian_tung_buoc_va_bao_cao
    pb, job = PF.build(PF.chair, %w[front])
    t = AL::PerfProbe.timings(job)
    assert t.keys.any? { |k| k.include?('MẶT ĐỨNG') }
    st = AL::PerfProbe.sheet_stats(pb.outputs)
    assert st[0]['paths'].positive?
    assert st[0]['snap_kb'].positive?, 'hình học bắt điểm tính riêng'
    vs = AL::PerfProbe.view_stats(pb.views)
    assert vs[0]['lines'].positive?
  end

  # Đếm model qua API (giả lập Entities): Component lặp lại được tính đủ, definition duyệt 1 lần
  def test_dem_model
    face = Sketchup::Face.allocate
    edge = Sketchup::Edge.allocate
    def edge.soft? = true
    def edge.smooth? = false
    def edge.hidden? = false
    leaf = Struct.new(:entities).new([face, face, edge])
    inst = Sketchup::ComponentInstance.allocate
    inst.define_singleton_method(:definition) { leaf }
    root = Struct.new(:definition).new(Struct.new(:entities).new([inst, inst, face]))
    s = AL::PerfProbe.model_stats(root)
    assert_equal 5, s['faces']
    assert_equal 2, s['edges']
    assert_equal 2, s['edges_soft']
    assert_equal 2, s['components']
    assert_equal 2, s['definitions']
  end
end
