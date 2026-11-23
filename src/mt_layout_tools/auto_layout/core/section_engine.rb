# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # MẶT CẮT THẬT: giao mặt phẳng cắt với hình học thực của model (tam giác của từng Face sau biến đổi).
      #  - Phần vật thể nằm phía hướng nhìn được giữ lại (cắt bỏ phần trước mặt phẳng), khử nét khuất như hình chiếu thường.
      #  - Giao tuyến mặt phẳng × tam giác tạo nét cắt (nét đậm); các vòng kín được tô hatch.
      # Toạ độ: mm, trục cục bộ của model (X rộng, Y sâu, Z cao), đã xoay theo hướng mặt trước.
      module SectionEngine
        module_function

        AXES = { 'x' => 0, 'y' => 1, 'z' => 2 }.freeze
        TOL = 1.0e-6

        # Hướng nhìn của mặt cắt: [tên hình chiếu dùng phép chiếu, dấu phía giữ lại]
        #  x, dir +1: nhìn về +X (từ trái sang), giữ phần x >= pos — như MẶT BÊN TRÁI
        #  x, dir -1: nhìn về -X, giữ x <= pos — như MẶT BÊN PHẢI
        #  z, dir -1: nhìn từ trên xuống, giữ z <= pos — như MẶT BẰNG
        #  z, dir +1: nhìn từ dưới lên, giữ z >= pos — như MẶT ĐÁY
        #  y, dir +1: nhìn từ trước ra sau, giữ y >= pos — như MẶT ĐỨNG
        #  y, dir -1: nhìn từ sau, giữ y <= pos — như MẶT SAU
        BASE = { ['x', 1] => 'left', ['x', -1] => 'right', ['z', -1] => 'top', ['z', 1] => 'bottom',
                 ['y', 1] => 'front', ['y', -1] => 'back' }.freeze

        def key(sec)
          "sec:#{sec['label']}"
        end

        def base_view(sec)
          BASE.fetch([sec['axis'], sec['dir'].to_i.positive? ? 1 : -1])
        end

        # Khoảng cách có dấu tới mặt phẳng, dương = phía được giữ.
        def side(p, ax, pos, dir)
          (p[ax] - pos) * dir
        end

        def lerp(a, b, t)
          [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]
        end

        # Bản đồng bộ (test): chạy SectionBuilder tới khi xong.
        def clip(cap, sec, _job = nil)
          sb = SectionBuilder.new(cap, sec)
          nil until sb.clip_step(Geometry::NO_JOB)
          [sb.clipped, sb.cuts]
        end

        def project(cap, sec, _job = nil)
          sb = SectionBuilder.new(cap, sec)
          nil until sb.call(Geometry::NO_JOB)
          sb.result
        end

        # Dựng MẶT CẮT dạng máy trạng thái: :clip_edges -> :clip_tris -> :project (Projector) -> xong.
        class SectionBuilder
          attr_reader :result, :clipped, :cuts

          def initialize(cap, sec)
            @cap = cap
            @sec = sec
            @ax = AXES.fetch(sec['axis'])
            @pos = sec['pos'].to_f
            @dir = sec['dir'].to_i.positive? ? 1 : -1
            @clipped = Geometry::Capture.new(cap.name, [], [], cap.materials, {})
            # tô mặt: dùng lại cây BSP của bản trích gốc + cắt theo mặt phẳng (giữ phía dot(n, p) >= d)
            if cap.respond_to?(:fill_tree)
              n = [0.0, 0.0, 0.0]
              n[@ax] = @dir.to_f
              @clipped.fill_parent = cap
              @clipped.fill_clip = [n, @pos * @dir]
            end
            @cuts = []
            @cut_mats = [] # vật liệu của mặt sinh ra từng đoạn nét cắt -> hatch theo vật liệu
            @phase = :clip_edges
            @i = 0
          end

          def label
            "MẶT CẮT #{@sec['label']}-#{@sec['label']}"
          end

          def call(job)
            loop do
              case @phase
              when :clip_edges, :clip_tris
                return false unless clip_step(job)

                start_projection
              when :project
                return false unless @proj.call(job)

                finalize
                return true
              when :done then return true
              end
            end
          end

          # true khi đã cắt xong cả cạnh lẫn tam giác.
          def clip_step(job)
            if @phase == :clip_edges
              src = @cap.edges
              while @i < src.length
                if (@i % 256).zero? && job.time_up?
                  job.progress("#{label}: cắt cạnh #{@i}/#{src.length}", 5)
                  return false
                end
                a, b = src[@i]
                @i += 1
                sa = SectionEngine.side(a, @ax, @pos, @dir)
                sb = SectionEngine.side(b, @ax, @pos, @dir)
                next if sa < -TOL && sb < -TOL

                if sa >= -TOL && sb >= -TOL
                  @clipped.edges << [a, b]
                else
                  m = SectionEngine.lerp(a, b, sa / (sa - sb))
                  @clipped.edges << (sa >= -TOL ? [a, m] : [m, b])
                end
              end
              @phase = :clip_tris
              @i = 0
            end
            src = @cap.triangles
            while @i < src.length
              if (@i % 256).zero? && job.time_up?
                job.progress("#{label}: giao mặt phẳng cắt #{@i}/#{src.length}", 8)
                return false
              end
              tr = src[@i]
              @i += 1
              clip_tri(tr)
            end
            @phase = :clip_done
            true
          end

          def clip_tri(tr)
            pts = tr[0, 3]
            s = pts.map { |p| SectionEngine.side(p, @ax, @pos, @dir) }
            return if s.all? { |v| v < -TOL }

            if s.all? { |v| v >= -TOL }
              @clipped.triangles << tr
              return
            end
            # Sutherland–Hodgman với 1 mặt phẳng; 2 điểm giao là 1 đoạn nét cắt.
            poly = []
            hits = []
            3.times do |k|
              p = pts[k]
              q = pts[(k + 1) % 3]
              sp = s[k]
              sq = s[(k + 1) % 3]
              poly << p if sp >= -TOL
              next unless (sp >= -TOL) != (sq >= -TOL)

              m = SectionEngine.lerp(p, q, sp / (sp - sq))
              poly << m
              hits << m
            end
            if hits.length == 2
              @cuts << hits
              @cut_mats << tr[3]
            end
            (1...poly.length - 1).each { |k| @clipped.triangles << [poly[0], poly[k], poly[k + 1], tr[3]] }
          end

          def start_projection
            if @cuts.empty? && @clipped.edges.empty?
              raise ArgumentError, "#{label}: mặt phẳng cắt nằm ngoài vật thể."
            end

            @fn = Geometry::VIEWS[SectionEngine.base_view(@sec)][1]
            @clipped.edges.concat(@cuts) # để khung hình chứa trọn nét cắt
            @proj = Geometry::Projector.new(@clipped, SectionEngine.key(@sec),
                                            [Geometry::BUDGET_L1, Geometry::BUDGET_L2], [label, @fn])
            @phase = :project
          end

          def finalize
            v = @proj.result
            l, t = v[:origin]
            segs = []
            smats = []
            @cuts.each_with_index do |(a, b), i|
              s2 = [@fn.call(a), @fn.call(b)].map { |p| [p[0] - l, p[1] - t] }
              next if Math.hypot(s2[1][0] - s2[0][0], s2[1][1] - s2[0][1]) < 0.01

              segs << s2
              smats << @cut_mats[i]
            end
            lps = SectionEngine.loops(segs)
            v[:cut] = { segs: segs, loops: lps, loop_mats: SectionEngine.loop_materials(lps, segs, smats, @cap.materials) }
            v[:section] = @sec
            v[:stats]['cut_segments'] = segs.length
            v[:stats]['cut_loops'] = v[:cut][:loops].length
            v[:notes] << "#{label}: mặt phẳng không cắt qua vật thể nào." if segs.empty?
            @result = v
            @clipped = @proj = nil
            @phase = :done
          end
        end

        # Vật liệu của từng vòng tiết diện: đa số theo các đoạn nét cắt chạm đỉnh của vòng. Trả tên vật liệu (nil nếu không có).
        def loop_materials(lps, segs, mats, table)
          key = ->(p) { [(p[0] * 100).round, (p[1] * 100).round] }
          at = Hash.new { |h, k| h[k] = [] }
          segs.each_with_index { |(a, b), i| at[key.call(a)] << mats[i]; at[key.call(b)] << mats[i] }
          lps.map do |lp|
            m = lp.flat_map { |p| at[key.call(p)] }.compact.tally.max_by { |_, n| n }&.first
            m && table[m] ? table[m]['name'] : nil
          end
        end

        # Kiểu hatch theo tên vật liệu (chỉ dựa trên vật liệu có trong model): [bước mm, kiểu] kiểu: :d45, :cross, :none
        def hatch_style(name)
          n = name.to_s.downcase
          return [nil, :none] if n =~ /k[íi]nh|glass|g[ươ]+ng|mirror/
          return [0.6, :cross] if n =~ /inox|th[ée]p|nh[ôo]m|kim lo|metal|steel|alu/
          return [1.5, :cross] if n =~ /đá|da |stone|b[êe] ?t[ôo]ng|concrete|marble/

          [1.2, :d45]
        end

        # Hatch theo vật liệu từng vòng (gỗ/ván: 45°, kim loại/đá: lưới chéo, kính: để trống).
        def hatch_by_material(loops, names)
          return hatch(loops) if names.nil? || names.compact.empty?

          loops.each_index.group_by { |i| hatch_style(names[i]) }.flat_map do |(sp, kind), ids|
            lps = ids.map { |i| loops[i] }
            case kind
            when :none then []
            when :cross
              mir = lps.map { |lp| lp.map { |p| [-p[0], p[1]] } }
              hatch(lps, sp) + hatch(mir, sp).map { |a, b| [[-a[0], a[1]], [-b[0], b[1]]] }
            else hatch(lps, sp)
            end
          end
        end

        # Nối các đoạn giao tuyến thành vòng kín (mỗi tiết diện của tấm/vật thể kín là 1 vòng).
        def loops(segs)
          key = ->(p) { [(p[0] * 100).round, (p[1] * 100).round] }
          ends = Hash.new { |h, k| h[k] = [] }
          segs.each_with_index { |(a, b), i| ends[key.call(a)] << i; ends[key.call(b)] << i }
          used = Array.new(segs.length, false)
          out = []
          segs.each_index do |i|
            next if used[i]

            used[i] = true
            start = key.call(segs[i][0])
            pts = [segs[i][0], segs[i][1]]
            loop do
              tip = key.call(pts.last)
              break if tip == start

              j = ends[tip].find { |k| !used[k] }
              break unless j

              used[j] = true
              a, b = segs[j]
              pts << (key.call(a) == tip ? b : a)
            end
            out << pts[0..-2] if key.call(pts.last) == start && pts.length >= 4
          end
          out
        end

        # Đề xuất vị trí cắt từ cấu tạo thật (vách/đợt đo được trên mặt đứng). Chỉ là đề xuất – người dùng sửa/xoá được.
        def suggest(front)
          l, t = front[:origin]
          w, h = front[:w], front[:h]
          xs = DimensionEngine.breaks(front[:lines], 0, w, [h * 0.3, 150.0].min, 0)
          ys = DimensionEngine.breaks(front[:lines], 1, h, [w * 0.3, 150.0].min, 0)
          cols = xs.each_cons(2).map { |a, b| [b - a, (a + b) / 2.0] }.sort_by { |g, _| -g }
          rows = ys.each_cons(2).map { |a, b| [b - a, (a + b) / 2.0] }.sort_by { |g, _| -g }
          out = []
          out << { 'axis' => 'x', 'pos' => (l + cols[0][1]).round(1), 'dir' => 1 } if cols[0]
          out << { 'axis' => 'z', 'pos' => -(t + rows[0][1]).round(1), 'dir' => -1 } if rows[0]
          if cols[1] && cols[1][0] > 150 && (cols[1][1] - cols[0][1]).abs > 100
            out << { 'axis' => 'x', 'pos' => (l + cols[1][1]).round(1), 'dir' => 1 }
          elsif rows[1] && rows[1][0] > 150
            out << { 'axis' => 'z', 'pos' => -(t + rows[1][1]).round(1), 'dir' => -1 }
          end
          out.each_with_index.map { |s, i| s.merge('label' => ('A'.ord + i).chr, 'auto' => true) }
        end

        # Hatch 45° cho các vòng kín (chẵn–lẻ, xử lý cả lỗ). Toạ độ giấy (mm). Trả về đoạn thẳng.
        def hatch(loops, spacing = 1.2)
          r2 = Math.sqrt(2)
          edges = loops.flat_map { |lp| lp.each_with_index.map { |p, i| [p, lp[(i + 1) % lp.length]] } }
          return [] if edges.empty?

          rot = ->(p) { [(p[0] - p[1]) / r2, (p[0] + p[1]) / r2] } # [r, q]
          re = edges.map { |a, b| [rot.call(a), rot.call(b)] }
          rmin, rmax = re.flat_map { |a, b| [a[0], b[0]] }.minmax
          out = []
          c = (rmin / spacing).ceil * spacing
          while c <= rmax
            qs = []
            re.each do |a, b|
              next if (a[0] - c) * (b[0] - c) > 0 || (a[0] - b[0]).abs < 1e-12
              next if [a[0], b[0]].max == c # quy tắc nửa mở để đỉnh không bị đếm 2 lần

              qs << a[1] + (b[1] - a[1]) * (c - a[0]) / (b[0] - a[0])
            end
            qs.sort!
            qs.each_slice(2) do |q1, q2|
              next unless q2

              out << [[(c + q1) / r2, (q1 - c) / r2], [(c + q2) / r2, (q2 - c) / r2]]
            end
            c += spacing
          end
          out
        end
      end
    end
  end
end
