# encoding: UTF-8
require 'json'

module MTDesign
  module LayoutTools
    module AutoLayout
      # Dự án dàn trang: lưu trong thuộc tính của file SKP (chỉ khi người dùng bấm Lưu) hoặc file .json riêng.
      module ProjectStore
        module_function

        DICT = 'MTDesign_AutoLayout'.freeze
        VERSION = 2
        VIEW_KEYS = %w[front open left right back top bottom iso].freeze
        TB_FIELDS = %w[client project location company company_info lead designer checker drafter date].freeze
        MAX_BYTES = 20 * 1024 * 1024

        def default_project
          {
            'version' => VERSION, 'name' => 'Dự án mới', 'paper' => 'A3',
            'tb' => { 'company' => 'MT DESIGN', 'company_info' => 'Kiến trúc & Nội thất Mạnh Trường',
                      'date' => Time.now.strftime('%d.%m.%Y') },
            'exclude_tags' => [], 'door_tag' => '',
            'defaults' => default_page_settings,
            'pages' => []
          }
        end

        def default_page_settings
          { 'views' => %w[front open left top iso], 'scale' => 0, 'fill' => true, 'dims' => true,
            'min_gap' => 0, 'round' => 1, 'front' => '-Y' }
        end

        def str(v, max = 200)
          v.to_s.strip[0, max]
        end

        # Làm sạch dữ liệu nhận từ giao diện/tệp trước khi dùng.
        def clean(raw)
          raise ArgumentError, 'Dữ liệu dự án không hợp lệ.' unless raw.is_a?(Hash)

          p = default_project
          p['name'] = str(raw['name']).empty? ? p['name'] : str(raw['name'])
          p['paper'] = Sheet::PAPERS.key?(raw['paper']) ? raw['paper'] : 'A3'
          tb = raw['tb'].is_a?(Hash) ? raw['tb'] : {}
          p['tb'] = TB_FIELDS.each_with_object({}) { |k, h| h[k] = str(tb[k]) }
          p['exclude_tags'] = Array(raw['exclude_tags']).map { |t| str(t) }.uniq.first(500)
          p['door_tag'] = str(raw['door_tag'])
          p['defaults'] = clean_settings(raw['defaults'] || {})
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
            'doors' => Array(pg['doors']).map(&:to_s).select { |x| x =~ %r{\A\d+(/\d+){0,30}\z} }.uniq.first(500),
            'front_dims' => %w[auto exterior interior].include?(pg['front_dims'].to_s) ? pg['front_dims'].to_s : 'auto',
            'dimoff' => clean_dimoff(pg['dimoff']),
            'offsets' => offs.each_with_object({}) do |(k, v), h|
              next unless (VIEW_KEYS.include?(k.to_s) || k.to_s =~ /\A(sec:[A-Z]|det:\d{1,2})\z/) && v.is_a?(Array) && v.length == 2

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

        # Dịch chuyển tay các hàng DIM: { view_key => { 'top'|'left'|'right' => mm giấy } }.
        def clean_dimoff(raw)
          return {} unless raw.is_a?(Hash)

          raw.first(60).each_with_object({}) do |(k, v), h|
            next unless v.is_a?(Hash) && k.to_s =~ /\A([a-z]+|sec:[A-Z]|det:\d{1,2})\z/

            sides = v.select { |side, _| %w[top left right].include?(side.to_s) }
                     .transform_values { |n| n.to_f.clamp(-60, 60).round(2) }
            h[k.to_s] = sides unless sides.empty?
          end
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

        # Ghi vào model thành 1 thao tác (Ctrl+Z được). Chỉ thêm thuộc tính, không đụng hình học.
        def save(model, project)
          model.start_operation('AUTO LAYOUT PRO – Lưu dự án', true)
          model.set_attribute(DICT, 'project', JSON.generate(project))
          model.commit_operation
        rescue StandardError
          model.abort_operation
          raise
        end

        def read_file(path)
          raise ArgumentError, 'Tệp dự án quá lớn.' if File.size(path) > MAX_BYTES

          clean(JSON.parse(File.read(path, encoding: 'UTF-8')))
        end
      end
    end
  end
end
