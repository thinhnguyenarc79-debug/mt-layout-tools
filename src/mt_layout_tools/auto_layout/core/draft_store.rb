# encoding: UTF-8
require 'json'
require 'fileutils'
require 'tmpdir'

module MTDesign
  module LayoutTools
    module AutoLayout
      # BẢN NHÁP TỰ ĐỘNG (autosave) – không bao giờ ghi đè bản lưu chính trong file SKP.
      # - Mỗi dự án 1 tệp <project_id>.json trong thư mục nháp của người dùng (không nằm trong file SKP).
      # - Ghi an toàn: ghi tệp tạm cùng thư mục rồi đổi tên (rename là thao tác nguyên tử) -> không có JSON dở dang.
      # - Lưu kèm đường dẫn SKP + thời điểm bản chính để biết bản nháp có mới hơn không (khôi phục sau khi tắt đột ngột).
      module DraftStore
        module_function

        def default_dir
          base = ENV['APPDATA'].to_s.empty? ? File.join(Dir.home, '.mtdesign') : File.join(ENV['APPDATA'], 'MTDesign')
          File.join(base, 'AutoLayout', 'drafts')
        rescue StandardError
          File.join(Dir.tmpdir, 'MTDesign', 'AutoLayout', 'drafts')
        end

        def safe_id(id)
          id.to_s.gsub(/[^\w.-]/, '_')[0, 80]
        end

        def path_for(dir, project_id)
          File.join(dir, "#{safe_id(project_id)}.json")
        end

        # meta: skp_path, model_title, plugin_version
        def write(dir, project, meta = {})
          FileUtils.mkdir_p(dir)
          doc = { 'kind' => 'draft', 'draft_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ'),
                  'project_id' => project['project_id'], 'base_saved_at' => project['saved_at'],
                  'skp_path' => meta['skp_path'].to_s, 'model_title' => meta['model_title'].to_s,
                  'plugin_version' => meta['plugin_version'].to_s,
                  'pages' => Array(project['pages']).length, 'project' => project }
          final = path_for(dir, project['project_id'])
          tmp = "#{final}.#{Process.pid}.#{rand(36**6).to_s(36)}.tmp"
          File.open(tmp, 'wb') do |f|
            f.write(JSON.generate(doc))
            f.flush
            begin
              f.fsync
            rescue StandardError
              nil
            end
          end
          File.rename(tmp, final)
          doc['draft_at']
        ensure
          File.delete(tmp) if tmp && File.exist?(tmp)
        end

        def read(path)
          doc = JSON.parse(File.read(path, encoding: 'UTF-8'))
          doc.is_a?(Hash) && doc['kind'] == 'draft' && doc['project'].is_a?(Hash) ? doc : nil
        rescue StandardError
          nil # tệp hỏng/không đọc được -> bỏ qua, không làm hỏng việc mở dự án
        end

        # Tìm bản nháp của dự án: theo project_id, nếu không có thì theo đường dẫn SKP (dự án chưa từng Lưu).
        def find(dir, project_id, skp_path = '')
          return nil unless File.directory?(dir)

          if project_id
            d = File.exist?(path_for(dir, project_id)) ? read(path_for(dir, project_id)) : nil
            return d if d
          end
          return nil if skp_path.to_s.empty?

          Dir[File.join(dir, '*.json')].map { |f| read(f) }.compact
                                       .select { |d| d['skp_path'] == skp_path.to_s }
                                       .max_by { |d| d['draft_at'].to_s }
        end

        # Bản nháp mới hơn bản chính (và khác nội dung) -> hỏi người dùng có khôi phục không.
        def newer?(draft, main)
          return false unless draft

          saved = main && main['saved_at'].to_s
          return false if saved && !saved.empty? && draft['draft_at'].to_s <= saved

          strip = ->(p) { p.reject { |k, _| k == 'saved_at' } }
          JSON.generate(strip.call(draft['project'])) != JSON.generate(strip.call(main || {}))
        end

        # Người dùng chọn "Mở bản lưu chính": giữ bản nháp làm bản dự phòng nhưng không hỏi lại.
        def dismiss(dir, project_id)
          f = path_for(dir, project_id)
          File.rename(f, f.sub(/\.json\z/, ".bo-qua-#{Time.now.strftime('%Y%m%d%H%M%S')}.bak")) if File.exist?(f)
        end

        # Đã Lưu dự án chính thức -> bản nháp không còn cần.
        def clear(dir, project_id)
          f = path_for(dir, project_id)
          File.delete(f) if File.exist?(f)
        end
      end
    end
  end
end
