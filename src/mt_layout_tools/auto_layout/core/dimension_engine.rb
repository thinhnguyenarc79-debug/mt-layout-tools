# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # Ghi kích thước đo từ hình học thực của hình chiếu (không chia đều, không đặt sẵn số).
      module DimensionEngine
        module_function

        TXT = 2.2
        COLOR = '#178A55'.freeze
        TIER1 = 5.5   # khoảng cách hàng DIM chuỗi tới vật (mm giấy)
        TIER2 = 11.5  # hàng DIM tổng
        MERGE_MIN = 5.0 # luôn gộp khe/sai số < 5 mm

        # Vị trí các cạnh cắt ngang trục đo. lines: đoạn thấy [[u,v],[u,v]] (mm thật, v hướng xuống).
        # axis 0: đo theo phương ngang (dò các đường đứng); axis 1: đo theo phương đứng (dò các đường ngang).
        # Chỉ lấy đường dài >= min_len (bỏ tay nắm, chi tiết nhỏ). Gộp các mốc gần nhau hơn gap.
        def breaks(lines, axis, total, min_len, gap)
          gap = [gap.to_f, MERGE_MIN].max
          other = 1 - axis
          vals = [0.0, total.to_f]
          lines.each do |a, b|
            next unless (a[axis] - b[axis]).abs < 0.5
            next if (a[other] - b[other]).abs < min_len

            vals << (a[axis] + b[axis]) / 2.0
          end
          vals = vals.map { |v| v.round(1) }.select { |v| v >= -0.05 && v <= total + 0.05 }.uniq.sort
          out = [vals.first]
          vals[1..-2].each { |v| out << v if v - out.last >= gap }
          if out.length > 1 && vals.last - out.last < gap
            out[-1] = vals.last
          else
            out << vals.last
          end
          out
        end

        # Mốc DIM của 1 hình (có cache theo khoảng gộp – tính trước theo lô trong PageBuild).
        def view_breaks(view, gap)
          view[:dim_cache] ||= {}
          view[:dim_cache][gap.to_f] ||= [breaks(view[:lines], 0, view[:w], [view[:h] * 0.3, 150.0].min, gap),
                                          breaks(view[:lines], 1, view[:h], [view[:w] * 0.3, 150.0].min, gap)]
        end

        # Số ghi trên DIM: mm, làm tròn theo bước round_to.
        def label(len, round_to = 1)
          r = round_to.to_f <= 0 ? 1.0 : round_to.to_f
          v = (len / r).round * r
          v == v.round ? v.round.to_s : v.round(1).to_s
        end

        # Đặt DIM cho 1 hình chiếu. view: { lines:, w:, h: }, s: mẫu số tỉ lệ, (ox, oy): góc trên-trái hình trên giấy.
        def draw(cv, view, s, ox, oy, opts = {})
          w, h = view[:w], view[:h]
          gap = opts.fetch('min_gap', 0).to_f
          rnd = opts.fetch('round', 1)
          xs, ys = view_breaks(view, gap)
          if xs.length > 2
            horizontal(cv, xs, s, ox, oy, oy - TIER1, rnd)
            horizontal(cv, [0, w], s, ox, oy, oy - TIER2, rnd)
          else
            horizontal(cv, [0, w], s, ox, oy, oy - TIER1, rnd)
          end
          vertical(cv, [0, h], s, oy, ox, ox - (TIER2 - 2), rnd)
          vertical(cv, ys, s, oy, ox + w / s, ox + w / s + TIER1 + 0.5, rnd) if ys.length > 2
          { 'x' => xs, 'y' => ys }
        end

        def tick(cv, x, y)
          cv.line([x - 0.8, y + 0.8], [x + 0.8, y - 0.8], 0.3, COLOR)
        end

        def horizontal(cv, xs, s, ox, y_obj, y_dim, rnd)
          xs.each { |u| cv.line([ox + u / s, y_obj - 1.0], [ox + u / s, y_dim - 1.5], 0.13, COLOR) }
          cv.line([ox + xs.first / s, y_dim], [ox + xs.last / s, y_dim], 0.13, COLOR)
          xs.each { |u| tick(cv, ox + u / s, y_dim) }
          xs.each_cons(2) do |a, b|
            val = label(b - a, rnd)
            small = (b - a) / s < cv.text_w(val, TXT) + 0.8
            cv.text(val, ox + (a + b) / 2 / s, small ? y_dim + 2.4 : y_dim - 1.5, small ? TXT * 0.85 : TXT, 0, COLOR)
          end
        end

        def vertical(cv, ys, s, oy, x_obj, x_dim, rnd)
          right = x_dim > x_obj
          ys.each do |v|
            y = oy + v / s
            cv.line([right ? x_obj + 1.0 : x_obj - 1.0, y], [right ? x_dim + 1.5 : x_dim - 1.5, y], 0.13, COLOR)
          end
          cv.line([x_dim, oy + ys.first / s], [x_dim, oy + ys.last / s], 0.13, COLOR)
          ys.each { |v| tick(cv, x_dim, oy + v / s) }
          ys.each_cons(2) do |a, b|
            val = label(b - a, rnd)
            small = (b - a) / s < cv.text_w(val, TXT) + 0.8
            x = small ? (right ? x_dim + 3.2 : x_dim - 3.2) : x_dim - 1.5
            cv.text(val, x, oy + (a + b) / 2 / s, small ? TXT * 0.85 : TXT, small ? 0 : 90, COLOR)
          end
        end
      end
    end
  end
end
