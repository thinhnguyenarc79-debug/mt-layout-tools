# encoding: UTF-8
# v2.9: LƯU DỰ ÁN – BẢN NHÁP TỰ ĐỘNG – THÊM MODEL KHÔNG ĐỤNG BẢN VẼ CŨ – BỐ CỤC ĐÃ CHỐT.
require_relative 'test_helper'
require_relative 'test_view_scale'
require File.join(ROOT, 'draft_store')
require 'tmpdir'

module PS
  module_function

  def find
    ->(pid) { { 'name' => "Tủ #{pid}", 'root' => true } }
  end

  def build(project, pg)
    pb = AL::PageBuild.new(TestDoorPages::Env.new(DoorFake.cabinet_with_doors), project, pg, :svg,
                           ->(p, n) { AL::ProjectStore.sheet_codes(project, { p['id'] => n })[p['id']].first })
    job = AL::Job.new('t', timer: ->(_b) {})
    pb.tasks.each { |t| job.add(t) }
    job.run_sync
    pb.outputs
  end

  # Giống giao diện: hình chưa có toạ độ -> chốt vị trí plugin vừa đặt (trạng thái "Tự động")
  def freeze(pg, outs)
    vp = pg['view_props'] || {}
    AL::Sheet.layout_of(outs).each do |k, (x, y, sh, _w, _h, sc)|
      next if vp[k] && vp[k]['x_mm']

      vp[k] = (vp[k] || {}).merge('placement_mode' => 'auto', 'x_mm' => x, 'y_mm' => y, 'sheet' => sh)
      vp[k]['base_scale'] = sc unless vp[k]['scale_override']
    end
    pg['view_props'] = AL::ProjectStore.clean_view_props(vp)
  end

  # "Thêm model" đúng quy trình giao dịch của plugin: dựng trang mới ở bản tạm, thành công mới ghép vào cuối.
  def add_models(project, pids)
    res = AL::ProjectStore.new_pages(project, pids, find)
    tmp = Marshal.load(Marshal.dump(project))
    AL::ProjectStore.append_pages(tmp, res['pages'])
    ok = res['pages'].map do |pg|
      p2 = tmp['pages'].find { |x| x['id'] == pg['id'] }
      outs = build(tmp, p2)
      freeze(p2, outs)
      p2['sheet_count'] = outs.length
      p2
    end
    AL::ProjectStore.append_pages(project, ok)
    res
  end

  def boxes(project, pg)
    build(project, pg).each_with_index.flat_map { |(_, i), s| i['boxes'].map { |k, b| [k, s, b] } }.sort
  end
end

