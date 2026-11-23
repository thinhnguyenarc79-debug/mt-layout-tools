# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # THEO DÕI THAY ĐỔI MODEL (v2.17) để giữ cache hình học/hình chiếu khi model KHÔNG đổi thật:
      # mở lại cửa sổ, bấm "Cập nhật bản vẽ", chuyển trang qua lại không phải đọc & dựng lại từ đầu.
      # Mọi thao tác sửa model trong SketchUp đều là 1 transaction -> ModelObserver#onTransactionCommit/Undo/Redo
      # tăng số phiên bản. Chỉ đọc, không ghi gì vào model. Nếu không gắn được observer -> trả nil và plugin
      # quay về cách cũ (chỉ giữ cache trong 1 phiên cửa sổ).
      module ModelWatch
        @revs ||= {}
        @attached ||= {}

        if defined?(Sketchup::ModelObserver)
          class Observer < Sketchup::ModelObserver
            def onTransactionCommit(model)
              ModelWatch.bump(model)
            end

            def onTransactionUndo(model)
              ModelWatch.bump(model)
            end

            def onTransactionRedo(model)
              ModelWatch.bump(model)
            end
          end
        end

        module_function

        def bump(model)
          id = model.object_id
          @revs[id] = @revs.fetch(id, 0) + 1
        end

        # Khoá cache [model, phiên bản]; nil nếu không theo dõi được.
        def key(model)
          return nil unless model

          id = model.object_id
          unless @attached.key?(id)
            @attached[id] = begin
              defined?(Observer) && model.add_observer(Observer.new) ? true : false
            rescue StandardError
              false
            end
          end
          @attached[id] ? [id, @revs.fetch(id, 0)] : nil
        end
      end
    end
  end
end
