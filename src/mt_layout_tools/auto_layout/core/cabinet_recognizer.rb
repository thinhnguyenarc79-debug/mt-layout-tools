# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # UNIVERSAL CABINET RECOGNITION – nhận diện bộ phận tủ từ HÌNH HỌC THẬT, không phụ thuộc kiểu bếp I/L/U.
      #
      # Chỉ chạy cho bộ phận CHƯA có vai trò chắc chắn (gán tay / thuộc tính / Tag / tên / vật liệu đã xử lý trước).
      # Mọi kết quả ở đây là ĐỀ XUẤT (sure = false) kèm độ tin cậy + lý do: không tự dùng để bỏ cánh / ghi DIM cánh
      # cho tới khi người dùng xác nhận (nút "Xác nhận" hàng loạt).
      #
      # Cách làm (không giả định hướng mặt trước chung cho cả model):
      #  1. Mỗi bộ phận -> hộp bao định hướng (OBB) từ pháp tuyến mặt thật => đúng cả khi tủ xoay góc bất kỳ, mirror.
      #  2. Phân loại hình dạng: tấm (dày <= 45), chi tiết nhỏ (<= 300), khối.
      #  3. Quan hệ tiếp xúc giữa các bộ phận (tách trục SAT, dung sai 3 mm): tiếp xúc qua MẶT RỘNG (phía +/-) hay qua CẠNH.
      #  4. Tấm đứng "vỏ ngoài": một phía áp vào thân tủ, phía kia trống. Cánh = vỏ ngoài + (tay nắm ở phía trống
      #     hoặc có tấm cùng mặt phẳng xếp hàng với khe hở - dãy cánh). Không coi là cánh chỉ vì là tấm đứng.
      #  5. Lan truyền cục bộ (chung bộ phận thân tủ): tấm vỏ cùng hướng với cánh chắc -> cánh; ngược hướng -> hậu;
      #     vuông góc -> vách hông lộ ra. Mỗi cụm tủ có hướng riêng (bếp chữ L/U, đảo, tủ xoay).
      #  6. Tấm nằm: nóc / đáy / đợt theo vị trí trên các vách đỡ nó. Chi tiết nhỏ trên mặt ngoài cánh -> tay nắm.
      module CabinetRecognizer
        TOL = 3.0
        PANEL_T = 45.0
        SMALL = 300.0
        THIN = 10.0
        DRAWER_H = 320.0

        Info = Struct.new(:id, :axes, :lo, :hi, :ext, :ti, :n, :t, :dims, :kind, :orient, :box, :corners, :up, :wi, :hgt, :wid)

        module_function

        def vdot(a, b)
          a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
        end

        def vcross(a, b)
          [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
        end

        def unit(a)
          l = Math.sqrt(vdot(a, a))
          l < 1.0e-12 ? nil : a.map { |x| x / l }
        end

        # ---------- 1. hộp bao định hướng ----------
        def info(id, pts, tris)
          return nil if pts.empty?

          buckets = {}
          tris.each do |a, b, c|
            n = vcross([b[0] - a[0], b[1] - a[1], b[2] - a[2]], [c[0] - a[0], c[1] - a[1], c[2] - a[2]])
            ar = Math.sqrt(vdot(n, n))
            next if ar < 1.0e-9

            u = n.map { |x| x / ar }
            k = u.find { |x| x.abs > 1.0e-6 }
            u = u.map { |x| -x } if k && k.negative?
            key = u.map { |x| (x * 40).round }
            bk = (buckets[key] ||= [[0.0, 0.0, 0.0], 0.0])
            bk[0] = [bk[0][0] + u[0] * ar, bk[0][1] + u[1] * ar, bk[0][2] + u[2] * ar]
            bk[1] += ar
          end
          ranked = buckets.values.sort_by { |_, ar| -ar }.map { |v, _| unit(v) }.compact
          a0 = ranked[0]
          a1 = a0 && ranked.find { |v| vdot(v, a0).abs < 0.15 }
          if a0.nil?
            a0 = [1.0, 0.0, 0.0]
            a1 = [0.0, 1.0, 0.0]
          elsif a1.nil?
            w = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]].min_by { |x| vdot(x, a0).abs }
            a1 = unit(vcross(vcross(a0, w), a0)) || [0.0, 1.0, 0.0]
          end
          a2 = unit(vcross(a0, a1))
          a1 = unit(vcross(a2, a0))
          axes = [a0, a1, a2]
          lo = [Float::INFINITY] * 3
          hi = [-Float::INFINITY] * 3
          box = [[Float::INFINITY, -Float::INFINITY], [Float::INFINITY, -Float::INFINITY], [Float::INFINITY, -Float::INFINITY]]
          pts.each do |p|
            3.times do |k|
              d = vdot(p, axes[k])
              lo[k] = d if d < lo[k]
              hi[k] = d if d > hi[k]
              box[k][0] = p[k] if p[k] < box[k][0]
              box[k][1] = p[k] if p[k] > box[k][1]
            end
          end
          ext = (0..2).map { |k| hi[k] - lo[k] }
          ti = (0..2).min_by { |k| ext[k] }
          dims = ext.sort
          kind = if dims[2] <= SMALL then :small
                 elsif dims[0] <= PANEL_T && dims[1] >= 3 * dims[0] && dims[1] >= 80 then :panel
                 else :bulk
                 end
          n = axes[ti]
          orient = if kind != :panel then nil
                   elsif n[2].abs < 0.35 then :v
                   elsif n[2].abs > 0.85 then :h
                   else :slope
                   end
          corners = [lo[0], hi[0]].product([lo[1], hi[1]], [lo[2], hi[2]]).map do |c0, c1, c2|
            (0..2).map { |k| axes[0][k] * c0 + axes[1][k] * c1 + axes[2][k] * c2 }
          end
          inplane = (0..2).to_a - [ti]
          up = inplane.max_by { |k| axes[k][2].abs }
          wi = (inplane - [up]).first
          Info.new(id, axes, lo, hi, ext, ti, n, dims[0], dims, kind, orient, box, corners, up, wi, ext[up], ext[wi])
        end

        def proj(corners, ax)
          mn = Float::INFINITY
          mx = -Float::INFINITY
          corners.each do |c|
            d = vdot(c, ax)
            mn = d if d < mn
            mx = d if d > mx
          end
          [mn, mx]
        end

        # khe hở lớn nhất theo các trục tách (OBB của 2 bộ phận); <= TOL là tiếp xúc
        def gap(a, b)
          (a.axes + b.axes).map do |ax|
            p = proj(a.corners, ax)
            q = proj(b.corners, ax)
            [q[0] - p[1], p[0] - q[1]].max
          end.max
        end

        # Vị trí của b so với tấm a: +1 / -1 = nằm hẳn về 1 phía mặt rộng, 0 = ngang cạnh. broad = chồng lên mặt rộng.
        def side(a, b)
          al = a.lo[a.ti]
          ah = a.hi[a.ti]
          bl, bh = proj(b.corners, a.n)
          s = if bl >= ah - TOL then 1
              elsif bh <= al + TOL then -1
              else 0
              end
          ov = ((0..2).to_a - [a.ti]).map do |k|
            q = proj(b.corners, a.axes[k])
            [a.hi[k], q[1]].min - [a.lo[k], q[0]].max
          end
          [s, s != 0 && ov.all? { |o| o > 5 }]
        end

        def parallel?(a, b)
          vdot(a.n, b.n).abs > 0.98
        end

        def coplanar?(a, b)
          parallel?(a, b) && (proj(b.corners, a.n).sum / 2 - (a.lo[a.ti] + a.hi[a.ti]) / 2).abs <= 4 && (a.t - b.t).abs <= 4
        end

        # ---------- 3. tiếp xúc ----------
        def contacts(infos)
          list = infos.compact.sort_by { |i| i.box[0][0] }
          out = Hash.new { |h, k| h[k] = [] }
          list.each_with_index do |a, x|
            ((x + 1)...list.length).each do |y|
              b = list[y]
              break if b.box[0][0] > a.box[0][1] + TOL
              next if b.box[1][0] > a.box[1][1] + TOL || a.box[1][0] > b.box[1][1] + TOL
              next if b.box[2][0] > a.box[2][1] + TOL || a.box[2][0] > b.box[2][1] + TOL
              next if gap(a, b) > TOL

              out[a.id] << b.id
              out[b.id] << a.id
            end
          end
          out
        end

        # parts: [{ 'id','role','sure','source', 'name' }] (đã có vai trò chắc chắn thì giữ nguyên)
        # geo: { id => [points[], triangles[]] }; mats: { id => tên vật liệu chính }
        def run(parts, geo, mats = {})
          infos = parts.map { |pt| g = geo[pt['id']]; g ? info(pt['id'], g[0], g[1]) : nil }
          by = infos.compact.to_h { |i| [i.id, i] }
          con = contacts(infos)
          role = {}
          why = {}
          conf = {}
          parts.each { |pt| role[pt['id']] = pt['role'] if pt['sure'] && pt['role'] }
          fixed = role.keys.to_h { |k| [k, true] }
          set = lambda do |id, r, c, w|
            return if fixed[id]

            role[id] = r
            conf[id] = c
            why[id] = w
          end
          zmin = infos.compact.map { |i| i.box[2][0] }.min || 0.0
          big = ->(id) { by[id] && by[id].kind != :small }

          # ---- 4. đặc trưng từng tấm đứng ----
          feat = {}
          infos.compact.each do |a|
            next unless a.kind == :panel && a.orient == :v

            f = { plus: [], minus: [], edge: [], small: { 1 => [], -1 => [] }, sib: [] }
            con[a.id].each do |j|
              b = by[j]
              s, broad = side(a, b)
              if b.kind == :small
                f[:small][s] << j if s != 0
              elsif s == 1 && broad then f[:plus] << j
              elsif s == -1 && broad then f[:minus] << j
              elsif s.zero? && !(b.kind == :panel && coplanar?(a, b)) then f[:edge] << j
              end
            end
            f[:ext] = if f[:plus].empty? && !f[:minus].empty? then 1
                      elsif f[:minus].empty? && !f[:plus].empty? then -1
                      end
            feat[a.id] = f
          end
          # dãy tấm cùng mặt phẳng (dãy cánh): gom theo mặt phẳng
          planes = Hash.new { |h, k| h[k] = [] }
          feat.each_key do |id|
            a = by[id]
            n = a.n.dup
            k = n.find { |x| x.abs > 1.0e-6 }
            n = n.map { |x| -x } if k && k.negative?
            off = vdot(n, a.corners.transpose.map { |c| c.sum / 8.0 })
            planes[[n.map { |x| (x * 50).round }, (off / 6.0).round]] << id
          end
          planes.each do |(nk, ok), ids|
            near = ids + [-1, 1].flat_map { |d| planes.fetch([nk, ok + d], []) }
            ids.each do |id|
              a = by[id]
              feat[id][:sib] = near.uniq.select do |j|
                next false if j == id || !coplanar?(a, by[j]) || feat[j][:ext].nil? || feat[id][:ext].nil?

                same = vdot(a.n, by[j].n).positive? ? feat[j][:ext] == feat[id][:ext] : feat[j][:ext] != feat[id][:ext]
                same && (vdot(a.corners.transpose.map { |c| c.sum / 8.0 }, a.axes[a.wi]) -
                         vdot(by[j].corners.transpose.map { |c| c.sum / 8.0 }, a.axes[a.wi])).abs < 2500
              end
            end
          end

          # ---- 5a. cánh chắc theo hình học ----
          door_like = {}
          feat.each do |id, f|
            a = by[id]
            next if fixed[id] && role[id] != 'door'

            if fixed[id]
              door_like[id] = f[:ext] || 0
              next
            end
            next unless f[:ext] && a.t > THIN && f[:edge].empty?
            next if a.box[2][1] - zmin <= 160 && a.hgt <= 160 # chân / len tủ

            handle = !f[:small][f[:ext]].empty?
            sib = !f[:sib].empty?
            next unless handle || sib

            c = handle && sib ? 0.9 : 0.8
            set.call(id, 'door', c, [handle ? 'có tay nắm ở mặt ngoài' : nil, sib ? "dãy #{f[:sib].length + 1} tấm cùng mặt phẳng" : nil,
                                     'áp vào thân tủ 1 phía'].compact.join(', '))
            door_like[id] = f[:ext]
          end

          # ---- 5a'. cánh lọt lòng: mặt ngoài phẳng với đầu các tấm khung quanh nó + tay nắm ----
          feat.each do |id, f|
            next if role[id] || fixed[id] || f[:ext].nil? || f[:edge].empty?

            a = by[id]
            next if a.t <= THIN || f[:small][f[:ext]].empty?

            face = f[:ext].positive? ? a.hi[a.ti] : a.lo[a.ti]
            flush = f[:edge].all? do |j|
              b = by[j]
              next false if parallel?(a, b)

              q = proj(b.corners, a.n)
              ((f[:ext].positive? ? q[1] : q[0]) - face).abs <= TOL + 1
            end
            next unless flush

            set.call(id, 'door', 0.7, 'cánh lọt lòng: phẳng với khung tủ, có tay nắm mặt ngoài')
            door_like[id] = f[:ext]
          end

          # ---- 5a''. cánh lùa: 2 tấm song song so le (chồng 1 phần theo chiều rộng, lệch nhau <= 30 mm) ----
          feat.each do |id, f|
            next if role[id] || fixed[id]

            a = by[id]
            (f[:plus] + f[:minus]).each do |j|
              b = by[j]
              next unless feat[j] && parallel?(a, b) && a.t > THIN && b.t > THIN && (a.hgt - b.hgt).abs <= 0.1 * a.hgt
              next if a.hgt < 600

              qa = proj(a.corners, a.axes[a.wi])
              qb = proj(b.corners, a.axes[a.wi])
              ov = [qa[1], qb[1]].min - [qa[0], qb[0]].max
              narrow = [qa[1] - qa[0], qb[1] - qb[0]].min
              next unless ov.positive? && ov < 0.6 * narrow && ov > 10

              [id, j].each do |k|
                next if fixed[k]

                set.call(k, 'door', 0.7, 'cánh lùa: 2 tấm song song so le')
                door_like[k] = feat[k][:ext] || 0
              end
            end
          end

          # ---- 5b. lan truyền cục bộ cho tấm vỏ còn lại ----
          feat.each do |id, f|
            next if role[id] || fixed[id]

            a = by[id]
            if f[:ext]
              if a.box[2][1] - zmin <= 160 && a.hgt <= 160
                set.call(id, 'accessory', 0.6, 'tấm chân/len chân tủ')
                next
              end
              anchor = nil
              (f[:plus] + f[:minus] + f[:edge]).each do |j|
                (con[j] + [j]).each do |k|
                  next unless door_like[k] && k != id

                  anchor = k
                  break
                end
                break if anchor
              end
              if anchor
                d = by[anchor]
                if parallel?(a, d)
                  ext_same = vdot(a.n, d.n).positive? ? door_like[anchor] == f[:ext] : door_like[anchor] != f[:ext]
                  if ext_same && f[:edge].empty? && a.t > THIN
                    set.call(id, 'door', 0.7, 'cùng hướng với cánh bên cạnh, áp thân tủ 1 phía')
                    door_like[id] = f[:ext]
                  elsif !ext_same
                    set.call(id, 'back', 0.75, 'đối diện cánh qua thân tủ')
                  end
                else
                  set.call(id, 'side', 0.75, 'vuông góc với cánh – vách hông lộ ngoài')
                end
              elsif a.t <= THIN
                set.call(id, 'back', 0.6, 'tấm mỏng phủ một phía thân tủ')
              end
              set.call(id, 'unknown', 0.0, 'tấm đứng ngoài cùng – chưa đủ dữ liệu để biết là cánh hay vách') unless role[id]
            elsif a.hgt <= 160 && a.box[2][1] - zmin <= 220
              set.call(id, 'accessory', 0.6, 'tấm chân/len chân tủ')
            elsif a.t <= THIN && a.dims[1] >= 200
              set.call(id, 'back', 0.7, 'tấm mỏng kẹp giữa thân tủ')
            elsif !f[:plus].empty? && !f[:minus].empty?
              set.call(id, 'side', 0.8, 'tấm đứng nối thân tủ cả hai phía')
            else
              set.call(id, 'unknown', 0.0, 'tấm đứng không đủ quan hệ để phân loại')
            end
          end

          # ---- ngăn kéo: mặt ngăn kéo thấp + hộp ngăn kéo phía sau ----
          door_like.keys.each do |id|
            a = by[id]
            next if fixed[id] || role[id] != 'door' || a.hgt > DRAWER_H || a.wid < a.hgt

            set.call(id, 'drawer', conf[id], "mặt ngăn kéo (cao #{a.hgt.round} mm), " + why[id].to_s)
            # hộp ngăn kéo: các tấm nối với mặt ngăn kéo (trực tiếp hoặc qua nhau), nằm trong chiều cao mặt,
            # và KHÔNG chạm thân tủ (vách, nóc, đáy...) -> thuộc ngăn kéo
            zl = a.box[2][0] - 30
            zh = a.box[2][1] + 10
            box = []
            queue = [id]
            until queue.empty?
              cur = queue.shift
              con[cur].each do |j|
                b = by[j]
                next if j == id || box.include?(j) || fixed[j] || b.kind == :small || door_like[j]
                next unless b.box[2][0] >= zl && b.box[2][1] <= zh

                box << j
                queue << j
              end
            end
            loop do
              keep = box.select { |j| (con[j].select { |k| big.call(k) } - box - [id]).empty? }
              break if keep.length == box.length

              box = keep
            end
            box.each { |j| set.call(j, 'drawer', 0.7, 'thuộc hộp ngăn kéo (chỉ nối với mặt ngăn kéo)') }
          end

          # ---- 6. tấm nằm: nóc / đáy / đợt ----
          infos.compact.each do |a|
            next unless a.kind == :panel && a.orient == :h
            next if fixed[a.id] || role[a.id] == 'drawer'

            sup = con[a.id].select { |j| by[j].kind == :panel && by[j].orient == :v && !%w[door drawer back].include?(role[j]) }
            if sup.empty?
              below = con[a.id].select { |j| by[j].orient == :h && by[j].box[2][1] <= a.box[2][0] + TOL }
              if below.empty?
                set.call(a.id, 'unknown', 0.0, 'tấm nằm không tựa vào vách nào')
              else
                set.call(a.id, 'top', 0.5, 'tấm nằm phủ trên tấm nằm khác (mặt bàn/nóc phủ)')
              end
              next
            end
            votes = Hash.new(0)
            sup.each do |s|
              b = by[s]
              hs = con[s].select { |j| by[j].kind == :panel && by[j].orient == :h && role[j] != 'drawer' }
              hs |= [a.id]
              zs = hs.map { |j| by[j].box[2][0] }
              if a.box[2][0] >= zs.max - 1 && a.box[2][1] >= b.box[2][1] - 30 then votes['top'] += 1
              elsif a.box[2][0] <= zs.min + 1 && a.box[2][0] <= b.box[2][0] + 160 then votes['bottom'] += 1
              else votes['shelf'] += 1
              end
            end
            r, n = votes.max_by { |_, v| v }
            set.call(a.id, r, 0.75, { 'top' => 'tấm nằm trên cùng của các vách đỡ', 'bottom' => 'tấm nằm dưới cùng của các vách đỡ',
                                      'shelf' => 'tấm nằm giữa các vách đỡ' }[r] + " (#{n}/#{sup.length} vách)")
          end

          # ---- chi tiết nhỏ: tay nắm / phụ kiện ----
          infos.compact.each do |a|
            next unless a.kind == :small && !fixed[a.id]

            host = con[a.id].find do |j|
              next false unless door_like[j] || %w[door drawer].include?(role[j])

              d = by[j]
              ext = door_like[j] || feat.dig(j, :ext)
              ext && side(d, a)[0] == ext
            end
            if host
              set.call(a.id, 'handle', 0.8, 'chi tiết nhỏ gắn mặt ngoài cánh/ngăn kéo')
            else
              set.call(a.id, 'accessory', 0.5, 'chi tiết nhỏ')
            end
          end

          # ---- còn lại ----
          parts.each do |pt|
            id = pt['id']
            next if fixed[id] || role[id]

            a = by[id]
            msg = if a.nil? then 'không có hình học'
                  elsif a.kind == :bulk then 'khối đặc / cụm phức tạp'
                  else 'tấm nghiêng'
                  end
            set.call(id, 'unknown', 0.0, msg)
          end

          # kính: vật liệu kính mà không phải cánh -> kính/gương
          parts.each do |pt|
            id = pt['id']
            next if fixed[id]
            next unless mats[id].to_s =~ /k[íi]nh|glass|g[ươ]+ng|mirror/i

            if role[id] == 'door'
              why[id] = "cánh kính – #{why[id]}"
            else
              set.call(id, 'glass', 0.7, "vật liệu \"#{mats[id]}\"")
            end
          end

          parts.each do |pt|
            id = pt['id']
            next if fixed[id]

            pt['role'] = role[id] || 'unknown'
            pt['confidence'] = (conf[id] || 0.0).round(2)
            pt['source'] = "hình học: #{why[id]}"
            pt['sure'] = false
          end
          parts
        end
      end
    end
  end
end