class TestAddModelKeepsOldSheets < Minitest::Test
  # Dự án 3 model đã chỉnh: kéo tay, khóa, tỉ lệ riêng, DIM kéo, ghi chú, mặt cắt; một số hình KHÔNG khóa.
  def setup_project
    project = AL::ProjectStore.default_project
    PS.add_models(project, [11, 12, 13])
    a, b, c = project['pages']
    a['view_props']['front'].merge!('placement_mode' => 'manual', 'x_mm' => 40.0, 'y_mm' => 35.0) # chỉnh tay, CHƯA khóa
    b['view_props']['top'].merge!('position_locked' => true)
    b['view_props']['front'].merge!('scale_override' => 15, 'scale_locked' => true)
    c['scale'] = 40
    a['notes'] = AL::AnnotationEngine.clean([{ 'id' => 'n1', 'type' => 'text', 'x' => 30, 'y' => 30, 'text' => 'GHI CHÚ A', 'sheet' => 0 },
                                            { 'id' => 'n2', 'type' => 'leader', 'x' => 60, 'y' => 40, 'tx' => 80, 'ty' => 20, 'text' => 'Leader' }])
    a['dimtext'] = { 'front|0|0|0' => [3.0, -2.0] }
    b['sections'] = [{ 'label' => 'A', 'axis' => 'x', 'pos' => 400.0, 'dir' => 1, 'auto' => false }]
    project['pages'] = project['pages'].map { |pg| AL::ProjectStore.clean_page(pg) }
    project
  end

  def test_them_10_model_trang_cu_khong_doi
    project = setup_project
    old_boxes = project['pages'].map { |pg| PS.boxes(project, pg) } # (dựng thử – như lúc người dùng xem các tờ)
    before = JSON.generate(project['pages'])
    codes = AL::ProjectStore.sheet_codes(project)
    res = PS.add_models(project, (21..30).to_a)
    assert_equal 10, res['pages'].length
    assert_equal 13, project['pages'].length
    assert_equal before, JSON.generate(project['pages'].first(3)), 'dữ liệu 3 trang cũ phải giữ nguyên tuyệt đối'
    assert_equal %w[11 12 13], project['pages'].first(3).map { |pg| pg['pid'].to_s }, 'thứ tự trang cũ'
    new_codes = AL::ProjectStore.sheet_codes(project)
    project['pages'].first(3).each { |pg| assert_equal codes[pg['id']], new_codes[pg['id']], 'mã tờ cũ không đổi' }
    project['pages'].first(3).each_with_index do |pg, i|
      assert_equal old_boxes[i], PS.boxes(project, pg), "vị trí hình trên giấy của #{pg['sheet_no']} không đổi"
    end
    assert_equal [40.0, 35.0], project['pages'][0]['view_props']['front'].values_at('x_mm', 'y_mm')
    assert_equal 'manual', project['pages'][0]['view_props']['front']['placement_mode']
  end

  def test_model_trung_khong_tao_trang
    project = setup_project
    before = JSON.generate(project)
    res = PS.add_models(project, [12, 13])
    assert_equal [12, 13], res['existing']
    assert_empty res['pages']
    assert_equal before, JSON.generate(project)
  end

  def test_model_khong_con_trong_sketchup
    project = AL::ProjectStore.default_project
    res = AL::ProjectStore.new_pages(project, [5, 6], ->(pid) { pid == 5 ? { 'name' => 'Tủ 5' } : nil })
    assert_equal [6], res['missing']
    assert_equal 1, res['pages'].length
    assert_empty project['pages'], 'new_pages không đụng dự án (vùng tạm)'
  end

  def test_huy_hoac_loi_du_an_nguyen_ven
    project = setup_project
    before = JSON.generate(project)
    res = AL::ProjectStore.new_pages(project, [40], PS.find)
    tmp = Marshal.load(Marshal.dump(project))
    AL::ProjectStore.append_pages(tmp, res['pages'])
    # (giả lập Hủy giữa chừng: bỏ bản tạm, không ghép)
    assert_equal before, JSON.generate(project)
  end

  def test_bo_cuc_da_chot_khong_tinh_lai
    project = setup_project
    pg = project['pages'][2]
    b0 = PS.boxes(project, pg)
    assert_equal b0, PS.boxes(project, pg), 'dựng lại (chuyển tờ / chuyển model / mở lại / PDF) – vị trí y hệt'
    # thêm 1 hình mới vào trang cũ: hình cũ giữ chỗ, hình mới được đặt, chồng thì báo
    pg['views'] = pg['views'] + ['right']
    outs = PS.build(project, pg)
    nb = outs.each_with_index.flat_map { |(_, i), s| i['boxes'].map { |k, b| [k, s, b] } }
    b0.each { |k, s, b| assert_includes nb, [k, s, b], "#{k} giữ nguyên chỗ" }
    assert(nb.any? { |k, _, _| k == 'right' })
  end

  def test_doi_ti_le_trang_khong_tu_dan_lai
    project = setup_project
    pg = project['pages'][2]
    pos = pg['view_props'].transform_values { |v| [v['x_mm'], v['y_mm']] }
    pg['scale'] = 20
    outs = PS.build(project, pg)
    outs.each { |_, i| i['boxes'].each { |k, b| assert_equal pos[k], b[0, 2], "#{k}: đổi tỉ lệ không tự dời" } }
  end
end

