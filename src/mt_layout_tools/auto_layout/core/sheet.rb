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
        HATCH = '#4A4A4A'.freeze
        CUT_RED = '#C0392B'.freeze
        MARK_VIEWS = %w[front open top].freeze

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
        # Tỉ lệ hiệu lực của 1 hình: tỉ lệ riêng (scale_override / chi tiết) nếu có, ngược lại theo tỉ lệ tờ.
        # PageBuild gán v[:fixed_scale] từ page['view_props'][key]['scale_override'] trước khi dàn trang.
        def sc(v, s)
          v[:fixed_scale] || v[:base_scale] || s
        end

        # Tỉ lệ hiện trong khung tên: 1 tỉ lệ nếu mọi hình cùng tỉ lệ, ngược lại "THEO HÌNH".
        def scale_label(views, s)
          all = views.map { |v| sc(v, s) }.uniq
          all.length == 1 ? "1:#{all[0]}" : 'THEO HÌNH'
        end

        def lock_text(v)
          v[:scale_locked] ? 'đã khóa' : 'tỉ lệ riêng'
        end

        def box_w(v, s)
          v[:w] / sc(v, s) + (v[:dims] ? M_LEFT + M_RIGHT : 4)
        end

        def box_h(v, s)
          v[:h] / sc(v, s) + (v[:dims] ? M_TOP : 4) + M_BOTTOM
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
        # Dựng cả tờ trong 1 lần (đồng bộ). PageBuild gọi 3 bước prepare / draw_placement (mỗi hình 1 lô) / assemble.
        def render(cv, views, mats, page, tb, pw, ph, notes = [])
          ctx = prepare(views, mats, page, pw, ph)
          frags = ctx[:placements].map do |pl|
            sub = Canvas.new(cv.fmt, pw, ph)
            draw_placement(sub, ctx, pl, page)
            sub.parts
          end
          assemble(cv, ctx, frags, page, tb, notes)
        end

        # Giữ đúng tỉ lệ người dùng chọn: nếu tất cả hình không vừa 1 tờ ở tỉ lệ đó thì chia sang nhiều tờ
        # (không thu nhỏ hình). Tỉ lệ "Tự động" -> 1 tờ, tự chọn tỉ lệ vừa khổ.
        # Trả về [[views, tỉ lệ ép | nil, ghi chú | nil], ...] – mỗi phần tử là 1 tờ.
        # Hình có tỉ lệ riêng (v[:fixed_scale]) KHÔNG BAO GIỜ bị thu nhỏ: không vừa thì chuyển sang tờ khác;
        # 1 hình riêng lẻ vẫn không vừa khổ -> giữ nguyên tỉ lệ và báo xung đột.
        def paginate(views, mats, page, pw, ph)
          want = page['scale'].to_i
          return [[views, nil, nil]] if views.empty?

          fixed = views.any? { |v| v[:fixed_scale] }
          return [[views, nil, nil]] if want <= 0 && !fixed

          _frame, _tb, area = frames(pw, ph)
          aw = area[2] - area[0]
          legend_h = mats.first(14).empty? ? 0 : mats.first(14).length * 4.2 + 2
          ah = area[3] - area[1] - legend_h
          fits = lambda do |group|
            if want.positive?
              pl = plan(group, want, aw, ah)
              pl[:w] <= aw && pl[:h] <= ah
            else
              !pick_scale(group, aw, ah).nil?
            end
          end
          pinned = views.select { |v| v[:pin] || v[:want_sheet] }
          tsheet = ->(v) { v[:pin] ? v[:pin][:sheet].to_i : v[:want_sheet].to_i }
          if pinned.all? { |v| tsheet.call(v).zero? } && fits.call(views)
            return [[views, want.positive? ? want : nil, nil]]
          end

          # Hình đặt tay (vị trí thủ công) ở lại đúng tờ đã đặt; các hình còn lại first-fit vào tờ đầu tiên còn chỗ.
          sheets = []
          pinned.each { |v| (sheets[tsheet.call(v).clamp(0, 49)] ||= []) << v }
          sheets = sheets.map { |g| g || [] }
          (views - pinned).each do |v|
            target = sheets.find { |g| fits.call(g + [v]) }
            target ? target << v : sheets << [v]
          end
          sheets.reject!(&:empty?)
          sheets.map! { |g| g.sort_by { |v| views.index(v) } }
          sheets.map do |group|
            if fits.call(group)
              [group, want.positive? ? want : nil, nil]
            elsif group.all? { |v| v[:fixed_scale] }
              msg = group.map { |v| "#{v[:name]} (TL 1:#{v[:fixed_scale]}, #{lock_text(v)})" }.join(', ')
              [group, want.positive? ? want : group[0][:fixed_scale],
               "XUNG ĐỘT TỈ LỆ: #{msg} không vừa khổ giấy – giữ nguyên tỉ lệ, không thu nhỏ. Hãy chọn khổ lớn hơn hoặc đổi tỉ lệ riêng."]
            else
              free = group.reject { |v| v[:fixed_scale] }
              [group, nil, "#{free.map { |v| v[:name] }.join(', ')}: quá lớn cho khổ giấy ở 1:#{want}, tờ này dùng tỉ lệ tự động " \
                           '(hình có tỉ lệ riêng giữ nguyên).']
            end
          end
        end

        # Chọn tỉ lệ + vị trí từng hình (chưa vẽ). Trả về ngữ cảnh dùng cho các bước sau.
        # forced: tỉ lệ đã được paginate xác nhận là vừa (giữ nguyên, không đổi).
        def prepare(views, mats, page, pw, ph, forced = nil)
          frame, tb_x, area = frames(pw, ph)
          aw = area[2] - area[0]
          legend = mats.first(14)
          legend_h = legend.empty? ? 0 : legend.length * 4.2 + 2
          ah = area[3] - area[1] - legend_h
          info = { 'note' => nil, 'boxes' => {}, 'offsets' => {}, 'frames' => {}, 'area' => area.map { |n| n.round(2) },
                   'legend_h' => (mats.first(14).empty? ? 0 : mats.first(14).length * 4.2 + 2) }
          ctx = { frame: frame, tb_x: tb_x, area: area, legend: legend, info: info, placements: [], empty: views.empty? }
          if views.empty?
            info['scale'] = page['scale'].to_i.positive? ? page['scale'].to_i : 20
            info['note'] = 'Trang chưa có hình chiếu nào.'
            return ctx
          end
          frozen = views.any? { |v| v[:pin] || v[:base_scale] }
          auto = forced || (frozen ? nil : pick_scale(views, aw, ah))
          want = forced || page['scale'].to_i
          if frozen
            # Bố cục đã chốt: KHÔNG tự đổi tỉ lệ để ép vừa giấy – hình nào tràn/chồng thì báo xung đột.
            scale = want.positive? ? want : (views.map { |v| v[:base_scale] }.compact.first || pick_scale(views, aw, ah) || 20)
          elsif auto.nil?
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
          info['scale_label'] = scale_label(views, scale)
          info['view_scales'] = views.map { |v| [v[:key], sc(v, scale)] }.to_h
          ctx[:scale] = scale
          ctx[:placements] = place_views(views, scale, area, ah, page.merge('__legend_h' => legend_h), info)
          ctx
        end

        # Vẽ 1 hình đã xếp chỗ (1 lô của Job).
        def draw_placement(cv, ctx, pl, page)
          v, x, base = pl
          cv.group('class' => 'view', 'data-key' => v[:key]) do
            ctx[:info]['frames'][v[:key]] = draw_view(cv, v, ctx[:scale], x, base, page)
          end
        end

        # Ghép các mảnh hình + bảng vật liệu + chú thích + khung + khung tên.
        def assemble(cv, ctx, frags, page, tb, notes = [])
          frame = ctx[:frame]
          tb_x = ctx[:tb_x]
          area = ctx[:area]
          info = ctx[:info]
          if ctx[:empty]
            # Không để trang trắng im lặng: in rõ lý do lên giấy.
            aw = area[2] - area[0]
            msgs = ['CHƯA DỰNG ĐƯỢC HÌNH CHIẾU CHO TRANG NÀY'] + (notes.empty? ? ['Chưa chọn hình chiếu nào.'] : notes)
            cx = (area[0] + area[2]) / 2
            y = (area[1] + area[3]) / 2 - msgs.length * 3
            msgs.each_with_index do |m, i|
              cv.wrap(m, i.zero? ? 4.0 : 2.6, aw - 20).each do |ln|
                cv.text(ln, cx, y, i.zero? ? 4.0 : 2.6, 0, i.zero? ? '#B3261E' : INK)
                y += i.zero? ? 7 : 4
              end
            end
          else
            cv.clip(frame[0] + 1.2, frame[1] + 1.2, tb_x - frame[0] - 1.2, frame[3] - frame[1] - 2.4) do
              frags.each { |f| cv.raw(f) }
            end
          end
          draw_legend(cv, ctx[:legend], area)
          AnnotationEngine.draw(cv, page['notes'], Array(page['hidden_layers']))
          draw_frame(cv, frame, tb_x)
          draw_title_block(cv, tb, info['scale_label'] || info['scale'], frame, tb_x)
          info
        end

        # Vị trí từng hình: [[view, x, base]] đã cộng dịch chuyển của người dùng và kẹp trong vùng vẽ.
        def place_views(views, s, area, ah, page, info)
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
          placed = slots.map do |v, x, base|
            bw, bh = box_w(v, s), box_h(v, s)
            bx, by = x, base + M_BOTTOM - bh
            if v[:pin]
              # Vị trí thủ công: toạ độ tuyệt đối (mm giấy) của góc trên-trái khung hình – KHÔNG tính lại, KHÔNG kẹp.
              px = v[:pin][:x].to_f
              py = v[:pin][:y].to_f
              info['boxes'][v[:key]] = [px, py, bw, bh].map { |n| n.round(2) }
              if px < area[0] - 0.5 || py < area[1] - 0.5 || px + bw > area[2] + 0.5 || py + bh > area[3] + 0.5
                (info['conflicts'] ||= []) << { 'type' => 'overflow', 'a' => v[:key] }
                add_note(info, "#{v[:name]} (#{v[:position_locked] ? 'đã khóa' : (v[:pin][:manual] ? 'đã chỉnh tay' : 'đã chốt chỗ')}) " \
                               'tràn ra ngoài vùng vẽ – giữ nguyên vị trí; kéo lại hoặc bấm "Dàn trang lại".')
              end
              next [v, px, py + bh - M_BOTTOM]
            end
            dx, dy = Array(offs[v[:key]]).map(&:to_f)
            dx ||= 0.0
            dy ||= 0.0
            # Kẹp trong vùng vẽ để không đè khung tên/viền giấy.
            dx = dx.clamp(area[0] - bx, [area[2] - bx - bw, area[0] - bx].max)
            dy = dy.clamp(area[1] - by, [area[3] - by - bh, area[1] - by].max)
            info['offsets'][v[:key]] = [dx.round(2), dy.round(2)]
            info['boxes'][v[:key]] = [bx + dx, by + dy, bw, bh].map { |n| n.round(2) }
            [v, x + dx, base + dy]
          end
          place_pending(placed, s, area, page, info)
          report_overlaps(placed, info)
          placed
        end

        # Hình CHỜ ĐẶT (đã định tờ, chưa có toạ độ) trên tờ đã có hình chốt chỗ: tìm chỗ trống trong vùng vẽ,
        # né mọi khung hình (đã gồm DIM), bảng vật liệu và chú thích/leader của tờ. Không đủ chỗ -> báo, không đổi tờ.
        def place_pending(placed, s, area, page, info)
          return unless placed.any? { |v, _, _| v[:pin] } && placed.any? { |v, _, _| v[:want_sheet] }

          occ = placed.reject { |v, _, _| v[:want_sheet] }.map { |v, _, _| info['boxes'][v[:key]] }.compact
          leg = page['__legend_h'].to_f
          occ << [area[2] - 64, area[3] - leg, 64, leg] if leg.positive?
          Array(page['notes']).each do |n|
            [[n['x'], n['y']], [n['tx'], n['ty']]].each do |x, y|
              next unless x.is_a?(Numeric) && (x.nonzero? || y.to_f.nonzero?)

              occ << [x - 3, y - 6, 45, 10]
            end
          end
          placed.map!.with_index do |(v, x, base), _i|
            next [v, x, base] unless v[:want_sheet]

            bw = box_w(v, s)
            bh = box_h(v, s)
            spot = free_spot(occ, bw, bh, area)
            if spot
              info['boxes'][v[:key]] = [spot[0], spot[1], bw, bh].map { |n| n.round(2) }
              occ << info['boxes'][v[:key]]
              [v, spot[0], spot[1] + bh - M_BOTTOM]
            else
              (info['no_room'] ||= []) << v[:key]
              add_note(info, "KHÔNG ĐỦ CHỖ: #{v[:name]} không vừa chỗ trống của tờ này – đang đặt tạm, có thể chồng hình. " \
                             'Chọn: Dàn lại trang này / Chuyển sang trang khác / Hủy (↶).')
              b = info['boxes'][v[:key]]
              [v, b[0], b[1] + bh - M_BOTTOM]
            end
          end
        end

        # Quét lưới 2 mm từ trên xuống, trái sang phải: chỗ đầu tiên không giao khung nào (chừa 3 mm).
        def free_spot(occ, bw, bh, area)
          pad = 3.0
          return nil if bw > area[2] - area[0] || bh > area[3] - area[1]

          y = area[1]
          while y + bh <= area[3] + 0.01
            x = area[0]
            while x + bw <= area[2] + 0.01
              hit = occ.find { |b| x < b[0] + b[2] + pad && b[0] < x + bw + pad && y < b[1] + b[3] + pad && b[1] < y + bh + pad }
              return [x.round(2), y.round(2)] unless hit

              x = hit[0] + hit[2] + pad # nhảy qua khung đang chắn
            end
            y += 2.0
          end
          nil
        end

        # Bố cục đã dựng của 1 trang (mọi tờ): { key => [x_mm, y_mm, tờ] } – để CHỐT vị trí, lần sau không tính lại.
        def layout_of(outs)
          outs.each_with_index.each_with_object({}) do |((_svg, inf), i), h|
            (inf['boxes'] || {}).each do |k, b|
              h[k] = [b[0].to_f.round(2), b[1].to_f.round(2), i, b[2].to_f.round(1), b[3].to_f.round(1), (inf['view_scales'] || {})[k]]
            end
          end
        end

        def add_note(info, msg)
          info['note'] = [info['note'], msg].compact.join(' | ')
        end

        # Hình chồng lên nhau (sau khi chỉnh tay / đổi tỉ lệ / thêm hình) -> báo, KHÔNG tự dời hình nào.
        def report_overlaps(placed, info)
          boxes = info['boxes']
          return unless placed.any? { |v, _, _| v[:pin] }

          placed.combination(2).each do |(v, _, _), (p, _, _)|
            a = boxes[v[:key]]
            b = boxes[p[:key]]
            next unless a && b && a[0] < b[0] + b[2] - 0.5 && b[0] < a[0] + a[2] - 0.5 && a[1] < b[1] + b[3] - 0.5 && b[1] < a[1] + a[3] - 0.5

            (info['conflicts'] ||= []) << { 'type' => 'overlap', 'a' => v[:key], 'b' => p[:key] }
            add_note(info, "XUNG ĐỘT VỊ TRÍ: #{v[:name]} chồng lên #{p[:name]} – kéo sang chỗ trống hoặc bấm \"Dàn trang lại\".")
          end
        end

        def draw_view(cv, v, s, x, base, page)
          s = sc(v, s)
          ox = x + (v[:dims] ? M_LEFT : 2)
          vw, vh = v[:w] / s, v[:h] / s
          oy = base - vh
          tf = ->(p) { [ox + p[0] / s, oy + p[1] / s] }
          if v[:detail]
            draw_detail(cv, v, s, ox, oy, page)
          else
            draw_fills(cv, v, tf, page)
            if v[:key] == 'iso' && page['iso_hidden'] && v[:hlines]
              v[:hlines].each { |a, b| cv.line(tf.call(a), tf.call(b), 0.13, '#8A8F8B', [1.2, 0.8]) }
            end
            polylines(v, tf).each { |pl| cv.polyline(pl, 0.25, INK) }
            draw_cut(cv, v, tf)
            cv.polyline(v[:border].map(&tf), 0.18, CUT_RED, [1.5, 0.8]) if v[:border] # viền chi tiết tròn/elip
            DoorSymbols.draw(cv, v, tf, page['door_symbols'])
            @obstacles = []
            section_marks(cv, v, s, ox, oy, page['sections']) if v[:origin] && MARK_VIEWS.include?(v[:key])
            detail_marks(cv, v, tf, s, page['details'])
          end
          if v[:dims] && page.fetch('dims', true)
            obs = Array(@obstacles) + note_boxes(cv, page['notes'])
            r = DimensionEngine.draw(cv, v, s, ox, oy, page.merge('obstacles' => obs))
            if r['moved']
              cv.text('DIM chi tiết: xem MẶT ĐỨNG THÁO CÁNH / MẶT CẮT', ox + vw / 2, base + 13.5, 2.0, 0, GREY)
            end
          end
          @obstacles = nil
          caption(cv, v[:name], "TL 1:#{s}", ox + vw / 2, base + 6.5)
          cv.text('BẢN XEM TRƯỚC – CHƯA KHỬ ĐỦ NÉT KHUẤT', ox + vw / 2, base + 13.5, 2.2, 0, '#B3261E') if v[:level].to_i >= 3
          [ox, oy, s, v[:w], v[:h]].map { |n| n.round(4) }
        end

        def draw_cut(cv, v, tf)
          return unless v[:cut]

          loops = v[:cut][:loops].map { |lp| lp.map(&tf) }
          SectionEngine.hatch(loops).each { |a, b| cv.line(a, b, 0.13, HATCH) }
          chain(v[:cut][:segs].map { |a, b| [tf.call(a), tf.call(b)] }).each { |pl| cv.polyline(pl, 0.5, INK) }
        end

        # Vẽ lại vùng khoanh của hình nguồn ở tỉ lệ chi tiết (màu, nét, nét cắt, hatch thật), có khung.
        def draw_detail(cv, v, s, ox, oy, page)
          src = v[:detail][:src]
          x0, y0 = v[:detail][:rect]
          tf = ->(p) { [ox + (p[0] - x0) / s, oy + (p[1] - y0) / s] }
          vw, vh = v[:w] / s, v[:h] / s
          shape = v[:detail][:shape] || 'rect'
          fill = v[:detail][:fill].nil? ? page['fill'] : v[:detail][:fill]
          body = lambda do
            # chỉ phần hình học trong vùng trích: mặt tô, nét (đã cắt sẵn), nét cắt + hatch của mặt cắt nguồn
            src[:fills].each { |tri, color| cv.poly(tri.map(&tf), color) } if fill
            chain(v[:lines].map { |a, b| [[ox + a[0] / s, oy + a[1] / s], [ox + b[0] / s, oy + b[1] / s]] })
              .each { |pl| cv.polyline(pl, 0.3, INK) }
            draw_cut(cv, src, tf)
          end
          if shape == 'rect'
            cv.clip(ox, oy, vw, vh, &body)
            cv.rect(ox, oy, vw, vh, nil, '#8A8F8B', 0.2)
          else
            cv.clip_ellipse(ox, oy, vw, vh, &body) # tròn/elip: không lộ phần ngoài đường bao
          end
        end

        # Ký hiệu vùng khoanh chi tiết trên hình nguồn: khung nét đứt + số chi tiết.
        def detail_marks(cv, v, tf, _s, details)
          Array(details).each do |d|
            next unless d['src'] == v[:key]

            x0, y0, x1, y1 = d['rect']
            a = tf.call([x0, y0])
            b = tf.call([x1, y1])
            mk = d['marker'] || {}
            dash = [1.5, 0.8]
            cv.group('class' => 'detmark', 'data-det' => d['n']) do
              cx = (a[0] + b[0]) / 2.0
              cy = (a[1] + b[1]) / 2.0
              rx = (b[0] - a[0]).abs / 2.0
              ry = (b[1] - a[1]).abs / 2.0
              case mk['shape']
              when 'circle', 'ellipse'
                if mk['shape'] == 'circle'
                  rx = ry = [rx, ry].max
                end
                pts = (0..72).map { |i| t = 2 * Math::PI * i / 72; [cx + rx * Math.cos(t), cy + ry * Math.sin(t)] }
                cv.polyline(pts, 0.25, CUT_RED, dash)
                edge = [cx + rx * Math.cos(-Math::PI / 4), cy + ry * Math.sin(-Math::PI / 4)]
              else
                cv.polyline([[a[0], a[1]], [b[0], a[1]], [b[0], b[1]], [a[0], b[1]], [a[0], a[1]]], 0.25, CUT_RED, dash)
                edge = [b[0], a[1]]
              end
              c = mk['arrow'] ? [edge[0] + 6.5, edge[1] - 6.5] : [edge[0] + 2.2, edge[1] - 2.2]
              if mk['arrow']
                # mũi tên từ ký hiệu tham chiếu chỉ vào vùng trích
                dx = edge[0] - c[0]
                dy = edge[1] - c[1]
                l = Math.hypot(dx, dy)
                ux = dx / l
                uy = dy / l
                s0 = [c[0] + ux * 2.0, c[1] + uy * 2.0]
                cv.line(s0, edge, 0.2, CUT_RED)
                cv.line(edge, [edge[0] - ux * 1.6 - uy * 0.6, edge[1] - uy * 1.6 + ux * 0.6], 0.2, CUT_RED)
                cv.line(edge, [edge[0] - ux * 1.6 + uy * 0.6, edge[1] - uy * 1.6 - ux * 0.6], 0.2, CUT_RED)
              end
              if mk['bubble'] == false
                cv.text_left(DetailEngine.label(d), c[0] - 1, c[1], 2.2, CUT_RED)
              else
                cv.circle(c, 2.0, '#FFFFFF', CUT_RED, 0.3)
                cv.text(d['n'].to_s, c[0], c[1], 2.4, 0, CUT_RED)
              end
            end
          end
        end

        # Đường gấp khúc của hình (đã nối sẵn theo lô bởi ChainBuilder nếu có), đổi sang giấy rồi rút gọn điểm.
        def polylines(v, tf)
          return chain(v[:lines].map { |a, b| [tf.call(a), tf.call(b)] }) unless v[:chains]

          v[:chains].map { |pl| pl.map(&tf) }
        end

        # Nối đoạn thành đường gấp khúc theo lô (máy trạng thái cho Job). Toạ độ thật của hình chiếu.
        class ChainBuilder
          attr_reader :result

          def initialize(lines)
            @segs = lines
            @ends = Hash.new { |h, k| h[k] = [] }
            @used = Array.new(lines.length, false)
            @i = 0
            @phase = :index
            @result = []
          end

          def key(p)
            [(p[0] * 100).round, (p[1] * 100).round]
          end

          # Rút gọn điểm với sai lệch 0,1 mm thật (= 0,02 mm trên giấy ở tỉ lệ 1:5, nhỏ hơn nét in).
          SIMPLIFY_TOL = 0.1

          def call(job)
            return simplify_step(job) if @phase == :simplify
            if @phase == :index
              while @i < @segs.length
                return false if (@i % 2048).zero? && @i.positive? && job.time_up?

                a, b = @segs[@i]
                @ends[key(a)] << @i
                @ends[key(b)] << @i
                @i += 1
              end
              @phase = :walk
              @i = 0
            end
            while @i < @segs.length
              return false if (@i % 512).zero? && @i.positive? && job.time_up?

              walk(@i) unless @used[@i]
              @i += 1
            end
            @ends = @used = nil
            @phase = :simplify
            @i = 0
            simplify_step(job)
          end

          def simplify_step(job)
            while @i < @result.length
              return false if (@i % 256).zero? && @i.positive? && job.time_up?

              @result[@i] = Sheet.simplify(@result[@i], SIMPLIFY_TOL)
              @i += 1
            end
            @phase = :done
            true
          end

          def walk(i)
            @used[i] = true
            pts = @segs[i].dup
            [true, false].each do |forward|
              loop do
                tip = forward ? pts.last : pts.first
                j = @ends[key(tip)].find { |k| !@used[k] }
                break unless j

                @used[j] = true
                a, b = @segs[j]
                nxt = key(a) == key(tip) ? b : a
                forward ? pts.push(nxt) : pts.unshift(nxt)
              end
            end
            @result << pts
          end
        end

        # Nối các đoạn chung đầu mút thành đường gấp khúc rồi rút gọn điểm (sai lệch < 0,02 mm trên giấy).
        # Giữ nguyên hình dạng in ra, nhưng file SVG/PDF nhẹ hơn nhiều với cung tròn chia mịn.
        def chain(segs, tol = 0.02)
          key = ->(p) { [(p[0] * 100).round, (p[1] * 100).round] }
          ends = Hash.new { |h, k| h[k] = [] }
          segs.each_with_index { |(a, b), i| ends[key.call(a)] << i; ends[key.call(b)] << i }
          used = Array.new(segs.length, false)
          out = []
          segs.each_index do |i|
            next if used[i]

            used[i] = true
            pts = segs[i].dup
            [true, false].each do |forward|
              loop do
                tip = forward ? pts.last : pts.first
                j = ends[key.call(tip)].find { |k| !used[k] }
                break unless j

                used[j] = true
                a, b = segs[j]
                nxt = key.call(a) == key.call(tip) ? b : a
                forward ? pts.push(nxt) : pts.unshift(nxt)
              end
            end
            out << simplify(pts, tol)
          end
          out
        end

        def simplify(pts, tol)
          return pts if pts.length < 3

          a = pts.first
          b = pts.last
          dx = b[0] - a[0]
          dy = b[1] - a[1]
          len = Math.hypot(dx, dy)
          far = 0
          dmax = -1.0
          (1...pts.length - 1).each do |i|
            p = pts[i]
            d = len < 1e-9 ? Math.hypot(p[0] - a[0], p[1] - a[1]) : ((p[0] - a[0]) * dy - (p[1] - a[1]) * dx).abs / len
            if d > dmax
              dmax = d
              far = i
            end
          end
          return [a, b] if dmax <= tol

          simplify(pts[0..far], tol)[0..-2] + simplify(pts[far..-1], tol)
        end

        # Ký hiệu đường cắt trên mặt đứng / mặt bằng: nét gạch chấm, vòng tròn chữ cái, mũi tên hướng nhìn.
        # Chế độ tô trục đo: material (màu vật liệu), mono (đơn sắc xám theo hướng sáng), none (không tô).
        # Mọi chế độ dùng chung 1 bộ mặt đã xử lý che khuất (BSP) – không tạo bản vẽ khác.
        def draw_fills(cv, v, tf, page)
          return unless page['fill']

          mode = v[:key] == 'iso' ? page['iso_mode'].to_s : 'material'
          return if mode == 'none'

          v[:fills].each { |tri, color, gray| cv.poly(tri.map(&tf), mode == 'mono' && gray ? gray : color) }
        end

        # Nhóm SVG class "secmark" để kéo đường cắt trực tiếp trên giấy.
        def section_marks(cv, v, s, ox, oy, sections)
          l, t = v[:origin]
          vw = v[:w] / s
          vh = v[:h] / s
          Array(sections).each do |sec|
            pos = sec['pos'].to_f
            dir = sec['dir'].to_i.positive? ? 1 : -1
            vertical = sec['axis'] == 'x'
            if vertical
              x = ox + (pos - l) / s
              next if x < ox - 0.01 || x > ox + vw + 0.01

              a = [x, oy - 17]     # vượt qua 2 hàng DIM phía trên
              b = [x, oy + vh + 3] # không đè tên hình phía dưới
              arrow = [dir * 1.0, 0.0]
            else
              # mặt đứng: z -> v = -z ; mặt bằng: y -> v = -y
              next if (v[:key] == 'top') != (sec['axis'] == 'y')

              y = oy + (-pos - t) / s
              next if y < oy - 0.01 || y > oy + vh + 0.01

              a = [ox - 13, y]
              b = [ox + vw + 12, y]
              # z nhìn xuống (dir -1) -> mũi tên xuống (v tăng); y nhìn ra sau (dir +1) -> mũi tên lên (về phía -v)
              arrow = sec['axis'] == 'z' ? [0.0, -dir * 1.0] : [0.0, -dir * 1.0]
            end
            cv.group('class' => 'secmark', 'data-sec' => sec['label'], 'data-axis' => sec['axis']) do
              cv.line(a, b, 0.25, CUT_RED, [5, 1, 1, 1])
              [a, b].each do |p|
                tip = [p[0] + arrow[0] * 4.5, p[1] + arrow[1] * 4.5]
                cv.line(p, tip, 0.35, CUT_RED)
                side = [-arrow[1], arrow[0]]
                cv.poly([tip, [tip[0] - arrow[0] * 1.6 + side[0] * 0.9, tip[1] - arrow[1] * 1.6 + side[1] * 0.9],
                         [tip[0] - arrow[0] * 1.6 - side[0] * 0.9, tip[1] - arrow[1] * 1.6 - side[1] * 0.9]], CUT_RED)
                # vòng chữ cái đặt phía ngược mũi tên, sát đầu đường cắt
                c = vertical ? [p[0] - arrow[0] * 3.0, p[1]] : [p[0], p[1] - arrow[1] * 3.0]
                cv.circle(c, 2.2, '#FFFFFF', CUT_RED, 0.3)
                cv.text(sec['label'], c[0], c[1], 2.6, 0, CUT_RED)
                @obstacles&.push([c[0] - 2.4, c[1] - 2.4, c[0] + 2.4, c[1] + 2.4])
              end
            end
          end
        end

        # Hộp chiếm chỗ (gần đúng) của chú thích để chữ DIM né.
        def note_boxes(cv, notes)
          Array(notes).map do |n|
            rows = n['text'].to_s.split("\n")
            rows = [''] if rows.empty?
            w = rows.map { |r| cv.text_w(r, n['size'].to_f) }.max.to_f
            h = n['size'].to_f * 1.35 * rows.length
            x = n['x'].to_f
            x -= w + 3.8 if %w[leader material].include?(n['type']) && n['x'].to_f < n['tx'].to_f
            [x - 0.5, n['y'].to_f - n['size'].to_f, x + w + 4.5, n['y'].to_f + h]
          end
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
          cv.text(scale.is_a?(String) ? scale : "1:#{scale}", (mid + x1) / 2, y + dh * 0.62, 2.6, 0, INK)
          y += dh
          hl.call(y)

          cv.text_left('KÝ HIỆU BẢN VẼ', x0 + 1.5, y + 2.4, 1.7, GREY)
          big = [6, (bottom - y) * 0.35].min
          cv.text(o['sheet_no'].to_s, (x0 + x1) / 2, (y + bottom) / 2 + 1.5, big, 0, INK)
          cv.text(o['sheet_of'].to_s, (x0 + x1) / 2, (y + bottom) / 2 + 1.5 + big * 0.9 + 1.5, 2.0, 0, GREY) if o['sheet_of']
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
