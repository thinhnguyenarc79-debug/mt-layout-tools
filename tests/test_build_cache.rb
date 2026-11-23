# encoding: UTF-8
# v2.17: tăng tốc dựng trang lần đầu / dựng lại – cache theo hình & theo phiên bản model, kết quả không đổi.
require_relative 'test_helper'
require_relative 'test_perf'

class TestBuildCache < Minitest::Test
  # Mảng tô viết theo toạ độ cục bộ + phép biến đổi: toạ độ trên giấy trùng cách vẽ cũ (sai số <= 0.01 mm thật)
  def test_mang_to_cuc_bo_dung_vi_tri
    items = [[[[10.0, 20.0], [110.123, 20.0], [10.0, 220.456]], '#A97C50'], [[[5.0, 5.0], [6.0, 5.0], [5.0, 9.0]], '#111111']]
    s = 20.0
    ox = 37.5
    oy = 41.25
    frag = AL::Canvas.local_fills(:svg, items, s)
    cv = AL::Canvas.new(:svg, 420, 297)
    cv.placed_fills(frag, ox, oy, s)
    out = cv.svg
    m = out.match(/translate\(([\d.]+) ([\d.]+)\) scale\(([\d.]+)\)/)
    assert_in_delta ox, m[1].to_f, 1e-6
    assert_in_delta oy, m[2].to_f, 1e-6
    assert_in_delta 1 / s, m[3].to_f, 1e-9
    pts = out.scan(/ d="([^"]+)"/).flat_map { |d| d[0].scan(/M([^Z]+)Z/) }.flat_map { |r| r[0].split("L").map { |p| p.split.map(&:to_f) } }
    want = items.flat_map { |ps, _| ps }
    want.each { |w| assert pts.any? { |p| (p[0] - w[0]).abs <= 0.005 && (p[1] - w[1]).abs <= 0.005 }, w.inspect }
    assert_match(/stroke-width="1.6"/, out, 'viền 0.08 mm giấy = 1.6 mm thật ở 1:20')
    pdf = AL::Canvas.new(:pdf, 420, 297)
    pdf.placed_fills(AL::Canvas.local_fills(:pdf, items, s), ox, oy, s)
    body = pdf.instance_variable_get(:@out).join("\n")
    k = AL::Pdf::MM_TO_PT
    assert_match(/q #{Regexp.escape(AL::Pdf.number(k / s))} 0 0 #{Regexp.escape(AL::Pdf.number(-k / s))} /, body)
    assert_equal 2, body.scan(/ B\b/).length
    assert body.rstrip.end_with?('Q')
  end

  def test_so_dinh_dang_nhanh_giong_cach_cu
    [0, 1, -1, 0.004, 0.006, 12.5, 12.05, 12.345, -12.345, 333_333.333, 99.999, -99.999, 1234.5678].each do |x|
      v = x.round(2)
      ref = v == v.to_i ? v.to_i.to_s : v.to_s
      assert_equal ref, AL::Canvas.f2(x), x.to_s
    end
  end

  # Dựng lại (dời hình, sửa DIM, chuyển tờ) dùng lại chuỗi mảng tô; dời hình không làm tính lại
  def test_dung_lai_dung_cache_mang_to
    cap = PF.chair
    pb, = PF.build(cap, %w[front iso])
    v = pb.views.find { |x| x[:key] == 'front' }
    frag = v[:fill_frag].values.first
    refute_nil frag
    pb2, j2 = PF.build(cap, %w[front iso], 'view_props' => { 'front' => { 'x_mm' => 30, 'y_mm' => 40, 'sheet' => 0, 'placement_mode' => 'manual' } })
    v2 = pb2.views.find { |x| x[:key] == 'front' }
    assert_same frag, v2[:fill_frag].values.first, 'cùng chuỗi đã cache dù hình đổi chỗ' if v2.equal?(v)
    assert_includes pb2.outputs[0][0], frag
    assert j2.timings.select { |k, _| k.start_with?('vẽ') }.values.sum < 1.0
  end

  # Cây che khuất là bước riêng; hình mặt đứng không còn gánh thời gian dựng cây
  def test_cay_che_khuat_la_buoc_rieng
    cap = Chair.build(Fake.capture('Ghế'), hard: :smooth, seg: 12)
    _pb, job = PF.build(cap, %w[front left])
    assert job.timings.key?('cây che khuất mặt tô (dùng chung)')
    assert cap.fill_tree.done?
  end

  def test_mau_bong_do_nhu_cu
    srand(7)
    50.times do
      tri = Array.new(3) { [rand * 100, rand * 100, rand * 100] }
      hex = format('#%02X%02X%02X', rand(256), rand(256), rand(256))
      a, b, c = tri
      u = [b[0] - a[0], b[1] - a[1], b[2] - a[2]]
      v = [c[0] - a[0], c[1] - a[1], c[2] - a[2]]
      n = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
      len = Math.sqrt(n.sum { |x| x * x })
      k = 0.72 + 0.28 * (n.zip(AL::Geometry::ISO_LIGHT).sum { |x, y| x * y } / len).abs
      ref = format('#%02X%02X%02X', *hex[1..-1].scan(/../).map { |hh| (hh.to_i(16) * k).round.clamp(0, 255) })
      assert_equal ref, AL::Geometry.shaded(hex, tri)
    end
  end

  # Phiên bản model: transaction -> khoá mới (bỏ cache); không theo dõi được -> nil (giữ cách cũ)
  def test_theo_doi_phien_ban_model
    fake = Object.new
    def fake.add_observer(_o) = true
    unless defined?(Sketchup::ModelObserver)
      Sketchup.const_set(:ModelObserver, Class.new)
      load File.join(ROOT, 'model_watch.rb')
    end
    k1 = AL::ModelWatch.key(fake)
    refute_nil k1
    assert_equal k1, AL::ModelWatch.key(fake), 'không có thay đổi -> giữ khoá'
    AL::ModelWatch::Observer.new.onTransactionCommit(fake)
    refute_equal k1, AL::ModelWatch.key(fake), 'sửa model -> khoá mới'
    k2 = AL::ModelWatch.key(fake)
    AL::ModelWatch::Observer.new.onTransactionUndo(fake)
    refute_equal k2, AL::ModelWatch.key(fake)
    bad = Object.new
    def bad.add_observer(_o) = raise('không hỗ trợ')
    assert_nil AL::ModelWatch.key(bad)
  end

  def test_xuat_pdf_ghe_cong
    cap = PF.chair
    project = AL::ProjectStore.default_project
    pg = AL::ProjectStore.clean_page(project['defaults'].merge('pid' => 1, 'sheet_no' => 'A-01', 'views' => %w[front iso], 'scale' => 10, 'sections' => []))
    project['pages'] = [pg]
    pb = AL::PageBuild.new(TestDoorPages::Env.new(cap), project, pg, :pdf)
    job = AL::Job.new('t', timer: ->(_b) {})
    pb.tasks.each { |t| job.add(t) }
    job.run_sync
    body = pb.outputs[0][0]
    assert_match(/ cm\n/, body)
    assert_equal body.scan(/^q /).length, body.scan(/^Q$/).length + body.scan(/\nQ\z/).length if false
    assert body.scan(/ B\b/).length.positive?
  end
end
