# encoding: UTF-8
require 'json'

module MTDesign
  module LayoutTools
    module AutoLayout
      # Dự án dàn trang: lưu trong thuộc tính của file SKP (chỉ khi người dùng bấm Lưu) hoặc file .json riêng.
      module ProjectStore
        module_function

        DICT = 'MTDesign_AutoLayout'.freeze
        VERSION = 1
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
          p['pages'] = Array(raw['pages']).first(1000).map { |pg| clean_page(pg) }
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
            'offsets' => offs.each_with_object({}) do |(k, v), h|
              next unless VIEW_KEYS.include?(k.to_s) && v.is_a?(Array) && v.length == 2

              h[k.to_s] = v.map { |n| n.to_f.clamp(-2000, 2000) }
            end
          )
        end

        # Tạo 1 trang cho mỗi pid được tick. finder: lambda(pid) -> [tên] hoặc nil nếu không còn đối tượng.
        # Chỉ tạo đúng các pid truyền vào, không thêm model nào khác.
        def add_pages(project, pids, finder)
          created = []
          pids.map(&:to_i).uniq.each do |pid|
            name = finder.call(pid)
            next unless name

            no = format('A-%02d', project['pages'].length + 1)
            page = clean_page(project['defaults'].merge('pid' => pid, 'name' => name, 'sheet_no' => no, 'offsets' => {}))
            project['pages'] << page
            created << page['id']
          end
          created
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
