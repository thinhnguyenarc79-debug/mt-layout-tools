# encoding: UTF-8
# v2.8: vị trí thủ công / khóa vị trí lưu bằng toạ độ mm tuyệt đối trên giấy, không bị tính lại.
require_relative 'test_helper'
require_relative 'test_view_scale'

class TestPlacement < Minitest::Test
  def pin(x, y, sheet = 0, locked = true, extra = {})
    { 'placement_mode' => 'manual', 'x_mm' => x, 'y_mm' => y, 'sheet' => sheet, 'position_locked' => locked }.merge(extra)
  end

  def box(outs, key)
    outs.each { |_, info| return info['boxes'][key] if info['boxes'][key] }
    nil
  end

  def test_1_khoa_tai_50_70
    outs = VS.build('scale' => 40, 'view_props' => { 'front' => pin(50, 70) })
    assert_equal [50.0, 70.0], box(outs, 'front')[0, 2]
    assert_equal 0, VS.sheet_of(outs, 'front')
  end

  def test_2_nhieu_to_giu_dung_to_va_vi_tri
    # 1:15 cần nhiều tờ; mặt bằng đặt tay ở tờ 2 (sheet 1)
    outs = VS.build('scale' => 15, 'views' => %w[front top left], 'view_props' => { 'top' => pin(60, 40, 1) })
    assert_operator outs.length, :>=, 2
    assert_equal 1, VS.sheet_of(outs, 'top'), 'ở lại đúng tờ đã đặt'
    assert_equal [60.0, 40.0], box(outs, 'top')[0, 2]
    keys = outs.flat_map { |_, i| i['view_keys'] }
    assert_equal keys.uniq.sort, keys.sort, 'không lặp / mất hình'
  end

  def test_4_luu_mo_lai
    _project, pg = VS.page('view_props' => { 'front' => pin(50, 70, 0, true, 'scale_override' => 15, 'scale_locked' => true) })
    vp = AL::ProjectStore.clean_page(JSON.parse(JSON.generate(pg)))['view_props']['front']
    assert_equal({ 'scale_override' => 15, 'scale_locked' => true, 'position_locked' => true, 'placement_mode' => 'manual',
                   'x_mm' => 50.0, 'y_mm' => 70.0, 'sheet' => 0 }, vp)
  end

  def test_5_cap_nhat_va_trien_khai_lai_giu_vi_tri
    project, pg = VS.page('view_props' => { 'front' => pin(50, 70), 'top' => pin(200, 60, 0, false) })
    AL::ProjectStore.add_pages(project, [pg['pid']], ->(_p) { { 'name' => 'Tủ', 'root' => true } }, true)
    vp = project['pages'][0]['view_props']
    assert_equal [50.0, 70.0, true], [vp['front']['x_mm'], vp['front']['y_mm'], vp['front']['position_locked']]
    assert_equal 'manual', vp['top']['placement_mode'], 'đặt tay (chưa khóa) cũng không bị xoá khi dựng lại'
  end

  def test_6_doi_ti_le_trang_khong_dich
    [40, 20, 50, 0].each do |sc|
      outs = VS.build('scale' => sc, 'view_props' => { 'front' => pin(50, 70) })
      assert_equal [50.0, 70.0], box(outs, 'front')[0, 2], "trang 1:#{sc}"
    end
  end

  def test_7_pdf_dung_toa_do
    a = VS.build({ 'scale' => 40, 'view_props' => { 'front' => pin(50, 70) } }, :svg)
    b = VS.build({ 'scale' => 40, 'view_props' => { 'front' => pin(50, 70) } }, :pdf)
    assert_equal box(a, 'front'), box(b, 'front')
    assert_equal a[0][1]['frames']['front'], b[0][1]['frames']['front']
  end

  def test_8_khoa_mot_hinh_hinh_khac_van_tu_do
    outs = VS.build('scale' => 40, 'view_props' => { 'front' => pin(50, 70) }, 'offsets' => { 'top' => [10, 5] })
    plain = VS.build('scale' => 40, 'view_props' => { 'front' => pin(50, 70) })
    t1 = box(outs, 'top')
    t0 = box(plain, 'top')
    assert_in_delta t0[0] + 10, t1[0], 0.01
    assert_in_delta t0[1] + 5, t1[1], 0.01
  end

  def test_tran_giay_bao_ro_khong_pha_khoa
    outs = VS.build('scale' => 40, 'view_props' => { 'front' => pin(380, 250) })
    assert_equal [380.0, 250.0], box(outs, 'front')[0, 2]
    assert_match(/tràn ra ngoài vùng vẽ/, outs[0][1]['note'].to_s)
  end

  def test_chong_len_hinh_dat_tay_bao_xung_dot
    auto = VS.build('scale' => 40)
    t = box(auto, 'top')
    outs = VS.build('scale' => 40, 'view_props' => { 'front' => pin(t[0], t[1]) })
    assert_match(/XUNG ĐỘT VỊ TRÍ/, outs[0][1]['note'].to_s)
  end

  def test_du_an_cu_offsets_van_dung
    a = VS.build('scale' => 40)
    b = VS.build('scale' => 40, 'offsets' => { 'front' => [7, -3] })
    assert_in_delta box(a, 'front')[0] + 7, box(b, 'front')[0], 0.01
  end
end
