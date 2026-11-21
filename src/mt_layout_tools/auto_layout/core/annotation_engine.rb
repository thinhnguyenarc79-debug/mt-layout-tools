# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # Chú thích do NGƯỜI DÙNG đặt trên giấy: Text, Text nhiều dòng, Leader (mũi tên chỉ chi tiết), Ghi chú vật liệu.
      # Plugin không tự sinh nội dung chú thích. Toạ độ: mm trên giấy (y hướng xuống).
      module AnnotationEngine
        module_function

        TYPES = %w[text mtext leader material].freeze
        ARROWS = %w[arrow dot none].freeze
        DEFAULT_LAYER = 'GHI CHÚ'.freeze

        def clean(list)
          used = {}
          Array(list).first(500).filter_map do |n|
            next unless n.is_a?(Hash) && TYPES.include?(n['type'].to_s)

            id = n['id'].to_s[0, 40]
            id = "n#{rand(36**8).to_s(36)}" if id.empty? || used[id]
            used[id] = true
            color = n['color'].to_s =~ /\A#[0-9A-Fa-f]{6}\z/ ? n['color'].to_s : '#1E1E1E'
            {
              'id' => id, 'type' => n['type'].to_s,
              'x' => n['x'].to_f.clamp(-50, 1300), 'y' => n['y'].to_f.clamp(-50, 900),
              'tx' => n['tx'].to_f.clamp(-50, 1300), 'ty' => n['ty'].to_f.clamp(-50, 900),
              'text' => n['text'].to_s[0, 2000],
              'size' => n.fetch('size', 2.5).to_f.clamp(1.0, 20.0),
              'color' => color,
              'arrow' => ARROWS.include?(n['arrow'].to_s) ? n['arrow'].to_s : 'arrow',
              'layer' => (n['layer'].to_s.strip.empty? ? DEFAULT_LAYER : n['layer'].to_s.strip[0, 60]),
              'sheet' => n['sheet'].to_i.clamp(0, 49) # chú thích thuộc tờ nào của trang
            }
          end
        end

        def draw(cv, notes, hidden_layers = [])
          Array(notes).each do |n|
            next if hidden_layers.include?(n['layer'])

            cv.group('class' => 'note', 'data-id' => n['id']) { draw_one(cv, n) }
          end
        end

        def lines_of(n)
          txt = n['text'].to_s
          n['type'] == 'text' ? [txt.split("\n").first.to_s] : txt.split("\n")
        end

        def draw_one(cv, n)
          size = n['size']
          rows = lines_of(n)
          rows = [''] if rows.empty?
          lh = size * 1.35
          width = rows.map { |r| cv.text_w(r, size) }.max.to_f
          x = n['x']
          y = n['y']
          if %w[leader material].include?(n['type'])
            tip = [n['tx'], n['ty']]
            right = x >= tip[0] # chữ nằm bên phải điểm gãy
            shoulder = [x + (right ? 0 : 0), y]
            cv.line(tip, shoulder, 0.18, n['color'])
            end_pt = [shoulder[0] + (right ? 3 : -3), y]
            cv.line(shoulder, end_pt, 0.18, n['color'])
            arrow_head(cv, tip, shoulder, n['arrow'], n['color'])
            tx = right ? end_pt[0] + 0.8 : end_pt[0] - 0.8 - width
            ty = y - (rows.length - 1) * lh / 2.0
          else
            tx = x
            ty = y
          end
          rows.each_with_index { |r, i| cv.text_left(r, tx, ty + i * lh, size, n['color']) }
          # vùng bấm chọn (trong suốt) cho giao diện
          cv.rect(tx - 0.6, ty - size * 0.75, width + 1.2, lh * rows.length + 0.3, 'transparent', nil) if cv.fmt == :svg
        end

        def arrow_head(cv, tip, from, kind, color)
          dx = from[0] - tip[0]
          dy = from[1] - tip[1]
          len = Math.hypot(dx, dy)
          return if len < 1e-6 || kind == 'none'

          if kind == 'dot'
            cv.circle(tip, 0.55, color, nil)
            return
          end
          ux = dx / len
          uy = dy / len
          a = [tip[0] + ux * 2.2 - uy * 0.7, tip[1] + uy * 2.2 + ux * 0.7]
          b = [tip[0] + ux * 2.2 + uy * 0.7, tip[1] + uy * 2.2 - ux * 0.7]
          cv.poly([tip, a, b], color)
        end
      end
    end
  end
end
