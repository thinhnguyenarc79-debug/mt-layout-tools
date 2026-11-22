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
        # opts: 'min_gap', 'round', 'dimoff' { view_key => { 'top' =>, 'left' =>, 'right' => mm giấy } } (kéo cả chuỗi),
        #       'dim_over' { id đoạn DIM => chỉnh sửa của người dùng } (v2.15 – xem DimEdit).
        # Mỗi đoạn DIM tự động là 1 đối tượng có id ổn định "<chuỗi>:<đầu>-<cuối>" (mm thật, theo mốc đo) và nằm trong
        # nhóm SVG riêng (class "dim") -> chọn/sửa/ẩn/xóa từng đoạn; chỉnh sửa lưu riêng, dựng lại vẫn áp lại.
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
          over = opts['dim_over'] || {}
          vw = w / s
          chains = []
          if xs.length > 2
            chains << ['top1', 'top', xs, oy - TIER1 + top, 't1']
            chains << ['top2', 'top', [0.0, w], oy - TIER2 + top, 't2']
          else
            chains << ['top1', 'top', [0.0, w], oy - TIER1 + top, 't1']
          end
          chains << ['left', 'left', [0.0, h], ox - (TIER2 - 2) + left, 'l']
          chains << ['right', 'right', ys, ox + vw + TIER1 + 0.5 + right, 'r'] if ys.length > 2
          segs = []
          chains.each do |chain, side, br, pos, tier|
            cv.group('class' => 'dimset', 'data-key' => view[:key], 'data-side' => side, 'data-chain' => chain) do
              segs.concat(draw_chain(cv, view, s, ox, oy, [chain, side, br, pos, tier], over, rnd, placed))
            end
          end
          # đoạn đã sửa điểm bám nhưng mốc gốc không còn (model đổi): vẫn vẽ theo điểm bám riêng, báo nếu mất liên kết
          ids = segs.map { |g| g['id'] }
          orphans = []
          over.each do |id, o|
            next if ids.include?(id) || !o.is_a?(Hash)

            if o['a'] && o['b'] && !o['deleted']
              chain = id.split(':').first
              side = CHAIN_SIDE[chain] || 'top'
              segs << custom_seg(cv, view, s, ox, oy, id, chain, side, o['a'], o['b'], o, nil, rnd)
            elsif DimEdit.modified?(o)
              orphans << id
            end
          end
          { 'x' => xs, 'y' => ys, 'mode' => mode.to_s, 'moved' => moved, 'segs' => segs, 'orphans' => orphans }
        end

        CHAIN_SIDE = { 'top1' => 'top', 'top2' => 'top', 'left' => 'left', 'right' => 'right' }.freeze
        SIDE_CHAR = { 'top' => 't', 'left' => 'l', 'right' => 'r' }.freeze

        def seg_id(chain, lo, hi)
          "#{chain}:#{lo.to_f.round(1)}-#{hi.to_f.round(1)}"
        end

        # Điểm bám mặc định của đoạn DIM tự động (mm thật, hệ hình): trên mép bao của hình.
        def anchors(view, side, lo, hi)
          if side == 'top'
            [[lo.to_f, 0.0], [hi.to_f, 0.0]]
          else
            u = side == 'right' ? view[:w].to_f : 0.0
            [[u, lo.to_f], [u, hi.to_f]]
          end
        end

        # Khoảng cách (mm giấy) từ mép hình tới đường DIM ở vị trí pos.
        def dist_of(side, pos, ox, oy, vw)
          case side
          when 'top' then oy - pos
          when 'left' then ox - pos
          else pos - (ox + vw)
          end
        end

        # 1 chuỗi DIM: đoạn chưa sửa vẽ chung đường gióng/đường DIM của chuỗi; đoạn đã sửa điểm bám hoặc đã tách
        # khỏi chuỗi vẽ riêng (DIM độc lập). Đoạn ẩn/xóa không vẽ nhưng vẫn báo về giao diện.
        def draw_chain(cv, view, s, ox, oy, ch, over, rnd, placed)
          chain, side, br, pos, tier = ch
          horiz = side == 'top'
          vw = view[:w] / s
          vh = view[:h] / s
          out = []
          plain = []
          br.each_cons(2).with_index do |(lo, hi), i|
            id = seg_id(chain, lo, hi)
            o = over[id].is_a?(Hash) ? over[id] : {}
            a, b = anchors(view, side, lo, hi)
            if o['hidden'] || o['deleted']
              out << seg_info(view, id, chain, side, o['a'] || a, o['b'] || b, o, rnd, nil, dist_of(side, pos, ox, oy, vw))
            elsif o['a'] || o.key?('off')
              out << custom_seg(cv, view, s, ox, oy, id, chain, side, o['a'] || a, o['b'] || b, o,
                                dist_of(side, pos, ox, oy, vw), rnd)
            else
              plain << [lo, hi, i, id, o, a, b]
            end
          end
          return out if plain.empty?

          # đường gióng từ mép hình gần đường DIM nhất (chuỗi kéo xuống dưới / sang phía kia vẫn đúng)
          if horiz
            edge = pos > oy + vh ? oy + vh : oy
            sg = pos > edge ? 1 : -1
            plain.flat_map { |g| [g[0], g[1]] }.uniq.each do |u|
              x = ox + u / s
              cv.line([x, edge + sg * 1.0], [x, pos + sg * 1.5], 0.13, COLOR)
              tick(cv, x, pos)
            end
          else
            edge = side == 'right' ? (pos < ox ? ox : ox + vw) : (pos > ox + vw ? ox + vw : ox)
            sg = pos > edge ? 1 : -1
            plain.flat_map { |g| [g[0], g[1]] }.uniq.each do |v|
              y = oy + v / s
              cv.line([edge + sg * 1.0, y], [pos + sg * 1.5, y], 0.13, COLOR)
              tick(cv, pos, y)
            end
          end
          plain.each do |lo, hi, i, id, o, a, b|
            geo = nil
            cv.group('class' => 'dim', 'data-key' => view[:key], 'data-id' => id, 'data-origin' => 'auto', 'data-chain' => chain) do
              la = horiz ? [ox + lo / s, pos] : [pos, oy + lo / s]
              lb = horiz ? [ox + hi / s, pos] : [pos, oy + hi / s]
              cv.line(la, lb, 0.13, COLOR)
              tid = "#{tier}|#{br.length}|#{i}"
              box, tc = horiz ? h_text(cv, lo, hi, s, ox, pos, rnd, placed, tid, o) : v_text(cv, lo, hi, s, oy, pos, side == 'right', rnd, placed, tid, o)
              pa = horiz ? [la[0], oy] : [side == 'right' ? ox + vw : ox, la[1]]
              pb = horiz ? [lb[0], oy] : [pa[0], lb[1]]
              geo = { 'pa' => pa, 'pb' => pb, 'la' => la, 'lb' => lb, 'tc' => tc, 'tbox' => box }
            end
            out << seg_info(view, id, chain, side, a, b, o, rnd, geo, dist_of(side, pos, ox, oy, vw)).merge('tid' => "#{tier}|#{br.length}|#{i}")
          end
          out
        end

        # Đoạn DIM tự động đã sửa điểm bám / tách chuỗi: vẽ như DIM độc lập (bám bộ phận, báo mất liên kết).
        def custom_seg(cv, view, s, ox, oy, id, chain, side, a, b, o, dist, rnd)
          d = { 'a' => a, 'b' => b, 'axis' => side == 'top' ? 'h' : 'v', 'side' => SIDE_CHAR[side],
                'off' => o.key?('off') ? o['off'].to_f : dist.to_f, 'ra' => o.key?('ra') ? o['ra'] : nil, 'rb' => o.key?('rb') ? o['rb'] : nil }
          d = o['a'] ? ManualDim.resolve(view, d) : d.merge('value' => ManualDim.value(d), 'status' => 'ok', 'ra' => d['ra'], 'rb' => d['rb'])
          vw = view[:w] / s
          vh = view[:h] / s
          col = d['status'] == 'broken' ? ManualDim::BROKEN : COLOR
          geo = nil
          cv.group('class' => 'dim', 'data-key' => view[:key], 'data-id' => id, 'data-origin' => 'auto', 'data-chain' => chain) do
            geo = ManualDim.draw_one(cv, d.merge(DimEdit.text_opts(o)), s, ox, oy, vw, vh, col, rnd)
          end
          seg_info(view, id, chain, side, d['a'], d['b'], o, rnd, geo, d['off'], d)
        end

        # Đối tượng DIM gửi giao diện (đủ trường theo yêu cầu, cùng khuôn với DIM thủ công).
        def seg_info(view, id, chain, side, a, b, o, rnd, geo, dist, d = nil)
          axis = side == 'top' ? 'h' : 'v'
          val = ManualDim.value('a' => a, 'b' => b, 'axis' => axis)
          {
            'id' => id, 'view' => view[:key].to_s, 'origin' => 'auto', 'chain' => chain, 'side' => side,
            'axis' => axis, 'type' => 'linear', 'a' => a.map { |n| n.to_f.round(2) }, 'b' => b.map { |n| n.to_f.round(2) },
            'value' => val.round(2), 'label' => label(val, rnd), 'text' => DimEdit.display(o['text'], label(val, rnd)),
            'text_override' => o['text'], 'tdx' => o['tdx'], 'tdy' => o['tdy'], 'size' => o['size'], 'bold' => o['bold'] == true,
            'off' => dist.to_f.round(2), 'detached' => o.key?('off'), 'custom_anchor' => !o['a'].nil?,
            'hidden' => o['hidden'] == true, 'deleted' => o['deleted'] == true, 'locked' => o['locked'] == true,
            'user_modified' => DimEdit.modified?(o), 'status' => d ? d['status'] : 'ok',
            'ra' => d ? d['ra'] : nil, 'rb' => d ? d['rb'] : nil, 'geo' => round_geo(geo)
          }
        end

        def round_geo(geo)
          return nil unless geo

          geo.transform_values { |p| p ? p.map { |n| n.to_f.round(3) } : nil }
        end

        # Chữ của 1 đoạn DIM ngang (giữ nguyên cách chọn vị trí cũ: dọc đường DIM rồi lên/xuống, né chữ khác).
        def h_text(cv, a, b, s, ox, y_dim, rnd, placed, tid, o)
          val = DimEdit.display(o['text'], label(b - a, rnd))
          sz = o['size'] ? o['size'].to_f : TXT
          small = (b - a) / s < cv.text_w(val, sz) + 0.8
          size = small && !o['size'] ? TXT * 0.85 : sz
          cx = ox + (a + b) / 2 / s
          cands = if small
                    [[cx, y_dim + 2.4], [cx, y_dim - 1.5], [cx, y_dim + 4.6], [cx, y_dim - 3.8]]
                  else
                    tw = cv.text_w(val, size)
                    half = (b - a) / s / 2 - tw / 2 - 0.5
                    shifts = [1, 2, 3, 4].map { |k| k * (tw + 2) }.select { |d| d <= half }
                    [[cx, y_dim - 1.5]] + shifts.flat_map { |d| [[cx - d, y_dim - 1.5], [cx + d, y_dim - 1.5]] } +
                      [[cx, y_dim + 2.4], [cx, y_dim - 3.8]]
                  end
          place_text(cv, val, cands, size, 0, placed, tid, o)
        end

        def v_text(cv, a, b, s, oy, x_dim, right, rnd, placed, tid, o)
          out = right ? 1 : -1
          val = DimEdit.display(o['text'], label(b - a, rnd))
          sz = o['size'] ? o['size'].to_f : TXT
          small = (b - a) / s < cv.text_w(val, sz) + 0.8
          cy = oy + (a + b) / 2 / s
          if small
            place_text(cv, val, [[x_dim + out * 3.2, cy], [x_dim + out * 6.0, cy], [x_dim - out * 2.6, cy]], o['size'] ? sz : TXT * 0.85, 0, placed, tid, o)
          else
            place_text(cv, val, [[x_dim - 1.5, cy], [x_dim + 1.7, cy]], sz, 90, placed, tid, o)
          end
        end

        def tick(cv, x, y)
          cv.line([x - 0.8, y + 0.8], [x + 0.8, y - 0.8], 0.3, COLOR)
        end

        # Đặt chữ không đè chữ đã đặt: thử lần lượt các vị trí ứng viên. placed: [[x0, y0, x1, y1]].
        # o: chỉnh sửa của người dùng ('tdx'/'tdy' dời chữ, 'bold'); không có -> dùng dời cũ (page['dimtext'], bản <= 2.14).
        # Trả về [hộp chữ, tâm chữ] (mm giấy).
        def place_text(cv, val, candidates, size, angle, placed, tid = nil, o = {})
          tw = cv.text_w(val, size)
          boxes = candidates.map do |cx, cy|
            if angle.zero?
              [cx - tw / 2 - 0.3, cy - size / 2, cx + tw / 2 + 0.3, cy + size / 2]
            else
              [cx - size / 2, cy - tw / 2 - 0.3, cx + size / 2, cy + tw / 2 + 0.3]
            end
          end
          k = boxes.index { |b| placed.none? { |p| b[0] < p[2] && p[0] < b[2] && b[1] < p[3] && p[1] < b[3] } } || 0
          if o && (o['tdx'] || o['tdy'])
            dx = o['tdx'].to_f
            dy = o['tdy'].to_f
          else
            dx, dy = tid && @txt_off ? Array(@txt_off["#{@txt_key}|#{tid}"]).map(&:to_f) : []
          end
          dx ||= 0.0
          dy ||= 0.0
          bold = o && o['bold'] == true
          box = [boxes[k][0] + dx, boxes[k][1] + dy, boxes[k][2] + dx, boxes[k][3] + dy]
          placed << box
          if tid
            cv.group('class' => 'dimtxt', 'data-id' => "#{@txt_key}|#{tid}") do
              cv.text(val, candidates[k][0] + dx, candidates[k][1] + dy, size, angle, COLOR, bold)
            end
          else
            cv.text(val, candidates[k][0] + dx, candidates[k][1] + dy, size, angle, COLOR, bold)
          end
          [box, [candidates[k][0] + dx, candidates[k][1] + dy]]
        end
      end
    end
  end
end
