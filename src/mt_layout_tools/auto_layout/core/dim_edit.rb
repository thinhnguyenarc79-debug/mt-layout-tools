# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # CHỈNH SỬA DIM & CHỮ (v2.15).
      #
      # 1) Chỉnh sửa DIM tự động: page['dim_over'] = { view_key => { id đoạn DIM => o } }.
      #    id đoạn = "<chuỗi>:<mốc đầu>-<mốc cuối>" (top1/top2/left/right, mm thật) – tính lại giống hệt mỗi lần dựng nên
      #    áp lại được sau mỗi lần dựng hình / Auto DIM. Auto DIM chỉ còn tự làm mới các đoạn KHÔNG có chỉnh sửa.
      #    o = { 'hidden', 'deleted', 'locked',            – ẩn / xóa (không tạo lại) / khóa
      #          'a', 'b', 'ra', 'rb',                     – điểm bám riêng (mm thật trong hình) + liên kết bộ phận
      #          'off',                                    – đã tách khỏi chuỗi: khoảng cách riêng từ mép hình (mm giấy)
      #          'text', 'tdx', 'tdy', 'size', 'bold' }    – nội dung hiển thị ("<>" = số đo thật), dời chữ, cỡ, đậm
      #    Số đo thật luôn tính từ 2 điểm bám; 'text' chỉ là nội dung hiển thị, lưu riêng, khôi phục được.
      #
      # 2) Chữ tên hình: page['captions'] = { view_key => c }
      #    c = { 'text' (tên hiển thị – không đổi loại hình nội bộ), 'scale_text' (dòng tỉ lệ, "{TL}" = tỉ lệ thật),
      #          'dx', 'dy' (dời so với vị trí mặc định, mm giấy), 'size', 'color', 'align', 'bold', 'locked' }
      module DimEdit
        module_function

        ID = /\A(top1|top2|left|right):-?\d+(\.\d+)?--?\d+(\.\d+)?\z/.freeze
        VIEW_KEY = /\A([a-z]{2,6}|sec:[A-Z]|det:\d{1,2}|cp:\d{1,3})\z/.freeze
        FLAGS = %w[hidden deleted locked bold].freeze
        MOD_KEYS = %w[a b off text tdx tdy size bold hidden deleted locked].freeze

        def num(x, lo, hi, digits = 2)
          ManualDim.num(x, lo, hi, digits)
        end

        def str(x, max = 120)
          x.to_s.gsub(/[\u0000-\u001F]/, ' ').strip[0, max]
        end

        def modified?(o)
          o.is_a?(Hash) && MOD_KEYS.any? { |k| !o[k].nil? && o[k] != false && o[k] != '' }
        end

        # Nội dung hiển thị: trống -> số đo thật; "<>" trong chữ tùy chỉnh -> số đo thật (như AutoCAD).
        def display(text, value_label)
          t = text.to_s
          return value_label if t.strip.empty?

          t.gsub('<>', value_label.to_s)
        end

        def text_opts(o)
          o = {} unless o.is_a?(Hash)
          { 'text' => o['text'], 'tdx' => o['tdx'], 'tdy' => o['tdy'], 'size' => o['size'], 'bold' => o['bold'] == true }
        end

        # Trường chữ dùng chung cho DIM tự động và DIM thủ công.
        def clean_text_fields(o)
          out = {}
          t = str(o['text'])
          out['text'] = t unless t.empty?
          %w[tdx tdy].each { |k| (v = num(o[k], -300, 300)) && !o[k].nil? && out[k] = v }
          (v = num(o['size'], 1.0, 12.0)) && !o['size'].nil? && out['size'] = v
          out['bold'] = true if o['bold'] == true
          out['locked'] = true if o['locked'] == true
          out
        end

        def clean_over(o)
          return nil unless o.is_a?(Hash)

          out = clean_text_fields(o)
          out['hidden'] = true if o['hidden'] == true
          out['deleted'] = true if o['deleted'] == true
          a = ManualDim.clean_pt(o['a'])
          b = ManualDim.clean_pt(o['b'])
          if a && b
            out['a'] = a
            out['b'] = b
            out['ra'] = ManualDim.clean_ref(o['ra']) if o.key?('ra')
            out['rb'] = ManualDim.clean_ref(o['rb']) if o.key?('rb')
          end
          out['off'] = num(o['off'], -300, 300) unless o['off'].nil?
          out.delete('off') if out['off'].nil?
          modified?(out) ? out : nil
        end

        def clean(raw)
          return {} unless raw.is_a?(Hash)

          raw.first(200).each_with_object({}) do |(k, list), h|
            next unless k.to_s =~ VIEW_KEY && list.is_a?(Hash)

            v = list.first(2000).each_with_object({}) do |(id, o), m|
              next unless id.to_s =~ ID

              c = clean_over(o)
              m[id.to_s] = c if c
            end
            h[k.to_s] = v unless v.empty?
          end
        end

        # ---------- chữ tên hình ----------
        ALIGNS = %w[left center right].freeze

        def clean_caption(c)
          return nil unless c.is_a?(Hash)

          out = {}
          t = str(c['text'], 120)
          out['text'] = t unless t.empty?
          st = str(c['scale_text'], 60)
          out['scale_text'] = st unless st.empty?
          %w[dx dy].each { |k| out[k] = num(c[k], -400, 400) unless c[k].nil? || num(c[k], -400, 400).nil? }
          out['size'] = num(c['size'], 1.5, 15.0) unless c['size'].nil? || num(c['size'], 1.5, 15.0).nil?
          out['color'] = c['color'].to_s if c['color'].to_s =~ /\A#[0-9A-Fa-f]{6}\z/
          out['align'] = c['align'].to_s if ALIGNS.include?(c['align'].to_s) && c['align'].to_s != 'center'
          out['bold'] = true if c['bold'] == true
          out['locked'] = true if c['locked'] == true
          out.empty? ? nil : out
        end

        def clean_captions(raw)
          return {} unless raw.is_a?(Hash)

          raw.first(200).each_with_object({}) do |(k, c), h|
            next unless k.to_s =~ VIEW_KEY

            cc = clean_caption(c)
            h[k.to_s] = cc if cc
          end
        end

        # Dòng tỉ lệ luôn bám tỉ lệ THẬT: "{TL}" -> "1:20". Nếu người dùng gõ cứng một tỉ lệ khác tỉ lệ thật
        # (vd. "TL 1:50" trong khi hình in 1:20) thì thay bằng tỉ lệ thật – không bao giờ in sai tỉ lệ bản vẽ.
        def scale_line(custom, s)
          real = "1:#{s}"
          return "TL #{real}" if custom.to_s.strip.empty?

          t = custom.to_s.gsub('{TL}', real)
          t.gsub(/1\s*:\s*\d+(?:[.,]\d+)?/) { real }
        end
      end
    end
  end
end
