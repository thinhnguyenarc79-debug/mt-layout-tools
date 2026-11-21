# encoding: UTF-8
module MTDesign
  module MatBang
    module Views
      module_function

      AXES = [
        ['MẶT ĐỨNG', 0, 2, 1, -1],
        ['MẶT BÊN PHẢI', 1, 2, 0, 1],
        ['MẶT BẰNG', 0, 1, 2, 1]
      ].freeze
      MAX_EDGES = 4000
      MAX_TRIANGLES = 4000
      EPS = 1.0e-9

      def capture(model)
        selected = model.selection.to_a
        unless selected.length == 1 && (selected.first.is_a?(Sketchup::Group) || selected.first.is_a?(Sketchup::ComponentInstance))
          raise ArgumentError, 'Chọn đúng một Group hoặc Component trong SketchUp trước khi xuất hình chiếu.'
        end

        chosen = selected.first
        world = model.edit_transform * chosen.transformation
        entities = chosen.is_a?(Sketchup::Group) ? chosen.entities : chosen.definition.entities
        origin = world.origin
        x_axis = world.xaxis.normalize
        z_axis = x_axis.cross(world.yaxis).normalize
        z_axis.reverse! if z_axis.dot(world.zaxis) < 0
        axes = [x_axis, z_axis.cross(x_axis).normalize, z_axis]
        converter = lambda do |point, t|
          delta = (point.transform(t) - origin)
          axes.map { |axis| delta.dot(axis).to_f * Model3D::MILLIMETRES_PER_INCH }
        end
        edges, faces = [], []
        collect(entities, world, converter, edges, faces)
        raise ArgumentError, 'Group được chọn chưa có cạnh hiển thị để xuất.' if edges.empty?

        label = chosen.name.to_s.strip
        label = chosen.definition.name.to_s.strip if label.empty? && chosen.respond_to?(:definition)
        label = 'Chi tiết SketchUp' if label.empty?
        [label[0, 100], layout(edges, faces)]
      end

      def collect(entities, transform, converter, lines, triangles, level = 0)
        raise ArgumentError, 'Model có quá nhiều cấp nhóm lồng nhau.' if level >= 52

        entities.each do |e|
          next unless e.is_a?(Sketchup::Drawingelement)
          next if e.hidden? || !e.layer.visible?

          case e
          when Sketchup::Group, Sketchup::ComponentInstance
            children = e.is_a?(Sketchup::Group) ? e.entities : e.definition.entities
            collect(children, transform * e.transformation, converter, lines, triangles, level + 1)
          when Sketchup::Edge
            next if e.soft? || e.smooth?

            lines << [converter.call(e.start.position, transform), converter.call(e.end.position, transform)]
          when Sketchup::Face
            mesh = e.mesh
            points = mesh.points.map { |point| converter.call(point, transform) }
            mesh.polygons.each do |poly|
              indices = poly.map { |i| i.abs - 1 }
              (1...indices.length - 1).each { |i| triangles << [points[indices[0]], points[indices[i]], points[indices[i + 1]]] }
            end
          end
          if lines.length > MAX_EDGES || triangles.length > MAX_TRIANGLES
            raise ArgumentError, 'Đối tượng quá phức tạp. Chọn riêng quầy, tủ hoặc một cụm chi tiết nhỏ hơn.'
          end
        end
      end

      def project(p, axes)
        _, horizontal, vertical, depth, side = axes
        [p[horizontal], -p[vertical], side * p[depth]]
      end

      def cross(a, b, p)
        (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
      end

      def triangles_on_screen(faces, axes)
        faces.filter_map do |face|
          tri = face.map { |pt| project(pt, axes) }
          a, b, c = tri
          area = cross(a, b, c)
          next if area.abs < EPS

          [tri, area, bounds(tri)]
        end
      end

      def bounds(points)
        [*points.map { |p| p[0] }.minmax, *points.map { |p| p[1] }.minmax]
      end

      def depth_at(point, tri, area)
        a, b, c = tri
        wa = cross(b, c, point).fdiv(area)
        wb = cross(c, a, point).fdiv(area)
        wa * a[2] + wb * b[2] + (1 - wa - wb) * c[2]
      end

      def hidden_interval(segment, tri, area)
        from, to = segment
        factor = area < 0 ? -1 : 1
        low, high = 0.0, 1.0
        tri.each_with_index do |a, i|
          b = tri[(i + 1) % 3]
          x = cross(a, b, from) * factor
          y = cross(a, b, to) * factor
          return nil if x < -EPS && y < -EPS
          next if x >= -EPS && y >= -EPS

          t = x.fdiv(x - y)
          x < -EPS ? low = [low, t].max : high = [high, t].min
          return nil if high - low < EPS
        end
        a = depth_at(from, tri, area) - from[2] - 0.12
        b = depth_at(to, tri, area) - to[2] - 0.12
        return nil if a <= 0 && b <= 0

        if (a <= 0) != (b <= 0)
          cut = a / (a - b)
          a <= 0 ? low = [low, cut].max : high = [high, cut].min
        end
        high - low >= EPS ? [low, high] : nil
      end

      def visible_segments(segment, projected_faces)
        a, b = segment
        xmin, xmax, ymin, ymax = bounds(segment)
        hidden = projected_faces.filter_map do |tri, area, (left, right, top, bottom)|
          next if left > xmax || right < xmin || top > ymax || bottom < ymin

          hidden_interval(segment, tri, area)
        end.sort_by(&:first)
        visible = []
        cursor = 0.0
        hidden.each do |u, v|
          next if v < cursor

          visible << [cursor, u] if u - cursor > EPS
          cursor = [cursor, v].max
        end
        visible << [cursor, 1.0] if 1.0 - cursor > EPS
        visible.map do |distances|
          distances.map { |r| [a[0] + (b[0] - a[0]) * r, a[1] + (b[1] - a[1]) * r] }
        end.select { |p, q| Schema.length(p, q) >= 0.2 }
      end

      def line(points, layer, width = 13)
        { 't' => 'line', 'p' => points, 's' => '#263830', 'sw' => width, 'l' => layer }
      end

      def label(point, text, size, angle = 0)
        { 't' => 'text', 'a' => point, 'text' => text, 's' => '#263830', 'size' => size, 'angle' => angle, 'l' => 'NOTE' }
      end

      def layout(lines, triangles)
        measures = AXES.map { |a| bounds(lines.flatten(1).map { |p| project(p, a) }) }
        biggest = measures.map { |a, b, c, d| [b - a, d - c].max }.max
        text_size = [[biggest * 0.075, 35].max, 240].min
        gap = text_size * 4.6
        cursor = 0.0
        output = []
        AXES.each_with_index do |axes, index|
          left, right, top, bottom = measures[index]
          width, height = right - left, bottom - top
          projected = triangles_on_screen(triangles, axes)
          seen = {}
          lines.each do |edge|
            seg = edge.map { |p| project(p, axes) }
            visible_segments(seg, projected).each do |a, b|
              points = [a, b].map { |x, y| [cursor + x - left, y - top] }
              key = points.map { |p| p.map { |n| n.round(3) } }.sort
              next if seen[key]

              seen[key] = true
              output << line(points, 'VIEW')
            end
          end
          output << label([cursor + width / 2, height + text_size * 2.8], axes[0], text_size * 0.88)
          if width >= 0.2
            y = -text_size * 1.3
            output << line([[cursor, 0], [cursor, y], [cursor + width, y], [cursor + width, 0]], 'DIM', 9)
            output << label([cursor + width / 2, y - text_size * 0.65], width.round.to_s, text_size * 0.78)
          end
          if height >= 0.2
            x = cursor + width + text_size * 1.1
            output << line([[cursor + width, 0], [x, 0], [x, height], [cursor + width, height]], 'DIM', 9)
            output << label([x + text_size * 0.62, height / 2], height.round.to_s, text_size * 0.78, -90)
          end
          # Keep captions readable even when the projection has a very narrow footprint.
          caption_width = axes[0].length * text_size * 0.55
          cursor += [width, caption_width].max + gap
        end
        output
      end
    end
  end
end
