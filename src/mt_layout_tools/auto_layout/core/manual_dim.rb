# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # DIM THỦ CÔNG 2 ĐIỂM (v2.14). Người dùng bấm 2 điểm trên hình học thực của 1 hình chiếu/mặt cắt.
      # - Lưu riêng ở page['manual_dims'] = { view_key => [dim, ...] }, KHÔNG nằm trong Auto DIM: chạy lại Auto DIM,
      #   dàn trang, đổi tỉ lệ, chuyển tờ không đụng tới.
      # - Toạ độ điểm đo: mm thật trong hệ toạ độ cục bộ của hình (gốc góc trên-trái vùng vẽ, v hướng xuống) –
      #   giống v[:lines]. Giá trị = khoảng cách thật giữa 2 điểm theo phương đo (không tính theo pixel / giấy).
      # - Vị trí đường DIM (side/off) tính theo mm giấy từ mép hình -> đổi tỉ lệ thì DIM vẫn nằm cạnh hình,
      #   dời hình thì DIM đi theo.
      # - Liên kết hình học: mỗi điểm nhớ bộ phận (đường dẫn persistent_id) + mép bám (x0/x1/y0/y1) hoặc tỉ lệ
      #   trong khung bộ phận. Cập nhật model -> điểm đi theo mép bộ phận; mất bộ phận và không còn nằm trên nét
      #   -> trạng thái 'broken' (vẽ đỏ, báo "DIM mất liên kết").
      #
      # dim = { 'id', 'a' => [u, v], 'b' => [u, v], 'axis' => 'v'|'h'|'a', 'kind' => 'clear'|'free',
      #         'side' => 'l'|'r'|'t'|'b'|'in', 'off' => mm giấy (l/r/t/b, a) | mm thật (in),
      #         'ra'/'rb' => { 'p' => path, 'x' => 'x0'|'x1'|tỉ lệ, 'y' => 'y0'|'y1'|tỉ lệ } | false (không bám bộ phận) | nil (chưa tính),
      #         'hidden' => bool }
      module ManualDim
        module_function

        COLOR = '#178A55'.freeze # cùng màu Auto DIM (đúng quy cách bản vẽ)
        BROKEN = '#C0392B'.freeze
        TXT = 2.2
        TOL = 0.6 # mm thật: điểm coi là nằm trên nét
        FREE = 'free' # điểm bám đặt tự do (không gắn hình học) – không kiểm tra mất liên kết
        AXES = %w[v h a].freeze
        SIDES = %w[l r t b in].freeze
        MAX_PER_VIEW = 300
        MAX_SNAP = 15_000

        # ---------- dữ liệu ----------
        def num(x, lo = -1.0e6, hi = 1.0e6, digits = 2)
          f = Float(x)
          f.finite? ? f.clamp(lo, hi).round(digits) : nil
        rescue ArgumentError, TypeError
          nil
        end

        def clean_pt(p)
          return nil unless p.is_a?(Array) && p.length == 2

          xy = p.map { |n| num(n) }
          xy.include?(nil) ? nil : xy
        end

        def clean_ref(r)
          return false if r == false
          return FREE if r == FREE
          return nil unless r.is_a?(Hash) && r['p'].to_s =~ %r{\A\d+(/\d+){0,30}\z}

          ax = lambda do |val, lo, hi|
            if [lo, hi].include?(val.to_s) then val.to_s
            else
              num(val, -0.5, 1.5, 5) # tỉ lệ dọc mép bộ phận: giữ 5 chữ số để điểm không trôi sau mỗi lần lưu
            end
          end
          x = ax.call(r['x'], 'x0', 'x1')
          y = ax.call(r['y'], 'y0', 'y1')
          return nil if x.nil? || y.nil?

          { 'p' => r['p'].to_s, 'x' => x, 'y' => y }
        end

        def clean_dim(d)
          return nil unless d.is_a?(Hash)

          a = clean_pt(d['a'])
          b = clean_pt(d['b'])
          return nil unless a && b

          id = d['id'].to_s =~ /\A[\w-]{1,40}\z/ ? d['id'].to_s : "md#{rand(36**8).to_s(36)}"
          side = SIDES.include?(d['side'].to_s) ? d['side'].to_s : 'l'
          {
            'id' => id, 'a' => a, 'b' => b,
            'axis' => AXES.include?(d['axis'].to_s) ? d['axis'].to_s : 'v',
            'kind' => d['kind'].to_s == 'free' ? 'free' : 'clear',
            'side' => side,
            'off' => num(d['off'] || 4.5, side == 'in' ? -1.0e5 : -80, side == 'in' ? 1.0e5 : 80),
            'ra' => clean_ref(d['ra']), 'rb' => clean_ref(d['rb']),
            'hidden' => d['hidden'] == true
          }.merge(DimEdit.clean_text_fields(d)) # nội dung hiển thị / dời chữ / cỡ / đậm / khóa (v2.15)
        end

        # page['manual_dims'] từ giao diện / tệp: bỏ mục hỏng, bỏ trùng (cùng 2 điểm + cùng phương đo).
        def clean(raw)
          return {} unless raw.is_a?(Hash)

          raw.each_with_object({}) do |(k, list), h|
            next unless k.to_s =~ /\A([a-z]{2,6}|sec:[A-Z]|det:\d{1,2}|cp:\d{1,3})\z/ && list.is_a?(Array)

            seen = {}
            ids = {}
            out = list.first(MAX_PER_VIEW).filter_map do |d|
              c = clean_dim(d)
              next unless c
              next if ids[c['id']]

              sig = sig(c)
              next if seen[sig]

              seen[sig] = ids[c['id']] = true
              c
            end
            h[k.to_s] = out unless out.empty?
          end
        end

        def sig(d)
          pts = [d['a'], d['b']].map { |p| p.map { |n| n.round(1) } }.sort
          [d['axis'], pts]
        end

        # Thiết lập công cụ (cấp dự án). Mặc định theo yêu cầu: 2 điểm, thông thủy, bên trái, Smart Snap bật.
        def clean_cfg(raw)
          r = raw.is_a?(Hash) ? raw : {}
          {
            'kind' => r['kind'].to_s == 'free' ? 'free' : 'clear',
            'axis' => %w[auto v h a].include?(r['axis'].to_s) ? r['axis'].to_s : 'auto',
            'side' => %w[l r free].include?(r['side'].to_s) ? r['side'].to_s : 'l',
            'snap' => r['snap'] != false
          }
        end

        # Giá trị đo (mm thật) theo phương đo – không bao giờ lấy đường chéo khi đo dọc/ngang.
        def value(d)
          a = d['a']
          b = d['b']
          case d['axis']
          when 'h' then (a[0] - b[0]).abs
          when 'a' then Math.hypot(a[0] - b[0], a[1] - b[1])
          else (a[1] - b[1]).abs
          end
        end

        # ---------- hình học bắt điểm ----------
        # Đoạn hình học THỰC của hình: nét thấy + nét cắt của mặt cắt. Không gồm DIM, hatch, leader, ký hiệu cánh,
        # đường đánh dấu mặt cắt (những thứ đó không nằm trong v[:lines] / v[:cut][:segs]).
        def segs(v)
          v[:snap_segs] ||= begin
            all = Array(v[:lines]) + Array(v[:cut] && v[:cut][:segs]) + Array(v[:snap_more]) # snap_more: hình nguồn quanh chi tiết
            seen = {}
            out = []
            all.each do |p, q|
              next unless p && q
              next if Math.hypot(p[0] - q[0], p[1] - q[1]) < 0.3

              s = [p[0], p[1], q[0], q[1]].map { |n| n.to_f.round(1) }
              s = [s[2], s[3], s[0], s[1]] if ([s[2], s[3]] <=> [s[0], s[1]]) == -1
              next if seen[s]

              seen[s] = true
              out << s
            end
            out = out.max_by(MAX_SNAP) { |s| Math.hypot(s[2] - s[0], s[3] - s[1]) } if out.length > MAX_SNAP
            out
          end
        end

        # Dữ liệu gửi giao diện để bắt điểm: đoạn thật [x1,y1,x2,y2] + khung bộ phận.
        def snap_payload(v)
          { 'segs' => segs(v), 'w' => v[:w].to_f.round(2), 'h' => v[:h].to_f.round(2), 'truncated' => segs_total(v) > MAX_SNAP,
            'sig' => snap_meta(v)['sig'] }
        end

        # Chỉ gửi kèm mỗi lần dựng phần nhẹ (v2.16); đoạn hình học (có thể > 1 MB) chỉ gửi khi giao diện cần bắt điểm
        # (callback 'snap'), và giao diện giữ lại cho tới khi chữ ký 'sig' đổi (hình học hình thay đổi).
        def snap_meta(v)
          sg = segs(v)
          v[:snap_sig] ||= "#{sg.length}:#{sg.sum { |a| a[0] + a[1] * 3 + a[2] * 7 + a[3] * 11 }.round(1)}"
          { 'w' => v[:w].to_f.round(2), 'h' => v[:h].to_f.round(2), 'n' => sg.length, 'sig' => v[:snap_sig] }
        end

        def segs_total(v)
          Array(v[:lines]).length + Array(v[:cut] && v[:cut][:segs]).length + Array(v[:snap_more]).length
        end

        def dist_seg(p, s)
          ax, ay, bx, by = s
          dx = bx - ax
          dy = by - ay
          l2 = (dx * dx + dy * dy).to_f
          t = l2.zero? ? 0 : (((p[0] - ax) * dx + (p[1] - ay) * dy) / l2).clamp(0.0, 1.0)
          Math.hypot(p[0] - (ax + t * dx), p[1] - (ay + t * dy))
        end

        def on_geometry?(v, p, tol = TOL)
          segs(v).any? { |s| dist_seg(p, s) <= tol }
        end

        # ---------- liên kết bộ phận ----------
        def rects(v)
          Array(v[:part_rects]).each_with_object({}) { |r, h| h[r[0].to_s] ||= r }
        end

        # Bộ phận chứa điểm (trên mép theo phương đo được ưu tiên, rồi bộ phận gần người xem nhất).
        def ref_for(v, p, axis)
          tol = TOL
          best = nil
          Array(v[:part_rects]).each do |path, x0, x1, y0, y1, dep|
            next unless p[0] >= x0 - tol && p[0] <= x1 + tol && p[1] >= y0 - tol && p[1] <= y1 + tol

            ex = (p[0] - x0).abs <= tol ? 'x0' : ((p[0] - x1).abs <= tol ? 'x1' : nil)
            ey = (p[1] - y0).abs <= tol ? 'y0' : ((p[1] - y1).abs <= tol ? 'y1' : nil)
            on = axis == 'h' ? ex : (axis == 'v' ? ey : (ex || ey))
            score = [on ? 1 : 0, (ex || ey) ? 1 : 0, dep.to_f]
            next if best && (best[0] <=> score) >= 0

            fx = x1 - x0 > 1.0e-6 ? ((p[0] - x0) / (x1 - x0)).round(5) : 0.5
            fy = y1 - y0 > 1.0e-6 ? ((p[1] - y0) / (y1 - y0)).round(5) : 0.5
            best = [score, { 'p' => path.to_s, 'x' => ex || fx, 'y' => ey || fy }]
          end
          best ? best[1] : false
        end

        def from_ref(r, rect)
          _path, x0, x1, y0, y1 = rect
          x = r['x'] == 'x0' ? x0 : (r['x'] == 'x1' ? x1 : x0 + (x1 - x0) * r['x'].to_f)
          y = r['y'] == 'y0' ? y0 : (r['y'] == 'y1' ? y1 : y0 + (y1 - y0) * r['y'].to_f)
          [x.to_f.round(2), y.to_f.round(2)]
        end

        # Gắn liên kết (lần đầu) + bám lại theo model hiện tại. Trả về bản dim mới kèm 'value' và 'status'.
        # status: 'ok' – điểm nằm trên hình học / mép bộ phận còn tồn tại; 'broken' – mất liên kết.
        def resolve(v, d)
          d = d.dup
          rs = rects(v)
          broken = false
          %w[a b].each do |k|
            rk = "r#{k}"
            pt = d[k]
            if d[rk].nil?
              # mới tạo / vừa kéo sang điểm khác: chưa có liên kết -> gắn theo hình học hiện tại.
              # Điểm đặt tự do (không nằm trên hình học nào) -> 'free': người dùng cố ý đặt, không bao giờ báo mất
              # liên kết (trước v2.18.2 điểm này thành false rồi lần dựng sau bị báo đỏ "(!)").
              d[rk] = ref_for(v, pt, d['axis'])
              d[rk] = FREE if d[rk] == false && !on_geometry?(v, pt)
              next
            end
            next if d[rk] == FREE
            if d[rk].is_a?(Hash) && (rect = rs[d[rk]['p']])
              d[k] = from_ref(d[rk], rect) # model đổi -> điểm đi theo mép bộ phận
              next
            end
            broken = true unless on_geometry?(v, pt)
          end
          d['value'] = value(d).round(2)
          d['status'] = broken ? 'broken' : 'ok'
          d['origin'] = 'manual'
          d
        end

        # ---------- vẽ ----------
        # (ox, oy): góc trên-trái vùng vẽ của hình trên giấy. Trả về danh sách dim đã bám lại (cho giao diện).
        def draw(cv, v, s, ox, oy, list, rnd = 1)
          vw = v[:w] / s
          vh = v[:h] / s
          Array(list).map do |raw|
            d = resolve(v, raw)
            next d if d['hidden']

            col = d['status'] == 'broken' ? BROKEN : COLOR
            cv.group('class' => 'mdim', 'data-key' => v[:key].to_s, 'data-id' => d['id']) do
              d['geo'] = DimensionEngine.round_geo(draw_one(cv, d, s, ox, oy, vw, vh, col, rnd))
            end
            d
          end
        end

        # Toạ độ giấy của đường DIM (x với dim đứng, y với dim ngang).
        def line_pos(d, s, ox, oy, vw, vh)
          off = d['off'].to_f
          case d['axis']
          when 'h'
            case d['side']
            when 'b' then oy + vh + off
            when 'in' then oy + off / s
            else oy - off
            end
          else
            case d['side']
            when 'r' then ox + vw + off
            when 'in' then ox + off / s
            else ox - off
            end
          end
        end

        # Vẽ 1 DIM từ 2 điểm bám. d có thể kèm 'text' ("<>" = số đo thật), 'tdx'/'tdy', 'size', 'bold'.
        # Trả về hình học giấy cho giao diện: pa/pb điểm bám, la/lb đầu đường DIM, tc tâm chữ, tbox hộp chữ.
        def draw_one(cv, d, s, ox, oy, vw, vh, col, rnd)
          a = [ox + d['a'][0] / s, oy + d['a'][1] / s]
          b = [ox + d['b'][0] / s, oy + d['b'][1] / s]
          val = DimEdit.display(d['text'], DimensionEngine.label(value(d), rnd))
          val = "#{val} (!)" if col == BROKEN
          dash = col == BROKEN ? [1.0, 0.6] : nil
          sz = d['size'] ? d['size'].to_f : TXT
          tdx = d['tdx'].to_f
          tdy = d['tdy'].to_f
          bold = d['bold'] == true
          return aligned(cv, a, b, d['off'].to_f, val, col, dash, sz, tdx, tdy, bold) if d['axis'] == 'a'

          lp = line_pos(d, s, ox, oy, vw, vh)
          k = d['axis'] == 'h' ? 1 : 0 # toạ độ giấy cố định của đường DIM
          pa = a.dup
          pb = b.dup
          pa[k] = pb[k] = lp
          [[a, pa], [b, pb]].each { |p, q| ext(cv, p, q, k, col) }
          cv.line(pa, pb, 0.13, col, dash)
          [pa, pb].each { |p| tick(cv, p, col) }
          mid = [(pa[0] + pb[0]) / 2, (pa[1] + pb[1]) / 2]
          len = Math.hypot(pb[0] - pa[0], pb[1] - pa[1])
          tw = cv.text_w(val, sz)
          small = len < tw + 0.8
          out = lp < (k.zero? ? a[0] : a[1]) ? -1 : 1 # phía ngoài: phía đường DIM so với vật
          size = small && !d['size'] ? sz * 0.85 : sz
          if k.zero?
            c, ang = small ? [[mid[0] + out * (tw / 2 + 1.6), mid[1]], 0] : [[mid[0] + (out.negative? ? -1.5 : 1.7), mid[1]], 90]
          else
            c, ang = small ? [[mid[0], mid[1] + out * 3.0], 0] : [[mid[0], mid[1] + (out.negative? ? -1.5 : 2.4)], 0]
          end
          c = [c[0] + tdx, c[1] + tdy]
          cv.text(val, c[0], c[1], size, ang, col, bold)
          tw = cv.text_w(val, size)
          box = ang.zero? ? [c[0] - tw / 2, c[1] - size / 2, c[0] + tw / 2, c[1] + size / 2] : [c[0] - size / 2, c[1] - tw / 2, c[0] + size / 2, c[1] + tw / 2]
          { 'pa' => a, 'pb' => b, 'la' => pa, 'lb' => pb, 'tc' => c, 'tbox' => box }
        end

        # Đường gióng: từ điểm đo (chừa khe 0.8 mm) tới quá đường DIM 1.5 mm.
        def ext(cv, p, q, k, col)
          dlt = q[k] - p[k]
          return if dlt.abs < 0.05

          sg = dlt.positive? ? 1 : -1
          st = p.dup
          en = q.dup
          st[k] += sg * [0.8, dlt.abs / 2].min
          en[k] += sg * 1.5
          cv.line(st, en, 0.13, col)
        end

        def tick(cv, p, col)
          cv.line([p[0] - 0.8, p[1] + 0.8], [p[0] + 0.8, p[1] - 0.8], 0.3, col)
        end

        # DIM thẳng (đo đường chéo – chỉ khi người dùng chọn rõ phương "thẳng").
        def aligned(cv, a, b, off, val, col, dash, sz = TXT, tdx = 0.0, tdy = 0.0, bold = false)
          l = Math.hypot(b[0] - a[0], b[1] - a[1])
          return { 'pa' => a, 'pb' => b, 'la' => a, 'lb' => b, 'tc' => a } if l < 1.0e-6

          ux = (b[0] - a[0]) / l
          uy = (b[1] - a[1]) / l
          nx = -uy
          ny = ux
          pa = [a[0] + nx * off, a[1] + ny * off]
          pb = [b[0] + nx * off, b[1] + ny * off]
          sg = off.negative? ? -1 : 1
          [[a, pa], [b, pb]].each do |p, q|
            cv.line([p[0] + nx * sg * 0.8, p[1] + ny * sg * 0.8], [q[0] + nx * sg * 1.5, q[1] + ny * sg * 1.5], 0.13, col) if off.abs > 0.9
          end
          cv.line(pa, pb, 0.13, col, dash)
          [pa, pb].each { |p| tick(cv, p, col) }
          ang = -Math.atan2(uy, ux) * 180 / Math::PI
          ang += 180 if ang > 90
          ang -= 180 if ang <= -90
          m = [(pa[0] + pb[0]) / 2 + nx * sg * 1.6 + tdx, (pa[1] + pb[1]) / 2 + ny * sg * 1.6 + tdy]
          cv.text(val, m[0], m[1], sz, ang.round(2), col, bold)
          { 'pa' => a, 'pb' => b, 'la' => pa, 'lb' => pb, 'tc' => m }
        end
      end
    end
  end
end
