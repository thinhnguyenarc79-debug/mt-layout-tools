# encoding: UTF-8
# Đo hiệu năng dựng trang ngoài SketchUp trên ghế cong giả lập. ruby tests/bench/run_bench.rb [smooth|all] [seg]
require_relative '../test_helper'
require_relative '../test_doors'
require_relative 'chair'
require 'json'
hard = (ARGV[0] || 'smooth').to_sym
seg = (ARGV[1] || 48).to_i
cap = Chair.build(Fake.capture('Ghế'), hard: hard, seg: seg)
TIMES = Hash.new(0.0)
module TimeTask
  def call(job)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    r = super
    TIMES[@label.to_s.sub(/ \(.*/, '')] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
    r
  end
end
AL::Job::Task.prepend(TimeTask)
AL::Job::Task.class_eval { attr_reader :label } unless AL::Job::Task.method_defined?(:label)
project = AL::ProjectStore.default_project
pg = AL::ProjectStore.clean_page(project['defaults'].merge('pid' => 1, 'sheet_no' => 'A-01', 'views' => %w[front left top iso], 'scale' => 10,
  'sections' => [{ 'label' => 'A', 'axis' => 'x', 'pos' => 250, 'dir' => 1, 'auto' => false }]))
project['pages'] = [pg]
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
pb = AL::PageBuild.new(TestDoorPages::Env.new(cap), project, pg, :svg)
job = AL::Job.new('t', timer: ->(_b) {})
pb.tasks.each { |t| job.add(t) }
job.run_sync
total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
svg, info = pb.outputs[0]
js = JSON.generate(info)
out = {
  'model' => { 'hard' => hard, 'seg' => seg, 'triangles' => cap.triangles.length, 'edges' => cap.edges.length },
  'views' => pb.instance_variable_get(:@views).map { |v| [v[:key], { 'lines' => Array(v[:lines]).length, 'chains' => Array(v[:chains]).length, 'level' => v[:level] }] }.to_h,
  'svg_kb' => (svg.bytesize / 1024.0).round, 'svg_paths' => svg.scan('<path').length, 'svg_elems' => svg.scan(/<(path|text|rect|circle|polygon)/).length,
  'info_kb' => (js.bytesize / 1024.0).round, 'snap_kb' => (JSON.generate(info['snap'] || {}).bytesize / 1024.0).round,
  'total_s' => total.round(2), 'tasks_s' => TIMES.sort_by { |_, v| -v }.first(12).map { |k, v| [k, v.round(3)] }.to_h
}
File.write("/tmp/bench_#{hard}_#{seg}.svg", svg)
File.write("/tmp/bench_#{hard}_#{seg}.json", JSON.generate('svg' => svg, 'info' => info))
puts JSON.pretty_generate(out)
$stdout.flush
exit!(0)
