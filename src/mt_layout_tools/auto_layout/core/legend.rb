# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # BẢNG CHÚ THÍCH VẬT LIỆU (v2.18) – chỉ là chú giải 2D trên bản vẽ.
      # Mọi chỉnh sửa (mã, tên hiển thị, ghi chú, ẩn dòng, thứ tự, màu ô mẫu, cỡ chữ, vị trí...) lưu ở
      # page['legend'], KHÔNG BAO GIỜ sửa material thật trong model SketchUp.
      #
      # page['legend'] = { 'hidden_sheets' => [chỉ số tờ ẩn bảng], 'x','y' (mm giấy, góc trên-trái; nil = tự đặt),
      #   'locked', 'cols' (1-4), 'size' (cỡ chữ), 'gap' (khoảng cách dòng), 'width' (độ rộng 1 cột),
      #   'order' => [tên material...], 'rows' => { tên material => { 'code','name','note','color','hidden' } } }
      module Legend
        module_function

        DEF_SIZE = 2.2
        DEF_GAP = 4.2
        DEF_WIDTH = 62.0
        MAX_ROWS = 60

        def num(x, lo, hi)
          ManualDim.num(x, lo, hi)
        end

        def str(x, max = 80)
          x.to_s.gsub(/[\u0000-\u001F]/, ' ').strip[0, max]
        end

        def clean(raw)
          return {} unless raw.is_a?(Hash)

          out = {}
          hs = Array(raw['hidden_sheets']).map(&:to_i).select { |i| i >= 0 && i < 50 }.uniq.sort
          out['hidden_sheets'] = hs unless hs.empty?
          %w[x y].each { |k| out[k] = num(raw[k], -50, 2000) unless raw[k].nil? || num(raw[k], -50, 2000).nil? }
          unless out.key?('x') && out.key?('y')
            out.delete('x')
            out.delete('y')
          end
          out['locked'] = true if raw['locked'] == true
          out['cols'] = raw['cols'].to_i.clamp(1, 4) if raw['cols'].to_i > 1
          out['size'] = num(raw['size'], 1.5, 6) if raw['size'] && num(raw['size'], 1.5, 6)
          out['gap'] = num(raw['gap'], 3, 12) if raw['gap'] && num(raw['gap'], 3, 12)
          out['width'] = num(raw['width'], 30, 200) if raw['width'] && num(raw['width'], 30, 200)
          ord = Array(raw['order']).map { |n| str(n, 120) }.reject(&:empty?).uniq.first(500)
          out['order'] = ord unless ord.empty?
          rows = {}
          (raw['rows'].is_a?(Hash) ? raw['rows'] : {}).first(500).each do |k, r|
            next unless r.is_a?(Hash)

            c = {}
            %w[code name note].each { |f| (t = str(r[f], f == 'note' ? 120 : 60)).empty? || c[f] = t }
            c['color'] = r['color'].to_s.upcase if r['color'].to_s =~ /\A#[0-9A-Fa-f]{6}\z/
            c['hidden'] = true if r['hidden'] == true
            rows[str(k, 120)] = c unless c.empty?
          end
          out['rows'] = rows unless rows.empty?
          out
        end

        # Danh sách dòng theo thứ tự hiển thị (gồm cả dòng ẩn để giao diện bật lại). Mã mặc định MAT-xx đánh theo
        # thứ tự đầy đủ nên ẩn 1 dòng không làm các dòng khác đổi mã. Mã người dùng sửa mà trùng -> dòng sau dùng
        # mã mặc định (không bao giờ có 2 dòng cùng mã).
        def rows(mats, cfg)
          cfg ||= {}
          by = {}
          Array(mats).each { |m| by[m['name'].to_s] ||= m }
          ord = Array(cfg['order']).select { |k| by.key?(k) }
          ord += by.keys - ord
          used = {}
          ord.first(MAX_ROWS).each_with_index.map do |k, i|
            m = by[k]
            r = (cfg['rows'] || {})[k] || {}
            code = r['code'].to_s
            code = format('MAT-%02d', i + 1) if code.empty? || used[code.upcase]
            code = "#{code}-#{i + 1}" if used[code.upcase]
            used[code.upcase] = true
            { 'key' => k, 'code' => code, 'name' => r['name'] || m['name'].to_s, 'note' => r['note'].to_s,
              'color' => r['color'] || m['color'], 'orig_name' => m['name'].to_s, 'orig_color' => m['color'],
              'orig_code' => format('MAT-%02d', i + 1), 'hidden' => r['hidden'] == true,
              'edited' => !(r['code'] || r['name'] || r['note'] || r['color']).nil? }
          end
        end

        def metrics(cfg, n)
          cfg ||= {}
          cols = (cfg['cols'] || 1).to_i.clamp(1, 4)
          gap = (cfg['gap'] || DEF_GAP).to_f
          per = (n.to_f / cols).ceil
          [cols, gap, (cfg['width'] || DEF_WIDTH).to_f, (cfg['size'] || DEF_SIZE).to_f, per]
        end

        # Kích thước [w, h] (mm giấy) của bảng với các dòng đang hiện.
        def size(cfg, n)
          return [0, 0] if n.zero?

          cols, gap, width, _sz, per = metrics(cfg, n)
          [cols * width, per * gap]
        end

        def overlap?(a, b)
          a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3]
        end

        # Vị trí [x, y]: người dùng đã đặt -> giữ nguyên (không bao giờ tự nhảy). Tự đặt -> góc dưới-phải vùng vẽ
        # như trước; nếu che hình nào thì thử các góc khác còn trống (không che TRỤC ĐO hay hình khác).
        def place(cfg, w, h, area, boxes)
          return [cfg['x'].to_f, cfg['y'].to_f, false] if cfg && cfg['x'] && cfg['y']

          cands = [[area[2] - w, area[3] - h], [area[0], area[3] - h], [area[2] - w, area[1]], [area[0], area[1]]]
          hit = ->(c) { boxes.values.any? { |b| overlap?([c[0], c[1], w, h], b) } }
          c = cands.find { |cc| !hit.call(cc) }
          c ? [c[0], c[1], false] : [cands[0][0], cands[0][1], true]
        end

        # Vẽ bảng (nhóm "legend" để chọn/kéo trên giấy). Trả về thông tin cho giao diện.
        def draw(cv, mats, cfg, area, boxes, sheet)
          cfg ||= {}
          all = rows(mats, cfg)
          vis = all.reject { |r| r['hidden'] }
          hidden = cfg['hidden_all'] == true || Array(cfg['hidden_sheets']).include?(sheet.to_i)
          w, h = size(cfg, vis.length)
          info = { 'rows' => all, 'hidden' => hidden, 'hidden_all' => cfg['hidden_all'] == true, 'custom' => !cfg['x'].nil?, 'locked' => cfg['locked'] == true }
          return info if vis.empty? || hidden

          x, y, blocked = place(cfg, w, h, area, boxes)
          cols, gap, width, sz, per = metrics(cfg, vis.length)
          cv.group('class' => 'legend', 'data-sheet' => sheet.to_s) do
            cv.rect(x - 1, y - 1, w + 1, h + 1, 'transparent', nil) if cv.fmt == :svg # vùng bấm (không in ra PDF)
            vis.each_with_index do |r, i|
              cx = x + (i / per) * width
              yy = y + (i % per) * gap
              bh = [gap * 0.72, 3.0].min
              cv.rect(cx, yy, bh * 2, bh, r['color'], '#555555')
              label = "#{r['code']}: #{r['name']}"
              label += " – #{r['note']}" unless r['note'].empty?
              cv.text_left(cv.fit(label, sz, width - bh * 2 - 2.5), cx + bh * 2 + 1.5, yy + bh / 2, sz, Sheet::INK)
            end
          end
          info.merge('box' => [x, y, w, h].map { |n| n.round(2) }, 'cols' => cols,
                     'covers' => boxes.select { |_, b| overlap?([x, y, w, h], b) }.keys, 'blocked' => blocked)
        end
      end
    end
  end
end
