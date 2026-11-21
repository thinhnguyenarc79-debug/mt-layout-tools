# encoding: UTF-8
# v2.7: quản lý cấu tạo theo từng model – lưu riêng, không ghi đè gán tay khi triển khai lại, chịu tải nhiều model.
require_relative 'test_helper'

class TestPartsManagement < Minitest::Test
  def finder = ->(pid) { { 'name' => "Tủ #{pid}", 'root' => true } }

  def test_luu_rieng_tung_model_theo_duong_dan_instance
    project = AL::ProjectStore.default_project
    AL::ProjectStore.add_pages(project, [11, 22], finder)
    a, b = project['pages']
    a['roles'] = { '11/5' => 'door', '11/6' => 'shelf' }
    b['roles'] = { '22/5' => 'side' } # cùng definition, khác instance/model -> phân loại riêng
    again = AL::ProjectStore.clean(JSON.parse(JSON.generate(project)))
    assert_equal({ '11/5' => 'door', '11/6' => 'shelf' }, again['pages'][0]['roles'])
    assert_equal({ '22/5' => 'side' }, again['pages'][1]['roles'])
  end

  def test_trien_khai_lai_khong_ghi_de_gan_tay
    project = AL::ProjectStore.default_project
    AL::ProjectStore.add_pages(project, [11], finder)
    project['pages'][0]['roles'] = { '11/5' => 'door', '11/7/8' => 'handle' }
    res = AL::ProjectStore.add_pages(project, [11], finder, true)
    assert_equal 1, res['replaced'].length
    assert_equal({ '11/5' => 'door', '11/7/8' => 'handle' }, project['pages'][0]['roles'])
  end

  def test_nhieu_model_nhieu_bo_phan
    project = AL::ProjectStore.default_project
    pids = (1..120).to_a
    AL::ProjectStore.add_pages(project, pids, finder)
    project['pages'].each_with_index do |pg, k|
      pg['roles'] = (0...400).to_h { |i| ["#{pids[k]}/#{i}", %w[door side shelf back][i % 4]] }
    end
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    again = AL::ProjectStore.clean(JSON.parse(JSON.generate(project)))
    dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    puts "\n  [120 model × 400 bộ phận] lưu/mở lại #{dt.round(2)} s"
    assert_equal 120, again['pages'].length
    assert_equal 400, again['pages'][57]['roles'].length
    assert_operator dt, :<, 5
  end
end
