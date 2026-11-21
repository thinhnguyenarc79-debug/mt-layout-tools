# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      module Geometry
        # Tô mặt có che khuất CHÍNH XÁC bằng cây BSP (Binary Space Partitioning).
        #
        # Vì sao: cách cũ sắp tam giác theo độ sâu tâm (thuật toán "người thợ sơn") sai khi tam giác dài
        # (hông tủ, hậu, nóc...) nằm chéo nhau trong phối cảnh trục đo -> tam giác lớn màu nâu/trắng đè lên cánh.
        # BSP cắt các mặt theo mặt phẳng của nhau nên thứ tự sau -> trước luôn đúng, kể cả khi mặt giao cắt.
        #
        # - Cây dựng 1 lần trong toạ độ model (không phụ thuộc hướng nhìn), dùng chung cho mọi hình chiếu.
        # - Chạy theo lô (job.time_up?) – không Fiber, không Thread.
        # - Không phụ thuộc chiều winding / pháp tuyến mặt: mặt đảo, Component mirror/scale âm vẫn đúng.
        module HiddenFill
          EPS = 0.02          # mm: dung sai đồng phẳng
          MIN_AREA = 1.0e-6   # mm²
          GROW_LIMIT = 6      # số mảnh sau khi cắt vượt n*6 -> bỏ cây, dùng cách dự phòng (có ghi chú)

          module_function

          def sub(a, b)
            [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
          end
          def dot(a, b)
            a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
          end

          def cross(a, b)
            [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
          end

          # Tam giác -> mảnh [điểm[], mkey, pháp tuyến đơn vị, d, diện tích, tam giác gốc]; nil nếu suy biến.
          def poly(tri)
            a, b, c, mkey = tri
            n = cross(sub(b, a), sub(c, a))
            len = Math.sqrt(dot(n, n))
            return nil if len < 1.0e-9

            n = n.map { |x| x / len }
            [[a, b, c], mkey, n, dot(n, a), len / 2.0, tri]
          end

          # Cắt đa giác lồi theo mặt phẳng (n, d): trả [phần trước, phần sau] (nil nếu rỗng).
          def split(pl, n, d)
            pts = pl[0]
            ds = pts.map { |p| dot(n, p) - d }
            front = []
            back = []
            pts.each_with_index do |p, i|
              q = pts[(i + 1) % pts.length]
              dp = ds[i]
              dq = ds[(i + 1) % pts.length]
              front << p if dp >= -EPS
              back << p if dp <= EPS
              next unless (dp > EPS && dq < -EPS) || (dp < -EPS && dq > EPS)

              t = dp / (dp - dq)
              x = [p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t, p[2] + (q[2] - p[2]) * t]
              front << x
              back << x
            end
            [piece(pl, front), piece(pl, back)]
          end

          def piece(pl, pts)
            return nil if pts.length < 3
            return nil if area3(pts) < MIN_AREA

            [pts, pl[1], pl[2], pl[3], pl[4], pl[5]]
          end

          def area3(pts)
            s = [0.0, 0.0, 0.0]
            o = pts[0]
            (1...pts.length - 1).each do |i|
              c = cross(sub(pts[i], o), sub(pts[i + 1], o))
              s[0] += c[0]
              s[1] += c[1]
              s[2] += c[2]
            end
            Math.sqrt(dot(s, s)) / 2.0
          end

          # -1 sau, 0 đồng phẳng, 1 trước, 2 cắt ngang
          def side(pl, n, d)
            f = b = false
            pl[0].each do |p|
              v = dot(n, p) - d
              f = true if v > EPS
              b = true if v < -EPS
            end
            return 2 if f && b
            return 1 if f
            return -1 if b

            0
          end

          # Dựng cây theo lô. nodes[i] = [n, d, mảnh đồng phẳng[], con trước, con sau]
          class Builder
            attr_reader :nodes, :pieces, :input

            def initialize(triangles)
              @src = triangles
              @i = 0
              @polys = []
              @nodes = []
              @work = nil
              @pieces = 0
              @failed = false
            end

            def failed?
              @failed
            end
            def done?
              @work && @work.empty?
            end

            def step(job)
              while @i < @src.length
                pl = HiddenFill.poly(@src[@i])
                @polys << pl if pl
                @i += 1
                return false if (@i % 512).zero? && job.time_up?
              end
              unless @work
                @input = @polys.length
                # mặt lớn trước: mặt phẳng tấm ván chia ít mảnh hơn mặt cong nhỏ (tay nắm, ốc...)
                @polys.sort_by! { |pl| -pl[4] }
                @work = @polys.empty? ? [] : [[nil, 0, @polys]]
                @pieces = @polys.length
                @polys = nil
              end
              until @work.empty?
                return false if job.time_up?

                build(*@work.pop)
                if @pieces > @input * GROW_LIMIT + 2000
                  @failed = true
                  @work = []
                end
              end
              true
            end

            private

            def build(parent, slot, list)
              n, d = choose(list)
              here = []
              front = []
              back = []
              list.each do |pl|
                case HiddenFill.side(pl, n, d)
                when 0 then here << pl
                when 1 then front << pl
                when -1 then back << pl
                else
                  f, b = HiddenFill.split(pl, n, d)
                  front << f if f
                  back << b if b
                  @pieces += 1
                end
              end
              idx = @nodes.length
              @nodes << [n, d, here, nil, nil]
              @nodes[parent][slot] = idx if parent
              @work << [idx, 3, front] unless front.empty?
              @work << [idx, 4, back] unless back.empty?
            end

            # Chọn mặt phẳng cắt: vài mảnh lớn nhất + vài mảnh rải đều, ít bị cắt nhất.
            def choose(list)
              return [list[0][2], list[0][3]] if list.length < 3

              cand = [0, 1, 2, list.length / 3, list.length * 2 / 3].uniq.map { |k| list[k] }
              step = [list.length / 160, 1].max
              sample = (0...list.length).step(step).map { |k| list[k] }
              best = cand.min_by do |c|
                splits = 0
                fr = 0
                bk = 0
                sample.each do |pl|
                  case HiddenFill.side(pl, c[2], c[3])
                  when 2 then splits += 1
                  when 1 then fr += 1
                  when -1 then bk += 1
                  end
                end
                [splits * 8 + (fr - bk).abs, -c[4]]
              end
              [best[2], best[3]]
            end
          end

          # Duyệt cây sau -> trước theo hướng nhìn g (vectơ từ vật tới người xem, toạ độ model). Chạy theo lô.
          class Walker
            def initialize(nodes, g)
              @nodes = nodes
              @g = g
              @stack = nodes.empty? ? [] : [[0, true]]
            end

            def done?
              @stack.empty?
            end

            # yield từng mảnh theo thứ tự vẽ; trả true khi xong
            def each_piece(job)
              until @stack.empty?
                return false if job.time_up?

                k, enter = @stack.pop
                nd = @nodes[k]
                unless enter
                  nd[2].each { |pl| yield pl }
                  next
                end
                viewer_front = HiddenFill.dot(nd[0], @g) >= 0
                near = viewer_front ? nd[3] : nd[4]
                far = viewer_front ? nd[4] : nd[3]
                @stack << [near, true] if near
                @stack << [k, false]
                @stack << [far, true] if far
              end
              true
            end
          end

          # Hướng tới người xem của 1 phép chiếu tuyến tính fn (độ sâu càng lớn càng gần).
          def viewer_dir(fn)
            o = fn.call([0.0, 0.0, 0.0])[2]
            [fn.call([1.0, 0.0, 0.0])[2] - o, fn.call([0.0, 1.0, 0.0])[2] - o, fn.call([0.0, 0.0, 1.0])[2] - o]
          end
        end
      end
    end
  end
end
