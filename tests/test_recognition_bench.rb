# encoding: UTF-8
# Bộ kiểm thử CÓ NHÃN CHUẨN cho nhận diện cấu tạo tổng quát (CabinetRecognizer).
# Mô hình TỔNG HỢP dựng bằng code (không phải model thật của người dùng): bếp I, L, U, song song, đảo, tủ áo,
# tủ giày, ngăn kéo xen cánh, tủ xoay 30° + mirror, tủ treo. Mọi bộ phận KHÔNG tên, không Tag, không thuộc tính.
require_relative 'test_helper'

module Bench
  module_function

  # Hộp (mm) -> [điểm, tam giác] sau phép biến đổi tf
  def box(x0, y0, z0, x1, y1, z1, tf)
    c = [[x0, y0, z0], [x1, y0, z0], [x1, y1, z0], [x0, y1, z0], [x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]].map { |p| tf.call(p) }
    tris = [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]].flat_map do |q|
      [[c[q[0]], c[q[1]], c[q[2]]], [c[q[0]], c[q[2]], c[q[3]]]]
    end
    [c, tris]
  end

  def tf(ox, oy, deg, mirror = false, oz = 0)
    r = deg * Math::PI / 180
    lambda do |p|
      x = mirror ? -p[0] : p[0]
      [ox + x * Math.cos(r) - p[1] * Math.sin(r), oy + x * Math.sin(r) + p[1] * Math.cos(r), oz + p[2]]
    end
  end

  # 1 tủ, toạ độ cục bộ: rộng theo x (0..w), sâu theo y (mặt trước y=0, cánh ở y<0), cao z.
  # fronts: [[:door, n] | [:drawers, k] | [:mix]] ; opts: plinth, handles, back (độ dày), shelves, top_overlay
  def cabinet(out, t, w:, d: 560, h: 720, z0: 0, fronts: [:door, 1], handles: true, back: 8, shelves: 1, plinth: 100, top_overlay: true,
              back_overlay: false)
    th = 18
    zb = z0 + plinth
    zt = z0 + h
    add = ->(lab, *b) { out << [lab, box(*b, t)] }
    add.call('side', 0, 0, z0, th, d, zt)
    add.call('side', w - th, 0, z0, w, d, zt)
    if top_overlay
      add.call('top', 0, 0, zt, w, d, zt + th)
      ztop = zt
    else
      add.call('top', th, 0, zt - th, w - th, d, zt)
      ztop = zt - th
    end
    add.call('bottom', th, 0, zb, w - th, d, zb + th)
    if back && back_overlay
      add.call('back', 0, d, zb, w, d + back, ztop + (top_overlay ? th : 0)) # hậu bắn đè sau lưng
    elsif back
      add.call('back', th, d - back, zb + th, w - th, d, ztop)
    end
    inner = (ztop - zb - th)
    shelves = 0 if fronts[0] == :drawers # tủ ngăn kéo không có đợt
    shelves.times { |i| add.call('shelf', th, 20, zb + th + inner * (i + 1) / (shelves + 1), w - th, d - (back || 0), zb + 2 * th + inner * (i + 1) / (shelves + 1)) }
    add.call('accessory', th, 40, z0, w - th, 58, zb) if plinth.positive? # len chân (giữa 2 hông)
    fh = (top_overlay ? zt + th : zt) - zb - 4
    kind, n = fronts
    case kind
    when :door
      dw = (w - 3 * (n - 1)) / n.to_f
      n.times do |i|
        x = i * (dw + 3)
        add.call('door', x, -20, zb + 2, x + dw, -2, zb + 2 + fh)
        add.call('handle', x + dw - 60, -45, zb + fh - 200, x + dw - 40, -20, zb + fh - 40) if handles && (n == 1 || i.odd? || n == 2)
      end
    when :inset # cánh lọt lòng: nằm giữa 2 hông, mặt cánh phẳng với cạnh hông
      add.call('door', th + 2, 0, zb + th + 2, w - th - 2, 18, ztop - 2)
      add.call('handle', w - th - 60, -25, zb + 300, w - th - 40, 0, zb + 450) if handles
    when :sliding # 2 cánh lùa so le trên 2 ray
      half = w / 2.0 + 20
      add.call('door', 0, -40, zb + 2, half, -22, zb + 2 + fh)
      add.call('door', w - half, -20, zb + 2, w, -2, zb + 2 + fh)
    when :drawers
      dh = (fh - 3 * (n - 1)) / n.to_f
      n.times do |i|
        z = zb + 2 + i * (dh + 3)
        add.call('drawer', 0, -20, z, w, -2, z + dh)
        add.call('handle', w / 2 - 80, -40, z + dh / 2 - 10, w / 2 + 80, -20, z + dh / 2 + 10) if handles
        bh = [dh - 60, 80].max
        add.call('drawer', 30, -2, z + 20, 42, d - 40, z + 20 + bh)
        add.call('drawer', w - 42, -2, z + 20, w - 30, d - 40, z + 20 + bh)
        add.call('drawer', 42, d - 52, z + 26, w - 42, d - 40, z + 20 + bh)
        add.call('drawer', 42, 0, z + 20, w - 42, d - 52, z + 26)
      end
    end
  end

  # Dãy tủ dọc trục x cục bộ của tf
  def run(out, t, widths, **o)
    x = 0
    widths.each_with_index do |w, i|
      fr = o[:fronts_list] ? o[:fronts_list][i] : (w >= 700 ? [:door, 2] : [:door, 1])
      cabinet(out, ->(p) { t.call([p[0] + x, p[1], p[2]]) }, **o.reject { |k, _| k == :fronts_list }.merge(w: w, fronts: fr))
      x += w
    end
    x
  end

  SCENES = {
    'Bếp thẳng chữ I' => lambda do |o|
      run(o, tf(0, 0, 0), [600, 800, 450, 900])
      run(o, tf(0, 0, 0), [600, 800, 450, 900], h: 700, d: 350, z0: 1450, plinth: 0, shelves: 1, top_overlay: false)
    end,
    'Bếp chữ L' => lambda do |o|
      run(o, tf(0, 0, 0), [600, 800, 600])
      run(o, tf(-560, 560, 90), [600, 900], fronts_list: [[:drawers, 3], [:door, 2]]) # cánh 2 nhánh nhìn theo hướng khác
    end,
    'Bếp chữ U' => lambda do |o|
      run(o, tf(0, 0, 0), [800, 600, 800])
      run(o, tf(-560, 560, 90), [700, 600])
      run(o, tf(2200 + 560, 560 + 1300, -90), [600, 700])
    end,
    'Bếp song song' => lambda do |o|
      run(o, tf(0, 0, 0), [600, 600, 900])
      run(o, tf(2100, -1500, 180), [900, 600, 600], fronts_list: [[:door, 2], [:drawers, 4], [:door, 1]])
    end,
    'Bếp có đảo (lưng tựa lưng)' => lambda do |o|
      run(o, tf(0, 0, 0), [900, 900])
      run(o, tf(1800, 1120, 180), [900, 900], fronts_list: [[:drawers, 3], [:door, 2]])
    end,
    'Tủ áo 3 cánh (không tay nắm)' => lambda do |o|
      cabinet(o, tf(0, 0, 0), w: 1500, d: 600, h: 2400, fronts: [:door, 3], handles: false, back: 18, shelves: 3, plinth: 80)
    end,
    'Tủ giày' => lambda do |o|
      cabinet(o, tf(0, 0, 0), w: 1000, d: 350, h: 1000, fronts: [:door, 2], shelves: 3, plinth: 0)
    end,
    'Ngăn kéo xen cánh' => lambda do |o|
      run(o, tf(0, 0, 0), [500, 600, 500, 600], fronts_list: [[:drawers, 4], [:door, 1], [:drawers, 2], [:door, 1]])
    end,
    'Tủ xoay 30° + mirror' => lambda do |o|
      run(o, tf(300, 200, 30, true), [600, 800, 600], fronts_list: [[:door, 1], [:door, 2], [:drawers, 3]])
    end,
    'Tủ lavabo treo' => lambda do |o|
      cabinet(o, tf(0, 0, 15), w: 800, d: 480, h: 500, z0: 400, fronts: [:drawers, 2], plinth: 0, shelves: 0)
    end
  }.freeze

  # Trường hợp KHÓ – báo cáo để biết giới hạn (không ép đạt).
  HARD = {
    'Tủ đơn 1 cánh không tay nắm' => ->(o) { cabinet(o, tf(0, 0, 0), w: 500, fronts: [:door, 1], handles: false) },
    'Cánh lọt lòng (inset)' => ->(o) { run(o, tf(0, 0, 0), [600, 600], fronts_list: [[:inset, 1], [:inset, 1]]) },
    'Cánh lùa 2 ray' => ->(o) { cabinet(o, tf(0, 0, 0), w: 1600, d: 600, h: 2200, fronts: [:sliding, 2], handles: false, shelves: 2) },
    'Hậu bắn đè sau lưng' => ->(o) { run(o, tf(0, 0, 0), [600, 800], back: 9, back_overlay: true) },
    'Tủ cao cạnh tủ thấp' => lambda do |o|
      cabinet(o, tf(0, 0, 0), w: 600, h: 2200, fronts: [:door, 1], shelves: 4)
      run(o, tf(600, 0, 0), [800, 600])
    end
  }.freeze

  def evaluate(name)
    items = []
    SCENES.merge(HARD).fetch(name).call(items)
    parts = items.each_with_index.map { |(_l, _g), i| { 'id' => i, 'role' => nil, 'sure' => false, 'name' => '' } }
    geo = items.each_with_index.to_h { |(_l, g), i| [i, g] }
    AL::CabinetRecognizer.run(parts, geo, {})
    items.each_with_index.map { |(lab, _), i| [lab, parts[i]['role'], parts[i]['confidence']] }
  end