class TestProjectFiles < Minitest::Test
  def test_xuat_va_mo_ban_sao_json
    project = AL::ProjectStore.default_project
    PS.add_models(project, [11])
    doc = AL::ProjectStore.export_doc(project, 'plugin_version' => '2.9.0', 'skp_path' => 'D:/a.skp')
    assert_equal ['mt-autolayout-project', AL::ProjectStore::VERSION], doc.values_at('schema', 'schema_version')
    refute_nil doc['created_at']
    back = AL::ProjectStore.import_doc(JSON.parse(JSON.generate(doc)))
    assert_equal JSON.generate(AL::ProjectStore.clean(project)), JSON.generate(back)
    assert_raises(ArgumentError) { AL::ProjectStore.import_doc(doc.merge('schema_version' => 99)) }
  end

  def test_du_an_cu_v2_mo_duoc
    legacy = { 'version' => 2, 'name' => 'Cũ', 'paper' => 'A3',
               'pages' => [{ 'id' => 'p1', 'pid' => 7, 'name' => 'Tủ', 'sheet_no' => 'A-01', 'offsets' => { 'front' => [5, 5] },
                             'view_props' => { 'front' => { 'scale_override' => 15, 'scale_locked' => true } }, 'doors' => ['7/3'] }] }
    p = AL::ProjectStore.import_doc(legacy)
    assert_match(/\Aprj-/, p['project_id'])
    pg = p['pages'][0]
    assert_equal [5.0, 5.0], pg['offsets']['front']
    assert_equal 15, pg['view_props']['front']['scale_override']
    assert_equal 'door', pg['roles']['7/3']
  end

  # model giả: thuộc tính + thao tác
  class FakeModel
    attr_reader :ops

    def initialize(broken = false)
      @a = {}
      @ops = []
      @broken = broken
    end

    def start_operation(*) = @ops << :start
    def commit_operation = @ops << :commit
    def abort_operation = @ops << :abort
    def get_attribute(d, k) = @a[[d, k]]

    def set_attribute(d, k, v)
      @a[[d, k]] = @broken ? v[0, 10] : v
    end
  end

  def test_luu_du_an_kiem_tra_doc_lai
    m = FakeModel.new
    project = AL::ProjectStore.default_project
    PS.add_models(project, [11])
    saved = AL::ProjectStore.save(m, project)
    refute_nil saved['saved_at']
    again = AL::ProjectStore.load(m)
    assert_equal JSON.generate(saved), JSON.generate(again), 'mở lại đúng y hệt'
    assert_raises(IOError) { AL::ProjectStore.save(FakeModel.new(true), project) }
  end
end

class TestDraftStore < Minitest::Test
  def test_ghi_an_toan_va_tim_ban_nhap
    Dir.mktmpdir do |dir|
      project = AL::ProjectStore.default_project
      PS.add_models(project, [11])
      at = AL::DraftStore.write(dir, project, 'skp_path' => 'D:/tu.skp')
      assert_equal ["#{project['project_id']}.json"], Dir.children(dir), 'không còn tệp tạm'
      d = AL::DraftStore.find(dir, project['project_id'])
      assert_equal at, d['draft_at']
      assert_equal JSON.generate(project), JSON.generate(d['project'])
      assert_equal d['draft_at'], AL::DraftStore.find(dir, 'khac', 'D:/tu.skp')['draft_at'], 'tìm theo đường dẫn SKP'
      File.write(File.join(dir, 'hong.json'), '{"kind":"draft","project":')
      assert AL::DraftStore.find(dir, nil, 'D:/tu.skp'), 'tệp hỏng bị bỏ qua'
    end
  end

  def test_ban_nhap_moi_hon_ban_chinh
    Dir.mktmpdir do |dir|
      main = AL::ProjectStore.default_project
      main['saved_at'] = '2026-01-01T00:00:00.000Z'
      edited = Marshal.load(Marshal.dump(main))
      edited['name'] = 'Đã sửa'
      AL::DraftStore.write(dir, edited)
      d = AL::DraftStore.find(dir, main['project_id'])
      assert AL::DraftStore.newer?(d, main), 'bản nháp mới hơn -> hỏi khôi phục'
      main2 = main.merge('saved_at' => '2999-01-01T00:00:00.000Z')
      refute AL::DraftStore.newer?(d, main2), 'đã lưu chính sau bản nháp -> không hỏi'
      AL::DraftStore.write(dir, main)
      refute AL::DraftStore.newer?(AL::DraftStore.find(dir, main['project_id']), main), 'giống hệt bản chính -> không hỏi'
      AL::DraftStore.dismiss(dir, main['project_id'])
      assert_nil AL::DraftStore.find(dir, main['project_id'])
      assert_equal 1, Dir.children(dir).length, 'bản nháp cất làm dự phòng, không xoá mất'
    end
  end
end
