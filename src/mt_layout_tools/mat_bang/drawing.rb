# encoding: UTF-8
require 'json'
require 'zlib'

module MTDesign
  module MatBang
    module Drawing
      module_function

      MM_TO_PT = 72.0 / 25.4
      PAPER = { 'A3' => [420.0, 297.0], 'A4' => [297.0, 210.0] }.freeze
      PEN_MM = { 'WALL' => 0.36, 'OPENING' => 0.25, 'FLOOR' => 0.17,
                 'FURNITURE' => 0.22, 'VIEW' => 0.25, 'DIM' => 0.16, 'NOTE' => 0.16 }.freeze
      FONT_PATH = File.join(__dir__, 'fonts', 'MTNotoSans.ttf')
      METRICS_PATH = File.join(__dir__, 'fonts', 'metrics.json')

      def number(n)
        format('%.5f', n).sub(/\.?0+\z/, '').sub(/\A-0\z/, '0')
      end

      def rgb(color)
        color[1..-1].scan(/../).map { |c| c.to_i(16) / 255.0 }
      end

      def layout(scene, config)
        width, height = PAPER.fetch(config['paper'])
        scale = config['scale']
        # Measure relative to the drawing origin, including rotated labels.
        points = scene.flat_map do |o|
          next o['p'] if o['p']

          anchor = o['a']
          size = o['size']
          half_width = font_run(o['text'])[1] * size / 2
          rad = o.fetch('angle', 0) * Math::PI / 180
          co, si = Math.cos(rad), Math.sin(rad)
          [-half_width, half_width].product([-size * 0.72, size * 0.72]).map do |x, y|
            [anchor[0] + x * co - y * si, anchor[1] + x * si + y * co]
          end
        end
        xs = points.map { |p| p[0] }.minmax
        ys = points.map { |p| p[1] }.minmax
        w, h = (xs[1] - xs[0]) / scale, (ys[1] - ys[0]) / scale
        box = [width - 30, height - 56]
        if w > box[0] || h > box[1]
          minimum = [w * scale / box[0], h * scale / box[1]].max.ceil
          raise ArgumentError, "Bản vẽ vượt khổ #{config['paper']}. Chọn tỉ lệ 1:#{minimum} hoặc nhỏ hơn, hay dùng khổ lớn hơn."
        end
        base_x = (width - w) / 2
        base_y = 23 + (box[1] - h) / 2
        transform = lambda do |p|
          [(base_x + (p[0] - xs[0]) / scale) * MM_TO_PT, (height - base_y - (p[1] - ys[0]) / scale) * MM_TO_PT]
        end
        [width, height, transform]
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

      def pdf(scene, config)
        width, height, transform = layout(scene, config)
        page_width, page_height = [width, height].map { |v| v * MM_TO_PT }
        out = []
        out << '1 J 1 j'
        scene.each do |o|
          if o['t'] == 'text'
            out << text_command(o['text'], transform.call(o['a']), o['size'] / config['scale'] * MM_TO_PT,
                                -o.fetch('angle', 0), config['mono'] ? '#202725' : o['s'], o['back'])
            next
          end
          stroke = config['mono'] ? '#2a302d' : o['s']
          fill = o['f']
          fill = o['l'] == 'WALL' ? '#343a37' : nil if config['mono']
          pts = o['p'].map { |p| transform.call(p) }
          out << "#{number(PEN_MM.fetch(o['l'], 0.18) * MM_TO_PT)} w #{xy(rgb(stroke))} RG"
          out << "#{xy(rgb(fill))} rg" if fill
          out << "#{xy(pts.shift)} m"
          pts.each { |p| out << "#{xy(p)} l" }
          out << (o['t'] == 'poly' ? (fill ? 'h B' : 'h S') : 'S')
        end
        margin = 11 * MM_TO_PT
        bottom = 11 * MM_TO_PT
        base = 25 * MM_TO_PT
        out << '0.17 0.23 0.21 RG 0.6 w'
        out << "#{xy([margin, bottom])} #{xy([page_width - 2 * margin, page_height - 2 * margin])} re S"
        out << "#{xy([margin, base])} m #{xy([page_width - margin, base])} l S"
        cell_width = 54 * MM_TO_PT
        [margin + cell_width, page_width - margin - cell_width].each do |x|
          out << "#{xy([x, bottom])} m #{xy([x, base])} l S"
        end
        title_size = 12.0
        title = config['name']
        max_width = page_width - 2 * (margin + cell_width) - 10 * MM_TO_PT
        while font_run(title)[1] * title_size > max_width && title.length > 3
          title = title[0, title.length - 2].rstrip + '…'
        end
        title_y = (base + bottom) / 2
        out << text_command(title, [page_width / 2, title_y], title_size, 0, '#20352b')
        out << text_command('MT MẶT BẰNG', [margin + cell_width / 2, title_y], 9, 0, '#20352b')
        ratio = "1:#{number(config['scale'])}"
        out << text_command("#{config['paper']}  ·  #{ratio}  ·  mm", [page_width - margin - cell_width / 2, title_y],
                            9, 0, '#20352b')
        pdf_file(out.join("\n") + "\n", [page_width, page_height])
      end

      class PdfFile
        def initialize
          @objects = []
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
        info = metrics
        doc = PdfFile.new
        font = File.binread(FONT_PATH)
        font_file = doc.stream(font, "/Length1 #{font.bytesize}")
        font_name = '/MTPDFX+NotoSans'
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
        drawing = doc.stream(content)
        page_id = doc.append("<< /Type /Page /Parent #{drawing + 2} 0 R /MediaBox [0 0 #{xy(page)}] /Contents #{drawing} 0 R " \
          "/Resources << /Font << /F1 #{resource} 0 R >> >> >>")
        pages = doc.append("<< /Type /Pages /Kids [#{page_id} 0 R] /Count 1 >>")
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

      class DxfFile
        def initialize
          @out = String.new(encoding: Encoding::UTF_8)
          @handle = 64
        end

        def put(*records)
          records.each_slice(2) do |code, val|
            val = Drawing.number(val) if val.is_a?(Float)
            @out << code.to_s << "\r\n" << val.to_s << "\r\n"
          end
        end

        def entity(type, layer, subclass, owner = nil)
          @handle += 1
          put(0, type, 5, @handle.to_s(16).upcase)
          put(330, owner) if owner
          put(100, 'AcDbEntity', 8, layer, 100, subclass)
        end

        def finish
          put(0, 'ENDSEC', 0, 'EOF')
          @out
        end
      end

      def dxf(scene)
        file = DxfFile.new
        file.put(0, 'SECTION', 2, 'HEADER', 9, '$ACADVER', 1, 'AC1021', 9, '$DWGCODEPAGE', 3, 'ANSI_1252',
                 9, '$HANDSEED', 5, 'FFFFF', 9, '$INSUNITS', 70, 4, 9, '$MEASUREMENT', 70, 1, 0, 'ENDSEC')
        layers = scene.map { |p| p['l'] }.uniq
        file.put(0, 'SECTION', 2, 'TABLES', 0, 'TABLE', 2, 'LTYPE', 5, '1', 100, 'AcDbSymbolTable', 70, 1,
                 0, 'LTYPE', 5, '2', 330, '1', 100, 'AcDbSymbolTableRecord', 100, 'AcDbLinetypeTableRecord',
                 2, 'CONTINUOUS', 70, 0, 3, 'Solid line', 72, 65, 73, 0, 40, 0, 0, 'ENDTAB')
        file.put(0, 'TABLE', 2, 'LAYER', 5, '3', 100, 'AcDbSymbolTable', 70, layers.length + 1)
        (['0'] + layers).each_with_index do |layer, i|
          file.put(0, 'LAYER', 5, (0x10 + i).to_s(16).upcase, 330, '3', 100, 'AcDbSymbolTableRecord',
                   100, 'AcDbLayerTableRecord', 2, layer, 70, 0, 62, 7, 6, 'CONTINUOUS')
        end
        file.put(0, 'ENDTAB', 0, 'TABLE', 2, 'STYLE', 5, '4', 100, 'AcDbSymbolTable', 70, 1,
                 0, 'STYLE', 5, '5', 330, '4', 100, 'AcDbSymbolTableRecord', 100, 'AcDbTextStyleTableRecord',
                 2, 'STANDARD', 70, 0, 40, 0, 41, 1, 50, 0, 71, 0, 42, 2.5, 3, 'arial.ttf', 4, '',
                 0, 'ENDTAB')
        file.put(0, 'TABLE', 2, 'BLOCK_RECORD', 5, '6', 100, 'AcDbSymbolTable', 70, 2)
        [['7', '*Model_Space'], ['8', '*Paper_Space']].each do |id, name|
          file.put(0, 'BLOCK_RECORD', 5, id, 330, '6', 100, 'AcDbSymbolTableRecord', 100, 'AcDbBlockTableRecord',
                   2, name, 70, 0, 280, 1, 281, 0)
        end
        file.put(0, 'ENDTAB', 0, 'ENDSEC', 0, 'SECTION', 2, 'BLOCKS')
        [['7', '*Model_Space'], ['8', '*Paper_Space']].each do |id, name|
          file.entity('BLOCK', '0', 'AcDbBlockBegin', id)
          file.put(2, name, 70, 0, 10, 0, 20, 0, 30, 0, 3, name, 1, '')
          file.entity('ENDBLK', '0', 'AcDbBlockEnd', id)
        end
        file.put(0, 'ENDSEC', 0, 'SECTION', 2, 'ENTITIES')
        scene.each do |o|
          if o['t'] == 'text'
            file.entity('TEXT', o['l'], 'AcDbText', '7')
            x, y = o['a']
            file.put(10, x, 20, -y, 30, 0, 40, o['size'] * 0.75, 1, o['text'], 50, -o.fetch('angle', 0),
                     7, 'STANDARD', 72, 1, 11, x, 21, -y, 31, 0, 100, 'AcDbText', 73, 2)
          else
            file.entity('LWPOLYLINE', o['l'], 'AcDbPolyline', '7')
            file.put(90, o['p'].length, 70, o['t'] == 'poly' ? 1 : 0)
            o['p'].each { |x, y| file.put(10, x, 20, -y) }
          end
        end
        file.finish
      end
    end
  end
end
