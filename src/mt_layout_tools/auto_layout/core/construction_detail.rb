# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # CHI TIẾT CẤU TẠO (Construction Detail) – mặt cắt THẬT qua hình học 3D tại vị trí người dùng chọn, không phải
      # phóng to hình 2D:
      #  1. Vùng khoanh (toạ độ hình nguồn) + đường cắt (đứng/ngang trong vùng) -> mặt phẳng cắt trong toạ độ model.
      #  2. Giới hạn chiều sâu thể hiện sau mặt cắt (cắt thêm 1 mặt phẳng xa) -> chỉ hình học trong phạm vi đó.
      #  3. SectionBuilder dựng mặt cắt (nét cắt đậm, hatch theo vật liệu, khử nét khuất) như mặt cắt A-A.
      #  4. Xén theo vùng khoanh (nét, mặt tô, tiết diện cắt – đa giác được xén để hatch kín).
      # Chỉ dùng hình học có trong model; không tự vẽ bản lề, vít, keo, lớp vật liệu không tồn tại.
      module ConstructionDetail
        module_function

        AXN = %w[x y z].freeze

        # Ma trận tuyến tính của phép chiếu fn: [[hệ số u theo x,y,z], [v...], [độ sâu...]] và phần tịnh tiến.
        def linear(fn)
          o = fn.call([0.0, 0.0, 0.0])
          cols = [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]].map { |e| p = fn.call(e); [p[0] - o[0], p[1] - o[1], p[2] - o[2]] }
          [(0..2).map { |r| cols.map { |c| c[r] } }, o]
        end

        # Trục model ứng với toạ độ u (0) / v (1) của hình chiếu vuông góc
        def axis_of(m, row)
          i = (0..2).max_by { |k| m[row][k].abs }
          m[row][i].abs > 0.5 ? i : nil
        end

        # Từ hình nguồn + chi tiết -> tham số mặt cắt & vùng xén (toạ độ model).
        # det['cut'] = { 'orient' => 'v'|'h', 'at' => toạ độ hình nguồn, 'dir' => 1|-1 }, det['depth'] mm (nil = toàn bộ)
        def plan(src, det)
          raise ArgumentError, 'Hình nguồn không phải hình chiếu vuông góc – không trích được chi tiết cấu tạo.' unless src[:fn] && src[:origin]

          m, o = linear(src[:fn])
          ia = axis_of(m, 0)
          ja = axis_of(m, 1)
          raise ArgumentError, 'Hình nguồn không phải hình chiếu vuông góc.' unless ia && ja && ia != ja

          l, t = src[:origin]
          x0, y0, x1, y1 = det['rect']
          cut = det['cut'] || {}
          orient = cut['orient'] == 'h' ? 'h' : 'v'
          at = cut['at'].is_a?(Numeric) ? cut['at'].to_f : (orient == 'v' ? (x0 + x1) / 2.0 : (y0 + y1) / 2.0)
          to_model_u = ->(u) { (u + l - o[0]) / m[0][ia] }
          to_model_v = ->(v) { (v + t - o[1]) / m[1][ja] }
          if orient == 'v'
            plane_ax = ia
            pos = to_model_u.call(at)
            reg_ax = ja
            reg = [to_model_v.call(y0), to_model_v.call(y1)].sort
          else
            plane_ax = ja
            pos = to_model_v.call(at)
            reg_ax = ia
            reg = [to_model_u.call(x0), to_model_u.call(x1)].sort
          end
          # mặc định: cắt ngang -> nhìn từ trên xuống (giữ phần dưới); cắt đứng -> nhìn theo chiều trục
          dir = if cut['dir'].nil? then orient == 'h' ? -1 : 1
                else cut['dir'].to_i.negative? ? -1 : 1
                end
          { 'axis' => AXN[plane_ax], 'pos' => pos.round(2), 'dir' => dir, 'label' => "CT#{det['n']}",
            reg_axis: reg_ax, reg: reg, depth: det['depth'].is_a?(Numeric) && det['depth'].positive? ? det['depth'].to_f : nil }
        end

        # Mặt phẳng xa giới hạn chiều sâu: giữ phần nằm giữa mặt cắt và pos + dir*depth.
        def far_plane(sec, depth)
          { 'axis' => sec['axis'], 'pos' => sec['pos'] + sec['dir'] * depth, 'dir' => -sec['dir'], 'label' => sec['label'] }
        end

        # ---- xén 2D ----
        def clip_poly(pts, r)
          x0, y0, x1, y1 = r
          [[0, x0, 1], [0, x1, -1], [1, y0, 1], [1, y1, -1]].each do |ax, c, sgn|
            return [] if pts.empty?

            out = []
            pts.each_with_index do |p, i|
              q = pts[(i + 1) % pts.length]
              ip = (p[ax] - c) * sgn >= 0
              iq = (q[ax] - c) * sgn >= 0
              out << p if ip
              next if ip == iq

              tt = (c - p[ax]) / (q[ax] - p[ax])
              out << [p[0] + (q[0] - p[0]) * tt, p[1] + (q[1] - p[1]) * tt]
            end
            pts = out
          end
          pts
        end

        # Hình mặt cắt đầy đủ v -> hình chi tiết đã xén theo vùng (toạ độ dời về góc vùng xén).
        def crop(v, pl, det)
          m, o = linear(v[:fn])
          l, t = v[:origin]
          # toạ độ hình mặt cắt của 2 mức vùng (theo trục reg)
          p0 = [0.0, 0.0, 0.0]
          p1 = [0.0, 0.0, 0.0]
          p0[pl[:reg_axis]] = pl[:reg][0]
          p1[pl[:reg_axis]] = pl[:reg][1]
          a = v[:fn].call(p0)
          b = v[:fn].call(p1)
          row = axis_of(m, 0) == pl[:reg_axis] ? 0 : 1
          lo, hi = [a[row] - (row.zero? ? l : t), b[row] - (row.zero? ? l : t)].minmax
          r = row.zero? ? [lo, 0.0, hi, v[:h]] : [0.0, lo, v[:w], hi]
          r = [[r[0], 0.0].max, [r[1], 0.0].max, [r[2], v[:w]].min, [r[3], v[:h]].min]
          raise ArgumentError, "CHI TIẾT #{det['n']}: vùng khoanh không giao với mặt cắt." if r[2] - r[0] < 0.5 || r[3] - r[1] < 0.5

          sh = ->(p) { [p[0] - r[0], p[1] - r[1]] }
          lines = v[:lines].filter_map { |p, q| (s = DetailEngine.clip_seg(p, q, r)) && s.map(&sh) }
          segs = v[:cut][:segs].filter_map { |p, q| (s = DetailEngine.clip_seg(p, q, r)) && s.map(&sh) }
          loops = []
          mats = []
          v[:cut][:loops].each_with_index do |lp, i|
            c = clip_poly(lp, r)
            next if c.length < 3

            loops << c.map(&sh)
            mats << (v[:cut][:loop_mats] || [])[i]
          end
          fills = Array(v[:fills]).filter_map do |pts, color, gray|
            c = clip_poly(pts, r)
            c.length >= 3 ? [c.map(&sh), color, gray] : nil
          end
          {
            key: "det:#{det['n']}", name: DetailEngine.label(det), w: r[2] - r[0], h: r[3] - r[1], dims: true, level: v[:level],
            lines: lines, fills: fills, notes: [], stats: { 'cut_segments' => segs.length }, fixed_scale: det['scale'],
            cut: { segs: segs, loops: loops, loop_mats: mats }, frame: true, construction: true,
            mat_labels: det['labels'] == false ? [] : mat_labels(loops, mats), section: v[:section], dim_mode: :section
          }
        end

        # Chú thích vật liệu tự động: mỗi vật liệu (có trong model) 1 nhãn, mũi tên chỉ vào tiết diện lớn nhất.
        def mat_labels(loops, mats)
          best = {}
          loops.each_with_index do |lp, i|
            name = mats[i]
            next unless name

            a = area(lp).abs
            best[name] = [a, lp] if !best[name] || a > best[name][0]
          end
          best.sort_by { |_, (_, lp)| centroid(lp)[1] }.map { |name, (_, lp)| [name, centroid(lp)] }
        end

        def area(lp)
          lp.each_with_index.sum { |p, i| q = lp[(i + 1) % lp.length]; p[0] * q[1] - q[0] * p[1] } / 2.0
        end

        def centroid(lp)
          [lp.sum { |p| p[0] } / lp.length, lp.sum { |p| p[1] } / lp.length]
        end
      end
    end
  end
end
