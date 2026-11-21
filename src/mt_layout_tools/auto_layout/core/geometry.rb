# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
    # Lấy hình học của Group/Component đang chọn và dựng hình chiếu có khử nét khuất.
    # Toạ độ hình chiếu: [u, v, sâu] đơn vị mm; u sang phải, v hướng XUỐNG, sâu càng lớn càng gần người nhìn.
    module Geometry
      module_function

      MM = 25.4
      MAX_EDGES = 6000
      MAX_TRIANGLES = 6000
      EPS = 1.0e-9
      DEFAULT_COLOR = '#E6E6E6'.freeze

      # key => [tên, lambda(p) -> [u, v_xuống, sâu]]
      VIEWS = {
        'front' => ['MẶT ĐỨNG',      ->(p) { [p[0], -p[2], -p[1]] }],
        'left'  => ['MẶT BÊN TRÁI',  ->(p) { [-p[1], -p[2], -p[0]] }],
        'right' => ['MẶT BÊN PHẢI',  ->(p) { [p[1], -p[2], p[0]] }],
        'back'  => ['MẶT SAU',       ->(p) { [-p[0], -p[2], p[1]] }],
        'top'   => ['MẶT BẰNG',      ->(p) { [p[0], -p[1], p[2]] }],
        'bottom' => ['MẶT ĐÁY',      ->(p) { [p[0], p[1], -p[2]] }],
        'open'  => ['MẶT ĐỨNG THÁO CÁNH', ->(p) { [p[0], -p[2], -p[1]] }],
        'iso'   => ['TRỤC ĐO', lambda do |p|
          r = [0.7071067811865476, -0.7071067811865476, 0.0]
          u = [0.4082482904638631, 0.4082482904638631, 0.8164965809277261]
          d = [-0.5773502691896258, -0.5773502691896258, 0.5773502691896258]
          dot = ->(a) { a[0] * p[0] + a[1] * p[1] + a[2] * p[2] }
          [dot.call(r), -dot.call(u), dot.call(d)]
        end]
      }.freeze
      ISO_LIGHT = [-0.45, -0.75, 0.48].freeze

      Capture = Struct.new(:name, :edges, :triangles, :materials)

      # Hướng mặt trước của đồ vật (người xem đứng ở phía nào theo trục cục bộ của Group/Component).
      # Xoay quanh Z để mặt trước luôn quay về -Y trước khi chiếu.
      FRONTS = {
        '-Y' => ->(x, y) { [x, y] },
        '+Y' => ->(x, y) { [-x, -y] },
        '-X' => ->(x, y) { [-y, x] },
        '+X' => ->(x, y) { [y, -x] }
      }.freeze

      # Ma trận đặt đối tượng trong toạ độ thế giới (tính cả khi đang mở edit một Group cha).
      def world_transform(model, inst)
        active_parent = model.active_entities.parent
        base = inst.parent == active_parent ? model.edit_transform : Geom::Transformation.new
        base * inst.transformation
      end

      # inst: Group/ComponentInstance. exclude: tên Tag bỏ qua. front: khoá trong FRONTS.
      def capture(model, inst, exclude = [], front = '-Y')
        unless inst.is_a?(Sketchup::Group) || inst.is_a?(Sketchup::ComponentInstance)
          raise ArgumentError, 'Đối tượng phải là Group hoặc Component.'
        end
        raise ArgumentError, 'Đối tượng đã bị xoá khỏi model.' if inst.deleted?

        world = world_transform(model, inst)
        origin = world.origin
        xa = world.xaxis.normalize
        ya = world.yaxis.normalize
        za = xa.cross(ya).normalize
        za.reverse! if za.dot(world.zaxis) < 0
        ya = za.cross(xa).normalize
        axes = [xa, ya, za]
        rot = FRONTS.fetch(front.to_s, FRONTS['-Y'])
        conv = lambda do |pt, t|
          d = pt.transform(t) - origin
          x, y, z = axes.map { |a| d.dot(a).to_f * MM }
          rx, ry = rot.call(x, y)
          [rx, ry, z]
        end

        cap = Capture.new(instance_name(inst), [], [], {})
        @exclude = exclude.map(&:to_s)
        ents = inst.is_a?(Sketchup::Group) ? inst.entities : inst.definition.entities
        collect(ents, world, conv, cap, inst.material, 0)
        raise ArgumentError, 'Đối tượng không có cạnh hiển thị (kiểm tra Tag đang lọc).' if cap.edges.empty?

        cap
      end

      def instance_name(inst)
        n = inst.name.to_s.strip
        n = inst.definition.name.to_s.strip if n.empty? && inst.respond_to?(:definition)
        n.empty? ? 'Chi tiết' : n[0, 100]
      end

      def collect(ents, tr, conv, cap, inherited, level)
        raise ArgumentError, 'Model lồng nhóm quá sâu.' if level > 50

        ents.each do |e|
          next unless e.is_a?(Sketchup::Drawingelement)
          next if e.hidden? || (e.layer && !e.layer.visible?)
          next if e.layer && @exclude.include?(e.layer.name)

          case e
          when Sketchup::Group, Sketchup::ComponentInstance
            kids = e.is_a?(Sketchup::Group) ? e.entities : e.definition.entities
            collect(kids, tr * e.transformation, conv, cap, e.material || inherited, level + 1)
          when Sketchup::Edge
            next if e.soft? || e.smooth?

            cap.edges << [conv.call(e.start.position, tr), conv.call(e.end.position, tr)]
          when Sketchup::Face
            mat = e.material || e.back_material || inherited
            key = register_material(cap, mat)
            mesh = e.mesh
            pts = mesh.points.map { |p| conv.call(p, tr) }
            mesh.polygons.each do |poly|
              idx = poly.map { |i| i.abs - 1 }
              (1...idx.length - 1).each { |i| cap.triangles << [pts[idx[0]], pts[idx[i]], pts[idx[i + 1]], key] }
            end
          end
          if cap.edges.length > MAX_EDGES || cap.triangles.length > MAX_TRIANGLES
            raise ArgumentError, 'Đối tượng quá phức tạp. Chọn riêng từng tủ/cụm nhỏ hơn.'
          end
        end
      end

      def register_material(cap, mat)
        return nil unless mat

        key = mat.display_name.to_s
        unless cap.materials[key]
          c = mat.color
          cap.materials[key] = { 'name' => key, 'color' => format('#%02X%02X%02X', c.red, c.green, c.blue) }
        end
        key
      end

      # --- Khử nét khuất -------------------------------------------------------

      def cross(a, b, p)
        (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
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

      def hidden_interval(seg, tri, area)
        from, to = seg
        f = area < 0 ? -1 : 1
        low, high = 0.0, 1.0
        tri.each_with_index do |a, i|
          b = tri[(i + 1) % 3]
          x = cross(a, b, from) * f
          y = cross(a, b, to) * f
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

      def visible_parts(seg, tris)
        a, b = seg
        xmin, xmax, ymin, ymax = bounds(seg)
        hidden = tris.filter_map do |tri, area, (l, r, t, btm)|
          next if l > xmax || r < xmin || t > ymax || btm < ymin

          hidden_interval(seg, tri, area)
        end.sort_by(&:first)
        vis = []
        cur = 0.0
        hidden.each do |u, v|
          next if v < cur

          vis << [cur, u] if u - cur > EPS
          cur = [cur, v].max
        end
        vis << [cur, 1.0] if 1.0 - cur > EPS
        vis.map { |r| r.map { |k| [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k] } }
           .reject { |p, q| Math.hypot(q[0] - p[0], q[1] - p[1]) < 0.2 }
      end

      # Trả về { name:, lines: [[p,q]..], fills: [[tri2d, color]..], box: [l,r,t,b] } toạ độ mm, gốc ở góc trên-trái.
      def project(cap, key)
        title, fn = VIEWS.fetch(key)
        tris = cap.triangles.filter_map do |t|
          p = t[0, 3].map { |pt| fn.call(pt) }
          area = cross(*p)
          next if area.abs < EPS

          [p, area, bounds(p), t[3], t]
        end
        all = cap.edges.flat_map { |e| e.map { |pt| fn.call(pt) } }
        l, r, t, b = bounds(all)
        lines = []
        seen = {}
        cap.edges.each do |e|
          seg = e.map { |pt| fn.call(pt) }
          visible_parts(seg, tris).each do |p, q|
            pts = [[p[0] - l, p[1] - t], [q[0] - l, q[1] - t]]
            k = pts.map { |pt| pt.map { |n| n.round(2) } }.sort
            next if seen[k]

            seen[k] = true
            lines << pts
          end
        end
        shade = key == 'iso'
        limit = [r - l, b - t].max / 8.0
        tris = tris.flat_map { |tr| subdivide(tr, limit, 3) } if shade
        fills = tris.sort_by { |p, _, _, _, _| p.sum { |pt| pt[2] } }.map do |p, _, _, mkey, raw|
          color = mkey ? cap.materials[mkey]['color'] : DEFAULT_COLOR
          color = shaded(color, raw) if shade
          [p.map { |pt| [pt[0] - l, pt[1] - t] }, color]
        end
        { key: key, name: title, lines: lines, fills: fills, w: r - l, h: b - t, dims: key != 'iso' }
      end

      # Chia nhỏ tam giác lớn để tô màu đúng thứ tự trước/sau (thuật toán hoạ sĩ).
      def subdivide(tr, limit, depth)
        p, area, _bb, mkey, raw = tr
        a, b, c = p
        long = [[a, b], [b, c], [c, a]].map { |x, y| Math.hypot(x[0] - y[0], x[1] - y[1]) }.max
        return [tr] if depth.zero? || long <= limit

        mid = ->(x, y) { x.zip(y).map { |m, n| (m + n) / 2.0 } }
        ab, bc, ca = mid.call(a, b), mid.call(b, c), mid.call(c, a)
        [[a, ab, ca], [ab, b, bc], [ca, bc, c], [ab, bc, ca]].flat_map do |q|
          subdivide([q, area / 4, nil, mkey, raw], limit, depth - 1)
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
        rgb = hex[1..-1].scan(/../).map { |h| (h.to_i(16) * k).round.clamp(0, 255) }
        format('#%02X%02X%02X', *rgb)
      end
    end
  end
  end
end