end

class TestRecognitionBench < Minitest::Test
  # Chỉ số trên bộ nhãn chuẩn: đúng / nhầm / chưa xác định; riêng CÁNH: độ chính xác & độ phủ.
  def test_bang_do_chinh_xac
    rows = []
    tot = Hash.new(0)
    Bench::SCENES.each_key do |name|
      res = Bench.evaluate(name)
      ok = res.count { |l, r, _| l == r }
      unk = res.count { |l, r, _| r == 'unknown' && l != 'unknown' }
      bad = res.length - ok - unk
      dl = res.count { |l, _, _| l == 'door' }
      dr = res.count { |_, r, _| r == 'door' }
      dt = res.count { |l, r, _| l == 'door' && r == 'door' }
      tot[:n] += res.length
      tot[:ok] += ok
      tot[:unk] += unk
      tot[:bad] += bad
      tot[:dl] += dl
      tot[:dr] += dr
      tot[:dt] += dt
      wrong = res.reject { |l, r, _| l == r || r == 'unknown' }.map { |l, r, _| "#{l}->#{r}" }.tally
      rows << format('  %-30s %3d bộ phận | đúng %5.1f%% | nhầm %2d | chưa xđ %2d | cánh %d/%d (đề xuất %d) %s',
                     name, res.length, 100.0 * ok / res.length, bad, unk, dt, dl, dr, wrong.empty? ? '' : wrong.inspect)
    end
    prec = tot[:dr].zero? ? 1.0 : tot[:dt].fdiv(tot[:dr])
    rec = tot[:dl].zero? ? 1.0 : tot[:dt].fdiv(tot[:dl])
    puts "\n  [BỘ NHÃN CHUẨN – mô hình tổng hợp]\n#{rows.join("\n")}"
    puts format('  TỔNG %d bộ phận: đúng %.1f%%, nhầm %.1f%%, chưa xác định %.1f%% | CÁNH: chính xác %.1f%%, phủ %.1f%%',
                tot[:n], 100.0 * tot[:ok] / tot[:n], 100.0 * tot[:bad] / tot[:n], 100.0 * tot[:unk] / tot[:n], 100 * prec, 100 * rec)
    assert_operator prec, :>=, 0.97, 'cánh đề xuất phải rất ít nhầm'
    assert_operator rec, :>=, 0.9
    assert_operator tot[:bad].fdiv(tot[:n]), :<=, 0.05
  end

  def test_bao_cao_truong_hop_kho
    rows = Bench::HARD.keys.map do |name|
      res = Bench.evaluate(name)
      ok = res.count { |l, r, _| l == r }
      unk = res.count { |l, r, _| r == 'unknown' && l != 'unknown' }
      wrong = res.reject { |l, r, _| l == r || r == 'unknown' }.map { |l, r, _| "#{l}->#{r}" }.tally
      dl = res.count { |l, _, _| l == 'door' }
      dt = res.count { |l, r, _| l == 'door' && r == 'door' }
      fp = res.count { |l, r, _| l != 'door' && r == 'door' }
      assert_equal 0, fp, "#{name}: không được đề xuất nhầm bộ phận khác thành cánh"
      format('  %-30s đúng %5.1f%% | chưa xđ %2d | cánh %d/%d %s', name, 100.0 * ok / res.length, unk, dt, dl, wrong.empty? ? '' : wrong.inspect)
    end
    puts "\n  [TRƯỜNG HỢP KHÓ – giới hạn hiện tại]\n#{rows.join("\n")}"
  end

  def test_xoay_mirror_khong_doi_ket_qua
    a = Bench.evaluate('Ngăn kéo xen cánh').map { |_, r, _| r }
    items = []
    Bench.run(items, Bench.tf(-700, 900, 137, true), [500, 600, 500, 600],
              fronts_list: [[:drawers, 4], [:door, 1], [:drawers, 2], [:door, 1]])
    parts = items.each_index.map { |i| { 'id' => i } }
    AL::CabinetRecognizer.run(parts, items.each_with_index.to_h { |(_l, g), i| [i, g] }, {})
    assert_equal a, parts.map { |p| p['role'] }
  end

  def test_gan_tay_va_thuoc_tinh_giu_nguyen
    items = []
    Bench::SCENES['Tủ giày'].call(items)
    parts = items.each_index.map { |i| { 'id' => i, 'role' => nil, 'sure' => false } }
    parts[0].merge!('role' => 'door', 'sure' => true, 'source' => 'gán tay') # người dùng gán (dù hình học nói khác)
    AL::CabinetRecognizer.run(parts, items.each_with_index.to_h { |(_l, g), i| [i, g] }, {})
    assert_equal ['door', true, 'gán tay'], parts[0].values_at('role', 'sure', 'source')
    assert(parts[1..-1].none? { |p| p['sure'] }, 'kết quả hình học luôn là đề xuất')
  end
end
