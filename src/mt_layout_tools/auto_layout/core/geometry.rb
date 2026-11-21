# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # Phép chiếu trực giao + khử nét khuất cho hình học đã trích (Extractor). Không phụ thuộc SketchUp API.
      # Toạ độ hình chiếu: [u, v, sâu] mm; u sang phải, v hướng XUỐNG, sâu càng lớn càng gần người nhìn.
      #
      # Khử nét khuất có 3 mức, chạy lần lượt theo ngân sách thời gian (không bao giờ bỏ trống hình):
      #   Mức 1: mọi tam giác đều che (chính xác).
      #   Mức 2: chỉ các tam giác lớn che (tay nắm, ốc vít... không che) – cho phần cạnh còn lại khi Mức 1 quá lâu.
      #   Mức 3: phần cạnh còn lại vẽ thẳng từ hình học thật, chưa khử nét – ghi rõ "bản xem trước chưa đầy đủ".
      module Geometry
        module_function

        MM = 25.4
        EPS = 1.0e-9
        DEPTH_TOL = 0.12          # mm: tam giác phải nằm trước cạnh ít nhất chừng này mới che
        MIN_EDGE = 0.01           # mm thật: chỉ bỏ cạnh suy biến (song song hướng nhìn); giữ cung tròn chia mịn
        DEFAULT_COLOR = '#E6E6E6'.freeze
        BUDGET_L1 = 40.0          # giây cho mức 1 mỗi hình chiếu
        BUDGET_L2 = 40.0          # giây thêm cho mức 2
        L2_OCCLUDERS = 15_000     # số tam giác lớn nhất dùng ở mức 2
        MAX_FILL = 40_000         # quá số tam giác này thì không tô màu hình đó (tránh file quá nặng)

        VIEWS = {
          'front' => ['MẶT ĐỨNG',      ->(p) { [p[0], -p[2], -p[1]] }],
          'left'  => ['MẶT BÊN TRÁI',  ->(p) { [-p[1], -p[2], -p[0]] }],
          'right' => ['MẶT BÊN PHẢI',  ->(p) { [p[1], -p[2], p[0]] }],
          'back'  => ['MẶT SAU',       ->(p) { [-p[0], -p[2], p[1]] }],
          'top'   => ['MẶT BẰNG',      ->(p) { [p[0], -p[1], p[2]] }],
          'bottom' => ['MẶT ĐÁY',      ->(p) { [p[0], p[1], -p[2]] }],
          'open'  => ['MẶT ĐỨNG THÁO CÁNH', ->(p) { [p[0], -p[2], -p[1]] }],
          'iso'   => ['TRỤC ĐO', lambda do |p|
            [0.7071067811865476 * p[0] - 0.7071067811865476 * p[1],
             -(0.4082482904638631 * p[0] + 0.4082482904638631 * p[1] + 0.8164965809277261 * p[2]),
             -0.5773502691896258 * p[0] - 0.5773502691896258 * p[1] + 0.5773502691896258 * p[2]]
          end]
        }.freeze
        ISO_LIGHT = [-0.45, -0.75, 0.48].freeze

        # Hướng mặt trước: xoay quanh Z để mặt trước luôn quay về -Y trước khi chiếu.
        FRONTS = {
          '-Y' => ->(x, y) { [x, y] },
          '+Y' => ->(x, y) { [-x, -y] },
          '-X' => ->(x, y) { [-y, x] },
          '+X' => ->(x, y) { [y, -x] }
        }.freeze

        # edges: [[p, q]], triangles: [[a, b, c, mat_key]], materials: {key => {name, color}}, stats: Hash
        # edge_door / tri_door: mã cánh (chỉ số trong doors) của từng cạnh/tam giác, nil = không thuộc cánh.
        Capture = Struct.new(:name, :edges, :triangles, :materials, :stats, :edge_door, :tri_door, :doors) do
          def initialize(name, edges, triangles, materials, stats = {}, edge_door = nil, tri_door = nil, doors = [])
            super
          end

          def doors?
            !doors.nil? && !doors.empty?
          end

          # Bản sao KHÔNG có cánh (cho MẶT ĐỨNG THÁO CÁNH). Chỉ lọc dữ liệu đã đọc, không đụng file SKP.
          def without_doors
            e = []
            t = []
            edges.each_with_index { |x, i| e << x if edge_door.nil? || edge_door[i].nil? }
            triangles.each_with_index { |x, i| t << x if tri_door.nil? || tri_door[i].nil? }
            Capture.new(name, e, t, materials, stats.merge('without_doors' => true), nil, nil, [])
          end

          # Hộp bao từng cánh theo 1 phép chiếu (toạ độ hình chiếu trước khi trừ gốc).
          def door_boxes(fn)
            return [] unless doors?

            boxes = {}
            edges.each_with_index do |(a, b), i|
              d = edge_door[i]
              next if d.nil?

              [fn.call(a), fn.call(b)].each do |p|
                bx = (boxes[d] ||= [Float::INFINITY, -Float::INFINITY, Float::INFINITY, -Float::INFINITY])
                bx[0] = p[0] if p[0] < bx[0]
                bx[1] = p[0] if p[0] > bx[1]
                bx[2] = p[1] if p[1] < bx[2]
                bx[3] = p[1] if p[1] > bx[3]
              end
            end
            boxes.map { |d, bx| { 'id' => d, 'name' => doors[d]['name'], 'box' => bx } }
          end
        end

        # Ma trận đặt đối tượng trong toạ độ thế giới (tính cả khi đang mở edit một Group cha).
        def world_transform(model, inst)
          active_parent = model.active_entities.parent
          base = inst.parent == active_parent ? model.edit_transform : Geom::Transformation.new
          base * inst.transformation
        end

        def instance_name(inst)
          n = inst.name.to_s.strip
          n = inst.definition.name.to_s.strip if n.empty? && inst.respond_to?(:definition)
          n.empty? ? 'Chi tiết' : n[0, 100]
        end

        # ---------------- toán 2D ----------------
        def cross(a, b, p)
          (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
        end

        def depth_at(point, tri, area)
          a, b, c = tri
          wa = cross(b, c, point).fdiv(area)
          wb = cross(c, a, point).fdiv(area)
          wa * a[2] + wb * b[2] + (1 - wa - wb) * c[2]
        end

        # Khoảng tham số [t0, t1] của đoạn seg bị tam giác tri che (nil nếu không che).
        def hidden_interval(seg, tri, area)
          from, to = seg
          f = area < 0 ? -1 : 1
          low = 0.0
          high = 1.0
          i = 0
          while i < 3
            a = tri[i]
            b = tri[(i + 1) % 3]
            x = cross(a, b, from) * f
            y = cross(a, b, to) * f
            return nil if x < -EPS && y < -EPS

            if x < -EPS || y < -EPS
              t = x.fdiv(x - y)
              x < -EPS ? (low = t if t > low) : (high = t if t < high)
              return nil if high - low < EPS
            end
            i += 1
          end
          da = depth_at(from, tri, area) - from[2] - DEPTH_TOL
          db = depth_at(to, tri, area) - to[2] - DEPTH_TOL
          return nil if da <= 0 && db <= 0

          if (da <= 0) != (db <= 0)
            cut = da / (da - db)
            da <= 0 ? (low = cut if cut > low) : (high = cut if cut < high)
          end
          high - low >= EPS ? [low, high] : nil
        end

        # ---------------- lưới không gian ----------------
        # Chia mặt phẳng hình chiếu thành ô; mỗi ô giữ chỉ số tam giác phủ lên nó.
        class Grid
          def initialize(tris, l, t, w, h, count)
            n = [[Math.sqrt(count) * 1.5, 8].max, 256].min.ceil
            @tris = tris
            @cell = [[w, h].max / n, 1.0].max
            @l = l
            @t = t
            @nx = (w / @cell).floor + 1
            @ny = (h / @cell).floor + 1
            @cells = Array.new(@nx * @ny)
            @big = [] # tam giác phủ quá nhiều ô: luôn đem ra thử
          end

          # Thêm 1 tam giác (gọi dần từng cái để có thể dừng/tiếp giữa chừng).
          def insert(i)
            bb = @tris[i][2]
            x0, x1, y0, y1 = range(bb[0], bb[1], bb[2], bb[3])
            if (x1 - x0 + 1) * (y1 - y0 + 1) > 2048
              @big << i
              return
            end
            y0.upto(y1) do |cy|
              row = cy * @nx
              x0.upto(x1) { |cx| (@cells[row + cx] ||= []) << i }
            end
          end

          def range(l, r, t, b)
            [cl(((l - @l) / @cell).floor, @nx), cl(((r - @l) / @cell).floor, @nx),
             cl(((t - @t) / @cell).floor, @ny), cl(((b - @t) / @cell).floor, @ny)]
          end

          def cl(v, n)
            v.negative? ? 0 : (v >= n ? n - 1 : v)
          end

          def each_candidate(l, r, t, b)
            x0, x1, y0, y1 = range(l, r, t, b)
            y0.upto(y1) do |cy|
              row = cy * @nx
              x0.upto(x1) do |cx|
                c = @cells[row + cx]
                c&.each { |i| yield i }
              end
            end
            @big.each { |i| yield i }
          end
        end

        # ---------------- chiếu 1 hình ----------------
        # Bản đồng bộ (test, công cụ): chạy Projector tới khi xong.
        def project(cap, key, job = nil, budget = [BUDGET_L1, BUDGET_L2], vdef = nil)
          pr = Projector.new(cap, key, budget, vdef)
          ctx = job || NO_JOB
          nil until pr.call(ctx)
          pr.result
        end

        # Ngữ cảnh rỗng khi chạy đồng bộ: không bao giờ hết giờ.
        NO_JOB = Object.new
        def NO_JOB.time_up?
          false
        end

        def NO_JOB.progress(*)
          nil
        end

        # Dựng 1 hình chiếu dạng máy trạng thái: mỗi lần call xử lý tới khi job.time_up? rồi trả false,
        # lưu lại pha + chỉ số để lần sau làm tiếp. Trả true khi xong (kết quả ở #result).
        # Pha: :tris -> :edges -> :grid -> :hidden (<-> :grid khi đổi mức) -> :fill_sort -> :fill -> xong.
        class Projector
          attr_reader :result

          CHECK = 128 # số phần tử giữa 2 lần xem đồng hồ

          def initialize(cap, key, budget = [BUDGET_L1, BUDGET_L2], vdef = nil)
            @cap = cap
            @key = key
            @title, @fn = vdef || VIEWS.fetch(key)
            @budget = budget
            @phase = :tris
            @i = 0
            @tris = []
            @segs = []
            @seen = {}
            @l = @t = Float::INFINITY
            @r = @b = -Float::INFINITY
            @lines = []
            @notes = []
            @fills = []
            @level = 1
            @busy = 0.0 # thời gian xử lý thực (không tính lúc nhường SketchUp)
          end

          def now
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          def call(job)
            t0 = now
            @call_start = t0
            done = run(job)
            @busy += now - t0
            done
          end

          private

          def pause?(job, i)
            (i % CHECK).zero? && job.time_up?
          end

          def run(job)
            loop do
              case @phase
              when :tris then return false unless phase_tris(job)
              when :edges then return false unless phase_edges(job)
              when :grid then return false unless phase_grid(job)
              when :hidden then return false unless phase_hidden(job)
              when :fill_sort then phase_fill_sort
              when :fill then return false unless phase_fill(job)
              when :done then return true
              end
            end
          end

          def phase_tris(job)
            src = @cap.triangles
            n = src.length
            while @i < n
              if pause?(job, @i)
                job.progress("#{@title}: chiếu tam giác #{@i}/#{n}", 5)
                return false
              end
              tr = src[@i]
              @i += 1
              a = @fn.call(tr[0])
              b = @fn.call(tr[1])
              c = @fn.call(tr[2])
              area = Geometry.cross(a, b, c)
              next if area.abs < 1.0e-6

              xs = [a[0], b[0], c[0]]
              ys = [a[1], b[1], c[1]]
              @tris << [[a, b, c], area, [xs.min, xs.max, ys.min, ys.max], [a[2], b[2], c[2]].max, tr[3], tr]
            end
            @phase = :edges
            @i = 0
            true
          end

          def phase_edges(job)
            src = @cap.edges
            n = src.length
            while @i < n
              if pause?(job, @i)
                job.progress("#{@title}: chiếu cạnh #{@i}/#{n}", 10)
                return false
              end
              e = src[@i]
              @i += 1
              p = @fn.call(e[0])
              q = @fn.call(e[1])
              @l = p[0] if p[0] < @l
              @l = q[0] if q[0] < @l
              @r = p[0] if p[0] > @r
              @r = q[0] if q[0] > @r
              @t = p[1] if p[1] < @t
              @t = q[1] if q[1] < @t
              @b = p[1] if p[1] > @b
              @b = q[1] if q[1] > @b
              next if Math.hypot(q[0] - p[0], q[1] - p[1]) < MIN_EDGE

              k = [(p[0] * 20).round, (p[1] * 20).round, (q[0] * 20).round, (q[1] * 20).round]
              k = [k[2], k[3], k[0], k[1]] if k[2] < k[0] || (k[2] == k[0] && k[3] < k[1])
              prev = @seen[k]
              if prev
                # cạnh trùng sau khi chiếu: giữ cạnh gần người nhìn hơn
                @segs[prev] = [p, q] if p[2] + q[2] > @segs[prev][0][2] + @segs[prev][1][2]
                next
              end
              @seen[k] = @segs.length
              @segs << [p, q]
            end
            raise ArgumentError, "#{@title}: không có cạnh nào sau khi chiếu." if @segs.empty?

            @seen = nil
            @w = @r - @l
            @h = @b - @t
            @stamp = Array.new(@tris.length, -1)
            @occluders = (0...@tris.length).to_a
            @grid = Grid.new(@tris, @l, @t, @w, @h, @occluders.length)
            @gi = 0
            @phase = :grid
            @seg_i ||= 0
            true
          end

          def phase_grid(job)
            n = @occluders.length
            while @gi < n
              if pause?(job, @gi)
                job.progress("#{@title}: lập lưới tìm kiếm #{@gi}/#{n}", 12)
                return false
              end
              @grid.insert(@occluders[@gi])
              @gi += 1
            end
            @phase = :hidden
            @deadline ||= @busy + @budget[0]
            true
          end

          # Khử nét theo từng cạnh; một cạnh có rất nhiều tam giác ứng viên cũng được chia lô
          # (lưu @cur = ứng viên + vị trí + các khoảng bị che) để không lô nào kéo dài.
          def phase_hidden(job)
            n = @segs.length
            while @seg_i < n
              if job.time_up?
                job.progress("#{@title}: khử nét khuất #{@seg_i}/#{n} (mức #{@level})", 15 + 80.0 * @seg_i / n)
                return false
              end
              return switch_level if @level < 3 && @busy + (now - @call_start) > @deadline

              seg = @segs[@seg_i]
              if @level == 3
                @lines << [[seg[0][0] - @l, seg[0][1] - @t], [seg[1][0] - @l, seg[1][1] - @t]]
              else
                @cur ||= { cands: Geometry.candidates(seg, @tris, @grid, @stamp, @seg_i), ci: 0, hidden: [] }
                cands = @cur[:cands]
                while @cur[:ci] < cands.length
                  return false if (@cur[:ci] % 256).zero? && @cur[:ci].positive? && job.time_up?

                  tr = @tris[cands[@cur[:ci]]]
                  @cur[:ci] += 1
                  iv = Geometry.hidden_interval(seg, tr[0], tr[1])
                  @cur[:hidden] << iv if iv
                end
                Geometry.merge_visible(seg, @cur[:hidden]).each do |p, q|
                  @lines << [[p[0] - @l, p[1] - @t], [q[0] - @l, q[1] - @t]]
                end
                @cur = nil
              end
              @seg_i += 1
            end
            @phase = :fill_sort
            true
          end

          # Mức 1 quá lâu -> mức 2 (chỉ mặt lớn che, lập lưới mới) -> mức 3 (nét thật chưa khử).
          def switch_level
            @cur = nil # cạnh đang làm dở sẽ làm lại ở mức mới
            @level += 1
            n = @segs.length
            if @level == 2
              @occluders = (0...@tris.length).sort_by { |k| -@tris[k][1].abs }.first(L2_OCCLUDERS)
              @grid = Grid.new(@tris, @l, @t, @w, @h, @occluders.length)
              @gi = 0
              @deadline = @busy + @budget[1]
              @phase = :grid
              @notes << "#{@title}: mô hình nặng – #{@seg_i}/#{n} cạnh khử nét đầy đủ, phần còn lại chỉ dùng #{@occluders.length} mặt lớn để che."
            else
              @notes << "#{@title}: BẢN XEM TRƯỚC CHƯA ĐẦY ĐỦ – #{n - @seg_i}/#{n} cạnh chưa khử nét khuất (vẽ từ hình học thật)."
            end
            false
          end

          def phase_fill_sort
            if @tris.length > MAX_FILL
              @notes << "#{@title}: #{@tris.length} tam giác – không tô màu để file nhẹ."
              @src = []
            else
              shade = @key == 'iso'
              @src = @tris
              if shade && @tris.length < 4000
                lim = [@w, @h].max / 8.0
                @src = @tris.flat_map { |tr| Geometry.subdivide(tr, lim, 3) }
              end
              @src = @src.sort_by { |tr| tr[0][0][2] + tr[0][1][2] + tr[0][2][2] }
            end
            @i = 0
            @phase = :fill
          end

          def phase_fill(job)
            shade = @key == 'iso'
            n = @src.length
            while @i < n
              if pause?(job, @i)
                job.progress("#{@title}: tô màu #{@i}/#{n}", 97)
                return false
              end
              tr = @src[@i]
              @i += 1
              mats = @cap.materials
              color = tr[4] && mats[tr[4]] ? mats[tr[4]]['color'] : DEFAULT_COLOR
              color = Geometry.shaded(color, tr[5]) if shade
              @fills << [tr[0].map { |pt| [pt[0] - @l, pt[1] - @t] }, color]
            end
            stats = { 'tris' => @tris.length, 'edges_in' => @cap.edges.length, 'edges' => @segs.length,
                      'level' => @level, 'lines' => @lines.length, 'seconds' => @busy.round(2) }
            @result = { key: @key, name: @title, lines: @lines, fills: @fills, w: @w, h: @h, dims: @key != 'iso',
                        level: @level, notes: @notes, stats: stats, origin: [@l, @t], fn: @fn }
            @tris = @src = @stamp = @grid = nil # giải phóng bộ nhớ
            @phase = :done
            true
          end
        end

        # Ứng viên che cạnh: tam giác trong các ô lưới cạnh đi qua, nằm trước cạnh, hộp bao giao nhau.
        def candidates(seg, tris, grid, stamp, sid)
          a, b = seg
          l = a[0] < b[0] ? a[0] : b[0]
          r = a[0] < b[0] ? b[0] : a[0]
          t = a[1] < b[1] ? a[1] : b[1]
          btm = a[1] < b[1] ? b[1] : a[1]
          zmin = (a[2] < b[2] ? a[2] : b[2]) + DEPTH_TOL
          out = []
          grid.each_candidate(l, r, t, btm) do |k|
            next if stamp[k] == sid

            stamp[k] = sid
            tr = tris[k]
            next if tr[3] <= zmin # tam giác nằm hoàn toàn phía sau cạnh

            bb = tr[2]
            next if bb[0] > r || bb[1] < l || bb[2] > btm || bb[3] < t

            out << k
          end
          out
        end

        # Từ các khoảng bị che -> các đoạn còn thấy.
        def merge_visible(seg, hidden)
          a, b = seg
          return [[a, b]] if hidden.empty?

          hidden.sort_by!(&:first)
          vis = []
          cur = 0.0
          hidden.each do |u, v|
            next if v < cur

            vis << [cur, u] if u - cur > EPS
            cur = v if v > cur
          end
          vis << [cur, 1.0] if 1.0 - cur > EPS
          vis.map { |rg| rg.map { |k| [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k] } }
             .reject { |p, q| Math.hypot(q[0] - p[0], q[1] - p[1]) < 0.2 }
        end

        def visible_parts(seg, tris, grid, stamp, sid)
          hidden = candidates(seg, tris, grid, stamp, sid).filter_map { |k| hidden_interval(seg, tris[k][0], tris[k][1]) }
          merge_visible(seg, hidden)
        end

        # Chia nhỏ tam giác lớn để tô màu đúng trước/sau (chỉ dùng cho trục đo ít tam giác).
        def subdivide(tr, limit, depth)
          p, area, _bb, _z, mkey, raw = tr
          a, b, c = p
          long = [[a, b], [b, c], [c, a]].map { |x, y| Math.hypot(x[0] - y[0], x[1] - y[1]) }.max
          return [tr] if depth.zero? || long <= limit

          mid = ->(x, y) { x.zip(y).map { |m, n| (m + n) / 2.0 } }
          ab = mid.call(a, b)
          bc = mid.call(b, c)
          ca = mid.call(c, a)
          [[a, ab, ca], [ab, b, bc], [ca, bc, c], [ab, bc, ca]].flat_map do |q|
            subdivide([q, area / 4, nil, nil, mkey, raw], limit, depth - 1)
          end
        end

        def shaded(hex, tri)
          a, b, c = tri
          u = [b[0] - a[0], b[1] - a[1], b[2] - a[2]]
          v = [c[0] - a[0], c[1] - a[1], c[2] - a[2]]
          n = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
          len = Math.sqrt(n.sum { |x| x * x })
          return hex if len < EPS

          k = 0.72 + 0.28 * (n.zip(ISO_LIGHT).sum { |x, y| x * y } / len).abs
          rgb = hex[1..-1].scan(/../).map { |hh| (hh.to_i(16) * k).round.clamp(0, 255) }
          format('#%02X%02X%02X', *rgb)
        end
      end
    end
  end
end
