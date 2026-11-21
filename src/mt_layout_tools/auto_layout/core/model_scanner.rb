# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # Đọc các Group/Component NGƯỜI DÙNG ĐANG CHỌN trong SketchUp. Chỉ đọc, không sửa model,
      # không quét cả file, không tách Group/Component con thành model riêng.
      module ModelScanner
        module_function

        MM = 25.4
        NO_SELECTION = 'Bạn chưa chọn Group hoặc Component trong SketchUp. Hãy chọn đối tượng cần triển khai trước.'.freeze

        def model_like?(e)
          e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        end

        # Hệ số co giãn theo 3 trục cục bộ (lấy từ ma trận 4x4, đọc theo cột).
        def scale_factors(t)
          a = t.to_a
          [a[0..2], a[4..6], a[8..10]].map { |v| Math.sqrt(v.sum { |c| c * c }) }
        end

        # Kích thước thật theo trục của chính đối tượng (đúng cả khi bị xoay): [Rộng X, Cao Z, Sâu Y] mm.
        # Lưu ý API: BoundingBox#width = X, #height = Y, #depth = Z.
        def size_mm(e)
          bb = e.definition.bounds
          sx, sy, sz = scale_factors(e.transformation)
          [bb.width * sx, bb.depth * sz, bb.height * sy].map { |v| (v.to_f * MM).round }
        end

        def item(e)
          {
            'pid' => e.persistent_id,
            'name' => Geometry.instance_name(e),
            'kind' => e.is_a?(Sketchup::Group) ? 'Group' : 'Component',
            'tag' => e.layer ? e.layer.name : '',
            'size' => size_mm(e),
            'hidden' => e.hidden?
          }
        end

        # Chỉ các Group/Component đang được chọn (bỏ qua cạnh, mặt, chữ...). Mỗi đối tượng chọn = 1 model.
        def models(model)
          seen = {}
          model.selection.to_a.select { |e| model_like?(e) }.each_with_object([]) do |e, list|
            next if seen[e.persistent_id]

            seen[e.persistent_id] = true
            list << item(e)
          end
        end

        def tags(model)
          model.layers.map { |l| { 'name' => l.name, 'visible' => l.visible? } }
        end

        def find(model, pid)
          e = model.find_entity_by_persistent_id(pid.to_i)
          e if e && !e.deleted? && model_like?(e)
        end
      end
    end
  end
end
