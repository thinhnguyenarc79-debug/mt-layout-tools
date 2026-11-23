# encoding: UTF-8
require 'json'
module MTDesign
  module LayoutTools
    module AutoLayout
      # ĐO HIỆU NĂNG (v2.16) trên chính model người dùng đang triển khai, chạy TRONG SketchUp:
      # thống kê model (đọc qua SketchUp Ruby API, không sửa gì), thời gian từng bước dựng (Job#timings),
      # số nét/mảng tô từng hình, số phần tử SVG phải vẽ. Phần zoom/pan/Smart Snap do giao diện tự đo (FPS).
      module PerfProbe
        module_function

        # Đếm Face/Edge/Group/Component trong Group/Component đang triển khai (tính cả lồng nhau và số lần lặp
        # của Component). Mỗi definition chỉ duyệt 1 lần.
        def model_stats(root)
          memo = {}
          defs = {}
          own = count_def(root.definition, memo, defs)
          own.merge('definitions' => defs.length)
        end

        def count_def(defn, memo, defs)
          return memo[defn] if memo[defn]

          defs[defn] = true
          c = Hash.new(0)
          defn.entities.each do |e|
            case e
            when Sketchup::Face
              c['faces'] += 1
            when Sketchup::Edge
              c['edges'] += 1
              c['edges_soft'] += 1 if e.soft? || e.smooth?
              c['edges_hidden'] += 1 if e.hidden?
            when Sketchup::Group, Sketchup::ComponentInstance
              c[e.is_a?(Sketchup::Group) ? 'groups' : 'components'] += 1
              sub = count_def(e.definition, memo, defs)
              %w[faces edges edges_soft edges_hidden groups components].each { |k| c[k] += sub[k] }
              c['depth'] = [c['depth'], sub['depth'] + 1].max
            end
          end
          memo[defn] = c
        end

        # Hình đã dựng của trang: nét thấy, chuỗi nét, mảng tô, mức khử nét.
        def view_stats(views)
          Array(views).map do |v|
            { 'key' => v[:key].to_s, 'name' => v[:name].to_s, 'lines' => Array(v[:lines]).length,
              'chains' => Array(v[:chains]).length, 'fills' => Array(v[:fills]).length,
              'cut' => v[:cut] ? Array(v[:cut][:segs]).length : 0, 'level' => v[:level],
              'snap_segs' => v[:snap_segs] ? v[:snap_segs].length : nil }
          end
        end

        # Kết quả từng tờ: dung lượng SVG, số phần tử phải vẽ, dung lượng gói gửi giao diện.
        def sheet_stats(outputs)
          Array(outputs).each_with_index.map do |(svg, info), i|
            light = info.reject { |k, _| k == 'snap_data' }
            { 'sheet' => i, 'svg_kb' => (svg.bytesize / 1024.0).round(1), 'paths' => svg.scan('<path').length,
              'texts' => svg.scan('<text').length, 'elements' => svg.scan(/<(?:path|text|rect|circle|polygon|line)\b/).length,
              'info_kb' => (JSON.generate(light).bytesize / 1024.0).round(1),
              'snap_kb' => (JSON.generate(info['snap_data'] || {}).bytesize / 1024.0).round(1) }
          end
        end

        def timings(job)
          job.timings.sort_by { |_, t| -t }.map { |k, t| [k, (t * 1000).round] }.to_h
        end
      end
    end
  end
end
