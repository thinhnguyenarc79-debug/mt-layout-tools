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
            { 'n' => n, 'src' => d['src'].to_s[0, 20],
              'rect' => [[r[0], r[2]].min, [r[1], r[3]].min, [r[0], r[2]].max, [r[1], r[3]].max].map { |v| v.round(1) },
              'scale' => d['scale'].to_i.clamp(1, 100).nonzero? || 4 }
          end
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
          lines = src[:lines].filter_map { |a, b| (s = clip_seg(a, b, det['rect'])) && s.map(&shift) }
          raise ArgumentError, "CHI TIẾT #{det['n']}: vùng khoanh không chứa nét nào." if lines.empty? && !src[:cut]

          {
            key: key(det), name: "CHI TIẾT #{det['n']}", w: x1 - x0, h: y1 - y0, dims: true, level: src[:level],
            lines: lines, fills: [], notes: [], stats: {}, fixed_scale: det['scale'],
            detail: { src: src, rect: det['rect'] }
          }
        end
      end
    end
  end
end
