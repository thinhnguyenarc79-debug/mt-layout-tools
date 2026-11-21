# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # Liệt kê model (Group/Component cấp ngoài cùng) và Tag trong file SketchUp. Chỉ đọc, không sửa model.
      module ModelScanner
        module_function

        MM = 25.4

        def item(e)
          bb = e.bounds
          {
            'pid' => e.persistent_id,
            'name' => Geometry.instance_name(e),
            'kind' => e.is_a?(Sketchup::Group) ? 'Group' : 'Component',
            'tag' => e.layer ? e.layer.name : '',
            'size' => [bb.width, bb.depth, bb.height].map { |v| (v.to_f * MM).round },
            'hidden' => e.hidden?
          }
        end

        # Model cấp ngoài cùng + các đối tượng đang chọn (kể cả khi đang mở Group cha).
        def models(model)
          list = model.entities.select { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
          sel = model.selection.select { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
          sel_ids = sel.map(&:persistent_id)
          (list | sel).map { |e| item(e).merge('selected' => sel_ids.include?(e.persistent_id)) }
        end

        def tags(model)
          model.layers.map { |l| { 'name' => l.name, 'visible' => l.visible? } }
        end

        def find(model, pid)
          e = model.find_entity_by_persistent_id(pid.to_i)
          e if e && !e.deleted? && (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance))
        end
      end
    end
  end
end
