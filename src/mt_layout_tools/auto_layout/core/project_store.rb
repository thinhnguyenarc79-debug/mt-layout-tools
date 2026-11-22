# encoding: UTF-8
require 'json'

module MTDesign
  module LayoutTools
    module AutoLayout
      # Dự án dàn trang: lưu trong thuộc tính của file SKP (chỉ khi người dùng bấm Lưu) hoặc file .json riêng.
      module ProjectStore
        module_function

        DICT = 'MTDesign_AutoLayout'.freeze
        VERSION = 3 # 3: project_id, saved_at, bố cục cố định từng hình (x_mm/y_mm/tờ cho cả hình tự động)
        SCHEMA = 'mt-autolayout-project'.freeze
        VIEW_KEYS = %w[front open left right back top bottom iso].freeze
        TB_FIELDS = %w[client project location company company_info lead designer checker drafter date].freeze
        MAX_BYTES = 20 * 1024 * 1024

        def default_project
          {
            'version' => VERSION, 'project_id' => new_id('prj'), 'saved_at' => nil, 'name' => 'Dự án mới', 'paper' => 'A3',
            'tb' => { 'company' => 'MT DESIGN', 'company_info' => 'Kiến trúc & Nội thất Mạnh Trường',
                      'date' => Time.now.strftime('%d.%m.%Y') },
            'exclude_tags' => [], 'door_tag' => '',
            'defaults' => default_page_settings,
            'mdim' => ManualDim.clean_cfg(nil),
            'pages' => []
          }
        end

        def default_page_settings
          { 'views' => %w[front open left top iso], 'scale' => 0, 'fill' => true, 'dims' => true,
            'min_gap' => 0, 'round' => 1, 'front' => '-Y' }
        end

        def new_id(prefix)
          "#{prefix}-#{Time.now.strftime('%y%m%d%H%M%S')}-#{rand(36**6).to_s(36)}"
        end

        def str(v, max = 200)
          v.to_s.strip[0, max]
        end

        # Làm sạch dữ liệu nhận từ giao diện/tệp trước khi dùng.
        def clean(raw)
          raise ArgumentError, 'Dữ liệu dự án không hợp lệ.' unless raw.is_a?(Hash)

          p = default_project
          p['project_id'] = str(raw['project_id'], 60) =~ /\A[\w.-]{4,60}\z/ ? str(raw['project_id'], 60) : p['project_id']
          p['saved_at'] = str(raw['saved_at'], 40).empty? ? nil : str(raw['saved_at'], 40)
          p['name'] = str(raw['name']).empty? ? p['name'] : str(raw['name'])
          p['paper'] = Sheet::PAPERS.key?(raw['paper']) ? raw['paper'] : 'A3'
          tb = raw['tb'].is_a?(Hash) ? raw['tb'] : {}
          p['tb'] = TB_FIELDS.each_with_object({}) { |k, h| h[k] = str(tb[k]) }
          p['exclude_tags'] = Array(raw['exclude_tags']).map { |t| str(t) }.uniq.first(500)
          p['door_tag'] = str(raw['door_tag'])
          p['defaults'] = clean_settings(raw['defaults'] || {})
          p['mdim'] = ManualDim.clean_cfg(raw['mdim']) # thiết lập công cụ DIM thủ công
          seen = {}
          p['pages'] = Array(raw['pages']).first(1000).map { |pg| clean_page(pg) }.reject do |pg|
            dup = pg['pid'].positive? && seen[pg['pid']]
            seen[pg['pid']] = true
            dup
          end
          p
        end

        def clean_settings(s)
          s = {} unless s.is_a?(Hash)
          d = default_page_settings
          {
            'views' => s.key?('views') ? Array(s['views']).map(&:to_s) & VIEW_KEYS : d['views'],
            'scale' => s.fetch('scale', 0).to_i.clamp(0, 500),
            'fill' => s.key?('fill') ? s['fill'] == true : true,
            # trục đo: material = màu vật liệu, mono = đơn sắc, none = không tô mặt; iso_hidden = vẽ nét khuất
            'iso_mode' => %w[material mono none].include?(s['iso_mode'].to_s) ? s['iso_mode'].to_s : 'material',
            'iso_hidden' => s['iso_hidden'] == true,
            'dims' => s.key?('dims') ? s['dims'] == true : true,
            'min_gap' => s.fetch('min_gap', 0).to_f.clamp(0, 1000),
            'round' => s.fetch('round', 1).to_f.clamp(0.1, 100),
            'front' => Geometry::FRONTS.key?(s['front']) ? s['front'] : '-Y'
          }
        end

        def clean_page(pg)
          raise ArgumentError, 'Trang giấy không hợp lệ.' unless pg.is_a?(Hash)

          offs = pg['offsets'].is_a?(Hash) ? pg['offsets'] : {}
          clean_settings(pg).merge(
            'id' => str(pg['id'], 40).empty? ? "p#{rand(36**8).to_s(36)}" : str(pg['id'], 40),
            'pid' => pg['pid'].to_i,
            'name' => str(pg['name']),
            'sheet_no' => str(pg['sheet_no'], 40),
            # số tờ giấy thật của trang (cập nhật sau mỗi lần dựng); mã tờ đánh tự động liên tiếp nếu auto_no
            'sheet_count' => pg.fetch('sheet_count', 1).to_i.clamp(1, 50),
            'auto_no' => pg['auto_no'] != false,
            'root' => pg['root'] != false, # trang cũ (v1) mặc định coi như tạo từ đối tượng ở gốc model
            'sections' => clean_sections(pg['sections']),
            'notes' => AnnotationEngine.clean(pg['notes']),
            'details' => DetailEngine.clean(pg['details']),
            'hidden_layers' => Array(pg['hidden_layers']).map { |x| str(x, 60) }.uniq.first(50),
            # Cánh chọn tay: đường dẫn persistent_id từ Group cha xuống instance cánh, vd "812/905".
            'doors' => [], # bản 2.4: đã chuyển sang 'roles' (cánh) – không giữ riêng nữa
            # vai trò bộ phận gán tay: { "pid/pid" => "door"|"side"|... }
            'roles' => clean_roles(pg['roles'], pg['doors']),
            # dịch tay từng số DIM: { "view|tier|n|i" => [dx, dy] } mm giấy
            'dimtext' => clean_dimtext(pg['dimtext']),
            'front_dims' => %w[auto exterior interior].include?(pg['front_dims'].to_s) ? pg['front_dims'].to_s : 'auto',
            'dimoff' => clean_dimoff(pg['dimoff']),
            # tỉ lệ riêng / khóa tỉ lệ / khóa vị trí từng hình: { key => {scale_override, scale_locked, position_locked} }
            'view_props' => clean_view_props(pg['view_props']),
            # ký hiệu hướng mở cánh (người dùng chọn): { "pid/pid" => {type, hinge, slide, open, style, visible} }
            'door_symbols' => DoorSymbols.clean(pg['door_symbols']),
            # cấu hình ký hiệu cánh mở nhìn từ trên (mặt bằng / mặt cắt nhìn từ trên) – dùng chung mọi cánh
            'swing' => DoorSwing.clean(pg['swing']),
            # bản sao hình chiếu: [{ 'n', 'src' (key hình gốc) }] -> hình 'cp:n' (độc lập vị trí/tỉ lệ/tờ)
            'copies' => clean_copies(pg['copies']),
            # DIM thủ công 2 điểm: { view_key => [dim] } – tách riêng Auto DIM, không bao giờ bị ghi đè khi dựng lại
            'manual_dims' => ManualDim.clean(pg['manual_dims']),
            # chỉnh sửa DIM tự động từng đoạn + chữ tên hình (v2.15) – lưu riêng, áp lại sau mỗi lần dựng
            'dim_over' => DimEdit.clean(pg['dim_over']),
            'captions' => DimEdit.clean_captions(pg['captions']),
            'offsets' => offs.each_with_object({}) do |(k, v), h|
              next unless (VIEW_KEYS.include?(k.to_s) || k.to_s =~ /\A(sec:[A-Z]|det:\d{1,2}|cp:\d{1,3})\z/) && v.is_a?(Array) && v.length == 2

              h[k.to_s] = v.map { |n| n.to_f.clamp(-2000, 2000) }
            end
          )
        end

        # Tạo/thay thế trang cho đúng các pid được tick (không thêm model nào khác).
        # finder: lambda(pid) -> { 'name' =>, 'root' => } hoặc nil nếu đối tượng không còn.
        # replace: true  -> model đã có trang thì dựng lại trang đó (giữ id, ký hiệu; đặt lại thiết lập & bố cục).
        #          false -> model đã có trang thì bỏ qua. Không bao giờ tạo trang trùng cho cùng 1 model.
        def add_pages(project, pids, finder, replace = true)
          res = { 'created' => [], 'replaced' => [], 'skipped' => [] }
          pids.map(&:to_i).uniq.each do |pid|
            found = finder.call(pid)
            next unless found

            found = { 'name' => found.to_s, 'root' => true } unless found.is_a?(Hash)
            old = project['pages'].find { |pg| pg['pid'] == pid }
            if old && !replace
              res['skipped'] << old['id']
              next
            end
            base = project['defaults'].merge('pid' => pid, 'name' => found['name'], 'root' => found['root'] != false,
                                             'offsets' => {})
            if old
              # dựng lại trang: giữ ký hiệu cánh và các hình đã KHÓA (tỉ lệ / vị trí) – không tự mở khóa
              keep = (old['view_props'] || {}).select do |_k, vp|
                vp['scale_locked'] || vp['position_locked'] || vp['placement_mode'] == 'manual'
              end
              # và phân loại bộ phận gán tay (roles) – không ghi đè dữ liệu người dùng khi triển khai lại
              base = base.merge('view_props' => keep, 'door_symbols' => old['door_symbols'] || {}, 'roles' => old['roles'] || {},
                                'manual_dims' => old['manual_dims'] || {}, 'dim_over' => old['dim_over'] || {},
                                'captions' => old['captions'] || {}, 'dimoff' => old['dimoff'] || {}, 'dimtext' => old['dimtext'] || {},
                                'offsets' => (old['offsets'] || {}).select { |k, _| keep[k] && keep[k]['position_locked'] })
              fresh = clean_page(base.merge('id' => old['id'], 'sheet_no' => old['sheet_no']))
              project['pages'][project['pages'].index(old)] = fresh
              res['replaced'] << fresh['id']
            else
              page = clean_page(base.merge('sheet_no' => next_sheet_no(project)))
              project['pages'] << page
              res['created'] << page['id']
            end
          end
          res
        end

        # Mã tờ thứ j (0-based) tính từ mã tờ đầu: "A-01" -> "A-02"; giữ số chữ số. Không có số -> "X-2".
        def increment(code, j)
          return code if j.zero?

          m = code.to_s.match(/\A(.*?)(\d+)(\D*)\z/)
          return "#{code}-#{j + 1}" unless m

          "#{m[1]}#{(m[2].to_i + j).to_s.rjust(m[2].length, '0')}#{m[3]}"
        end

        # Đánh lại mã cho mọi tờ theo thứ tự trang: trang auto_no nhận mã liên tiếp sau tờ cuối của trang trước.
        # counts: { page_id => số tờ } (mặc định page['sheet_count']). Trả về { page_id => [mã tờ 1, mã tờ 2, ...] }.
        def sheet_codes(project, counts = {})
          out = {}
          prev = nil
          project['pages'].each do |pg|
            n = (counts[pg['id']] || pg['sheet_count'] || 1).to_i.clamp(1, 50)
            base = pg['auto_no'] && prev ? increment(prev, 1) : (pg['sheet_no'].to_s.empty? ? 'A-01' : pg['sheet_no'])
            codes = (0...n).map { |j| increment(base, j) }
            out[pg['id']] = codes
            prev = codes.last
          end
          out
        end

        def next_sheet_no(project)
          used = project['pages'].map { |pg| pg['sheet_no'] }
          n = project['pages'].length + 1
          n += 1 while used.include?(format('A-%02d', n))
          format('A-%02d', n)
        end

        def clean_roles(raw, legacy_doors = nil)
          out = {}
          Array(legacy_doors).each { |pth| out[pth.to_s] = 'door' if pth.to_s =~ %r{\A\d+(/\d+){0,30}\z} } # chuyển từ bản 2.4
          return out unless raw.is_a?(Hash)

          raw.first(10_000).each do |k, v|
            next unless k.to_s =~ %r{\A\d+(/\d+){0,30}\z} && PartClassifier::ROLES.key?(v.to_s)

            out[k.to_s] = v.to_s
          end
          out
        end

        def clean_dimtext(raw)
          return {} unless raw.is_a?(Hash)

          raw.first(500).each_with_object({}) do |(k, v), h|
            next unless k.to_s.length <= 60 && v.is_a?(Array) && v.length == 2

            h[k.to_s] = v.map { |n| n.to_f.clamp(-80, 80).round(2) }
          end
        end

        # Dịch chuyển tay các hàng DIM: { view_key => { 'top'|'left'|'right' => mm giấy } }.
        def clean_dimoff(raw)
          return {} unless raw.is_a?(Hash)

          raw.first(60).each_with_object({}) do |(k, v), h|
            next unless v.is_a?(Hash) && k.to_s =~ /\A([a-z]+|sec:[A-Z]|det:\d{1,2}|cp:\d{1,3})\z/

            sides = v.select { |side, _| %w[top left right].include?(side.to_s) }
                     .transform_values { |n| n.to_f.clamp(-400, 400).round(2) } # kéo cả chuỗi (cả xuống dưới hình)
            h[k.to_s] = sides unless sides.empty?
          end
        end

        VIEW_PROP_KEY = /\A([a-z]+|sec:[A-Z]|det:\d{1,2}|cp:\d{1,3})\z/.freeze

        # Hình khóa tỉ lệ luôn có scale_override (khóa = giữ đúng tỉ lệ đang dùng). Không bao giờ tự mở khóa.
        def clean_view_props(raw)
          return {} unless raw.is_a?(Hash)

          raw.first(80).each_with_object({}) do |(k, v), h|
            next unless v.is_a?(Hash) && k.to_s =~ VIEW_PROP_KEY

            sc = v['scale_override'].to_i
            sc = nil unless sc.between?(1, 500)
            locked = v['scale_locked'] == true && !sc.nil?
            pos = v['position_locked'] == true
            # Vị trí trên giấy (mm, góc trên-trái khung hình) + tờ chứa hình. Có cho CẢ hình tự động (bố cục đã chốt
            # lần dựng đầu) -> không bao giờ tự tính lại; chỉ "Dàn trang lại" mới xoá.
            # placement_mode: 'auto' = plugin đặt, 'manual' = người dùng đã chỉnh (vẫn kéo tiếp được).
            has = v['x_mm'].is_a?(Numeric) && v['y_mm'].is_a?(Numeric)
            manual = v['placement_mode'] == 'manual' && has
            # chỉ có tờ, chưa có toạ độ: hình CHỜ ĐẶT trên tờ đó (vd. chi tiết mới trích, hình vừa chuyển tờ)
            pend = !has && v['sheet'].is_a?(Numeric)
            next if sc.nil? && !pos && !has && !pend

            h[k.to_s] = { 'scale_override' => sc, 'scale_locked' => locked, 'position_locked' => pos,
                          'placement_mode' => manual ? 'manual' : 'auto',
                          'x_mm' => has ? v['x_mm'].to_f.clamp(-500.0, 2000.0).round(2) : nil,
                          'y_mm' => has ? v['y_mm'].to_f.clamp(-500.0, 2000.0).round(2) : nil,
                          'sheet' => has || pend ? v['sheet'].to_i.clamp(0, 49) : nil,
                          'base_scale' => v['base_scale'].to_i.between?(1, 500) ? v['base_scale'].to_i : nil }
          end
        end

        def clean_copies(raw)
          used = {}
          Array(raw).first(60).filter_map do |c|
            next unless c.is_a?(Hash)

            n = c['n'].to_i
            src = c['src'].to_s
            next if n <= 0 || used[n] || src !~ /\A([a-z]+|sec:[A-Z]|det:\d{1,2})\z/

            used[n] = true
            { 'n' => n, 'src' => src }
          end
        end

        # Tỉ lệ hiệu lực của 1 hình: tỉ lệ riêng nếu có, ngược lại tỉ lệ mặc định của trang (0 = tự động).
        def effective_scale(page, key)
          vp = (page['view_props'] || {})[key]
          vp && vp['scale_override'] ? vp['scale_override'] : page['scale'].to_i
        end

        # nil = chưa có -> plugin tự đề xuất ở lần dựng đầu; [] = người dùng đã xoá hết.
        def clean_sections(list)
          return nil if list.nil?

          used = {}
          Array(list).first(26).filter_map do |sc|
            next unless sc.is_a?(Hash)

            label = sc['label'].to_s.upcase[0]
            next unless label =~ /[A-Z]/ && !used[label]
            next unless SectionEngine::AXES.key?(sc['axis'].to_s)

            used[label] = true
            { 'label' => label, 'axis' => sc['axis'].to_s, 'pos' => sc['pos'].to_f.clamp(-1.0e6, 1.0e6).round(1),
              'dir' => sc['dir'].to_i.negative? ? -1 : 1, 'auto' => sc['auto'] == true }
          end
        end

        def load(model)
          json = model.get_attribute(DICT, 'project')
          json ? clean(JSON.parse(json)) : default_project
        rescue JSON::ParserError, ArgumentError
          default_project
        end

        # LƯU DỰ ÁN: ghi vào thuộc tính của model thành 1 thao tác (Ctrl+Z được), không đụng hình học.
        # Đọc lại để xác nhận đã ghi đúng – lỗi thì báo lỗi, không báo thành công.
        # Lưu ý: đây là dữ liệu trong model đang mở; file .skp chỉ được ghi xuống ổ đĩa khi người dùng lưu SKP.
        def save(model, project)
          project = clean(project)
          project['saved_at'] = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
          json = JSON.generate(project)
          model.start_operation('AUTO LAYOUT PRO – Lưu dự án', true)
          model.set_attribute(DICT, 'project', json)
          model.commit_operation
          raise IOError, 'Đọc lại dữ liệu vừa lưu không khớp – chưa lưu được dự án.' unless model.get_attribute(DICT, 'project') == json

          project
        rescue StandardError
          begin
            model.abort_operation
          rescue StandardError
            nil
          end
          raise
        end

        # Bản sao .json độc lập: có schema, phiên bản, thời điểm tạo.
        def export_doc(project, meta = {})
          { 'schema' => SCHEMA, 'schema_version' => VERSION, 'created_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
            'plugin_version' => meta['plugin_version'], 'skp_path' => meta['skp_path'], 'project' => clean(project) }
        end

        # Nhận cả bản sao mới (có schema) lẫn tệp .json cũ (chỉ dự án).
        def import_doc(raw)
          raise ArgumentError, 'Tệp không phải dự án AUTO LAYOUT.' unless raw.is_a?(Hash)

          if raw['schema'] == SCHEMA
            raise ArgumentError, "Bản sao tạo bởi phiên bản mới hơn (schema #{raw['schema_version']})." if raw['schema_version'].to_i > VERSION

            clean(raw['project'])
          else
            clean(raw)
          end
        end

        def read_file(path)
          raise ArgumentError, 'Tệp dự án quá lớn.' if File.size(path) > MAX_BYTES

          import_doc(JSON.parse(File.read(path, encoding: 'UTF-8')))
        end

        # THÊM MODEL (giao dịch): dựng trang MỚI cho các model chưa có trang, KHÔNG đụng dự án hiện tại.
        # Trả { 'pages' => trang mới (chưa ghép), 'existing' => [pid đã có trang], 'missing' => [pid không tìm thấy] }.
        def new_pages(project, pids, finder)
          have = project['pages'].map { |pg| pg['pid'] }
          res = { 'pages' => [], 'existing' => [], 'missing' => [] }
          tmp = { 'pages' => project['pages'].dup }
          pids.map(&:to_i).uniq.each do |pid|
            if have.include?(pid)
              res['existing'] << pid
              next
            end
            found = finder.call(pid)
            unless found
              res['missing'] << pid
              next
            end
            found = { 'name' => found.to_s, 'root' => true } unless found.is_a?(Hash)
            pg = clean_page(project['defaults'].merge('pid' => pid, 'name' => found['name'], 'root' => found['root'] != false,
                                                      'offsets' => {}, 'sheet_no' => next_sheet_no(tmp)))
            tmp['pages'] << pg
            res['pages'] << pg
          end
          res
        end

        # Ghép trang mới vào CUỐI dự án; trang cũ giữ nguyên tuyệt đối (không sửa, không đổi thứ tự).
        def append_pages(project, pages)
          have = project['pages'].map { |pg| pg['pid'] }
          pages.each { |pg| project['pages'] << clean_page(pg) unless have.include?(pg['pid']) }
          project
        end
      end
    end
  end
end
