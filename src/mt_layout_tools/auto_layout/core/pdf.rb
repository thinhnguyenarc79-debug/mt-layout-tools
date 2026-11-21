# encoding: UTF-8
require 'json'
require 'zlib'

module MTDesign
  module LayoutTools
    module AutoLayout
    # Bộ ghi PDF vector nhiều trang (font Noto Sans nhúng, hỗ trợ tiếng Việt).
    module Pdf
      module_function

      MM_TO_PT = 72.0 / 25.4
      FONT_PATH = File.join(__dir__, '..', 'fonts', 'MTNotoSans.ttf')
      METRICS_PATH = File.join(__dir__, '..', 'fonts', 'metrics.json')

      def number(n)
        format('%.5f', n).sub(/\.?0+\z/, '').sub(/\A-0\z/, '0')
      end

      def rgb(color)
        color[1..-1].scan(/../).map { |c| c.to_i(16) / 255.0 }
      end

      def metrics
        @metrics ||= JSON.parse(File.binread(METRICS_PATH))
      end

      def font_run(text)
        chars = metrics.fetch('chars')
        glyphs, advance = [], 0
        text.unicode_normalize(:nfc).codepoints.each do |point|
          id, width = chars[point.to_s] || chars.fetch('63')
          advance += width
          glyphs << format('%04X', id)
        end
        [glyphs.join, advance / 1000.0]
      end

      def text_command(text, anchor, size, angle, color, backed = false)
        glyphs, width = font_run(text)
        r = angle * Math::PI / 180
        co, si = Math.cos(r), Math.sin(r)
        dx = -width * size / 2
        dy = -size * (metrics['ascent'] + metrics['descent']) / 2000.0
        x, y = anchor[0] + co * dx - si * dy, anchor[1] + si * dx + co * dy
        fill = rgb(color).map { |n| number(n) }.join(' ')
        matrix = [co, si, -si, co, x, y].map { |n| number(n) }.join(' ')
        text_start = "BT /F1 #{number(size)} Tf"
        run = "#{matrix} Tm <#{glyphs}> Tj ET"
        outline = backed ? "1 1 1 RG #{number(size * 0.17)} w 1 j\n#{text_start} 1 Tr #{run}\n" : ''
        "q\n#{fill} rg\n#{outline}#{text_start} 0 Tr #{run}\nQ"
      end

      def xy(p)
        p.map { |n| number(n) }.join(' ')
      end

      class PdfFile
        def initialize
          @objects = []
        end

        def objects_count
          @objects.length
        end

        def append(object)
          @objects << object
          @objects.length
        end

        def stream(bytes, extra = '')
          binary = Zlib::Deflate.deflate(bytes)
          append("<< /Length #{binary.bytesize} /Filter /FlateDecode #{extra} >>\nstream\n".b + binary + "\nendstream")
        end

        def render
          file = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".b
          offsets = @objects.each_with_index.map do |body, i|
            offset = file.bytesize
            file << "#{i + 1} 0 obj\n".b << body.b << "\nendobj\n".b
            offset
          end
          xref = file.bytesize
          file << "xref\n0 #{@objects.length + 1}\n0000000000 65535 f \n"
          offsets.each { |offset| file << format("%010d 00000 n \n", offset) }
          file << "trailer\n<< /Root #{@objects.length} 0 R /Size #{@objects.length + 1} >>\nstartxref\n#{xref}\n%%EOF\n"
        end
      end

      def pdf_file(content, page)
        pdf_pages([content], page)
      end

      # contents: mảng nội dung từng trang (cùng khổ giấy page = [w_pt, h_pt]).
      def pdf_pages(contents, page)
        info = metrics
        doc = PdfFile.new
        font = File.binread(FONT_PATH)
        font_file = doc.stream(font, "/Length1 #{font.bytesize}")
        font_name = '/MTLTXX+NotoSans'
        descriptor = doc.append("<< /Type /FontDescriptor /FontName #{font_name} /Flags 32 " \
          "/Ascent #{info['ascent']} /Descent #{info['descent']} /CapHeight #{info['cap_height']} /ItalicAngle 0 /StemV 88 " \
          "/FontBBox [#{info['bbox'].join(' ')}] /FontFile2 #{font_file} 0 R >>")
        unique = info['chars'].each_with_object({}) do |(code, (id, advance)), result|
          result[id] ||= [code.to_i, advance]
        end
        widths = unique.sort.map { |id, (_, advance)| "#{id} [#{advance}]" }.join(' ')
        cid = doc.append("<< /Type /Font /Subtype /CIDFontType2 /BaseFont #{font_name} /FontDescriptor #{descriptor} 0 R " \
          "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /CIDToGIDMap /Identity /W [#{widths}] >>")
        unicode = doc.stream(cmap(unique))
        resource = doc.append("<< /Type /Font /Subtype /Type0 /BaseFont #{font_name} /Encoding /Identity-H " \
          "/DescendantFonts [#{cid} 0 R] /ToUnicode #{unicode} 0 R >>")
        pages_id = doc.objects_count + contents.length * 2 + 1
        kids = contents.map do |content|
          drawing = doc.stream(content)
          doc.append("<< /Type /Page /Parent #{pages_id} 0 R /MediaBox [0 0 #{xy(page)}] /Contents #{drawing} 0 R " \
            "/Resources << /Font << /F1 #{resource} 0 R >> >> >>")
        end
        pages = doc.append("<< /Type /Pages /Kids [#{kids.map { |k| "#{k} 0 R" }.join(' ')}] /Count #{kids.length} >>")
        raise 'PDF: sai số đối tượng' unless pages == pages_id

        doc.append("<< /Type /Catalog /Pages #{pages} 0 R >>")
        doc.render
      end

      def cmap(unique)
        header = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n" \
          "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n" \
          "/CMapName /MTNotoUnicode def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
        unique.sort.each_slice(100) do |slice|
          header << "#{slice.length} beginbfchar\n"
          slice.each { |id, (cp, _)| header << format("<%04X> <%04X>\n", id, cp) }
          header << "endbfchar\n"
        end
        header << "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
      end
    end
  end
  end
end
