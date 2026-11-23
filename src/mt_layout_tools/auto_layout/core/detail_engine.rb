# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # CHI TIẾT PHÓNG TO: khoanh 1 vùng trên hình chiếu/mặt cắt đã dựng, vẽ lại vùng đó ở tỉ lệ lớn hơn
      # bằng chính hình học thực (nét, nét cắt, hatch, màu) – không vẽ lại tay, không đặt số giả.
      module DetailEngine
        module_function

        def clean(list)
          used = {}
          Array(list).first(50).filter_map do |d|
            next unless d.is_a?(Hash)

            n = d['n'].to_i
            next if n <= 0 || used[n]

            r = Array(d['rect']).map(&:to_f)
            next unless r.length == 4 && (r[2] - r[0]).abs > 1 && (r[3] - r[1]).abs > 1

            used[n] = true
            mk = d['marker'].is_a?(Hash) ? d['marker'] : {}
            sheet = ->(x) { x.is_a?(Numeric) ? x.to_i.clamp(0, 49) : nil }
            { 'n' => n, 'src' => d['src'].to_s[0, 20],
              'rect' => [[r[0], r[2]].min, [r[1], r[3]].min, [r[0], r[2]].max, [r[1], r[3]].max].map { |v| v.round(1) },
              'scale' => d['scale'].to_i.clamp(1, 100).nonzero? || 4,
              # tên hiển thị (đổi tên -> nhãn trên marker nguồn đổi theo)
              'label' => d['label'].to_s.strip[0, 40].then { |t| t.empty? ? nil : t },
              # kiểu vùng trích: rect | circle | ellipse (nét đứt), mũi tên, bóng số tham chiếu
              'marker' => { 'shape' => SHAPES.include?(mk['shape'].to_s) ? mk['shape'].to_s : 'rect',
                            'arrow' => mk['arrow'] == true, 'bubble' => mk['bubble'] != false },
              # tờ chứa hình nguồn lúc trích và tờ đặt chi tiết (mặc định = tờ trích)
              'src_sheet' => sheet.call(d['src_sheet']), 'sheet' => sheet.call(d['sheet']),
              'fill' => d['fill'].nil? ? nil : d['fill'] == true, # nil = theo trang, true = tô vật liệu, false = nét đơn sắc
              # 'enlarge' = phóng to vùng 2D; 'section' = chi tiết cấu tạo (mặt cắt thật qua hình học 3D)
              'type' => d['type'] == 'section' ? 'section' : 'enlarge',
              'cut' => clean_cut(d['cut']),
              'depth' => d['depth'].is_a?(Numeric) && d['depth'].to_f.positive? ? d['depth'].to_f.clamp(1, 5000).round(1) : nil,
              'labels' => d['labels'] != false }
          end
        end

        SHAPES = %w[rect circle ellipse].freeze

        # Đường cắt trong vùng khoanh: orient 'v' (đường đứng, toạ độ u) | 'h' (ngang, toạ độ v); dir: hướng nhìn.
        def clean_cut(c)
          return nil unless c.is_a?(Hash)

          { 'orient' => c['orient'] == 'h' ? 'h' : 'v', 'at' => c['at'].is_a?(Numeric) ? c['at'].to_f.round(1) : nil,
            'dir' => c['dir'].nil? ? nil : (c['dir'].to_i.negative? ? -1 : 1) }
        end

        def label(det)
          det['label'] || "CHI TIẾT #{det['n']}"
        end

        # Cắt đoạn bởi elip nội tiếp khung r (hình tròn = elip có 2 bán trục bằng nhau).
        def clip_ellipse(a, b, r)
          cx = (r[0] + r[2]) / 2.0
          cy = (r[1] + r[3]) / 2.0
          rx = [(r[2] - r[0]) / 2.0, 1e-9].max
          ry = [(r[3] - r[1]) / 2.0, 1e-9].max
          ax = (a[0] - cx) / rx
          ay = (a[1] - cy) / ry
          dx = (b[0] - a[0]) / rx
          dy = (b[1] - a[1]) / ry
          qa = dx * dx + dy * dy
          return (ax * ax + ay * ay <= 1 ? [a, b] : nil) if qa < 1e-18

          qb = 2 * (ax * dx + ay * dy)
          qc = ax * ax + ay * ay - 1
          disc = qb * qb - 4 * qa * qc
          return nil if disc <= 0

          t0 = [(-qb - Math.sqrt(disc)) / (2 * qa), 0.0].max
          t1 = [(-qb + Math.sqrt(disc)) / (2 * qa), 1.0].min
          return nil if t1 <= t0

          [[a[0] + (b[0] - a[0]) * t0, a[1] + (b[1] - a[1]) * t0], [a[0] + (b[0] - a[0]) * t1, a[1] + (b[1] - a[1]) * t1]]
        end

        # Đường biên elip (toạ độ đã dời về góc khung) – vẽ viền hình chi tiết tròn/elip
        def ellipse_pts(w, h, n = 72)
          (0..n).map { |i| t = 2 * Math::PI * i / n; [w / 2.0 + w / 2.0 * Math.cos(t), h / 2.0 + h / 2.0 * Math.sin(t)] }
        end

        def key(det)
          "det:#{det['n']}"
        end

        # ---------- v2.18.2: vùng trích tự nới theo DIM ----------
        # Người dùng kéo điểm bám DIM (thủ công hoặc DIM tự động đã đổi điểm) ra ngoài vùng khoanh -> vùng khoanh tự nới
        # tới đó (trong giới hạn hình nguồn) để hình học ở điểm bám hiện ra và DIM không bị báo mất liên kết.
        # Toạ độ hình chi tiết có gốc ở góc trên-trái vùng khoanh, nên khi nới sang trái/lên trên phải dời theo:
        # điểm bám DIM, id đoạn DIM tự động đã chỉnh, vị trí đã chốt của hình (để hình học đứng yên trên giấy).
        # Trả về { 'n', 'rect' (mới), 'old', 'shift' } hoặc nil nếu không cần nới. Sửa trực tiếp det và page.
        GROW_TOL = 0.5
        SEG_ID = /\A(top1|top2|left|right):(-?\d+(?:\.\d+)?)-(-?\d+(?:\.\d+)?)\z/.freeze

        def anchor_points(page, k)
          pts = []
          Array((page['manual_dims'] || {})[k]).each do |d|
            next if !d.is_a?(Hash) || d['hidden'] == true

            pts << d['a'] << d['b']
          end
          ((page['dim_over'] || {})[k] || {}).each_value do |o|
            next if !o.is_a?(Hash) || o['deleted'] == true || o['hidden'] == true || !o['a'] || !o['b']

            pts << o['a'] << o['b']
          end
          pts.select { |p| p.is_a?(Array) && p.length == 2 && p.all? { |n| n.is_a?(Numeric) } }
        end

        def inside?(p, w, h, shape, tol = GROW_TOL)
          return false unless p[0] >= -tol && p[0] <= w + tol && p[1] >= -tol && p[1] <= h + tol
          return true if shape == 'rect'

          rx = w / 2.0
          ry = h / 2.0
          return false if rx <= 0 || ry <= 0

          ((p[0] - rx) / (rx + tol))**2 + ((p[1] - ry) / (ry + tol))**2 <= 1.0
        end

        def grow(det, src, page)
          k = key(det)
          x0, y0, x1, y1 = det['rect']
          shape = (det['marker'] || {})['shape'] || 'rect'
          pts = anchor_points(page, k)
          out = pts.reject { |p| inside?(p, x1 - x0, y1 - y0, shape) }
          return nil if out.empty?

          sw = src[:w].to_f
          sh = src[:h].to_f
          m = [5.0, 0.04 * [x1 - x0, y1 - y0].max].max
          src_pts = out.map { |p| [p[0] + x0, p[1] + y0] }
          nx0 = [x0, src_pts.map { |p| p[0] - m }.min].min
          ny0 = [y0, src_pts.map { |p| p[1] - m }.min].min
          nx1 = [x1, src_pts.map { |p| p[0] + m }.max].max
          ny1 = [y1, src_pts.map { |p| p[1] + m }.max].max
          if shape != 'rect'
            # elip nội tiếp phải chứa mọi điểm bám: phóng khung quanh tâm theo bán kính chuẩn hoá lớn nhất
            cx = (nx0 + nx1) / 2.0
            cy = (ny0 + ny1) / 2.0
            rx = (nx1 - nx0) / 2.0
            ry = (ny1 - ny0) / 2.0
            all = pts.map { |p| [p[0] + x0, p[1] + y0] }
            f = all.map { |p| Math.sqrt(((p[0] - cx) / rx)**2 + ((p[1] - cy) / ry)**2) }.max * 1.02
            if f > 1
              rx *= f
              ry *= f
              nx0, nx1, ny0, ny1 = cx - rx, cx + rx, cy - ry, cy + ry
            end
          end
          # không vượt ra ngoài hình nguồn (ngoài đó không có hình học)
          lo_x = [0.0, x0].min
          lo_y = [0.0, y0].min
          nx0 = [nx0, lo_x].max
          ny0 = [ny0, lo_y].max
          nx1 = [nx1, [sw, x1].max].min
          ny1 = [ny1, [sh, y1].max].min
          rect = [nx0, ny0, nx1, ny1].map { |v| v.round(1) }
          return nil if rect == det['rect'].map { |v| v.to_f.round(1) }

          old = det['rect'].dup
          dx = (x0 - rect[0]).round(1)
          dy = (y0 - rect[1]).round(1)
          det['rect'] = rect
          shift_anchors(page, k, dx, dy) if dx.nonzero? || dy.nonzero?
          shift_pin(page, k, dx, dy, det) if dx.nonzero? || dy.nonzero?
          { 'n' => det['n'], 'key' => k, 'rect' => rect, 'old' => old, 'shift' => [dx, dy] }
        end

        def shift_pt(p, dx, dy)
          [(p[0] + dx).round(2), (p[1] + dy).round(2)]
        end

        def shift_anchors(page, k, dx, dy)
          Array((page['manual_dims'] || {})[k]).each do |d|
            next unless d.is_a?(Hash)

            d['a'] = shift_pt(d['a'], dx, dy) if d['a'].is_a?(Array)
            d['b'] = shift_pt(d['b'], dx, dy) if d['b'].is_a?(Array)
            # DIM đặt "trong hình": off là khoảng cách (mm thật) từ mép trên/trái hình -> đi theo gốc mới
            d['off'] = (d['off'].to_f + (d['axis'] == 'h' ? dy : dx)).round(2) if d['side'] == 'in'
          end
          over = (page['dim_over'] || {})[k]
          return unless over.is_a?(Hash)

          moved = {}
          over.each do |id, o|
            nid = id
            if (m = SEG_ID.match(id.to_s))
              d = m[1].start_with?('top') ? dx : dy
              nid = "#{m[1]}:#{(m[2].to_f + d).round(1)}-#{(m[3].to_f + d).round(1)}"
            end
            if o.is_a?(Hash)
              o['a'] = shift_pt(o['a'], dx, dy) if o['a'].is_a?(Array)
              o['b'] = shift_pt(o['b'], dx, dy) if o['b'].is_a?(Array)
            end
            moved[nid] = o
          end
          page['dim_over'][k] = moved
        end

        # Hình đã chốt chỗ: toạ độ là góc trên-trái khung -> lùi theo phần nới để nét cũ đứng yên trên giấy.
        def shift_pin(page, k, dx, dy, det)
          vp = (page['view_props'] || {})[k]
          return unless vp.is_a?(Hash) && vp['x_mm'] && vp['y_mm']

          s = (vp['scale_override'] || det['scale']).to_f
          s = 1.0 unless s.positive?
          vp['x_mm'] = (vp['x_mm'].to_f - dx / s).round(2)
          vp['y_mm'] = (vp['y_mm'].to_f - dy / s).round(2)
        end

        # Cắt đoạn thẳng theo hình chữ nhật (Liang–Barsky). Trả về đoạn đã cắt hoặc nil.
        def clip_seg(a, b, r)
          x0, y0, x1, y1 = r
          dx = b[0] - a[0]
          dy = b[1] - a[1]
          t0 = 0.0
          t1 = 1.0
          [[-dx, a[0] - x0], [dx, x1 - a[0]], [-dy, a[1] - y0], [dy, y1 - a[1]]].each do |p, q|
            if p.abs < 1e-12
              return nil if q.negative?
            else
              t = q / p
              if p.negative?
                return nil if t > t1

                t0 = t if t > t0
              else
                return nil if t < t0

                t1 = t if t < t1
              end
            end
          end
          [[a[0] + dx * t0, a[1] + dy * t0], [a[0] + dx * t1, a[1] + dy * t1]]
        end

        # Hình học nguồn QUANH vùng khoanh (toạ độ chi tiết) – chỉ để bắt điểm: kéo điểm bám DIM ra ngoài vùng
        # vẫn bắt được cạnh thật của hình nguồn; dựng lại thì vùng khoanh tự nới tới điểm đó (grow).
        def around(src, rect)
          x0, y0, x1, y1 = rect
          m = [x1 - x0, y1 - y0].max * 0.75
          win = [x0 - m, y0 - m, x1 + m, y1 + m]
          all = Array(src[:lines]) + Array(src[:cut] && src[:cut][:segs])
          all.filter_map do |a, b|
            next unless a && b

            s = clip_seg(a, b, win)
            s && s.map { |p| [p[0] - x0, p[1] - y0] }
          end
        end

        # Tạo hình chi tiết từ hình nguồn. Toạ độ hình chi tiết: gốc tại góc trên-trái vùng khoanh.
        # hộp bao đa giác giao vùng chữ nhật [x0, y0, x1, y1]
        def overlaps?(pts, rect)
          x0, y0, x1, y1 = rect
          xs = pts.map { |p| p[0] }
          ys = pts.map { |p| p[1] }
          xs.max >= x0 && xs.min <= x1 && ys.max >= y0 && ys.min <= y1
        end

        def build(src, det)
          x0, y0, x1, y1 = det['rect']
          shift = ->(p) { [p[0] - x0, p[1] - y0] }
          shape = (det['marker'] || {})['shape'] || 'rect'
          clip = shape == 'rect' ? ->(a, b) { clip_seg(a, b, det['rect']) } : ->(a, b) { clip_ellipse(a, b, det['rect']) }
          lines = src[:lines].filter_map { |a, b| (s = clip.call(a, b)) && s.map(&shift) }
          fills_in = Array(src[:fills]).count { |tri, _| overlaps?(tri, det['rect']) }
          cut_in = src[:cut] ? Array(src[:cut][:segs]).count { |a, b| clip_seg(a, b, det['rect']) } : 0
          stats = { 'src' => src[:key].to_s, 'rect' => det['rect'], 'lines_src' => Array(src[:lines]).length,
                    'lines_in' => lines.length, 'fills_src' => Array(src[:fills]).length, 'fills_in' => fills_in, 'cut_in' => cut_in }
          # vùng không có nét, mảng tô, nét cắt nào -> báo rõ (không tạo chi tiết trống)
          if lines.empty? && fills_in.zero? && cut_in.zero?
            raise ArgumentError, "#{label(det)}: vùng khoanh trên #{src[:name]} không chứa hình học nào " \
                                 "(#{stats['lines_src']} nét, #{stats['fills_src']} mảng tô của hình nguồn đều nằm ngoài vùng) – khoanh lại vùng."
          end

          {
            key: key(det), name: label(det), w: x1 - x0, h: y1 - y0, dims: true, level: src[:level],
            lines: lines, fills: [], notes: [], stats: {}, fixed_scale: det['scale'], snap_more: around(src, det['rect']),
            detail: { src: src, rect: det['rect'], shape: shape, n: det['n'], fill: det['fill'], stats: stats },
            border: shape == 'rect' ? nil : ellipse_pts(x1 - x0, y1 - y0)
          }
        end
      end
    end
  end
end
