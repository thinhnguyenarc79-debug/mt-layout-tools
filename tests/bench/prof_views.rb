# encoding: UTF-8
# Tách thời gian từng pha dựng của TỪNG hình (ruby tests/bench/prof_views.rb [seg] [multi]).
module Minitest; def self.autorun; end; end
require 'minitest'
require_relative '../test_helper'
require_relative '../test_doors'
require_relative 'chair'
require 'json'
seg = (ARGV[0] || 32).to_i
cap = Chair.build(Fake.capture('Ghế'), hard: :smooth, seg: seg, multi: ARGV[1] == 'multi')
PH = Hash.new { |h, k| h[k] = Hash.new(0.0) }
P = AL::Geometry::Projector
%i[phase_tris phase_edges phase_grid phase_hidden phase_fill_sort phase_fill_tree phase_fill phase_fill_old].each do |m|
  orig = P.instance_method(m)
  P.send(:define_method, m) do |*a|
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC); r = orig.bind(self).call(*a)
    PH[@key.to_s][m.to_s.sub('phase_', '')] += (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000; r
  end
end
project = AL::ProjectStore.default_project
pg = AL::ProjectStore.clean_page(project['defaults'].merge('pid' => 1, 'sheet_no' => 'A-01', 'views' => %w[front left top iso], 'scale' => 10,
  'sections' => [{ 'label' => 'A', 'axis' => 'x', 'pos' => 250, 'dir' => 1, 'auto' => false }]))
project['pages'] = [pg]
env = TestDoorPages::Env.new(cap)
runs = []
2.times do |run|
  PH.clear
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  pb = AL::PageBuild.new(env, project, pg, :svg)
  job = AL::Job.new('t', timer: ->(_b) {}); pb.tasks.each { |t| job.add(t) }; job.run_sync
  total = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
  svg = pb.outputs[0][0]
  runs << { 'run' => run + 1, 'total_ms' => total.round, 'steps_ms' => AL::PerfProbe.timings(job),
            'phases_ms' => PH.transform_values { |h| h.transform_values(&:round) },
            'fills' => pb.views.map { |v| [v[:key], Array(v[:fills]).length] }.to_h,
            'svg_kb' => svg.bytesize / 1024, 'svg_elems' => svg.scan(/<(?:path|text|rect|circle)\b/).length }
end
puts JSON.pretty_generate('tris' => cap.triangles.length, 'edges' => cap.edges.length, 'runs' => runs)
$stdout.flush
exit!(0)
