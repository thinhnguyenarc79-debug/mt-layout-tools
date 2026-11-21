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

        # Đọc toàn bộ 1 definition (đồng bộ) – dùng khi không cần chia lô.
        def def_data(defn, _job = nil)
          return @defs[defn] if @defs[defn]

          r = DefReader.new(self, defn)
          nil until r.call(Geometry::NO_JOB)
          @defs[defn] = r.data
        end

        def defs_count
          @defs.length
        end

        def cached(defn)
          @defs[defn]
        end

        def store(defn, data)
          @defs[defn] = data
        end

        # Đọc các entity của 1 definition theo lô (mỗi lần call làm tới khi hết giờ).
        class DefReader
          attr_reader :data

          def initialize(ex, defn)
            @ex = ex
            @ents = defn.entities.to_a
            @i = 0
            @data = DefData.new(defn.name.to_s, {}, [], 0, 0, 0)
          end

          def call(job)
            while @i < @ents.length
              return false if (@i % 64).zero? && @i.positive? && job.time_up?

              read(@ents[@i])
              @i += 1
            end
            true
          end

          def read(e)
            return unless e.is_a?(Sketchup::Drawingelement)
            return if e.hidden?

            data = @data
            case e
            when Sketchup::Group, Sketchup::ComponentInstance
              info = { name: e.name.to_s, def_name: e.definition.name.to_s, tag: @ex.tag_of(e),
                       attr: PartClassifier.attribute_role(e) }
              data.kids << [e.transformation.to_a, @ex.material_key(e.material), e.definition, @ex.tag_of(e),
                            e.is_a?(Sketchup::Group) ? :group : :component, e.persistent_id, info]
            when Sketchup::Edge
              return if e.soft? || e.smooth?

              a = e.start.position
              b = e.end.position
              @ex.part(data, @ex.tag_of(e))[:edges] << [a.x.to_f, a.y.to_f, a.z.to_f, b.x.to_f, b.y.to_f, b.z.to_f]
              data.edges += 1
            when Sketchup::Face
              mkey = @ex.material_key(e.material || e.back_material)
              mesh = e.mesh(0)
              pts = mesh.points.map { |p| [p.x.to_f, p.y.to_f, p.z.to_f] }
              list = @ex.part(data, @ex.tag_of(e))[:tris]
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

        # Bản đồng bộ (test): chạy CaptureBuilder tới khi xong.
        def capture(model, inst, exclude, front, _job = nil, doors = {})
          cb = builder(model, inst, exclude, front, doors)
          nil until cb.call(Geometry::NO_JOB)
          cb.result
        end

        # doors: { manual: ["pid/pid", ...], tags: ["Tag cánh"] } – xem DoorDetector.
        def builder(model, inst, exclude, front, doors = {})
          CaptureBuilder.new(self, model, inst, exclude, front, doors)
        end

        # Mở rộng cây Group/Component bên trong model đã chọn thành Capture (mm, toạ độ cục bộ),
        # dạng máy trạng thái: lấy 1 khung (definition + ma trận) từ ngăn xếp -> đọc definition nếu chưa có
        # trong cache (theo lô) -> biến đổi cạnh/tam giác (theo lô) -> đẩy các instance con vào ngăn xếp.
        class CaptureBuilder
          attr_reader :result

          def initialize(ex, model, inst, exclude, front, doors = {})
            @ex = ex
            @t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            world = Geometry.world_transform(model, inst)
            @cap = Geometry::Capture.new(Geometry.instance_name(inst), [], [], ex.materials,
                                         { 'groups' => 0, 'components' => 0, 'faces' => 0, 'edges_src' => 0 })
            @skip = exclude.map(&:to_s) | model.layers.reject(&:visible?).map(&:name)
            @heavy = Hash.new(0)
            # cấu hình nhận diện: roles {đường dẫn => vai trò gán tay}, manual (cánh chọn tay – bản 2.4), tags (Tag cánh)
            @roles = (doors[:roles] || doors['roles'] || {}).transform_keys(&:to_s)
            Array(doors[:manual] || doors['manual']).each { |pth| @roles[pth.to_s] ||= 'door' }
            @door_tags = Array(doors[:tags] || doors['tags']).map(&:to_s).reject(&:empty?)
            @seen_paths = {}
            @cap.edge_door = []
            @cap.tri_door = []
            @cap.doors = []
            @cap.parts = []
            @cap.edge_part = []
            @cap.tri_part = []
            @part_mats = []
            # khung: [definition, ma trận, vật liệu thừa kế, độ sâu, đường dẫn pid, bộ phận (vai trò rõ, kế thừa)|nil, tên]
            @stack = [[inst.definition, ex.root_matrix(world, front), ex.material_key(inst.material), 0, '', nil,
                       Geometry.instance_name(inst)]]
            @visited = 0
            @mins = [Float::INFINITY] * 3
            @maxs = [-Float::INFINITY] * 3
            @phase = :next
          end

          def call(job)
            loop do
              case @phase
              when :next
                return finish if @stack.empty?

                @defn, @m, @inherit, @depth, @path, @door, @fname = @stack.pop
                raise ArgumentError, 'Lồng nhóm quá 60 cấp (có thể tự tham chiếu).' if @depth > 60

                if (@data = @ex.cached(@defn))
                  begin_expand
                else
                  @reader = DefReader.new(@ex, @defn)
                  @phase = :read
                end
              when :read
                unless @reader.call(job)
                  job.progress("Đọc hình học: #{@visited} cụm, #{@cap.triangles.length} tam giác", 2)
                  return false
                end
                @data = @reader.data
                @ex.store(@defn, @data)
                @reader = nil
                begin_expand
              when :expand
                return false unless expand(job)

                push_kids
                @phase = :next
              when :done then return true
              end
              if job.time_up?
                job.progress("Đọc hình học: #{@visited} cụm, #{@cap.triangles.length} tam giác", 2)
                return false
              end
            end
          end

          private

          def new_part(path, name, role, source)
            id = @cap.parts.length
            @cap.parts << { 'id' => id, 'path' => path, 'name' => name.to_s.empty? ? 'Bộ phận' : name.to_s,
                            'role' => role, 'source' => source, 'sure' => !role.nil?,
                            'bounds' => [[Float::INFINITY, -Float::INFINITY], [Float::INFINITY, -Float::INFINITY],
                                         [Float::INFINITY, -Float::INFINITY]] }
            @part_mats << Hash.new(0)
            id
          end

          def grow(pid, a, b)
            return unless pid

            bb = @cap.parts[pid]['bounds']
            3.times do |k|
              lo, hi = a[k] < b[k] ? [a[k], b[k]] : [b[k], a[k]]
              bb[k][0] = lo if lo < bb[k][0]
              bb[k][1] = hi if hi > bb[k][1]
            end
          end

          # Bộ phận chưa có vai trò rõ -> đề xuất theo vật liệu/hình học (sure = false: cần người dùng xác nhận).
          # Sau đó lập bảng cánh (edge_door/tri_door) cho hình tháo cánh và DIM cánh.
          def classify_parts
            @cap.parts.each { |pt| pt['bounds'] = pt['bounds'].map { |lo, hi| [lo.round(1), hi.round(1)] } }
            # Khung thân tủ: chỉ tính các bộ phận lớn (>= 300 mm) để tay nắm, phụ kiện nhô ra không làm lệch mặt trước.
            big = @cap.parts.select { |pt| pt['bounds'].all? { |lo, hi| lo.finite? && hi.finite? } && pt['bounds'].map { |lo, hi| hi - lo }.max >= 300 }
            ext = if big.empty?
                    (0..2).map { |k| [@mins[k], @maxs[k]] }
                  else
                    (0..2).map { |k| [big.map { |pt| pt['bounds'][k][0] }.min, big.map { |pt| pt['bounds'][k][1] }.max] }
                  end
            @cap.parts.each_with_index do |pt, i|
              next if pt['role']

              mkey = @part_mats[i].max_by { |_, n| n }&.first
              mname = mkey && @cap.materials[mkey] ? @cap.materials[mkey]['name'] : nil
              valid = pt['bounds'].all? { |lo, hi| lo.finite? && hi.finite? }
              role, why = valid ? PartClassifier.geometric(pt['bounds'], ext, mname) : ['unknown', 'không có cạnh']
              pt['role'] = role
              pt['source'] = role == 'glass' ? why : "hình học: #{why}"
              pt['sure'] = false
            end
            door_idx = {}
            @cap.parts.each do |pt|
              next unless pt['role'] == 'door'

              door_idx[pt['id']] = @cap.doors.length
              @cap.doors << { 'id' => @cap.doors.length, 'part' => pt['id'], 'path' => pt['path'], 'name' => pt['name'],
                              'reason' => pt['source'], 'sure' => pt['sure'] }
            end
            @cap.edge_door = @cap.edge_part.map { |p| p && door_idx[p] }
            @cap.tri_door = @cap.tri_part.map { |p| p && door_idx[p] }
          end

          def begin_expand
            @visited += 1
            @cap.stats['faces'] += @data.faces
            @cap.stats['edges_src'] += @data.edges
            @heavy[@data.name] += @data.tris
            @parts = @data.parts.reject { |tag, _| @skip.include?(tag) }.values
            # Bộ phận của hình học trực tiếp trong khung này: kế thừa bộ phận có vai trò rõ của cha,
            # nếu không thì là 1 bộ phận riêng (vai trò sẽ đề xuất theo hình học khi đọc xong).
            @part = @door
            if @part.nil? && @parts.any? { |pt| !pt[:edges].empty? || !pt[:tris].empty? }
              @part = new_part(@path, @path.empty? ? "#{@fname} (hình trực tiếp)" : @fname, nil, nil)
            end
            @pi = 0
            @ei = 0
            @ti = 0
            @phase = :expand
          end

          def expand(job)
            m = @m
            while @pi < @parts.length
              pt = @parts[@pi]
              edges = pt[:edges]
              while @ei < edges.length
                return false if (@ei % 512).zero? && @ei.positive? && job.time_up?

                e = edges[@ei]
                @ei += 1
                a = @ex.apply(m, e[0], e[1], e[2])
                b = @ex.apply(m, e[3], e[4], e[5])
                3.times do |k|
                  lo, hi = a[k] < b[k] ? [a[k], b[k]] : [b[k], a[k]]
                  @mins[k] = lo if lo < @mins[k]
                  @maxs[k] = hi if hi > @maxs[k]
                end
                @cap.edges << [a, b]
                @cap.edge_part << @part
                grow(@part, a, b)
              end
              tris = pt[:tris]
              while @ti < tris.length
                return false if (@ti % 512).zero? && @ti.positive? && job.time_up?

                tr = tris[@ti]
                @ti += 1
                @cap.triangles << [@ex.apply(m, tr[0], tr[1], tr[2]), @ex.apply(m, tr[3], tr[4], tr[5]),
                                   @ex.apply(m, tr[6], tr[7], tr[8]), tr[9] || @inherit]
                @cap.tri_part << @part
                @part_mats[@part][tr[9] || @inherit] += 1 if @part
              end
              @pi += 1
              @ei = 0
              @ti = 0
            end
            true
          end

          def push_kids
            @data.kids.each do |t, mkey, child, tag, kind, pid, info|
              next if @skip.include?(tag)

              kind == :group ? @cap.stats['groups'] += 1 : @cap.stats['components'] += 1
              path = @path.empty? ? pid.to_s : "#{@path}/#{pid}"
              @seen_paths[path] = true
              name = info ? (info[:name].empty? ? info[:def_name] : info[:name]) : ''
              part = @door
              if part.nil? && info
                role = PartClassifier.explicit(info, path, @roles, @door_tags)
                part = new_part(path, name, role[0], role[1]) if role
              elsif part && @roles[path] && @roles[path] != @cap.parts[part]['role']
                # gán tay trên 1 phần con nằm trong bộ phận cha có vai trò khác -> tách thành bộ phận riêng
                part = new_part(path, name, @roles[path], 'gán tay')
              end
              @stack << [child, @ex.compose(@m, t), mkey || @inherit, @depth + 1, path, part, name.empty? ? 'Bộ phận' : name]
            end
          end

          def finish
            st = @cap.stats
            st['triangles'] = @cap.triangles.length
            st['edges'] = @cap.edges.length
            st['defs_cached'] = @ex.defs_count
            classify_parts
            st['parts'] = @cap.parts.length
            st['doors'] = @cap.doors.length
            st['missing_roles'] = @roles.keys.reject { |pth| @seen_paths[pth] }
            st['extent'] = (0..2).map { |k| [@mins[k].round(1), @maxs[k].round(1)] } unless @cap.edges.empty?
            st['heaviest'] = @heavy.sort_by { |_, v| -v }.first(5).map { |n, v| "#{n}: #{v} tam giác" }
            st['seconds'] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @t0).round(2)
            raise ArgumentError, 'Đối tượng không có cạnh hiển thị (kiểm tra Tag đang lọc).' if @cap.edges.empty?

            @result = @cap
            @phase = :done
            true
          end
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
