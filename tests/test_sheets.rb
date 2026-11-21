# encoding: UTF-8
# Mỗi tờ giấy thật = 1 mục, có mã riêng A-01, A-02...; đổi tỉ lệ cập nhật số tờ; PDF đủ tờ.
require_relative 'test_helper'
require_relative 'test_doors' unless defined?(DoorFake)

class TestSheetCodes < Minitest::Test
  PS = AL::ProjectStore

  def test_tang_ma
    assert_equal 'A-01', PS.increment('A-01', 0)
    assert_equal 'A-03', PS.increment('A-01', 2)
    assert_equal 'A-10', PS.increment('A-09', 1)
    assert_equal 'KT-100', PS.increment('KT-099', 1)
    assert_equal 'BIA-2', PS.increment('BIA', 1)
  end

  def test_danh_ma_lien_tiep_qua_cac_model
    pr = PS.default_project
    pr['pages'] = [PS.clean_page('id' => 'a', 'pid' => 1, 'sheet_no' => 'A-01', 'sheet_count' => 3),
                   PS.clean_page('id' => 'b', 'pid' => 2, 'sheet_no' => 'A-02', 'sheet_count' => 1),
                   PS.clean_page('id' => 'c', 'pid' => 3, 'sheet_no' => 'X-07', 'auto_no' => false, 'sheet_count' => 2),
                   PS.clean_page('id' => 'd', 'pid' => 4, 'sheet_no' => 'A-03')]
    c = PS.sheet_codes(pr)
    assert_equal %w[A-01 A-02 A-03], c['a']
    assert_equal %w[A-04], c['b'], 'trang sau tự đẩy mã, không trùng'
    assert_equal %w[X-07 X-08], c['c'], 'mã sửa tay được giữ'
    assert_equal %w[X-09], c['d']
    all = c.values.flatten
    assert_equal all.uniq, all
    assert_equal %w[A-01 A-02 A-03 A-04], PS.sheet_codes(pr, { 'a' => 1, 'b' => 3 }).values_at('a', 'b').flatten, 'đổi số tờ -> đánh lại'
  end

  def test_luu_mo_lai_giu_so_to
    pg = PS.clean_page(JSON.parse(JSON.generate(PS.clean_page('pid' => 1, 'sheet_count' => 3, 'auto_no' => false))))
    assert_equal 3, pg['sheet_count']
    assert_equal false, pg['auto_no']
  end
end

class TestSheetPaging < Minitest::Test
  def build(scale, notes = [])
    cap = DoorFake.cabinet_with_doors
    project = AL::ProjectStore.default_project
    pg = AL::ProjectStore.clean_page(project['defaults'].merge('id' => 'p1', 'pid' => 1, 'name' => 'Group#3', 'sheet_no' => 'A-01',
                                                               'scale' => scale, 'views' => %w[front open top iso], 'sections' => nil,
                                                               'notes' => notes))
    project['pages'] = [pg]
    pb = AL::PageBuild.new(TestDoorPages::Env.new(cap), project, pg, :svg,
                           ->(p, n) { AL::ProjectStore.sheet_codes(project, { p['id'] => n })[p['id']].first })
    job = AL::Job.new('t', timer: ->(_b) {})
    pb.tasks.each { |t| job.add(t) }
    job.run_sync
    pb.outputs
  end

  def test_doi_ti_le_40_20_15_40
    counts = {}
    [40, 20, 15, 40].each_with_index do |sc, i|
      outs = build(sc)
      counts["#{i}:#{sc}"] = outs.length
      outs.each_with_index do |(svg, info), j|
        assert_equal sc, info['scale'], "tờ #{j + 1} giữ đúng 1:#{sc}"
        assert_equal format('A-%02d', j + 1), info['code'], 'mỗi tờ có mã riêng'
        assert_includes svg, ">A-#{format('%02d', j + 1)}<"
        assert_includes svg, ">Tờ #{j + 1}/#{outs.length}<" if outs.length > 1
        refute_match(/A-01 \(\d\/\d\)/, svg, 'không dùng "A-01 (1/n)" làm mã')
      end
    end
    puts "\n  [số tờ theo tỉ lệ] #{counts}"
    assert_equal 1, counts['0:40']
    assert_operator counts['2:15'], :>, counts['1:20'] - 1
    assert_operator counts['2:15'], :>, 1
    assert_equal 1, counts['3:40'], 'về lại 1:40 không thừa tờ'
  end

  def test_moi_to_noi_dung_rieng_va_chu_thich_dung_to
    notes = AL::AnnotationEngine.clean([{ 'id' => 'n0', 'type' => 'text', 'x' => 30, 'y' => 30, 'text' => 'GHI CHÚ TỜ 1', 'sheet' => 0 },
                                        { 'id' => 'n1', 'type' => 'text', 'x' => 30, 'y' => 30, 'text' => 'GHI CHÚ TỜ 2', 'sheet' => 1 }])
    outs = build(15, notes)
    assert_operator outs.length, :>=, 2
    keys = outs.map { |_, info| info['boxes'].keys }
    assert_equal keys.flatten.uniq.length, keys.flatten.length, 'không hình nào lặp lại giữa các tờ'
    assert_includes outs[0][0], 'GHI CHÚ TỜ 1'
    refute_includes outs[0][0], 'GHI CHÚ TỜ 2'
    assert_includes outs[1][0], 'GHI CHÚ TỜ 2'
  end
end
