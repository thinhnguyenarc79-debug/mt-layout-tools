# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # MẶT CẮT THẬT: giao mặt phẳng cắt với hình học thực của model (tam giác của từng Face sau biến đổi).
      #  - Phần vật thể nằm phía hướng nhìn được giữ lại (cắt bỏ phần trước mặt phẳng), khử nét khuất như hình chiếu thường.
      #  - Giao tuyến mặt phẳng × tam giác tạo nét cắt (nét đậm); các vòng kín được tô hatch.
      # Toạ độ: mm, trục cục bộ của model (X rộng, Y sâu, Z cao), đã xoay theo hướng mặt trước.
      module SectionEngine
        module_function

        AXES = { 'x' => 0, 'y' => 1, 'z' => 2 }.freeze
        TOL = 1.0e-6

        # Hướng nhìn của mặt cắt: [tên hình chiếu dùng phép chiếu, dấu phía giữ lại]
        #  x, dir +1: nhìn về +X (từ trái sang), giữ phần x >= pos — như MẶT BÊN TRÁI
        #  x, dir -1: nhìn về -X, giữ x <= pos — như MẶT BÊN PHẢI
        #  z, dir -1: nhìn từ trên xuống, giữ z <= pos — như MẶT BẰNG
        #  z, dir +1: nhìn từ dưới lên, giữ z >= pos — như MẶT ĐÁY
        #  y, dir +1: nhìn từ trước ra sau, giữ y >= pos — như MẶT ĐỨNG
        #  y, dir -1: nhìn từ sau, giữ y <= pos — như MẶT SAU
        BASE = { ['x', 1] => 'left', ['x', -1] => 'right', ['z', -1] => 'top', ['z', 1] => 'bottom',
                 ['y', 1] => 'front', ['y', -1] => 'back' }.freeze

        def key(sec)
          "sec:#{sec['label']}"
        end

        def base_view(sec)
          BASE.fetch([sec['axis'], sec['dir'].to_i.positive? ? 1 : -1])
        end

        # Khoảng cách có dấu tới mặt phẳng, dương = phía được giữ.
        def side(p, ax, pos, dir)
          (p[ax] - pos) * dir
        end

        def lerp(a, b, t)
          [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]
        end

        # Cắt hình học theo mặt phẳng. Trả về [Capture phần giữ lại, các đoạn giao tuyến 3D].
        def clip(cap, sec, job = nil)
          ax = AXES.fetch(sec['axis'])
          pos = sec['pos'].to_f
          dir = sec['dir'].to_i.positive? ? 1 : -1
          out = Geometry::Capture.new(cap.name, [], [], cap.materials, {})
          cuts = []
          cap.edges.each_with_index do |(a, b), i|
            job&.tick if (i & 2047).zero?
            sa = side(a, ax, pos, dir)
            sb = side(b, ax, pos, dir)
            next if sa < -TOL && sb < -TOL

            if sa >= -TOL && sb >= -TOL
              out.edges << [a, b]
            else
              m = lerp(a, b, sa / (sa - sb))
              out.edges << (sa >= -TOL ? [a, m] : [m, b])
            end
          end
          cap.triangles.each_with_index do |tr, i|
            job&.tick if (i & 2047).zero?
            pts = tr[0, 3]
            s = pts.map { |p| side(p, ax, pos, dir) }
            next if s.all? { |v| v < -TOL }

            if s.all? { |v| v >= -TOL }
              out.triangles << tr
              next
            end
            # Sutherland–Hodgman với 1 mặt phẳng; ghi lại 2 điểm giao làm nét cắt.
            poly = []
            hits = []
            3.times do |k|
              p = pts[k]
              q = pts[(k + 1) % 3]
              sp = s[k]
              sq = s[(k + 1) % 3]
              poly << p if sp >= -TOL
              next unless (sp >= -TOL) != (sq >= -TOL)

              m = lerp(p, q, sp / (sp - sq))
              poly << m
              hits << m
            end
            cuts << hits if hits.length == 2
            (1...poly.length - 1).each { |k| out.triangles << [poly[0], poly[k], poly[k + 1], tr[3]] }
          end
          [out, cuts]
        end

        # Dựng hình MẶT CẮT: hình chiếu phần còn lại + nét cắt + vòng kín để hatch.
        def project(cap, sec, job = nil)
          clipped, cuts = clip(cap, sec, job)
          raise ArgumentError, "Mặt cắt #{sec['label']}-#{sec['label']}: mặt phẳng cắt nằm ngoài vật thể." if cuts.empty? && clipped.edges.empty?

          base = base_view(sec)
          fn = Geometry::VIEWS[base][1]
          title = "MẶT CẮT #{sec['label']}-#{sec['label']}"
          # Đưa các điểm giao vào tập cạnh để khung hình chứa trọn nét cắt.
          clipped.edges.concat(cuts)
          v = Geometry.project(clipped, key(sec), job, [Geometry::BUDGET_L1, Geometry::BUDGET_L2], [title, fn])
          l, t = v[:origin]
          segs = cuts.map { |a, b| [fn.call(a), fn.call(b)].map { |p| [p[0] - l, p[1] - t] } }
                     .reject { |a, b| Math.hypot(b[0] - a[0], b[1] - a[1]) < 0.01 }
          v[:cut] = { segs: segs, loops: loops(segs) }
          v[:section] = sec
          v[:stats]['cut_segments'] = segs.length
          v[:stats]['cut_loops'] = v[:cut][:loops].length
          v[:notes] << "#{title}: mặt phẳng không cắt qua vật thể nào." if segs.empty?
          v
        end

        # Nối các đoạn giao tuyến thành vòng kín (mỗi tiết diện của tấm/vật thể kín là 1 vòng).
        def loops(segs)
          key = ->(p) { [(p[0] * 100).round, (p[1] * 100).round] }
          ends = Hash.new { |h, k| h[k] = [] }
          segs.each_with_index { |(a, b), i| ends[key.call(a)] << i; ends[key.call(b)] << i }
          used = Array.new(segs.length, false)
          out = []
          segs.each_index do |i|
            next if used[i]

            used[i] = true
            start = key.call(segs[i][0])
            pts = [segs[i][0], segs[i][1]]
            loop do
              tip = key.call(pts.last)
              break if tip == start

              j = ends[tip].find { |k| !used[k] }
              break unless j

              used[j] = true
              a, b = segs[j]
              pts << (key.call(a) == tip ? b : a)
            end
            out << pts[0..-2] if key.call(pts.last) == start && pts.length >= 4
          end
          out
        end

        # Đề xuất vị trí cắt từ cấu tạo thật (vách/đợt đo được trên mặt đứng). Chỉ là đề xuất – người dùng sửa/xoá được.
        def suggest(front)
          l, t = front[:origin]
          w, h = front[:w], front[:h]
          xs = DimensionEngine.breaks(front[:lines], 0, w, [h * 0.3, 150.0].min, 0)
          ys = DimensionEngine.breaks(front[:lines], 1, h, [w * 0.3, 150.0].min, 0)
          cols = xs.each_cons(2).map { |a, b| [b - a, (a + b) / 2.0] }.sort_by { |g, _| -g }
          rows = ys.each_cons(2).map { |a, b| [b - a, (a + b) / 2.0] }.sort_by { |g, _| -g }
          out = []
          out << { 'axis' => 'x', 'pos' => (l + cols[0][1]).round(1), 'dir' => 1 } if cols[0]
          out << { 'axis' => 'z', 'pos' => -(t + rows[0][1]).round(1), 'dir' => -1 } if rows[0]
          if cols[1] && cols[1][0] > 150 && (cols[1][1] - cols[0][1]).abs > 100
            out << { 'axis' => 'x', 'pos' => (l + cols[1][1]).round(1), 'dir' => 1 }
          elsif rows[1] && rows[1][0] > 150
            out << { 'axis' => 'z', 'pos' => -(t + rows[1][1]).round(1), 'dir' => -1 }
          end
          out.each_with_index.map { |s, i| s.merge('label' => ('A'.ord + i).chr, 'auto' => true) }
        end

        # Hatch 45° cho các vòng kín (chẵn–lẻ, xử lý cả lỗ). Toạ độ giấy (mm). Trả về đoạn thẳng.
        def hatch(loops, spacing = 1.2)
          r2 = Math.sqrt(2)
          edges = loops.flat_map { |lp| lp.each_with_index.map { |p, i| [p, lp[(i + 1) % lp.length]] } }
          return [] if edges.empty?

          rot = ->(p) { [(p[0] - p[1]) / r2, (p[0] + p[1]) / r2] } # [r, q]
          re = edges.map { |a, b| [rot.call(a), rot.call(b)] }
          rmin, rmax = re.flat_map { |a, b| [a[0], b[0]] }.minmax
          out = []
          c = (rmin / spacing).ceil * spacing
          while c <= rmax
            qs = []
            re.each do |a, b|
              next if (a[0] - c) * (b[0] - c) > 0 || (a[0] - b[0]).abs < 1e-12
              next if [a[0], b[0]].max == c # quy tắc nửa mở để đỉnh không bị đếm 2 lần

              qs << a[1] + (b[1] - a[1]) * (c - a[0]) / (b[0] - a[0])
            end
            qs.sort!
            qs.each_slice(2) do |q1, q2|
              next unless q2

              out << [[(c + q1) / r2, (q1 - c) / r2], [(c + q2) / r2, (q2 - c) / r2]]
            end
            c += spacing
          end
          out
        end
      end
    end
  end
end
