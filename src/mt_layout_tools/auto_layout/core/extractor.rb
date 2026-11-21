# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # GEOMETRY EXTRACTION: đọc hình học BÊN TRONG model đã chọn (không phải model discovery).
      # - Đọc mỗi ComponentDefinition một lần (cache), các instance dùng lại bằng ma trận tích luỹ.
      # - Chỉ đọc, không sửa model. Chạy theo lát thời gian (Job#tick) để SketchUp không treo.
      class Extractor
        MM = 25.4

        # Dữ liệu cục bộ của 1 definition (đơn vị inch, toạ độ của definition).
        # parts: { tag => { edges: [[ax,ay,az,bx,by,bz]], tris: [[9 số, mat_key|nil]] } }
        # kids:  [[ma trận 4x4 (to_a), mat_key|nil, definition, tag, loại]]
        DefData = Struct.new(:name, :parts, :kids, :faces, :edges, :tris)

        attr_reader :materials

        def initialize(log = nil)
          @defs = {}
          @materials = {}
          @log = log
        end

        def reset
          @defs.clear
          @materials.clear
        end

        def material_key(mat)
          return nil unless mat

          key = mat.display_name.to_s
          unless @materials[key]
            c = mat.color
            @materials[key] = { 'name' => key, 'color' => format('#%02X%02X%02X', c.red, c.green, c.blue) }
          end
          key
        end

        def tag_of(e)
          e.layer ? e.layer.name : ''
        end

        def def_data(defn, job)
          @defs[defn] ||= begin
            data = DefData.new(defn.name.to_s, {}, [], 0, 0, 0)
            defn.entities.each_with_index do |e, i|
              job&.tick if (i & 255).zero?
              next unless e.is_a?(Sketchup::Drawingelement)
              next if e.hidden?

              case e
              when Sketchup::Group, Sketchup::ComponentInstance
                data.kids << [e.transformation.to_a, material_key(e.material), e.definition, tag_of(e),
                              e.is_a?(Sketchup::Group) ? :group : :component]
              when Sketchup::Edge
                next if e.soft? || e.smooth?

                a = e.start.position
                b = e.end.position
                part(data, tag_of(e))[:edges] << [a.x.to_f, a.y.to_f, a.z.to_f, b.x.to_f, b.y.to_f, b.z.to_f]
                data.edges += 1
              when Sketchup::Face
                mkey = material_key(e.material || e.back_material)
                mesh = e.mesh(0)
                pts = mesh.points.map { |p| [p.x.to_f, p.y.to_f, p.z.to_f] }
                list = part(data, tag_of(e))[:tris]
                mesh.polygons.each do |poly|
                  idx = poly.map { |k| k.abs - 1 }
                  (1...idx.length - 1).each do |k|
                    list << [*pts[idx[0]], *pts[idx[k]], *pts[idx[k + 1]], mkey]
                    data.tris += 1
                  end
                end
                data.faces += 1
              end
            end
            data
          end
        end

        def part(data, tag)
          data.parts[tag] ||= { edges: [], tris: [] }
        end

        # ---- ma trận: A là 3x4 hàng-trước (12 số), T là to_a 4x4 cột-trước của SketchUp ----
        def compose(a, t)
          out = Array.new(12)
          3.times do |r|
            a0 = a[r * 4]
            a1 = a[r * 4 + 1]
            a2 = a[r * 4 + 2]
            4.times do |c|
              v = a0 * t[c * 4] + a1 * t[c * 4 + 1] + a2 * t[c * 4 + 2]
              v += a[r * 4 + 3] if c == 3
              out[r * 4 + c] = v
            end
          end
          out
        end

        # Ma trận gốc: toạ độ thế giới (inch) -> toạ độ cục bộ của model đã chọn (mm), đã xoay theo hướng mặt trước.
        def root_matrix(world, front)
          origin = world.origin
          xa = world.xaxis.normalize
          ya = world.yaxis.normalize
          za = xa.cross(ya).normalize
          za.reverse! if za.dot(world.zaxis) < 0
          ya = za.cross(xa).normalize
          axes = [xa, ya, za].map { |v| [v.x.to_f, v.y.to_f, v.z.to_f] }
          rot = Geometry::FRONTS.fetch(front.to_s, Geometry::FRONTS['-Y'])
          ex = rot.call(1.0, 0.0)
          ey = rot.call(0.0, 1.0)
          # hàng i của phép xoay 2D: x' = ex[0]*x + ey[0]*y ; y' = ex[1]*x + ey[1]*y
          rows = [
            axes[0].zip(axes[1]).map { |x, y| (ex[0] * x + ey[0] * y) * MM },
            axes[0].zip(axes[1]).map { |x, y| (ex[1] * x + ey[1] * y) * MM },
            axes[2].map { |v| v * MM }
          ]
          o = [origin.x.to_f, origin.y.to_f, origin.z.to_f]
          rows.flat_map { |row| row + [-(row[0] * o[0] + row[1] * o[1] + row[2] * o[2])] }.then do |c|
            compose(c, world.to_a)
          end
        end

        # Mở rộng toàn bộ cây Group/Component bên trong inst thành Capture (mm, toạ độ cục bộ).
        # exclude: Tag loại bỏ; hidden_tags: Tag đang tắt hiển thị.
        def capture(model, inst, exclude, front, job = nil)
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          world = Geometry.world_transform(model, inst)
          cap = Geometry::Capture.new(Geometry.instance_name(inst), [], [], @materials,
                                      { 'groups' => 0, 'components' => 0, 'faces' => 0, 'edges_src' => 0 })
          skip = exclude.map(&:to_s) | model.layers.reject(&:visible?).map(&:name)
          heavy = Hash.new(0)
          stack = [[inst.definition, root_matrix(world, front), material_key(inst.material), 0]]
          visited = 0
          until stack.empty?
            defn, m, inherit, depth = stack.pop
            raise ArgumentError, 'Lồng nhóm quá 60 cấp (có thể tự tham chiếu).' if depth > 60

            job&.progress("Đọc hình học: #{visited} cụm, #{cap.triangles.length} tam giác", 2)
            data = def_data(defn, job)
            visited += 1
            cap.stats['faces'] += data.faces
            cap.stats['edges_src'] += data.edges
            heavy[data.name] += data.tris
            data.parts.each do |tag, pt|
              next if skip.include?(tag)

              pt[:edges].each_with_index do |e, i|
                job&.tick if (i & 1023).zero?
                cap.edges << [apply(m, e[0], e[1], e[2]), apply(m, e[3], e[4], e[5])]
              end
              pt[:tris].each_with_index do |tr, i|
                job&.tick if (i & 1023).zero?
                cap.triangles << [apply(m, tr[0], tr[1], tr[2]), apply(m, tr[3], tr[4], tr[5]),
                                  apply(m, tr[6], tr[7], tr[8]), tr[9] || inherit]
              end
            end
            data.kids.each do |t, mkey, child, tag, kind|
              next if skip.include?(tag)

              kind == :group ? cap.stats['groups'] += 1 : cap.stats['components'] += 1
              stack << [child, compose(m, t), mkey || inherit, depth + 1]
            end
          end
          cap.stats['triangles'] = cap.triangles.length
          cap.stats['edges'] = cap.edges.length
          cap.stats['defs_cached'] = @defs.length
          cap.stats['heaviest'] = heavy.sort_by { |_, v| -v }.first(5).map { |n, v| "#{n}: #{v} tam giác" }
          cap.stats['seconds'] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(2)
          raise ArgumentError, 'Đối tượng không có cạnh hiển thị (kiểm tra Tag đang lọc).' if cap.edges.empty?

          cap
        end

        def apply(m, x, y, z)
          [m[0] * x + m[1] * y + m[2] * z + m[3],
           m[4] * x + m[5] * y + m[6] * z + m[7],
           m[8] * x + m[9] * y + m[10] * z + m[11]]
        end
      end
    end
  end
end
