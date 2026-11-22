# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # Bề mặt vẽ 2D dùng chung cho PDF (in) và SVG (xem/biên tập). Đơn vị: mm trên giấy, trục y hướng xuống.
      class Canvas
        K = Pdf::MM_TO_PT
        attr_reader :fmt

        def initialize(fmt, paper_w, paper_h)
          @fmt = fmt
          @pw = paper_w
          @ph = paper_h
          @out = fmt == :pdf ? ['1 J 1 j'] : []
        end

        # ---- tiện ích ----
        def n(v)
          Pdf.number(v.round(3))
        end

        def pt(p)
          [p[0] * K, (@ph - p[1]) * K]
        end

        def xy(p)
          Pdf.xy(pt(p))
        end

        def rgb(c)
          Pdf.rgb(c).map { |v| Pdf.number(v) }.join(' ')
        end

        def esc(t)
          t.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
        end

        def text_w(s, size)
          Pdf.font_run(s.to_s)[1] * size
        end

        # ---- nét ----
        # dash: nil (liền) hoặc mảng mm, vd [2, 1] nét đứt, [6, 1, 1, 1] gạch chấm.
        def line(a, b, w, color, dash = nil)
          if @fmt == :svg
            da = dash ? %( stroke-dasharray="#{dash.map { |d| n(d) }.join(' ')}") : ''
            @out << %(<path d="M#{n(a[0])} #{n(a[1])}L#{n(b[0])} #{n(b[1])}" stroke="#{color}" stroke-width="#{n(w)}"#{da}/>)
          else
            d = dash ? "[#{dash.map { |v| Pdf.number(v * K) }.join(' ')}] 0 d " : ''
            @out << "#{Pdf.number(w * K)} w #{d}#{rgb(color)} RG #{xy(a)} m #{xy(b)} l S#{dash ? ' [] 0 d' : ''}"
          end
        end

        # Đường gấp khúc mở (nhiều đoạn nối nhau) – gọn hơn nhiều so với từng đoạn riêng.
        def polyline(points, w, color, dash = nil)
          return if points.length < 2

          if @fmt == :svg
            da = dash ? %( stroke-dasharray="#{dash.map { |d| n(d) }.join(' ')}") : ''
            @out << %(<path d="M#{points.map { |p| "#{n(p[0])} #{n(p[1])}" }.join('L')}" fill="none" stroke="#{color}" stroke-width="#{n(w)}"#{da}/>)
          else
            d = dash ? "[#{dash.map { |v| Pdf.number(v * K) }.join(' ')}] 0 d " : ''
            @out << "#{Pdf.number(w * K)} w #{d}#{rgb(color)} RG #{xy(points[0])} m " +
                    points[1..-1].map { |p| "#{xy(p)} l" }.join(' ') + ' S' + (dash ? ' [] 0 d' : '')
          end
        end

        def poly(points, color)
          if @fmt == :svg
            @out << %(<path d="M#{points.map { |p| "#{n(p[0])} #{n(p[1])}" }.join('L')}Z" fill="#{color}" stroke="#{color}" stroke-width="0.08"/>)
          else
            path = "#{xy(points[0])} m " + points[1..-1].map { |p| "#{xy(p)} l" }.join(' ') + ' h'
            @out << "#{rgb(color)} rg #{rgb(color)} RG #{Pdf.number(0.08 * K)} w #{path} B"
          end
        end

        def circle(c, r, fill, stroke, wt = 0.2)
          if @fmt == :svg
            @out << %(<circle cx="#{n(c[0])}" cy="#{n(c[1])}" r="#{n(r)}" fill="#{fill || 'none'}") +
                    (stroke ? %( stroke="#{stroke}" stroke-width="#{n(wt)}") : '') + '/>'
            return
          end
          k = 0.5523 * r
          x, y = c
          path = "#{xy([x + r, y])} m #{xy([x + r, y + k])} #{xy([x + k, y + r])} #{xy([x, y + r])} c " \
                 "#{xy([x - k, y + r])} #{xy([x - r, y + k])} #{xy([x - r, y])} c " \
                 "#{xy([x - r, y - k])} #{xy([x - k, y - r])} #{xy([x, y - r])} c " \
                 "#{xy([x + k, y - r])} #{xy([x + r, y - k])} #{xy([x + r, y])} c h"
          op = fill && stroke ? 'B' : (fill ? 'f' : 'S')
          @out << "#{fill ? "#{rgb(fill)} rg " : ''}#{stroke ? "#{rgb(stroke)} RG #{Pdf.number(wt * K)} w " : ''}#{path} #{op}"
        end

        def rect(x, y, w, h, fill, stroke, wt = 0.2)
          if @fmt == :svg
            @out << %(<rect x="#{n(x)}" y="#{n(y)}" width="#{n(w)}" height="#{n(h)}" fill="#{fill || 'none'}") +
                    (stroke ? %( stroke="#{stroke}" stroke-width="#{n(wt)}") : '') + '/>'
            return
          end
          r = "#{xy([x, y + h])} #{Pdf.number(w * K)} #{Pdf.number(h * K)} re"
          @out << if fill && stroke
                    "#{rgb(fill)} rg #{rgb(stroke)} RG #{Pdf.number(wt * K)} w #{r} B"
                  elsif fill
                    "#{rgb(fill)} rg #{r} f"
                  else
                    "#{rgb(stroke)} RG #{Pdf.number(wt * K)} w #{r} S"
                  end
        end

        # size: chiều cao chữ (mm); angle: độ, ngược chiều kim đồng hồ.
        def text(s, cx, cy, size, angle, color)
          return if s.to_s.empty?

          if @fmt == :svg
            rot = angle.zero? ? '' : %( transform="rotate(#{n(-angle)} #{n(cx)} #{n(cy)})")
            @out << %(<text x="#{n(cx)}" y="#{n(cy + size * 0.36)}" font-size="#{n(size)}" fill="#{color}" text-anchor="middle"#{rot}>#{esc(s)}</text>)
          else
            @out << Pdf.text_command(s.to_s, pt([cx, cy]), size * K, angle, color)
          end
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
          lines = []
          cur = ''
          s.to_s.split(/\s+/).each do |wd|
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

        # ---- nhóm & vùng cắt ----
        def clip(x, y, w, h)
          if @fmt == :pdf
            @out << "q #{xy([x, y + h])} #{Pdf.number(w * K)} #{Pdf.number(h * K)} re W n"
            yield
            @out << 'Q'
          else
            id = "c#{@out.length}"
            @out << %(<clipPath id="#{id}"><rect x="#{n(x)}" y="#{n(y)}" width="#{n(w)}" height="#{n(h)}"/></clipPath><g clip-path="url(##{id})">)
            yield
            @out << '</g>'
          end
        end

        # Nhóm có thuộc tính (chỉ SVG) để giao diện chọn/kéo từng hình chiếu.
        def group(attrs = {})
          @out << '<g' + attrs.map { |k, v| %( #{k}="#{esc(v)}") }.join + '>' if @fmt == :svg
          yield
          @out << '</g>' if @fmt == :svg
        end

        def content
          @out.join("\n") + "\n"
        end

        # Mảnh nội dung vẽ riêng (để dựng từng hình ở bước riêng rồi ghép lại).
        def parts
          @fmt == :pdf ? @out[1..-1] : @out
        end

        def raw(parts)
          @out.concat(parts)
        end

        def svg
          %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{n(@pw)} #{n(@ph)}" width="#{n(@pw)}mm" height="#{n(@ph)}mm" ) +
            %(stroke-linecap="round" stroke-linejoin="round" font-family="MTNoto, 'Noto Sans', 'Segoe UI', Arial">) +
            %(<rect width="#{n(@pw)}" height="#{n(@ph)}" fill="#fff"/>) + @out.join + '</svg>'
        end
      end
    end
  end
end
