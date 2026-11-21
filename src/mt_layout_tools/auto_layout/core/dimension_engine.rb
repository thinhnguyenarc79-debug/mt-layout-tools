# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # Ghi kích thước đo từ hình học THỰC SỰ HIỂN THỊ trong từng hình chiếu (không chia đều, không đặt sẵn số).
      # Mỗi hình chiếu dùng đúng bộ DIM của nó (view[:dim_mode]):
      #   :exterior – ExteriorDimension: chỉ kích thước bao ngoài (rộng, cao).
      #   :door     – Exterior + DoorDimension: bề rộng từng cánh và khe, chiều cao cánh (từ hộp bao các cánh).
      #   :interior – Exterior + InteriorDimension: vách, đợt, khoang, chiều dày ván (mặt đứng tháo cánh, tủ không cánh).
      #   :section  – Exterior + SectionDimension: như interior, đo trên nét thấy + nét cắt của mặt cắt.
      #   :none     – không ghi (trục đo).
      module DimensionEngine
        module_function

        TXT = 2.2
        COLOR = '#178A55'.freeze
        TIER1 = 5.5   # hàng DIM phân đoạn/chi tiết (mm giấy tính từ vật)
        TIER2 = 11.5  # hàng DIM tổng (ngoài cùng)
        MERGE_MIN = 5.0 # luôn gộp khe/sai số < 5 mm

        # Vị trí các cạnh cắt ngang trục đo. lines: đoạn thấy [[u,v],[u,v]] (mm thật, v hướng xuống).
        # axis 0: đo theo phương ngang (dò các đường đứng); axis 1: đo theo phương đứng (dò các đường ngang).
        # Chỉ lấy đường dài >= min_len (bỏ tay nắm, chi tiết nhỏ). Gộp các mốc gần nhau hơn gap.
        def breaks(lines, axis, total, min_len, gap)
          other = 1 - axis
          vals = [0.0, total.to_f]
          lines.each do |a, b|
            next unless (a[axis] - b[axis]).abs < 0.5
            next if (a[other] - b[other]).abs < min_len

            vals << (a[axis] + b[axis]) / 2.0
          end
          merge(vals, total, gap)
        end

        def merge(vals, total, gap, floor = MERGE_MIN)
          gap = [gap.to_f, floor].max
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

        def dim_mode(view)
          (view[:dim_mode] || (view[:dims] ? :interior : :none)).to_sym
        end

        # Mốc DIM của 1 hình theo bộ DIM của nó (có cache – PageBuild tính trước theo lô).
        def view_breaks(view, gap)
          mode = dim_mode(view)
          view[:dim_cache] ||= {}
          view[:dim_cache][[mode, gap.to_f]] ||=
            case mode
            when :door then door_breaks(view, gap)
            when :interior, :section
              if view[:part_breaks]
                # mốc lấy từ bộ phận đã phân loại (vách, đợt, nóc, đáy, ngăn kéo) – không lẫn nét trang trí/tay nắm
                xs, ys = view[:part_breaks]
                [merge([0.0, view[:w]] + xs, view[:w], gap), merge([0.0, view[:h]] + ys, view[:h], gap)]
              else
                [breaks(view[:lines], 0, view[:w], [view[:h] * 0.3, 150.0].min, gap),
                 breaks(view[:lines], 1, view[:h], [view[:w] * 0.3, 150.0].min, gap)]
              end
            else [[0.0, view[:w].to_f], [0.0, view[:h].to_f]]
            end
        end

        # DoorDimension: mép trái/phải từng cánh (=> bề rộng cánh + khe) và mép trên/dưới các cánh (=> chiều cao cánh).
        # view[:door_boxes]: [[u0, u1, v0, v1]] toạ độ hình (đã trừ gốc). Khe cánh thường 2–3 mm nên gộp tối thiểu 1 mm.
        def door_breaks(view, gap)
          boxes = Array(view[:door_boxes])
          return [[0.0, view[:w].to_f], [0.0, view[:h].to_f]] if boxes.empty?

          xs = [0.0, view[:w]] + boxes.flat_map { |b| [b[0], b[1]] }
          ys = [0.0, view[:h]] + boxes.flat_map { |b| [b[2], b[3]] } + Array(view[:handle_ys]) # tay nắm đã xác nhận
          [merge(xs, view[:w], gap, 1.0), merge(ys, view[:h], gap, 1.0)]
        end

        # Số ghi trên DIM: mm, làm tròn theo bước round_to.
        def label(len, round_to = 1)
          r = round_to.to_f <= 0 ? 1.0 : round_to.to_f
          v = (len / r).round * r
          v == v.round ? v.round.to_s : v.round(1).to_s
        end

        # Đặt DIM cho 1 hình. (ox, oy): góc trên-trái hình trên giấy.
        # opts: 'min_gap', 'round', 'dimoff' { view_key => { 'top' =>, 'left' =>, 'right' => mm giấy } } (kéo tay).
        def draw(cv, view, s, ox, oy, opts = {})
          mode = dim_mode(view)
          return {} if mode == :none

          w, h = view[:w], view[:h]
          rnd = opts.fetch('round', 1)
          off = (opts['dimoff'] || {})[view[:key].to_s] || {}
          top = off['top'].to_f
          left = off['left'].to_f
          right = off['right'].to_f
          xs, ys = view_breaks(view, opts.fetch('min_gap', 0))
          # Quá dày (nhiều khoảng hẹp) trên mặt đứng chính -> chỉ giữ kích thước tổng, chi tiết xem hình tháo cánh/mặt cắt
          moved = false
          if view[:key] == 'front' && opts['has_detail_view']
            dense = lambda do |arr|
              n = arr.each_cons(2).count { |a, b| (b - a) / s < 3.0 }
              n >= 4 && n >= 0.4 * (arr.length - 1)
            end
            if dense.call(xs) || dense.call(ys)
              xs = [0.0, w]
              ys = [0.0, h]
              moved = true
            end
          end
          placed = Array(opts['obstacles']).map(&:dup) # ký hiệu mặt cắt, chú thích... chữ DIM không được đè
          @txt_off = opts['dimtext'] || {}
          @txt_key = view[:key].to_s
          cv.group('class' => 'dimset', 'data-key' => view[:key], 'data-side' => 'top') do
            if xs.length > 2
              horizontal(cv, xs, s, ox, oy, oy - TIER1 + top, rnd, placed, 't1')
              horizontal(cv, [0, w], s, ox, oy, oy - TIER2 + top, rnd, placed, 't2')
            else
              horizontal(cv, [0, w], s, ox, oy, oy - TIER1 + top, rnd, placed, 't1')
            end
          end
          cv.group('class' => 'dimset', 'data-key' => view[:key], 'data-side' => 'left') do
            vertical(cv, [0, h], s, oy, ox, ox - (TIER2 - 2) + left, rnd, placed)
          end
          if ys.length > 2
            cv.group('class' => 'dimset', 'data-key' => view[:key], 'data-side' => 'right') do
              vertical(cv, ys, s, oy, ox + w / s, ox + w / s + TIER1 + 0.5 + right, rnd, placed)
            end
          end
          { 'x' => xs, 'y' => ys, 'mode' => mode.to_s, 'moved' => moved }
        end

        def tick(cv, x, y)
          cv.line([x - 0.8, y + 0.8], [x + 0.8, y - 0.8], 0.3, COLOR)
        end

        # Đặt chữ không đè chữ đã đặt: thử lần lượt các vị trí ứng viên. placed: [[x0, y0, x1, y1]].
        def place_text(cv, val, candidates, size, angle, placed, tid = nil)
          tw = cv.text_w(val, size)
          boxes = candidates.map do |cx, cy|
            if angle.zero?
              [cx - tw / 2 - 0.3, cy - size / 2, cx + tw / 2 + 0.3, cy + size / 2]
            else
              [cx - size / 2, cy - tw / 2 - 0.3, cx + size / 2, cy + tw / 2 + 0.3]
            end
          end
          k = boxes.index { |b| placed.none? { |p| b[0] < p[2] && p[0] < b[2] && b[1] < p[3] && p[1] < b[3] } } || 0
          dx, dy = tid && @txt_off ? Array(@txt_off["#{@txt_key}|#{tid}"]).map(&:to_f) : []
          dx ||= 0.0
          dy ||= 0.0
          box = [boxes[k][0] + dx, boxes[k][1] + dy, boxes[k][2] + dx, boxes[k][3] + dy]
          placed << box
          if tid
            cv.group('class' => 'dimtxt', 'data-id' => "#{@txt_key}|#{tid}") do
              cv.text(val, candidates[k][0] + dx, candidates[k][1] + dy, size, angle, COLOR)
            end
          else
            cv.text(val, candidates[k][0] + dx, candidates[k][1] + dy, size, angle, COLOR)
          end
          box
        end

        def horizontal(cv, xs, s, ox, y_obj, y_dim, rnd, placed = [], tier = 't1')
          xs.each { |u| cv.line([ox + u / s, y_obj - 1.0], [ox + u / s, y_dim - 1.5], 0.13, COLOR) }
          cv.line([ox + xs.first / s, y_dim], [ox + xs.last / s, y_dim], 0.13, COLOR)
          xs.each { |u| tick(cv, ox + u / s, y_dim) }
          xs.each_cons(2).with_index do |(a, b), i|
            val = label(b - a, rnd)
            small = (b - a) / s < cv.text_w(val, TXT) + 0.8
            size = small ? TXT * 0.85 : TXT
            cx = ox + (a + b) / 2 / s
            cands = if small
                      [[cx, y_dim + 2.4], [cx, y_dim - 1.5], [cx, y_dim + 4.6], [cx, y_dim - 3.8]]
                    else
                      tw = cv.text_w(val, size)
                      # dọc theo đường DIM (trong phạm vi đoạn đo) rồi mới lên/xuống
                      half = (b - a) / s / 2 - tw / 2 - 0.5
                      shifts = [1, 2, 3, 4].map { |k| k * (tw + 2) }.select { |d| d <= half }
                      [[cx, y_dim - 1.5]] + shifts.flat_map { |d| [[cx - d, y_dim - 1.5], [cx + d, y_dim - 1.5]] } +
                        [[cx, y_dim + 2.4], [cx, y_dim - 3.8]]
                    end
            place_text(cv, val, cands, size, 0, placed, "#{tier}|#{xs.length}|#{i}")
          end
        end

        def vertical(cv, ys, s, oy, x_obj, x_dim, rnd, placed = [])
          right = x_dim > x_obj
          ys.each do |v|
            y = oy + v / s
            cv.line([right ? x_obj + 1.0 : x_obj - 1.0, y], [right ? x_dim + 1.5 : x_dim - 1.5, y], 0.13, COLOR)
          end
          cv.line([x_dim, oy + ys.first / s], [x_dim, oy + ys.last / s], 0.13, COLOR)
          ys.each { |v| tick(cv, x_dim, oy + v / s) }
          out = right ? 1 : -1
          side = right ? 'r' : 'l'
          ys.each_cons(2).with_index do |(a, b), i|
            val = label(b - a, rnd)
            small = (b - a) / s < cv.text_w(val, TXT) + 0.8
            cy = oy + (a + b) / 2 / s
            tid = "#{side}|#{ys.length}|#{i}"
            if small
              place_text(cv, val, [[x_dim + out * 3.2, cy], [x_dim + out * 6.0, cy], [x_dim - out * 2.6, cy]], TXT * 0.85, 0, placed, tid)
            else
              place_text(cv, val, [[x_dim - 1.5, cy], [x_dim + 1.7, cy]], TXT, 90, placed, tid)
            end
          end
        end
      end
    end
  end
end
