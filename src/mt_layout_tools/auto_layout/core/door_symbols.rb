# frozen_string_literal: true

module MTDesign
  module LayoutTools
    module AutoLayout
      # Ký hiệu hướng mở cánh trên mặt đứng.
      # - Loại ký hiệu do NGƯỜI DÙNG chọn cho từng cánh (không tự đoán bản lề theo vị trí).
      # - Lưu theo đường dẫn persistent_id ổn định của instance cánh: page['door_symbols'][path].
      # - Vẽ trong hộp bao của chính cánh trên hình chiếu (toạ độ hình -> giấy qua tf), nên đi theo hình
      #   khi đổi tỉ lệ / di chuyển / chuyển tờ. Mặt sau: tự đảo trái-phải.
      # - Chỉ vẽ lên bản vẽ (SVG/PDF), không đụng hình học, vật liệu, Tag của file SKP.
      module DoorSymbols
        TYPES = {
          'none' => 'Không ký hiệu',
          'left' => 'Mở trái (bản lề trái)',
          'right' => 'Mở phải (bản lề phải)',
          'double' => 'Cánh đôi',
          'up' => 'Lật lên (bản lề trên)',
          'down' => 'Lật xuống (bản lề dưới)',
          'slide_left' => 'Lùa sang trái',
          'slide_right' => 'Lùa sang phải',
          'drawer' => 'Ngăn kéo (kéo ra)'
        }.freeze
        HINGE = { 'left' => 'left', 'right' => 'right', 'double' => 'both', 'up' => 'top', 'down' => 'bottom' }.freeze
        SLIDE = { 'slide_left' => 'left', 'slide_right' => 'right', 'drawer' => 'out' }.freeze
        DASHES = { 'solid' => nil, 'dash' => [2.0, 1.0], 'dot' => [0.4, 0.8], 'dashdot' => [3.0, 0.8, 0.4, 0.8] }.freeze
        MIRROR = { 'left' => 'right', 'right' => 'left', 'slide_left' => 'slide_right', 'slide_right' => 'slide_left' }.freeze
        DEFAULT_STYLE = { 'w' => 0.18, 'color' => '#6B6F6C', 'dash' => 'dash' }.freeze

        module_function

        def clean_style(st)
          st = {} unless st.is_a?(Hash)
          color = st['color'].to_s =~ /\A#[0-9A-Fa-f]{6}\z/ ? st['color'].to_s.upcase : DEFAULT_STYLE['color']
          {
            'w' => (st.key?('w') ? st['w'].to_f : DEFAULT_STYLE['w']).clamp(0.05, 1.0).round(3),
            'color' => color,
            'dash' => DASHES.key?(st['dash'].to_s) ? st['dash'].to_s : DEFAULT_STYLE['dash']
          }
        end

        # { path => { type, hinge, slide, open, style, visible } }
        def clean(raw)
          return {} unless raw.is_a?(Hash)

          raw.each_with_object({}) do |(path, d), h|
            next unless path.to_s =~ %r{\A\d+(/\d+)*\z} && d.is_a?(Hash)

            type = TYPES.key?(d['type'].to_s) ? d['type'].to_s : 'none'
            h[path.to_s] = {
              'type' => type,
              'hinge' => HINGE[type],            # vị trí bản lề suy ra từ loại người dùng chọn
              'slide' => SLIDE[type],            # hướng lùa / kéo
              'open' => d['open'].to_s == 'in' ? 'in' : 'out',
              'style' => clean_style(d['style']),
              'visible' => d['visible'] != false
            }
            break h if h.length >= 2000
          end
        end

        # Đoạn thẳng (toạ độ giấy) cho 1 loại ký hiệu trong khung [l, t, r, b].
        def segments(type, l, t, r, b)
          mx = (l + r) / 2.0
          my = (t + b) / 2.0
          w = r - l
          h = b - t
          case type
          when 'left' then [[[r, t], [l, my]], [[r, b], [l, my]]]
          when 'right' then [[[l, t], [r, my]], [[l, b], [r, my]]]
          when 'double'
            [[[mx, t], [l, my]], [[mx, b], [l, my]], [[mx, t], [r, my]], [[mx, b], [r, my]]]
          when 'up' then [[[l, b], [mx, t]], [[r, b], [mx, t]]]
          when 'down' then [[[l, t], [mx, b]], [[r, t], [mx, b]]]
          when 'slide_left', 'slide_right'
            len = w * 0.6
            hs = [[w * 0.12, h * 0.25, 3.0].min, 0.6].max
            a = [mx + len / 2, my]
            z = [mx - len / 2, my]
            a, z = z, a if type == 'slide_right'
            dir = type == 'slide_left' ? 1 : -1
            [[a, z], [z, [z[0] + dir * hs, my - hs * 0.55]], [z, [z[0] + dir * hs, my + hs * 0.55]]]
          when 'drawer'
            len = h * 0.4
            hs = [[h * 0.12, w * 0.25, 3.0].min, 0.6].max
            a = [mx, my - len / 2]
            z = [mx, my + len / 2]
            [[a, z], [z, [mx - hs * 0.55, z[1] - hs]], [z, [mx + hs * 0.55, z[1] - hs]]]
          else []
          end
        end

        # v[:door_items]: [{ 'path', 'name', 'box' => [u0, u1, v0, v1] }] toạ độ hình (đã trừ gốc).
        def draw(cv, v, tf, syms)
          items = Array(v[:door_items])
          return if items.empty? || !syms.is_a?(Hash) || syms.empty?

          items.each do |it|
            sym = syms[it['path']]
            next unless sym && sym['visible'] != false

            type = sym['type'].to_s
            type = MIRROR.fetch(type, type) if v[:key] == 'back'
            next if type == 'none' || !TYPES.key?(type)

            u0, u1, v0, v1 = it['box']
            p0 = tf.call([u0, v0])
            p1 = tf.call([u1, v1])
            l, r = [p0[0], p1[0]].minmax
            t, b = [p0[1], p1[1]].minmax
            next if r - l < 0.5 || b - t < 0.5

            st = clean_style(sym['style'])
            dash = DASHES[st['dash']]
            cv.group('class' => 'doorsym', 'data-path' => it['path']) do
              segments(type, l, t, r, b).each { |a, z| cv.line(a, z, st['w'], st['color'], dash) }
            end
          end
        end
      end
    end
  end
end
