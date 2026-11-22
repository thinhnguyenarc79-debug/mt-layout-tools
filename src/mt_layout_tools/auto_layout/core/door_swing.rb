# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # KÝ HIỆU CÁNH MỞ NHÌN TỪ TRÊN (mặt bằng + mặt cắt nhìn từ trên xuống) – đồng bộ từ dữ liệu ký hiệu cánh
      # duy nhất page['door_symbols'][đường dẫn instance] (gán trên mặt đứng / bảng bên phải).
      #
      # Hình học thật, không dùng khung bao cố định:
      #  - Hộp bao định hướng (OBB) của chính cánh từ mặt/cạnh 3D -> đúng khi tủ xoay góc bất kỳ, mirror.
      #  - "Trái/phải" theo người đứng nhìn MẶT NGOÀI cánh (như trên mặt đứng): trái = bản lề phía tay trái.
      #  - Vị trí mở = quay các góc cánh quanh trục bản lề (đứng cho mở trái/phải/đôi, nằm cho lật lên/xuống)
      #    một góc đã chọn; cung = quỹ đạo mép tự do. Chiếu lên hình bằng chính phép chiếu của hình.
      #  - Chỉ hình nhìn từ trên xuống (theo hướng nhìn thật, không theo tên A-A/B-B), mặt cắt phải cắt qua cánh.
      #  - Cánh lùa / ngăn kéo / không ký hiệu: không vẽ cung quay.
      # Chỉ là ký hiệu vẽ thêm: không đổi hình học, nét cắt, hatch.
      module DoorSwing
        HINGED = %w[left right double up down].freeze
        DEFAULTS = { 'plan' => true, 'section' => true, 'angle' => 90, 'open' => 'out', 'arc' => 'dash', 'leaf' => 'solid' }.freeze
        DASH = { 'solid' => nil, 'dash' => [2.0, 1.0], 'dot' => [0.4, 0.8] }.freeze

        module_function

        def clean(raw)
          r = raw.is_a?(Hash) ? raw : {}
          a = r['angle'].to_f
          {
            'plan' => r.key?('plan') ? r['plan'] == true : true,
            'section' => r.key?('section') ? r['section'] == true : true,
            'angle' => a.between?(5, 180) ? a.round(1) : 90,
            'open' => r['open'] == 'in' ? 'in' : 'out',
            'arc' => DASH.key?(r['arc'].to_s) ? r['arc'].to_s : 'dash',
            'leaf' => DASH.key?(r['leaf'].to_s) ? r['leaf'].to_s : 'solid'
          }
        end

        def unit(v)
          l = Math.sqrt(v.sum { |x| x * x })
          l < 1e-12 ? v : v.map { |x| x / l }
        end

        def vdot(a, b)
          a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
        end

        def cross(a, b)
          [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
        end

        # Quay điểm p quanh trục (gốc o, hướng k đơn vị) góc t (rad) – công thức Rodrigues.
        def rotate(p, o, k, t)
          v = [p[0] - o[0], p[1] - o[1], p[2] - o[2]]
          c = Math.cos(t)
          s = Math.sin(t)
          kv = cross(k, v)
          kd = vdot(k, v) * (1 - c)
          (0..2).map { |i| o[i] + v[i] * c + kv[i] * s + k[i] * kd }
        end

        # OBB của từng bộ phận (đường dẫn => Info), tính 1 lần cho mỗi bản trích
        def frames(cap)
          return {} unless cap.parts && cap.tri_part

          geo = Hash.new { |h, k| h[k] = [[], []] }
          cap.triangles.each_with_index do |t, i|
            pid = cap.tri_part[i]
            next unless pid

            geo[pid][0] << t[0] << t[1] << t[2]
            geo[pid][1] << t
          end
          Array(cap.edges).each_with_index do |(a, b), i|
            pid = cap.edge_part && cap.edge_part[i]
            geo[pid][0] << a << b if pid
          end
          out = {}
          cap.parts.each_with_index do |pt, i|
            next unless geo.key?(i)

            inf = CabinetRecognizer.info(i, geo[i][0], geo[i][1])
            out[pt['path']] = inf if inf
          end
          out
        end

        # Các lá cánh (đôi = 2 lá) ở dạng [trục gốc, trục hướng, góc ký hiệu (rad, có dấu), các góc lá, điểm mép tự do].
        # Mặt NGOÀI cánh: phía không có thân tủ áp sát (bộ phận lớn nằm sau cánh trong phạm vi 60 mm, chồng lên mặt cánh).
        # Không xác định được -> phía hướng về người xem mặt đứng.
        def exterior(inf, others, front_g)
          n = inf.axes[inf.ti]
          lo = inf.lo[inf.ti]
          hi = inf.hi[inf.ti]
          score = { 1 => 0.0, -1 => 0.0 }
          inplane = [inf.wi, inf.up]
          others.each do |o|
            next if o.equal?(inf) || o.kind == :small

            q = CabinetRecognizer.proj(o.corners, n)
            ov = inplane.map do |k|
              r = CabinetRecognizer.proj(o.corners, inf.axes[k])
              [inf.hi[k], r[1]].min - [inf.lo[k], r[0]].max
            end
            next unless ov.all? { |x| x > 5 }

            a = ov[0] * ov[1]
            score[1] += a if q[0] >= hi - 3 && q[0] <= hi + 60
            score[-1] += a if q[1] <= lo + 3 && q[1] >= lo - 60
          end
          if (score[1] - score[-1]).abs > 1
            score[1] > score[-1] ? n.map(&:-@) : n
          else
            vdot(n, front_g).negative? ? n.map(&:-@) : n
          end
        end

        def leaves(inf, sym, st, e)
          type = sym['type'].to_s
          return [] unless HINGED.include?(type)

          ax = inf.axes
          n = ax[inf.ti]
          up_i = inf.up
          w_i = inf.wi
          upv = ax[up_i][2].negative? ? ax[up_i].map(&:-@) : ax[up_i]
          right = unit(cross(e.map(&:-@), [0.0, 0.0, 1.0]))
          rs = vdot(ax[w_i], right).negative? ? -1 : 1
          wlo = inf.lo[w_i]
          whi = inf.hi[w_i]
          ne = vdot(e, n).positive? ? inf.hi[inf.ti] : inf.lo[inf.ti]
          ni = vdot(e, n).positive? ? inf.lo[inf.ti] : inf.hi[inf.ti]
          ulo = inf.lo[up_i]
          uhi = inf.hi[up_i]
          umid = (ulo + uhi) / 2.0
          pt = lambda do |wv, nv, uv|
            co = []
            co[w_i] = wv
            co[inf.ti] = nv
            co[up_i] = uv
            (0..2).map { |k| ax[0][k] * co[0] + ax[1][k] * co[1] + ax[2][k] * co[2] }
          end
          ang = (sym['angle'].to_f.positive? ? sym['angle'].to_f : st['angle'].to_f) * Math::PI / 180
          outward = (sym['open'] || st['open']) == 'in' ? -1 : 1
          left_w = rs.positive? ? wlo : whi
          right_w = rs.positive? ? whi : wlo
          mk = lambda do |hinge_w, free_w, axis_o, axis_k, corners, free_pt|
            # dấu góc: mép tự do phải đi về phía mở (ra ngoài = +e)
            t = rotate(free_pt, axis_o, axis_k, 0.1)
            sgn = vdot(t.zip(free_pt).map { |a, b| a - b }, e) * outward >= 0 ? 1 : -1
            { o: axis_o, k: axis_k, t: sgn * ang, corners: corners, free: free_pt, hinge_w: hinge_w, free_w: free_w }
          end
          case type
          when 'left', 'right', 'double'
            spans = if type == 'double'
                      mid = (wlo + whi) / 2.0
                      [[left_w, mid], [right_w, mid]]
                    else
                      type == 'left' ? [[left_w, right_w]] : [[right_w, left_w]]
                    end
            spans.map do |hw, fw|
              o = pt.call(hw, ne, umid)
              corners = [pt.call(hw, ne, umid), pt.call(fw, ne, umid), pt.call(fw, ni, umid), pt.call(hw, ni, umid)]
              mk.call(hw, fw, o, upv, corners, pt.call(fw, ne, umid))
            end
          else # lật lên / lật xuống: trục nằm theo chiều rộng cánh, tại mép trên / dưới
            hu = (type == 'up') == (vdot(ax[up_i], upv).positive?) ? uhi : ulo
            fu = hu == uhi ? ulo : uhi
            o = pt.call(wlo, ne, hu)
            k = unit(ax[w_i])
            wm = (wlo + whi) / 2.0
            corners = [pt.call(wlo, ne, hu), pt.call(whi, ne, hu), pt.call(whi, ne, fu), pt.call(wlo, ne, fu)]
            [mk.call(nil, nil, o, k, corners, pt.call(wm, ne, fu))]
          end
        end

        # Hình nhìn từ trên xuống? (theo hướng nhìn thật của phép chiếu – không theo tên hình)
        def top_down?(fn)
          g = HiddenFillShim.viewer_dir(fn)
          l = Math.sqrt(g.sum { |x| x * x })
          l > 1e-9 && g[2] / l > 0.9
        end

        # Gán v[:swings] (toạ độ hình) và v[:swing_pad] [trái, trên, phải, dưới] (mm thật) cho 1 hình.
        def apply(v, fr, syms, st, front_g, _centre = nil)
          v[:swings] = nil
          v[:swing_pad] = nil
          return unless v[:fn] && v[:origin] && !v[:detail] && !v[:construction] && top_down?(v[:fn])

          sec = v[:section]
          if sec
            return unless st['section'] && sec['axis'] == 'z'
          else
            return unless st['plan'] && (v[:copy_of] || v[:key]) == 'top'
          end
          l, t = v[:origin]
          proj = ->(p) { q = v[:fn].call(p); [q[0] - l, q[1] - t] }
          out = []
          (syms || {}).each do |path, sym|
            next unless sym['visible'] != false && HINGED.include?(sym['type'].to_s)

            inf = fr[path]
            next unless inf
            # mặt cắt: chỉ cánh mà mặt phẳng cắt đi qua (theo cao độ thật của cánh)
            next if sec && !(inf.box[2][0] - 0.5..inf.box[2][1] + 0.5).cover?(sec['pos'].to_f)

            leaves(inf, sym, st, exterior(inf, fr.values, front_g)).each do |lf|
              open_poly = lf[:corners].map { |c| rotate(c, lf[:o], lf[:k], lf[:t]) }
              steps = [(lf[:t].abs / (3 * Math::PI / 180)).ceil, 2].max
              arc = (0..steps).map { |i| rotate(lf[:free], lf[:o], lf[:k], lf[:t] * i / steps) }
              out << { path: path, leaf: (open_poly + [open_poly[0]]).map(&proj), arc: arc.map(&proj),
                       style: sym['style'] || {} }
            end
          end
          return if out.empty?

          v[:swings] = out
          pts = out.flat_map { |s| s[:leaf] + s[:arc] }
          xs = pts.map(&:first)
          ys = pts.map(&:last)
          v[:swing_pad] = [[-xs.min, 0].max, [-ys.min, 0].max, [xs.max - v[:w], 0].max, [ys.max - v[:h], 0].max].map { |x| x.round(1) }
        end

        def draw(cv, v, tf, st)
          return unless v[:swings]

          v[:swings].each do |s|
            sty = DoorSymbols.clean_style(s[:style])
            cv.group('class' => 'doorswing', 'data-path' => s[:path]) do
              cv.polyline(s[:leaf].map(&tf), [sty['w'], 0.25].max, sty['color'], DASH[st['leaf']])
              cv.polyline(s[:arc].map(&tf), sty['w'], sty['color'], DASH[st['arc']])
            end
          end
        end
      end

      # hướng tới người xem của phép chiếu tuyến tính (dùng chung công thức với HiddenFill)
      module HiddenFillShim
        module_function

        def viewer_dir(fn)
          Geometry::HiddenFill.viewer_dir(fn)
        end
      end
    end
  end
end
