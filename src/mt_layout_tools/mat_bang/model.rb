# encoding: UTF-8
require 'digest'
require 'json'

module MTDesign
  module MatBang
    module Model3D
      module_function

      DICT = 'MTDesign_MatBang'
      MILLIMETRES_PER_INCH = 25.4

      def build(model, project, furniture_boxes)
        ensure_root_context(model)
        items = project.fetch('items')
        walls = items.select { |o| o['type'] == 'wall' }.each_with_object({}) { |o, h| h[o['id']] = o }
        cuts = items.select { |o| o.key?('wall') }.group_by { |o| o['wall'] }
        joints = join_coefficients(walls, cuts)
        specs = items.reject { |o| o['type'] == 'dimension' }.filter_map do |o|
          specification(o, walls, cuts, furniture_boxes, joints)
        end
        raise ArgumentError, 'Chưa có đối tượng dựng 3D.' if specs.empty?

        model.start_operation('MT Mặt Bằng – Dựng 3D', true)
        begin
          root = model.entities.grep(Sketchup::Group).find { |g| g.get_attribute(DICT, 'root') == true }
          unless root
            root = model.entities.add_group
            root.set_attribute(DICT, 'root', true)
          end
          root.name = 'MT Mặt Bằng · ' + project['name']
          existing = root.entities.grep(Sketchup::Group).each_with_object({}) do |g, h|
            id = g.get_attribute(DICT, 'id')
            h[id] = g if id
          end
          changes = 0
          specs.each do |spec|
            old = existing.delete(spec[:id])
            signature = Digest::SHA256.hexdigest(JSON.generate(spec.fetch(:shape)))
            if old && old.get_attribute(DICT, 'shape') == signature
              if old.get_attribute(DICT, 'pose') != JSON.generate(spec[:pose])
                old.transformation = transform(spec[:pose])
                old.set_attribute(DICT, 'pose', JSON.generate(spec[:pose]))
                changes += 1
              end
              old.name = spec[:name]
              next
            end
            old.erase! if old
            group = root.entities.add_group
            group.name = spec[:name]
            group.set_attribute(DICT, 'id', spec[:id])
            group.set_attribute(DICT, 'shape', signature)
            group.set_attribute(DICT, 'pose', JSON.generate(spec[:pose]))
            draw(model, group.entities, spec[:shape])
            group.transformation = transform(spec[:pose])
            changes += 1
          end
          existing.each_value { |g| g.erase!; changes += 1 }
          model.set_attribute(DICT, 'project', JSON.generate(project))
          model.commit_operation
        rescue StandardError
          model.abort_operation
          raise
        end
        [root, changes]
      end

      def ensure_root_context(model)
        return if model.active_path.nil? || model.active_path.empty?

        raise ArgumentError, 'Thoát chế độ sửa Group hoặc Component trong SketchUp trước khi dựng.'
      end

      def wall_geometry(o)
        a, b = o.values_at('a', 'b')
        [[a[0], -a[1], -Math.atan2(b[1] - a[1], b[0] - a[0])], Schema.length(a, b)]
      end

      def join_coefficients(walls, cuts)
        nodes = Hash.new { |h, k| h[k] = [] }
        walls.each_value do |w|
          a, b = w.values_at('a', 'b')
          span = Schema.length(a, b)
          u = [(b[0] - a[0]) / span, (b[1] - a[1]) / span]
          gaps = cuts.fetch(w['id'], []).sort_by { |o| o['at'] }
          space = if gaps.empty?
                    [span, span]
                  else
                    first, last = gaps.first, gaps.last
                    [first['at'] - first['w'] / 2, span - last['at'] - last['w'] / 2]
                  end
          nodes[a] << [w, 0, u, space[0]]
          nodes[b] << [w, 1, u.map { |v| -v }, space[1]]
        end
        joins = Hash.new { |h, k| h[k] = [0.0, 0.0] }
        nodes.each_value do |pair|
          next unless pair.length == 2

          (a, i, u, x), (b, j, v, y) = pair
          cross = u[0] * v[1] - u[1] * v[0]
          next if a['t'] != b['t'] || a['h'] != b['h'] || cross.abs < 0.001

          k = (1 + u[0] * v[0] + u[1] * v[1]) / cross
          next if k.abs > 2.5 || k.abs * a['t'] / 2 + 1 >= [x, y].min

          joins[a['id']][i] = k.round(8)
          joins[b['id']][j] = -k.round(8)
        end
        joins
      end

      def specification(o, walls, cuts, furniture_boxes, joints = {})
        id, type = o.values_at('id', 'type')
        name = o['name']
        pose = [0, 0, 0]
        shape = { type: type }
        case type
        when 'wall'
          pose, span = wall_geometry(o)
          gaps = cuts.fetch(id, []).sort_by { |c| c['at'] }.map do |c|
            [[0.0, c['at'] - c['w'] / 2].max, [span, c['at'] + c['w'] / 2].min, c['sill'],
             [o['h'], c['sill'] + c['h']].min]
          end
          # A floor-to-ceiling glazed run may occupy the entire wall.
          return nil if gaps.all? { |_, _, lo, hi| lo.zero? && hi >= o['h'] } &&
                        gaps.sum { |left, right, _, _| right - left } >= span - 0.002

          name = 'Tường ' + id
          shape.merge!(span: span.round(4), h: o['h'], t: o['t'], color: o['c'],
                       gaps: gaps.map { |g| g.map { |v| v.round(4) } }, joint: joints.fetch(id, [0.0, 0.0]))
        when 'door', 'window'
          wall = walls.fetch(o['wall'])
          base, = wall_geometry(wall)
          name = (type == 'door' ? 'Cửa đi ' : 'Cửa sổ ') + id
          pose = [base[0] + o['at'] * Math.cos(base[2]), base[1] + o['at'] * Math.sin(base[2]), base[2]]
          shape.merge!(w: o['w'], h: o['h'], sill: o['sill'], t: wall['t'], flip: o['flip'], swing: o['swing'])
        when 'floor'
          origin = o['p'].first
          pose = [origin[0], -origin[1], 0]
          local = o['p'].map { |x, y| [(x - origin[0]).round(4), (origin[1] - y).round(4)] }
          shape.merge!(p: local, t: o['t'], color: o['c'])
        when 'furniture'
          pose = [o['a'][0], -o['a'][1], -o['angle'] * Math::PI / 180]
          boxes = furniture_boxes.fetch(id).map { |x, y, z, w, d, h| [x, -y - d, z, w, d, h] }
          shape.merge!(boxes: boxes, color: o['c'])
        end
        { id: id, name: name, pose: pose.map { |n| n.round(8) }, shape: shape }
      end

      def native(x, y, z)
        Geom::Point3d.new(x / MILLIMETRES_PER_INCH, y / MILLIMETRES_PER_INCH, z / MILLIMETRES_PER_INCH)
      end

      def transform(pose)
        move = Geom::Transformation.translation(native(pose[0], pose[1], 0).to_a)
        turn = Geom::Transformation.rotation(ORIGIN, Z_AXIS, pose[2])
        move * turn
      end

      def material(model, color, transparent = false)
        name = 'MT ' + color + (transparent ? ' · Kính' : '')
        model.materials[name] || begin
          value = model.materials.add(name)
          value.color = Sketchup::Color.new(*color[1..-1].scan(/../).map { |s| s.to_i(16) })
          value.alpha = 0.38 if transparent
          value
        end
      end

      def poly_face(entities, points, finish)
        face = entities.add_face(points.map { |p| native(*p) })
        raise ArgumentError, 'Có chi tiết quá nhỏ hoặc biên hình học không hợp lệ.' unless face

        face.material = finish
        face.back_material = finish
        face
      end

      def prism(entities, polygon, base, height, finish)
        face = poly_face(entities, polygon.map { |x, y| [x, y, base] }, finish)
        face.reverse! if face.normal.z < 0
        face.pushpull(height / MILLIMETRES_PER_INCH)
        entities.grep(Sketchup::Face).each do |f|
          f.material = finish
          f.back_material = finish
        end
      end

      def box(entities, dims, finish)
        x, y, z, w, d, h = dims
        group = entities.add_group
        prism(group.entities, [[x, y], [x + w, y], [x + w, y + d], [x, y + d]], z, h, finish)
      end

      def wall_surface(entities, s, finish)
        # Tile the x/z profile and emit only exterior faces, including jambs and headers.
        xs = ([0.0, s[:span]] + s[:gaps].flat_map { |a, b, _, _| [a, b] }).sort.uniq
        zs = ([0.0, s[:h]] + s[:gaps].flat_map { |_, _, a, b| [a, b] }).sort.uniq
        xs = compact_axis(xs)
        zs = compact_axis(zs)
        ny = -s[:t] / 2
        py = s[:t] / 2
        left, right = s.fetch(:joint)
        face = lambda do |points|
          adjusted = points.map do |x, y, z|
            coefficient = x.zero? ? left : (x == s[:span] ? right : 0.0)
            [x - y * coefficient, y, z]
          end
          poly_face(entities, adjusted, finish)
        end
        grid = xs.each_cons(2).map do |x0, x1|
          x = (x0 + x1) / 2
          gap = s[:gaps].find { |a, b, _, _| x.between?(a, b) }
          zs.each_cons(2).map do |z0, z1|
            z = (z0 + z1) / 2
            !gap || !z.between?(gap[2], gap[3])
          end
        end
        full = lambda { |i, j| i >= 0 && j >= 0 && grid[i] && grid[i][j] }
        grid.each_with_index do |column, i|
          column.each_with_index do |on, j|
            next unless on

            x0, x1 = xs[i, 2]
            z0, z1 = zs[j, 2]
            face.call([[x0, ny, z0], [x1, ny, z0], [x1, ny, z1], [x0, ny, z1]])
            face.call([[x1, py, z0], [x0, py, z0], [x0, py, z1], [x1, py, z1]])
            face.call([[x0, py, z0], [x0, ny, z0], [x0, ny, z1], [x0, py, z1]]) unless full.call(i - 1, j)
            face.call([[x1, ny, z0], [x1, py, z0], [x1, py, z1], [x1, ny, z1]]) unless full.call(i + 1, j)
            face.call([[x0, ny, z0], [x0, py, z0], [x1, py, z0], [x1, ny, z0]]) unless full.call(i, j - 1)
            face.call([[x0, ny, z1], [x1, ny, z1], [x1, py, z1], [x0, py, z1]]) unless full.call(i, j + 1)
          end
        end
        # Hide construction seams shared by two coplanar faces.
        entities.grep(Sketchup::Edge).each do |edge|
          faces = edge.faces
          edge.hidden = true if faces.length == 2 && faces[0].normal.dot(faces[1].normal) > 0.9999
        end
      end

      def compact_axis(values)
        values.each_with_object([]) { |v, arr| arr << v if arr.empty? || v - arr.last >= 0.08 }
      end

      def draw(model, entities, s)
        case s[:type]
        when 'wall'
          wall_surface(entities, s, material(model, s[:color]))
        when 'floor'
          prism(entities, s[:p], -s[:t], s[:t], material(model, s[:color]))
        when 'furniture'
          finish = material(model, s[:color])
          s[:boxes].each { |b| box(entities, b, finish) }
        when 'window', 'door'
          w, h, z = s.values_at(:w, :h, :sill)
          frame = material(model, '#44544e')
          glass = material(model, '#95c5cb', true)
          b, d = [28, w * 0.12, h * 0.12].min, [42, s[:t] * 0.78].min
          x = -w / 2
          box(entities, [x, -d / 2, z, b, d, h], frame)
          box(entities, [w / 2 - b, -d / 2, z, b, d, h], frame)
          box(entities, [x + b, -d / 2, z + h - b, w - 2 * b, d, b], frame)
          if s[:type] == 'window'
            box(entities, [x + b, -d / 2, z, w - 2 * b, d, b], frame)
            box(entities, [x + b, -4, z + b, w - 2 * b, 8, h - 2 * b], glass)
          else
            hinge = s[:flip] ? w / 2 - b : x + b
            start = s[:swing] ? 0 : -(w - 2 * b)
            box(entities, [hinge - 6, start, z + 5, 12, w - 2 * b, h - b - 5], glass)
          end
        end
      end
    end
  end
end
