# encoding: UTF-8
module MTDesign
  module LayoutTools
    # Dàn 1 tờ A3 ngang: hình chiếu + kích thước tổng/chuỗi + bảng vật liệu + khung tên. Đơn vị giấy: mm, trục y hướng xuống.
    module Sheet
      module_function

      PAPER_W = 420.0
      PAPER_H = 297.0
      K = Pdf::MM_TO_PT
      SCALES = [5, 10, 15, 20, 25, 30, 40, 50, 75, 100].freeze
      FRAME = [10.0, 10.0, 410.0, 287.0].freeze
      TB_X = 350.0                         # mép trái khung tên
      AREA = [16.0, 16.0, 344.0, 281.0].freeze # vùng đặt hình chiếu
      M_TOP, M_LEFT, M_RIGHT, M_BOTTOM, GAP = 15.0, 15.0, 10.0, 13.0, 10.0
      DIM_TXT = 2.2
      INK = '#1E1E1E'.freeze
      DIM_INK = '#178A55'.freeze
      DIM_TEXT = '#178A55'.freeze
      BLUE = '#1E6FB5'.freeze
      GREEN = '#2F4A3A'.freeze
      GOLD = '#C9A45C'.freeze
      GREY = '#6B6B6B'.freeze

      # caps: { 'all' => Capture, 'open' => Capture (không có cánh) }
      def build(caps, opts)
        cap = caps['all']
        views = opts['views'].map { |k| Geometry.project(k == 'open' ? caps['open'] : cap, k) }
        raise ArgumentError, 'Chọn ít nhất 1 hình chiếu.' if views.empty?

        mats = cap.materials.values.first(14)
        legend_h = mats.empty? ? 0 : mats.length * 4.2 + 2
        scale = opts['scale'].to_i
        scale = pick_scale(views, legend_h) if scale <= 0
        @out = ['1 J 1 j']
        draw_views(views, scale, legend_h, opts)
        draw_legend(mats)
        draw_frame
        draw_title_block(opts, scale)
        Pdf.pdf_file(@out.join("\n") + "\n", [PAPER_W * K, PAPER_H * K])
      end

      # ---------- bố cục (xếp nhiều hàng) ----------
      def box_w(v, s)
        v[:w] / s + (v[:dims] ? M_LEFT + M_RIGHT : 4)
      end

      def box_h(v, s)
        v[:h] / s + (v[:dims] ? M_TOP : 4) + M_BOTTOM
      end

      def rows_for(views, s, aw)
        rows = [[]]
        views.each do |v|
          cur = rows.last
          need = cur.sum { |q| box_w(q, s) } + GAP * cur.length + box_w(v, s)
          rows << [] if !cur.empty? && need > aw
          rows.last << v
        end
        rows
      end

      def layout_size(rows, s)
        w = rows.map { |r| r.sum { |v| box_w(v, s) } + GAP * (r.length - 1) }.max
        h = rows.sum { |r| r.map { |v| box_h(v, s) }.max } + GAP * (rows.length - 1)
        [w, h]
      end

      def pick_scale(views, legend_h)
        aw = AREA[2] - AREA[0]
        ah = AREA[3] - AREA[1] - legend_h
        SCALES.each do |s|
          rows = rows_for(views, s, aw)
          w, h = layout_size(rows, s)
          return s if w <= aw && h <= ah
        end
        raise ArgumentError, 'Đối tượng quá lớn cho khổ A3 kể cả tỉ lệ 1:100. Bớt hình chiếu hoặc chọn đối tượng nhỏ hơn.'
      end

      def draw_views(views, s, legend_h, opts)
        aw = AREA[2] - AREA[0]
        rows = rows_for(views, s, aw)
        _, total_h = layout_size(rows, s)
        y = AREA[1] + [(AREA[3] - AREA[1] - legend_h - total_h) / 2, 0].max
        gap_mm = opts['min_gap'].to_f
        rows.each do |row|
          row_h = row.map { |v| box_h(v, s) }.max
          base = y + row_h - M_BOTTOM # đường đáy chung của hàng
          row_w = row.sum { |v| box_w(v, s) } + GAP * (row.length - 1)
          x = AREA[0] + (aw - row_w) / 2
          row.each do |v|
            ox = x + (v[:dims] ? M_LEFT : 2)
            vw, vh = v[:w] / s, v[:h] / s
            oy = base - vh
            tf = ->(p) { [ox + p[0] / s, oy + p[1] / s] }
            v[:fills].each { |tri, color| poly(tri.map(&tf), color) } if opts['fill']
            v[:lines].each { |a, b| line(tf.call(a), tf.call(b), 0.25, INK) }
            dims(v, s, ox, oy, gap_mm) if v[:dims]
            caption(v[:name], "TL 1:#{s}", ox + vw / 2, base + 6.5)
            x += box_w(v, s) + GAP
          end
          y += row_h + GAP
        end
      end

      # ---------- kích thước ----------
      # Vị trí các vách/kệ dọc theo trục đo (axis 0 = ngang, 1 = đứng), gộp các khoảng < gap (độ dày ván).
      def breaks(lines, axis, total, min_len, gap)
        other = 1 - axis
        vals = [0.0, total]
        lines.each do |a, b|
          next unless (a[axis] - b[axis]).abs < 0.5
          next if (a[other] - b[other]).abs < min_len

          vals << (a[axis] + b[axis]) / 2
        end
        vals = vals.map { |n| n.round(1) }.uniq.sort
        out = [vals.first]
        vals[1..-2].each { |n| out << n if n - out.last >= gap }
        if out.length > 1 && vals.last - out.last < gap
          out[-1] = vals.last
        else
          out << vals.last
        end
        out
      end

      def dims(v, s, ox, oy, gap)
        w, h = v[:w], v[:h]
        gap = [gap, 5.0].max # luôn gộp khe/sai số < 5 mm
        xs = breaks(v[:lines], 0, w, [h * 0.3, 150.0].min, gap)
        ys = breaks(v[:lines], 1, h, [w * 0.3, 150.0].min, gap)
        top = oy
        if xs.length > 2
          hdim_chain(xs, s, ox, top, top - 5.5)
          hdim_chain([0, w], s, ox, top, top - 11.5)
        else
          hdim_chain([0, w], s, ox, top, top - 5.5)
        end
        vdim_chain([0, h], s, oy, ox, ox - 9.5)
        vdim_chain(ys, s, oy, ox + w / s, ox + w / s + 6) if ys.length > 2
      end

      def hdim_chain(xs, s, ox, y_obj, y_dim)
        xs.each do |u|
          x = ox + u / s
          line([x, y_obj - 1.0], [x, y_dim - 1.5], 0.13, DIM_INK)
        end
        line([ox + xs.first / s, y_dim], [ox + xs.last / s, y_dim], 0.13, DIM_INK)
        xs.each { |u| tick(ox + u / s, y_dim) }
        xs.each_cons(2) do |a, b|
          val = (b - a).round.to_s
          tw = text_w(val, DIM_TXT)
          small = (b - a) / s < tw + 0.8
          # khoảng nhỏ (vd. ván 18): ghi số phía dưới đường kích thước để không đè số bên cạnh
          text(val, ox + (a + b) / 2 / s, small ? y_dim + 2.4 : y_dim - 1.5, small ? DIM_TXT * 0.85 : DIM_TXT, 0, DIM_TEXT)
        end
      end

      def vdim_chain(ys, s, oy, x_obj, x_dim)
        right = x_dim > x_obj
        ys.each do |v|
          y = oy + v / s
          line([right ? x_obj + 1.0 : x_obj - 1.0, y], [right ? x_dim + 1.5 : x_dim - 1.5, y], 0.13, DIM_INK)
        end
        line([x_dim, oy + ys.first / s], [x_dim, oy + ys.last / s], 0.13, DIM_INK)
        ys.each { |v| tick(x_dim, oy + v / s) }
        ys.each_cons(2) do |a, b|
          val = (b - a).round.to_s
          tw = text_w(val, DIM_TXT)
          small = (b - a) / s < tw + 0.8
          outside = right ? x_dim + 3.2 : x_dim - 3.2
          text(val, small ? outside : x_dim - 1.5, oy + (a + b) / 2 / s, small ? DIM_TXT * 0.85 : DIM_TXT, small ? 0 : 90, DIM_TEXT)
        end
      end

      def tick(x, y)
        line([x - 0.8, y + 0.8], [x + 0.8, y - 0.8], 0.3, DIM_INK)
      end

      def caption(name, scale, cx, cy)
        tw = text_w(name, 3.6)
        text(name, cx, cy, 3.6, 0, BLUE)
        line([cx - tw / 2, cy + 2.4], [cx + tw / 2, cy + 2.4], 0.3, BLUE)
        text(scale, cx, cy + 4.6, 2.4, 0, BLUE)
      end

      # ---------- bảng vật liệu ----------
      def draw_legend(mats)
        return if mats.empty?

        x = AREA[2] - 62
        y = AREA[3] - mats.length * 4.2
        mats.each_with_index do |m, i|
          yy = y + i * 4.2
          rect(x, yy, 6, 3, m['color'], '#555555')
          label = format('MAT-%02d: %s', i + 1, m['name'])
          text_left(fit(label, 2.2, 54), x + 7.5, yy + 1.5, 2.2, INK)
        end
      end

      # ---------- khung ----------
      def draw_frame
        x1, y1, x2, y2 = FRAME
        rect(x1, y1, x2 - x1, y2 - y1, nil, INK, 0.5)
        rect(x1 + 1.2, y1 + 1.2, x2 - x1 - 2.4, y2 - y1 - 2.4, nil, INK, 0.18)
        line([TB_X, y1 + 1.2], [TB_X, y2 - 1.2], 0.35, INK)
      end

      def draw_title_block(o, scale)
        x0 = TB_X
        x1 = FRAME[2] - 1.2
        w = x1 - x0
        y = FRAME[1] + 1.2
        hl = ->(yy, wt = 0.25) { line([x0, yy], [x1, yy], wt, INK) }

        # Hiệu chỉnh
        split = x0 + w * 0.68
        text(fit('HIỆU CHỈNH - REVISION', 1.7, w * 0.6), (x0 + split) / 2, y + 2.4, 1.7, 0, GREY)
        text('NGÀY - DATE', (split + x1) / 2, y + 2.4, 1.7, 0, GREY)
        line([split, y], [split, y + 25], 0.18, INK)
        line([x0 + 6, y + 5], [x0 + 6, y + 25], 0.18, INK)
        (1..4).each do |i|
          line([x0, y + 5 * i], [x1, y + 5 * i], 0.18, INK)
          text(i.to_s, x0 + 3, y + 5 * i + 2.5, 2, 0, INK)
        end
        y += 25
        hl.call(y, 0.35)

        y = field(o, 'CHỦ ĐẦU TƯ - CLIENT', o['client'], x0, x1, y, 22, 3.0)
        y = field(o, 'CÔNG TRÌNH - PROJECT', o['project'], x0, x1, y, 22, 3.0)
        y = field(o, 'ĐỊA ĐIỂM XÂY DỰNG - LOCATION', o['location'], x0, x1, y, 15, 2.3)

        # Đơn vị thiết kế + logo
        h = 40
        text_left('ĐƠN VỊ THIẾT KẾ', x0 + 1.5, y + 2.4, 1.7, GREY)
        wrap(o['company'], 3.0, w - 4).each_with_index { |ln, i| text(ln, (x0 + x1) / 2, y + 7.5 + i * 3.8, 3.0, 0, INK) }
        logo((x0 + x1) / 2, y + 23)
        wrap(o['company_info'], 1.8, w - 4).first(2).each_with_index do |ln, i|
          text(ln, (x0 + x1) / 2, y + 33 + i * 2.6, 1.8, 0, GREY)
        end
        y += h
        hl.call(y)

        [['CHỦ TRÌ THIẾT KẾ', o['lead']], ['THIẾT KẾ', o['designer']],
         ['KIỂM DUYỆT', o['checker']], ['THỂ HIỆN', o['drafter']]].each do |lab, val|
          lx = x0 + 20
          line([lx, y], [lx, y + 12], 0.18, INK)
          wrap(lab, 1.7, 18).each_with_index { |ln, i| text(ln, x0 + 10, y + 5 + i * 2.4, 1.7, 0, GREY) }
          wrap(val, 2.3, x1 - lx - 2).first(2).each_with_index { |ln, i| text(ln, (lx + x1) / 2, y + 5 + i * 3, 2.3, 0, INK) }
          y += 12
          hl.call(y)
        end

        y = field(o, 'TÊN BẢN VẼ - NAME DRAWING', o['sheet_name'], x0, x1, y, 22, 3.2)

        mid = x0 + w / 2
        line([mid, y], [mid, y + 12], 0.18, INK)
        text('NGÀY - DATE', (x0 + mid) / 2, y + 2.6, 1.7, 0, GREY)
        text('TỈ LỆ - SCALE', (mid + x1) / 2, y + 2.6, 1.7, 0, GREY)
        text(o['date'].to_s, (x0 + mid) / 2, y + 7.5, 2.6, 0, INK)
        text("1:#{scale}", (mid + x1) / 2, y + 7.5, 2.6, 0, INK)
        y += 12
        hl.call(y)

        bottom = FRAME[3] - 1.2
        text_left('KÝ HIỆU BẢN VẼ', x0 + 1.5, y + 2.4, 1.7, GREY)
        text(o['sheet_no'].to_s, (x0 + x1) / 2, (y + bottom) / 2 + 1.5, 6, 0, INK)
      end

      def field(_o, label, value, x0, x1, y, h, size)
        text_left(label, x0 + 1.5, y + 2.4, 1.7, GREY)
        lines = wrap(value.to_s, size, x1 - x0 - 4).first(((h - 5) / (size * 1.3)).floor.clamp(1, 4))
        start = y + 5 + (h - 5 - lines.length * size * 1.3) / 2 + size * 0.65
        lines.each_with_index { |ln, i| text(ln, (x0 + x1) / 2, start + i * size * 1.3, size, 0, INK) }
        line([x0, y + h], [x1, y + h], 0.25, INK)
        y + h
      end

      def logo(cx, cy)
        rect(cx - 9, cy - 6, 18, 12, GREEN, nil)
        text('MT', cx, cy - 0.6, 6.5, 0, GOLD)
        text('DESIGN', cx, cy + 4, 2.0, 0, '#FFFFFF')
      end

      # ---------- vẽ cơ bản ----------
      def pt(p)
        [p[0] * K, (PAPER_H - p[1]) * K]
      end

      def xy(p)
        Pdf.xy(pt(p))
      end

      def rgb(c)
        Pdf.rgb(c).map { |n| Pdf.number(n) }.join(' ')
      end

      def line(a, b, w, color)
        @out << "#{Pdf.number(w * K)} w #{rgb(color)} RG #{xy(a)} m #{xy(b)} l S"
      end

      def poly(points, color)
        path = "#{xy(points[0])} m " + points[1..-1].map { |p| "#{xy(p)} l" }.join(' ') + ' h'
        @out << "#{rgb(color)} rg #{rgb(color)} RG #{Pdf.number(0.08 * K)} w #{path} B"
      end

      def rect(x, y, w, h, fill, stroke, wt = 0.2)
        r = "#{Pdf.xy(pt([x, y + h]))} #{Pdf.number(w * K)} #{Pdf.number(h * K)} re"
        if fill && stroke
          @out << "#{rgb(fill)} rg #{rgb(stroke)} RG #{Pdf.number(wt * K)} w #{r} B"
        elsif fill
          @out << "#{rgb(fill)} rg #{r} f"
        else
          @out << "#{rgb(stroke)} RG #{Pdf.number(wt * K)} w #{r} S"
        end
      end

      def text_w(s, size)
        Pdf.font_run(s.to_s)[1] * size
      end

      # size: chiều cao chữ (mm). angle: độ, ngược chiều kim đồng hồ.
      def text(s, cx, cy, size, angle, color)
        return if s.to_s.empty?

        @out << Pdf.text_command(s.to_s, pt([cx, cy]), size * K, angle, color)
      end

      def text_left(s, x, cy, size, color)
        text(s, x + text_w(s, size) / 2, cy, size, 0, color)
      end

      def fit(s, size, max_w)
        s = s.to_s
        s = s[0..-3].rstrip + '…' while text_w(s, size) > max_w && s.length > 3
        s
      end

      def wrap(s, size, max_w)
        words = s.to_s.split(/\s+/)
        lines = []
        cur = ''
        words.each do |wd|
          trial = cur.empty? ? wd : "#{cur} #{wd}"
          if text_w(trial, size) <= max_w || cur.empty?
            cur = trial
          else
            lines << cur
            cur = wd
          end
        end
        lines << cur unless cur.empty?
        lines.map { |ln| fit(ln, size, max_w) }
      end
    end
  end
end
