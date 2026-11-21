# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # Dàn 1 tờ giấy: hình chiếu + DIM + bảng vật liệu + khung tên. Đơn vị mm giấy, y hướng xuống.
      module Sheet
        module_function

        PAPERS = { 'A4' => [297.0, 210.0], 'A3' => [420.0, 297.0], 'A2' => [594.0, 420.0],
                   'A1' => [841.0, 594.0], 'A0' => [1189.0, 841.0] }.freeze
        SCALES = [5, 10, 15, 20, 25, 30, 40, 50, 75, 100].freeze
        MARGIN = 10.0
        TB_W = 60.0
        M_TOP, M_LEFT, M_RIGHT, M_BOTTOM, GAP = 15.0, 15.0, 10.0, 13.0, 10.0
        INK = '#1E1E1E'.freeze
        BLUE = '#1E6FB5'.freeze
        GREEN = '#2F4A3A'.freeze
        GOLD = '#C9A45C'.freeze
        GREY = '#6B6B6B'.freeze
        SEL = '#C9A45C'.freeze

        def paper(name)
          PAPERS.fetch(name.to_s, PAPERS['A3'])
        end

        # Khung giấy, mép trái khung tên, vùng đặt hình [x1, y1, x2, y2].
        def frames(pw, ph)
          frame = [MARGIN, MARGIN, pw - MARGIN, ph - MARGIN]
          tb_x = frame[2] - 1.2 - TB_W
          area = [frame[0] + 6, frame[1] + 6, tb_x - 6, frame[3] - 6]
          [frame, tb_x, area]
        end

        # ---------- bố cục ----------
        def box_w(v, s)
          v[:w] / s + (v[:dims] ? M_LEFT + M_RIGHT : 4)
        end

        def box_h(v, s)
          v[:h] / s + (v[:dims] ? M_TOP : 4) + M_BOTTOM
        end

        def layout_size(rows, s)
          w = rows.map { |r| r.sum { |v| box_w(v, s) } + GAP * (r.length - 1) }.max || 0
          h = rows.sum { |r| r.map { |v| box_h(v, s) }.max } + GAP * (rows.length - 1)
          [w, h]
        end

        # Thử mọi cách ngắt hàng (giữ thứ tự hình), chọn cách vừa khổ và cân đối nhất.
        def rows_for(views, s, aw, ah)
          n = views.length
          return [] if n.zero?

          best = nil
          (0...(1 << (n - 1))).each do |mask|
            rows = [[views[0]]]
            (1...n).each { |i| mask[i - 1] == 1 ? rows << [views[i]] : rows.last << views[i] }
            w, h = layout_size(rows, s)
            next if w > aw

            fits = h <= ah
            score = [fits ? 0 : 1, fits ? rows.length : h, (w / aw - h / ah).abs]
            best = [score, rows] if best.nil? || (score <=> best[0]) < 0
          end
          best ? best[1] : views.map { |v| [v] }
        end

        # Hình chiếu thẳng xếp hàng bên trái, phối cảnh trục đo thành cột riêng bên phải.
        def plan(views, s, aw, ah)
          iso = views.find { |v| !v[:dims] }
          flat = views.reject { |v| v.equal?(iso) }
          if iso && !flat.empty?
            iw, ih = box_w(iso, s), box_h(iso, s)
            rows = rows_for(flat, s, aw - iw - GAP, ah)
            w, h = layout_size(rows, s)
            { rows: rows, iso: iso, w: w + GAP + iw, h: [h, ih].max, rows_w: w }
          else
            rows = rows_for(views, s, aw, ah)
            w, h = layout_size(rows, s)
            { rows: rows, iso: nil, w: w, h: h, rows_w: w }
          end
        end

        def pick_scale(views, aw, ah)
          SCALES.each do |s|
            pl = plan(views, s, aw, ah)
            return s if pl[:w] <= aw && pl[:h] <= ah
          end
          nil
        end

        # ---------- vẽ 1 tờ ----------
        # views: mảng hình chiếu từ Geometry.project (đã gắn :key). mats: [{name,color}].
        # page: 'scale','fill','min_gap','round','offsets' {key=>[dx,dy]}, 'paper'. tb: thông tin khung tên.
        # Trả về info: scale, note, boxes {key=>[x,y,w,h]}, offsets (đã kẹp trong vùng vẽ).
        def render(cv, views, mats, page, tb, pw, ph)
          frame, tb_x, area = frames(pw, ph)
          aw = area[2] - area[0]
          legend = mats.first(14)
          legend_h = legend.empty? ? 0 : legend.length * 4.2 + 2
          ah = area[3] - area[1] - legend_h
          info = { 'note' => nil, 'boxes' => {}, 'offsets' => {} }
          if views.empty?
            info['scale'] = page['scale'].to_i.positive? ? page['scale'].to_i : 20
            info['note'] = 'Trang chưa có hình chiếu nào.'
          else
            auto = pick_scale(views, aw, ah)
            want = page['scale'].to_i
            if auto.nil?
              scale = want.positive? ? want : SCALES.last
              info['note'] = 'Đối tượng quá lớn cho khổ giấy này; hãy chọn khổ lớn hơn hoặc bớt hình.'
            elsif want <= 0
              scale = auto
            elsif want < auto
              scale = auto
              info['note'] = "Tỉ lệ 1:#{want} không vừa khổ giấy, đã tự dùng 1:#{auto}."
            else
              scale = want
            end
            info['scale'] = scale
            cv.clip(frame[0] + 1.2, frame[1] + 1.2, tb_x - frame[0] - 1.2, frame[3] - frame[1] - 2.4) do
              draw_views(cv, views, scale, area, ah, page, info)
            end
          end
          draw_legend(cv, legend, area)
          draw_frame(cv, frame, tb_x)
          draw_title_block(cv, tb, info['scale'], frame, tb_x)
          info
        end

        def draw_views(cv, views, s, area, ah, page, info)
          aw = area[2] - area[0]
          pl = plan(views, s, aw, ah)
          x0 = area[0] + [(aw - pl[:w]) / 2, 0].max
          y0 = area[1] + [(ah - pl[:h]) / 2, 0].max
          slots = []
          y = y0
          pl[:rows].each do |row|
            row_h = row.map { |v| box_h(v, s) }.max
            row_w = row.sum { |v| box_w(v, s) } + GAP * (row.length - 1)
            x = x0 + (pl[:rows_w] - row_w) / 2
            row.each do |v|
              slots << [v, x, y + row_h - M_BOTTOM]
              x += box_w(v, s) + GAP
            end
            y += row_h + GAP
          end
          if pl[:iso]
            iso = pl[:iso]
            slots << [iso, x0 + pl[:rows_w] + GAP, y0 + (pl[:h] + box_h(iso, s)) / 2 - M_BOTTOM]
          end
          offs = page['offsets'] || {}
          slots.each do |v, x, base|
            bw, bh = box_w(v, s), box_h(v, s)
            bx, by = x, base + M_BOTTOM - bh
            dx, dy = Array(offs[v[:key]]).map(&:to_f)
            dx ||= 0.0
            dy ||= 0.0
            # Kẹp trong vùng vẽ để không đè khung tên/viền giấy.
            dx = dx.clamp(area[0] - bx, [area[2] - bx - bw, area[0] - bx].max)
            dy = dy.clamp(area[1] - by, [area[3] - by - bh, area[1] - by].max)
            info['offsets'][v[:key]] = [dx.round(2), dy.round(2)]
            info['boxes'][v[:key]] = [bx + dx, by + dy, bw, bh].map { |n| n.round(2) }
            cv.group('class' => 'view', 'data-key' => v[:key]) do
              draw_view(cv, v, s, x + dx, base + dy, page)
            end
          end
        end

        def draw_view(cv, v, s, x, base, page)
          ox = x + (v[:dims] ? M_LEFT : 2)
          vw, vh = v[:w] / s, v[:h] / s
          oy = base - vh
          tf = ->(p) { [ox + p[0] / s, oy + p[1] / s] }
          v[:fills].each { |tri, color| cv.poly(tri.map(&tf), color) } if page['fill']
          v[:lines].each { |a, b| cv.line(tf.call(a), tf.call(b), 0.25, INK) }
          DimensionEngine.draw(cv, v, s, ox, oy, page) if v[:dims] && page.fetch('dims', true)
          caption(cv, v[:name], "TL 1:#{s}", ox + vw / 2, base + 6.5)
        end

        def caption(cv, name, scale, cx, cy)
          tw = cv.text_w(name, 3.6)
          cv.text(name, cx, cy, 3.6, 0, BLUE)
          cv.line([cx - tw / 2, cy + 2.4], [cx + tw / 2, cy + 2.4], 0.3, BLUE)
          cv.text(scale, cx, cy + 4.6, 2.4, 0, BLUE)
        end

        def draw_legend(cv, mats, area)
          return if mats.empty?

          x = area[2] - 62
          y = area[3] - mats.length * 4.2
          mats.each_with_index do |m, i|
            yy = y + i * 4.2
            cv.rect(x, yy, 6, 3, m['color'], '#555555')
            cv.text_left(cv.fit(format('MAT-%02d: %s', i + 1, m['name']), 2.2, 54), x + 7.5, yy + 1.5, 2.2, INK)
          end
        end

        def draw_frame(cv, frame, tb_x)
          x1, y1, x2, y2 = frame
          cv.rect(x1, y1, x2 - x1, y2 - y1, nil, INK, 0.5)
          cv.rect(x1 + 1.2, y1 + 1.2, x2 - x1 - 2.4, y2 - y1 - 2.4, nil, INK, 0.18)
          cv.line([tb_x, y1 + 1.2], [tb_x, y2 - 1.2], 0.35, INK)
        end

        # Khung tên dạng cột bên phải, chiều cao các ô co giãn theo khổ giấy.
        def draw_title_block(cv, o, scale, frame, tb_x)
          x0 = tb_x
          x1 = frame[2] - 1.2
          w = x1 - x0
          top = frame[1] + 1.2
          bottom = frame[3] - 1.2
          k = ((bottom - top) / 274.6).clamp(0.6, 2.0)
          y = top
          hl = ->(yy, wt = 0.25) { cv.line([x0, yy], [x1, yy], wt, INK) }

          rev = 25 * k
          split = x0 + w * 0.68
          cv.text(cv.fit('HIỆU CHỈNH - REVISION', 1.7, w * 0.6), (x0 + split) / 2, y + rev / 10, 1.7, 0, GREY)
          cv.text('NGÀY - DATE', (split + x1) / 2, y + rev / 10, 1.7, 0, GREY)
          cv.line([split, y], [split, y + rev], 0.18, INK)
          cv.line([x0 + 6, y + rev / 5], [x0 + 6, y + rev], 0.18, INK)
          (1..4).each do |i|
            yy = y + rev / 5 * i
            cv.line([x0, yy], [x1, yy], 0.18, INK)
            cv.text(i.to_s, x0 + 3, yy + rev / 10, 2, 0, INK)
          end
          y += rev
          hl.call(y, 0.35)

          y = field(cv, 'CHỦ ĐẦU TƯ - CLIENT', o['client'], x0, x1, y, 22 * k, 3.0)
          y = field(cv, 'CÔNG TRÌNH - PROJECT', o['project'], x0, x1, y, 22 * k, 3.0)
          y = field(cv, 'ĐỊA ĐIỂM XÂY DỰNG - LOCATION', o['location'], x0, x1, y, 15 * k, 2.3)

          h = 40 * k
          cv.text_left('ĐƠN VỊ THIẾT KẾ', x0 + 1.5, y + 2.4, 1.7, GREY)
          cv.wrap(o['company'], 3.0, w - 4).first(2).each_with_index { |ln, i| cv.text(ln, (x0 + x1) / 2, y + 7.5 + i * 3.8, 3.0, 0, INK) }
          logo(cv, (x0 + x1) / 2, y + h * 0.58) if h > 30
          cv.wrap(o['company_info'], 1.8, w - 4).first(2).each_with_index do |ln, i|
            cv.text(ln, (x0 + x1) / 2, y + h - 6.5 + i * 2.6, 1.8, 0, GREY)
          end
          y += h
          hl.call(y)

          rh = 12 * k
          [['CHỦ TRÌ THIẾT KẾ', o['lead']], ['THIẾT KẾ', o['designer']],
           ['KIỂM DUYỆT', o['checker']], ['THỂ HIỆN', o['drafter']]].each do |lab, val|
            lx = x0 + 20
            cv.line([lx, y], [lx, y + rh], 0.18, INK)
            labs = cv.wrap(lab, 1.7, 18)
            labs.each_with_index { |ln, i| cv.text(ln, x0 + 10, y + rh / 2 + (i - (labs.length - 1) / 2.0) * 2.4, 1.7, 0, GREY) }
            cv.wrap(val, 2.3, x1 - lx - 2).first(2).each_with_index { |ln, i| cv.text(ln, (lx + x1) / 2, y + rh / 2 + i * 3, 2.3, 0, INK) }
            y += rh
            hl.call(y)
          end

          y = field(cv, 'TÊN BẢN VẼ - NAME DRAWING', o['sheet_name'], x0, x1, y, 22 * k, 3.2)

          dh = 12 * k
          mid = x0 + w / 2
          cv.line([mid, y], [mid, y + dh], 0.18, INK)
          cv.text('NGÀY - DATE', (x0 + mid) / 2, y + 2.6, 1.7, 0, GREY)
          cv.text('TỈ LỆ - SCALE', (mid + x1) / 2, y + 2.6, 1.7, 0, GREY)
          cv.text(o['date'].to_s, (x0 + mid) / 2, y + dh * 0.62, 2.6, 0, INK)
          cv.text("1:#{scale}", (mid + x1) / 2, y + dh * 0.62, 2.6, 0, INK)
          y += dh
          hl.call(y)

          cv.text_left('KÝ HIỆU BẢN VẼ', x0 + 1.5, y + 2.4, 1.7, GREY)
          cv.text(o['sheet_no'].to_s, (x0 + x1) / 2, (y + bottom) / 2 + 1.5, [6, (bottom - y) * 0.35].min, 0, INK)
        end

        def field(cv, label, value, x0, x1, y, h, size)
          cv.text_left(label, x0 + 1.5, y + 2.4, 1.7, GREY)
          lines = cv.wrap(value.to_s, size, x1 - x0 - 4).first(((h - 5) / (size * 1.3)).floor.clamp(1, 4))
          start = y + 5 + (h - 5 - lines.length * size * 1.3) / 2 + size * 0.65
          lines.each_with_index { |ln, i| cv.text(ln, (x0 + x1) / 2, start + i * size * 1.3, size, 0, INK) }
          cv.line([x0, y + h], [x1, y + h], 0.25, INK)
          y + h
        end

        def logo(cv, cx, cy)
          cv.rect(cx - 9, cy - 6, 18, 12, GREEN, nil)
          cv.text('MT', cx, cy - 0.6, 6.5, 0, GOLD)
          cv.text('DESIGN', cx, cy + 4, 2.0, 0, '#FFFFFF')
        end
      end
    end
  end
end
