# encoding: UTF-8
module MTDesign
  module MatBang
    module Schema
      module_function

      MAX_COORD = 2_000_000
      ITEM_TYPES = %w[wall floor door window furniture dimension].freeze
      FURNITURE = %w[table dining counter cabinet sofa planter].freeze
      NAME = /\A[^\u0000-\u001f\u007f]{1,100}\z/
      PID = /\Ap[1-9][0-9]{0,8}\z/
      HEX = /\A#[0-9a-fA-F]{6}\z/
      LAYER = /\A[A-Z_]{1,24}\z/

      def object(value)
        raise ArgumentError, 'Dữ liệu phải là một đối tượng.' unless value.is_a?(Hash)

        value
      end

      def list(value, min, max)
        unless value.is_a?(Array) && value.length.between?(min, max)
          raise ArgumentError, 'Số phần tử của dữ liệu không hợp lệ.'
        end
        value
      end

      def num(value, min = -MAX_COORD, max = MAX_COORD)
        unless value.is_a?(Numeric) && value.finite? && value.between?(min, max)
          raise ArgumentError, 'Giá trị kích thước hoặc tọa độ vượt phạm vi.'
        end
        value.to_f
      end

      def text(value, pattern = NAME)
        unless value.is_a?(String) && value.valid_encoding? && pattern.match?(value)
          raise ArgumentError, 'Tên hoặc mã đối tượng không hợp lệ.'
        end
        value.unicode_normalize(:nfc)
      end

      def point(value)
        list(value, 2, 2).map { |n| num(n) }
      end

      def length(a, b)
        Math.hypot(b[0] - a[0], b[1] - a[1])
      end

      def polygon(value)
        points = list(value, 3, 400).map { |p| point(p) }
        edges = points.each_index.map { |i| [points[i], points[(i + 1) % points.length]] }
        area = edges.sum { |a, b| a[0] * b[1] - a[1] * b[0] }.abs / 2
        raise ArgumentError, 'Biên sàn quá nhỏ.' if area < 100 || edges.any? { |a, b| length(a, b) < 9.99 }

        edges.each_with_index do |(a, b), i|
          edges.each_with_index do |(c, d), j|
            next if j <= i + 1 || (i.zero? && j == edges.length - 1)
            raise ArgumentError, 'Biên sàn tự giao.' if crossing?(a, b, c, d)
          end
        end
        points
      end

      def cross(a, b, c)
        (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
      end

      def crossing?(a, b, c, d)
        u, v, x, y = [cross(a, b, c), cross(a, b, d), cross(c, d, a), cross(c, d, b)]
        between = lambda do |p, q, r|
          r[0].between?(*[p[0], q[0]].minmax) && r[1].between?(*[p[1], q[1]].minmax)
        end
        (u * v < 0 && x * y < 0) ||
          (u.zero? && between.call(a, b, c)) || (v.zero? && between.call(a, b, d)) ||
          (x.zero? && between.call(c, d, a)) || (y.zero? && between.call(c, d, b))
      end

      def shape(raw)
        raw = object(raw)
        id = text(raw['id'], PID)
        type = raw['type']
        raise ArgumentError, 'Kiểu đối tượng mặt bằng không hợp lệ.' unless ITEM_TYPES.include?(type)

        result = { 'id' => id, 'type' => type }
        result['c'] = text(raw['c'], HEX) if %w[wall floor furniture].include?(type)
        result['a'] = point(raw['a']) if %w[wall furniture dimension].include?(type)
        result['b'] = point(raw['b']) if %w[wall dimension].include?(type)
        result['name'] = text(raw['name']) if %w[floor furniture].include?(type)
        case type
        when 'wall'
          result['t'] = num(raw['t'], 25, 3000)
          result['h'] = num(raw['h'], 100, 30_000)
          if length(result['a'], result['b']) < 24.99
            raise ArgumentError, 'Đoạn tường cần dài ít nhất 25 mm.'
          end
        when 'floor'
          result['p'] = polygon(raw['p'])
          result['t'] = num(raw['t'], 10, 3000)
        when 'door', 'window'
          result['wall'] = text(raw['wall'], PID)
          result['at'] = num(raw['at'], 0, MAX_COORD)
          result['w'] = num(raw['w'], 100, 20_000)
          result['h'] = num(raw['h'], 100, 30_000)
          result['sill'] = type == 'window' ? num(raw['sill'], 0, 29_900) : 0.0
          result['flip'] = raw['flip'] == true if type == 'door'
          result['swing'] = raw['swing'] == true if type == 'door'
        when 'furniture'
          raise ArgumentError, 'Mẫu nội thất không hợp lệ.' unless FURNITURE.include?(raw['kind'])

          result['kind'] = raw['kind']
          %w[w d h].each { |k| result[k] = num(raw[k], 100, 30_000) }
          result['angle'] = num(raw['angle'], -360, 360)
        when 'dimension'
          result['offset'] = num(raw['offset'])
          %w[ra rb].each do |key|
            next unless raw[key]

            ref = object(raw[key])
            raise ArgumentError, 'Điểm neo dim không hợp lệ.' unless %w[a b p].include?(ref['k'])

            result[key] = { 'id' => text(ref['id'], PID), 'k' => ref['k'] }
            result[key]['i'] = num(ref['i'], 0, 399).to_i if ref['k'] == 'p'
          end
        end
        result
      end

      def project(raw)
        raw = object(raw)
        raise ArgumentError, 'Phiên bản mặt bằng không tương thích.' unless raw['v'] == 1

        items = list(raw['items'], 0, 1200).map { |o| shape(o) }
        index = items.each_with_object({}) do |part, by_id|
          raise ArgumentError, 'Có mã đối tượng bị trùng.' if by_id.key?(part['id'])

          by_id[part['id']] = part
        end
        openings = items.select { |o| o.key?('wall') }.group_by { |o| o['wall'] }
        openings.each do |wid, cuts|
          wall = index[wid]
          raise ArgumentError, 'Cửa đã mất liên kết với tường.' unless wall && wall['type'] == 'wall'

          span = length(wall['a'], wall['b'])
          previous = 0.0
          cuts.sort_by { |o| o['at'] }.each do |o|
            start = o['at'] - o['w'] / 2
            finish = o['at'] + o['w'] / 2
            unless start >= previous - 0.002 && start >= -0.002 && finish <= span + 0.002 &&
                   o['sill'] + o['h'] <= wall['h'] + 0.002
              raise ArgumentError, 'Ô cửa vượt khỏi tường hoặc chồng lên cửa khác.'
            end
            previous = finish
          end
        end
        items.each do |o|
          next unless o['type'] == 'dimension'

          %w[ra rb].zip(%w[a b]).each do |key, point_key|
            ref = o[key]
            next unless ref

            source = index[ref['id']]
            point = source && (ref['k'] == 'p' ? source.fetch('p', [])[ref['i']] : source[ref['k']])
            if point && %w[wall floor furniture].include?(source['type'])
              o[point_key] = point.dup
            else
              o.delete(key)
            end
          end
        end
        watermark = [num(raw.fetch('watermark', 0), 0, 999_999_999).to_i,
                     items.map { |o| o['id'][1..-1].to_i }.max || 0].max
        { 'v' => 1, 'name' => text(raw['name']), 'items' => items, 'watermark' => watermark }
      end

      def boxes(raw, project)
        raw = object(raw)
        project['items'].each_with_object({}) do |o, result|
          next unless o['type'] == 'furniture'

          result[o['id']] = list(raw[o['id']], 1, 60).map do |row|
            list(row, 6, 6).each_with_index.map { |v, i| i < 3 ? num(v) : num(v, 0.1, 40_000) }
          end
        end
      end

      def scene(raw)
        list(raw, 1, 30_000).map do |entry|
          o = object(entry)
          t = o['t']
          raise ArgumentError, 'Nét vẽ không hợp lệ.' unless %w[line poly text].include?(t)

          result = { 't' => t, 's' => text(o['s'], HEX), 'l' => text(o['l'], LAYER) }
          if t == 'text'
            result.merge!('a' => point(o['a']), 'text' => text(o['text']), 'size' => num(o['size'], 1, 5000),
                          'angle' => num(o.fetch('angle', 0), -360, 360), 'back' => o['back'] == true)
          else
            result['p'] = list(o['p'], t == 'poly' ? 3 : 2, 400).map { |p| point(p) }
            result['f'] = text(o['f'], HEX) if o['f']
            result['sw'] = num(o['sw'], 0.01, 1000)
          end
          result
        end
      end

      def settings(raw)
        raw = object(raw)
        paper = raw['paper']
        raise ArgumentError, 'Khổ giấy không hợp lệ.' unless %w[A3 A4].include?(paper)

        scale = num(raw['scale'], 10, 500)
        { 'paper' => paper, 'scale' => scale, 'name' => text(raw['name']), 'mono' => raw['mono'] == true }
      end
    end
  end
end
