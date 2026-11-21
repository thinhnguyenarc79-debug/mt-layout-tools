require 'sketchup.rb'
require 'json'
require 'digest'
require 'tmpdir'

module MTDesign
  module LayoutTools
    # Nút "Cập nhật": đọc version.json trên GitHub, so phiên bản, tải .rbz, kiểm SHA-256, cài đè, nạp lại code.
    module Updater
      REPO        = 'thinhnguyenarc79-debug/mt-layout-tools'.freeze
      BRANCH      = 'main'.freeze
      MANIFEST    = "https://raw.githubusercontent.com/#{REPO}/#{BRANCH}/version.json".freeze
      PREF_KEY    = 'MTDesign_LayoutTools'.freeze
      CHECK_EVERY = 24 * 60 * 60 # giây

      @busy = false
      @request = nil # giữ tham chiếu để request không bị GC giữa chừng

      class << self
        def due_for_auto_check?
          last = Sketchup.read_default(PREF_KEY, 'last_check', 0).to_i
          Time.now.to_i - last >= CHECK_EVERY
        end

        # silent: true  -> chỉ báo khi có bản mới (dùng lúc khởi động)
        # silent: false -> luôn báo kết quả (dùng khi bấm nút)
        def check(silent: false)
          return if @busy
          @busy = true
          Sketchup.status_text = 'MT Layout Tools: đang kiểm tra cập nhật...'
          url = "#{MANIFEST}?t=#{Time.now.to_i}" # tránh cache
          http_get(url) do |ok, body, err|
            @busy = false
            Sketchup.status_text = ''
            Sketchup.write_default(PREF_KEY, 'last_check', Time.now.to_i) if ok
            panel_status('')
            if ok
              handle_manifest(body, silent)
            elsif !silent
              UI.messagebox("Không kiểm tra được cập nhật.\n#{err}")
            end
          end
        rescue StandardError => e
          @busy = false
          UI.messagebox("Lỗi kiểm tra cập nhật: #{e.message}") unless silent
        end

        private

        def handle_manifest(body, silent)
          info = JSON.parse(body)
          latest = info['version'].to_s
          if newer?(latest, VERSION)
            notes = info['notes'].to_s.strip
            msg = "Có bản mới: #{latest} (đang dùng #{VERSION}).\n"
            msg << "\n#{notes}\n" unless notes.empty?
            msg << "\nCập nhật ngay?"
            download_and_install(info) if UI.messagebox(msg, MB_YESNO) == IDYES
          elsif !silent
            UI.messagebox("Bạn đang dùng bản mới nhất (#{VERSION}).")
          end
        rescue JSON::ParserError => e
          UI.messagebox("File version.json không hợp lệ: #{e.message}") unless silent
        end

        def panel_status(text)
          LayoutTools::Panel.set_status(text) if LayoutTools.const_defined?(:Panel, false)
        rescue StandardError
          nil
        end

        def panel_refresh
          return unless LayoutTools.const_defined?(:Panel, false)
          LayoutTools::Panel.refresh_version
        rescue StandardError
          nil
        end

        def newer?(a, b)
          Gem::Version.new(a) > Gem::Version.new(b)
        rescue ArgumentError
          false
        end

        def download_and_install(info)
          url = info['rbz_url'].to_s
          raise 'version.json thiếu rbz_url' if url.empty?
          Sketchup.status_text = 'MT Layout Tools: đang tải bản cập nhật...'
          http_get("#{url}?t=#{Time.now.to_i}") do |ok, body, err|
            Sketchup.status_text = ''
            unless ok
              UI.messagebox("Tải bản cập nhật thất bại.\n#{err}")
              next
            end
            install(body, info)
          end
        rescue StandardError => e
          UI.messagebox("Lỗi cập nhật: #{e.message}")
        end

        def install(data, info)
          data = data.to_s.dup.force_encoding(Encoding::BINARY)
          unless data.start_with?("PK".b)
            UI.messagebox('File tải về không phải gói .rbz hợp lệ.')
            return
          end
          expected = info['sha256'].to_s.downcase
          if !expected.empty? && Digest::SHA256.hexdigest(data) != expected
            UI.messagebox('Mã kiểm tra SHA-256 không khớp. Đã hủy cập nhật.')
            return
          end

          path = File.join(Dir.tmpdir, "mt_layout_tools_#{info['version']}.rbz")
          File.open(path, 'wb') { |f| f.write(data) }

          begin
            Sketchup.install_from_archive(path, false)
          rescue ArgumentError
            Sketchup.install_from_archive(path) # bản SketchUp cũ không có tham số thứ 2
          end
          File.delete(path) rescue nil

          reload_code
          panel_refresh
          UI.messagebox("Đã cập nhật lên #{info['version']}.\n" \
                        'Chức năng đã áp dụng ngay. Nếu bản mới có thêm nút/menu, ' \
                        'khởi động lại SketchUp để hiện đủ.')
        rescue Interrupt
          # người dùng hủy hộp thoại cài đặt
        end

        # Nạp lại các file .rb để code mới chạy ngay, không cần mở lại SketchUp.
        def reload_code
          dir = File.dirname(__FILE__)
          LayoutTools.send(:remove_const, :VERSION) if LayoutTools.const_defined?(:VERSION, false)
          Dir.glob(File.join(dir, '**', '*.rb')).sort.each do |f|
            begin
              load f
            rescue StandardError, ScriptError => e
              puts "MT Layout Tools: lỗi nạp lại #{f}: #{e.message}"
            end
          end
        end

        # GET bất đồng bộ bằng Sketchup::Http (không treo giao diện). Tự theo chuyển hướng 3xx.
        def http_get(url, redirects = 5, &block)
          req = Sketchup::Http::Request.new(url, Sketchup::Http::GET)
          req.headers = { 'User-Agent' => "MTLayoutTools/#{VERSION}", 'Cache-Control' => 'no-cache' }
          @request = req
          req.start do |_r, res|
            code = res.status_code.to_i
            if (300..399).cover?(code) && redirects > 0 && res.headers['Location']
              http_get(res.headers['Location'], redirects - 1, &block)
            elsif code == 200
              block.call(true, res.body, nil)
            else
              block.call(false, nil, "HTTP #{code}")
            end
          end
        rescue StandardError => e
          block.call(false, nil, e.message)
        end
      end
    end
  end
end
