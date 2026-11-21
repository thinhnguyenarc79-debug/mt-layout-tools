# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # Nhận diện CÁNH TỦ – chỉ dựa trên dữ liệu người dùng đã gán, không đoán từ hình dạng tấm ván:
      #   1. Chọn tay (nút "CHỌN CÁNH TRONG SKETCHUP"), lưu theo đường dẫn instance ổn định (persistent_id).
      #   2. Thuộc tính (AttributeDictionary) có giá trị "cánh"/"door".
      #   3. Tag được chọn làm "Tag cánh".
      #   4. Tên Group/Component hoặc tên Definition chứa từ "cánh"/"door".
      # Không có dữ liệu nào -> coi như CHƯA xác định cánh (không ẩn gì, không tạo hình tháo cánh giả).
      module DoorDetector
        module_function

        NAME_RE = /(\A|[^[:alnum:]])(c[aá]nh|door|doors|c[ửu]a t[ủu])([^[:alnum:]]|\z)/i.freeze # 'cạnh' (edge) KHÔNG khớp
        VALUE_RE = /\A\s*(c[aá]nh|door|c[aá]nh t[ủu])\s*\z/i.freeze

        # Thuộc tính đánh dấu cánh trên instance hoặc definition (đọc 1 lần khi đọc definition).
        def attribute_says_door?(ent)
          [ent, ent.respond_to?(:definition) ? ent.definition : nil].compact.any? do |e|
            dicts = e.respond_to?(:attribute_dictionaries) ? e.attribute_dictionaries : nil
            next false unless dicts

            dicts.any? { |d| d.each_pair.any? { |_k, v| v.is_a?(String) && nfc(v) =~ VALUE_RE } }
          end
        rescue StandardError
          false
        end

        # Chuẩn hoá Unicode (tên tiếng Việt có thể ở dạng dấu tách rời).
        def nfc(str)
          str.to_s.unicode_normalize(:nfc)
        rescue StandardError
          str.to_s
        end

        # Lý do 1 instance là cánh (nil nếu không phải). info: { name:, def_name:, tag:, attr: }, path: "pid/pid".
        def reason(info, path, manual_paths, door_tags)
          return 'chọn tay' if manual_paths.include?(path)
          return 'thuộc tính' if info[:attr]
          return "Tag \"#{info[:tag]}\"" if !info[:tag].to_s.empty? && door_tags.include?(info[:tag])
          return 'tên' if nfc("#{info[:name]} #{info[:def_name]}") =~ NAME_RE

          nil
        end
      end
    end
  end
end
