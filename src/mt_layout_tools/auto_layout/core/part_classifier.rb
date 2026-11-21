# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # NHẬN DIỆN BỘ PHẬN TỦ. Thứ tự ưu tiên (cao -> thấp):
      #   1. Người dùng gán tay (theo đường dẫn instance ổn định)            -> chắc chắn
      #   2. AttributeDictionary (giá trị "cánh", "door", "vách", ...)         -> chắc chắn
      #   3. Tag được chọn làm "Tag cánh"                                      -> chắc chắn
      #   4. Tên Group/Component/Definition                                    -> chắc chắn
      #   5. Tên Tag chứa từ khoá                                              -> chắc chắn
      #   6. Vật liệu kính/gương                                               -> đề xuất
      #   7. Hình học: độ dày, hướng tấm, vị trí trong thân tủ                -> ĐỀ XUẤT (cần xác nhận)
      # Không đủ dữ liệu -> "unknown" (Chưa xác định). Không bao giờ coi mọi tấm đứng là cánh.
      module PartClassifier
        module_function

        ROLES = {
          'door' => 'Cánh', 'side' => 'Vách đứng', 'shelf' => 'Đợt', 'top' => 'Nóc', 'bottom' => 'Đáy',
          'back' => 'Hậu', 'drawer' => 'Ngăn kéo', 'handle' => 'Tay nắm', 'glass' => 'Kính/gương',
          'accessory' => 'Phụ kiện', 'unknown' => 'Chưa xác định'
        }.freeze

        B = '(\A|[^[:alnum:]])'.freeze
        E = '([^[:alnum:]]|\z)'.freeze
        NAME_RES = {
          'drawer' => /#{B}(ng[aă]n k[eé]o|hộc kéo|h[oộ]c k[eé]o|drawer)#{E}/i,
          'handle' => /#{B}(tay n[aắ]m|handle|knob|pull)#{E}/i,
          'door' => /#{B}(c[aá]nh|door|doors|c[ửu]a t[ủu])#{E}/i, # 'cạnh' (edge) KHÔNG khớp
          'glass' => /#{B}(k[ií]nh|g[ưu][ơo]ng|glass|mirror)#{E}/i,
          'back' => /#{B}(h[ậa]u|back|backpanel)#{E}/i,
          'top' => /#{B}(n[óo]c|top)#{E}/i,
          'bottom' => /#{B}(đáy|bottom)#{E}/i,
          'shelf' => /#{B}(đợt|shelf|shelves)#{E}/i,
          'side' => /#{B}(v[aá]ch|h[ôo]ng|side|divider)#{E}/i,
          'accessory' => /#{B}(ph[ụu] ki[ệe]n|b[ảa]n l[ềe]|ray tr[ưu][ợo]t|hinge|accessor\w*)#{E}/i
        }.freeze
        GLASS_MAT = /(k[ií]nh|g[ưu][ơo]ng|glass|mirror)/i.freeze

        def nfc(str)
          str.to_s.unicode_normalize(:nfc)
        rescue StandardError
          str.to_s
        end

        def label(role)
          ROLES.fetch(role.to_s, ROLES['unknown'])
        end

        def by_text(text)
          t = nfc(text)
          NAME_RES.each { |role, re| return role if t =~ re }
          nil
        end

        # Giá trị thuộc tính chỉ rõ vai trò (vd. role=door, loai=cánh) trên instance hoặc definition.
        def attribute_role(ent)
          [ent, ent.respond_to?(:definition) ? ent.definition : nil].compact.each do |e|
            dicts = e.respond_to?(:attribute_dictionaries) ? e.attribute_dictionaries : nil
            next unless dicts

            dicts.each do |d|
              d.each_pair do |_k, v|
                next unless v.is_a?(String) && v.length <= 40

                return v.strip.downcase if ROLES.key?(v.strip.downcase) && v.strip.downcase != 'unknown'

                r = by_text(v)
                return r if r && nfc(v).strip.split(/\s+/).length <= 3
              end
            end
          end
          nil
        rescue StandardError
          nil
        end

        # Vai trò chắc chắn từ dữ liệu (không dùng hình học). info: { name:, def_name:, tag:, attr: }.
        # Trả về [role, nguồn] hoặc nil.
        def explicit(info, path, manual, door_tags)
          m = manual[path]
          return [m, 'gán tay'] if m && ROLES.key?(m)
          return [info[:attr], 'thuộc tính'] if info[:attr]
          return ['door', "Tag \"#{info[:tag]}\""] if !info[:tag].to_s.empty? && door_tags.include?(info[:tag])

          r = by_text("#{info[:name]} #{info[:def_name]}")
          return [r, 'tên'] if r

          r = by_text(info[:tag])
          return [r, "Tag \"#{info[:tag]}\""] if r && info[:tag].to_s !~ /\Auntagged\z/i

          nil
        end

        # ĐỀ XUẤT theo hình học. b: [[xmin,xmax],[ymin,ymax],[zmin,zmax]] của bộ phận; ext: của cả tủ (mm, trục tủ:
        # X rộng, Y sâu – mặt trước ở Y nhỏ, Z cao). Trả về [role, lý do].
        def geometric(b, ext, material = nil)
          return ['glass', 'vật liệu kính/gương'] if material && material.to_s =~ GLASS_MAT

          dx, dy, dz = b.map { |lo, hi| hi - lo }
          w = ext[0][1] - ext[0][0]
          d = ext[1][1] - ext[1][0]
          h = ext[2][1] - ext[2][0]
          front = ext[1][0]
          back = ext[1][1]
          t = [dx, dy, dz].min
          return ['handle', 'chi tiết nhỏ ở mặt trước'] if [dx, dy, dz].max < 250 && b[1][0] <= front + 60
          return ['unknown', 'không phải tấm ván (dày > 40 mm)'] if t > 40

          if dy <= t + 1e-6 # tấm đứng song song mặt trước
            if b[1][0] <= front + 25 && dx * dz >= 0.04 * w * h
              ['door', 'tấm đứng nằm ở mặt trước tủ']
            elsif b[1][1] >= back - 25 && dx * dz >= 0.2 * w * h
              ['back', 'tấm đứng nằm ở mặt sau tủ']
            else
              ['unknown', 'tấm đứng song song mặt trước, không ở mặt trước/sau']
            end
          elsif dx <= t + 1e-6 # tấm đứng vuông góc mặt trước
            dy >= 0.5 * d ? ['side', 'tấm đứng chạy theo chiều sâu'] : ['unknown', 'tấm đứng ngắn theo chiều sâu']
          else # tấm nằm ngang
            if b[2][1] >= ext[2][1] - 25 && dx >= 0.5 * w
              ['top', 'tấm ngang trên cùng']
            elsif b[2][0] <= ext[2][0] + 0.2 * h && dx >= 0.5 * w
              ['bottom', 'tấm ngang thấp nhất']
            else
              ['shelf', 'tấm ngang bên trong']
            end
          end
        end
      end

      # Tương thích bản 2.4 (nhận diện cánh).
      module DoorDetector
        module_function

        NAME_RE = PartClassifier::NAME_RES['door']

        def nfc(str)
          PartClassifier.nfc(str)
        end

        def attribute_says_door?(ent)
          PartClassifier.attribute_role(ent) == 'door'
        end

        def reason(info, path, manual_paths, door_tags)
          manual = manual_paths.is_a?(Hash) ? manual_paths : manual_paths.to_h { |p| [p, 'door'] }
          r = PartClassifier.explicit(info.merge(attr: info[:attr] == true ? 'door' : info[:attr]), path, manual, door_tags)
          return nil unless r && r[0] == 'door'

          r[1] == 'gán tay' ? 'chọn tay' : r[1]
        end
      end
    end
  end
end
