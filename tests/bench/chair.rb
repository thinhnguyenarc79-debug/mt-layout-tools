# encoding: UTF-8
# Ghế gỗ nhiều chi tiết cong (giả lập độ phức tạp model SketchUp thật) cho đo hiệu năng ngoài SketchUp.
# hard: :smooth – mặt cong đã làm mịn (cạnh mềm bị bỏ, chỉ còn cạnh cứng: mép vòng, đường bao)
#       :all    – mọi cạnh tam giác là cạnh cứng (model nhập từ 3ds/OBJ, chưa làm mịn) – trường hợp nặng nhất
module Chair
  module_function

  # quét tiết diện (vòng n điểm, bán kính rx, ry) dọc đường cong path (mảng điểm) -> lưới tứ giác
  def sweep(cap, path, n, rx, ry, hard, mat)
    rings = path.each_with_index.map do |c, i|
      nx = path[[i + 1, path.length - 1].min]
      pv = path[[i - 1, 0].max]
      t = [nx[0] - pv[0], nx[1] - pv[1], nx[2] - pv[2]]
      l = Math.sqrt(t.sum { |q| q * q }); t = t.map { |q| q / l }
      up = t[2].abs > 0.9 ? [1.0, 0, 0] : [0, 0, 1.0]
      u = [t[1] * up[2] - t[2] * up[1], t[2] * up[0] - t[0] * up[2], t[0] * up[1] - t[1] * up[0]]
      ul = Math.sqrt(u.sum { |q| q * q }); u = u.map { |q| q / ul }
      w = [t[1] * u[2] - t[2] * u[1], t[2] * u[0] - t[0] * u[2], t[0] * u[1] - t[1] * u[0]]
      (0...n).map do |k|
        a = 2 * Math::PI * k / n
        ca = rx * Math.cos(a); sa = ry * Math.sin(a)
        [c[0] + u[0] * ca + w[0] * sa, c[1] + u[1] * ca + w[1] * sa, c[2] + u[2] * ca + w[2] * sa]
      end
    end
    rings.each_cons(2) do |r0, r1|
      n.times do |k|
        j = (k + 1) % n
        cap.triangles << [r0[k], r0[j], r1[j], mat]
        cap.triangles << [r0[k], r1[j], r1[k], mat]
        if hard == :all
          cap.edges << [r0[k], r0[j]]; cap.edges << [r0[k], r1[k]]; cap.edges << [r0[k], r1[j]]
        elsif k % (n / 4) == 0
          cap.edges << [r0[k], r1[k]] # 4 cạnh cứng dọc thân (mép vát)
        end
      end
    end
    [rings.first, rings.last].each do |r|
      n.times { |k| cap.edges << [r[k], r[(k + 1) % n]] }
      (1...n - 1).each { |k| cap.triangles << [r[0], r[k], r[k + 1], mat] }
    end
  end

  # mặt cong dạng lưới (mặt ngồi lõm, tựa lưng uốn)
  def surface(cap, nu, nv, hard, mat)
    pts = (0..nv).map { |j| (0..nu).map { |i| yield(i.to_f / nu, j.to_f / nv) } }
    nv.times do |j|
      nu.times do |i|
        a, b, c, d = pts[j][i], pts[j][i + 1], pts[j + 1][i + 1], pts[j + 1][i]
        cap.triangles << [a, b, c, mat]; cap.triangles << [a, c, d, mat]
        if hard == :all
          cap.edges << [a, b]; cap.edges << [a, d]; cap.edges << [a, c]
        end
      end
    end
    (0...nu).each { |i| cap.edges << [pts[0][i], pts[0][i + 1]]; cap.edges << [pts[nv][i], pts[nv][i + 1]] }
    (0...nv).each { |j| cap.edges << [pts[j][0], pts[j + 1][0]]; cap.edges << [pts[j][nu], pts[j + 1][nu]] }
  end

  def arc(p0, p1, bulge, steps)
    (0..steps).map do |i|
      t = i.to_f / steps
      s = Math.sin(Math::PI * t); b = bulge.map { |q| q * s }
      [p0[0] + (p1[0] - p0[0]) * t + b[0], p0[1] + (p1[1] - p0[1]) * t + b[1], p0[2] + (p1[2] - p0[2]) * t + b[2]]
    end
  end

  # mức chi tiết: seg = số đoạn mỗi cung (SketchUp mặc định 12–24; ghế đẹp thường 48–96)
  MATS = { 'Gỗ sồi' => '#A97C50', 'Mây đan' => '#5A3E28', 'Gỗ óc chó' => '#4E3524', 'Đệm' => '#8C8C7A' }.freeze

  def build(cap, hard: :smooth, seg: 48, multi: false)
    MATS.each { |k, c| cap.materials[k] = { 'name' => k, 'color' => c } }
    m = 'Gỗ sồi'
    mm = ->(k) { multi ? k : m }
    # 4 chân cong, thuôn
    [[40, 40, -60], [460, 40, 60], [40, 440, -60], [460, 440, 60]].each do |x, y, bx|
      sweep(cap, arc([x, y, 0], [x, y, 440], [bx * 0.5, 0, 0], seg), seg / 2, 18, 18, hard, m)
    end
    # mặt ngồi lõm 500 x 480, dày 30 (2 mặt)
    [440, 470].each do |z0|
      surface(cap, seg, seg, hard, mm.call('Mây đan')) { |u, v| [u * 500, v * 480, z0 - 25 * Math.sin(Math::PI * u) * Math.sin(Math::PI * v)] }
    end
    # 5 nan tựa lưng uốn cong
    5.times do |k|
      x = 60 + k * 95
      sweep(cap, arc([x, 470, 470], [x, 520, 900], [0, 60, 0], seg), 16, 22, 8, hard, mm.call('Gỗ óc chó'))
    end
    # khung tựa trên cong
    sweep(cap, arc([20, 520, 900], [480, 520, 900], [0, 40, 30], seg * 2), seg / 2, 30, 20, hard, m)
    # 2 tay vịn cong
    [0, 500].each { |x| sweep(cap, arc([x, 40, 650], [x, 500, 700], [0, 0, 60], seg * 2), seg / 2, 22, 16, hard, mm.call('Đệm')) }
    # giằng chân
    [[40, 460], [440, 440]].each { |y0, _| sweep(cap, arc([40, y0, 150], [460, y0, 150], [0, 0, -20], seg), 16, 10, 10, hard, m) }
    cap
  end
end
