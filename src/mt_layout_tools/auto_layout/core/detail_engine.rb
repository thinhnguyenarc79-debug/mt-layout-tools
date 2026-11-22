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

        # Tạo hình chi tiết từ hình nguồn. Toạ độ hình chi tiết: gốc tại góc trên-trái vùng khoanh.
        def build(src, det)
          x0, y0, x1, y1 = det['rect']
          shift = ->(p) { [p[0] - x0, p[1] - y0] }
          shape = (det['marker'] || {})['shape'] || 'rect'
          clip = shape == 'rect' ? ->(a, b) { clip_seg(a, b, det['rect']) } : ->(a, b) { clip_ellipse(a, b, det['rect']) }
          lines = src[:lines].filter_map { |a, b| (s = clip.call(a, b)) && s.map(&shift) }
          raise ArgumentError, "#{label(det)}: vùng khoanh không chứa nét nào." if lines.empty? && !src[:cut]

          {
            key: key(det), name: label(det), w: x1 - x0, h: y1 - y0, dims: true, level: src[:level],
            lines: lines, fills: [], notes: [], stats: {}, fixed_scale: det['scale'],
            detail: { src: src, rect: det['rect'], shape: shape, n: det['n'], fill: det['fill'] },
            border: shape == 'rect' ? nil : ellipse_pts(x1 - x0, y1 - y0)
          }
        end
      end
    end
  end
end
