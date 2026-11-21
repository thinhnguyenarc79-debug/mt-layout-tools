# encoding: UTF-8
# Job Engine máy trạng thái: chia lô thật, tiếp tục đúng, huỷ, lỗi, không chạy lồng.
require_relative 'test_helper'
require File.join(ROOT, 'extractor')
require_relative 'test_large' unless defined?(Big)

class TestJobEngine < Minitest::Test
  # Bộ hẹn giờ giả: ghi lại các lần hẹn, test tự gọi lần lượt (như SketchUp gọi UI.start_timer).
  class FakeTimer
    attr_reader :queue

    def initialize
      @queue = []
    end

    def call(blk)
      @queue << blk
    end

    def run_all(limit = 1_000_000)
      n = 0
      until @queue.empty?
        @queue.shift.call
        n += 1
        raise 'quá nhiều lần hẹn giờ' if n > limit
      end
      n
    end
  end

  def counter_task(total, per_check = 1)
    i = 0
    AL::Job::Task.new('đếm') do |job|
      while i < total
        i += 1
        return_false = (i % per_check).zero? && job.time_up?
        break if return_false
      end
      i >= total
    end
  end

  def test_chia_lo_va_ket_thuc
    timer = FakeTimer.new
    done = nil
    job = AL::Job.new('t', slice: 0.0, timer: timer, on_done: ->(r) { done = r })
    job.add(counter_task(50))
    job.add(AL::Job.once('kết quả') { |j| j.result = 42 })
    job.start
    steps = timer.run_all
    assert_operator steps, :>, 10, 'slice 0 => mỗi lô 1 bước, phải qua nhiều lần hẹn giờ'
    assert_equal 42, done
    assert_equal :done, job.state
  end

  def test_huy_giua_chung
    timer = FakeTimer.new
    err = nil
    job = AL::Job.new('t', slice: 0.0, timer: timer, on_error: ->(e) { err = e })
    job.add(counter_task(1000))
    job.start
    3.times { timer.queue.shift&.call }
    job.cancel!
    timer.run_all
    assert_kind_of AL::Job::Cancelled, err
    assert_equal :cancelled, job.state
  end

  def test_loi_trong_task_duoc_bao_va_ghi_log
    logs = []
    err = nil
    job = AL::Job.new('t', timer: FakeTimer.new, log: ->(m) { logs << m }, on_error: ->(e) { err = e })
    job.add(AL::Job.once('hỏng') { raise 'nổ' })
    job.start
    job.step
    assert_equal 'nổ', err.message
    assert_match(/JOB t LỖI: RuntimeError: nổ/, logs.join)
  end

  def test_khong_chay_long_nhau
    job = AL::Job.new('t', timer: FakeTimer.new)
    inner = nil
    job.add(AL::Job.once('a') { |j| inner = j.step }) # gọi step khi đang trong step -> bị bỏ qua
    job.run_sync
    assert_nil inner
  end

  # Toàn bộ pipeline 1 trang chạy qua step() với lô rất nhỏ trên model ~120k tam giác:
  # không lô nào được chạy quá lâu (SketchUp vẫn phản hồi) và kết quả có hình thật.
  class FakeEnv
    attr_reader :cache, :logs

    def initialize(cap)
      @cap = cap
      @cache = {}
      @logs = []
    end

    def find(_pid)
      :entity
    end

    def page_status(_pg)
      'ok'
    end

    def capture_builder(_e, _exclude, _front, _doors = {})
      cap = @cap
      Struct.new(:result) { def call(_job); true; end }.new(cap)
    end

    def log(m)
      @logs << m
    end
  end

  def test_pipeline_trang_chia_lo_that
    cap = Big.cabinet
    project = AL::ProjectStore.default_project
    pg = AL::ProjectStore.clean_page(project['defaults'].merge('pid' => 1, 'name' => 'Group#3', 'sheet_no' => 'A-01',
                                                               'views' => %w[front top iso]))
    env = FakeEnv.new(cap)
    pb = AL::PageBuild.new(env, project, pg, :svg)
    timer = FakeTimer.new
    longest = 0.0
    job = AL::Job.new('render', slice: 0.05, timer: lambda { |blk|
      timer.call(lambda {
        t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        blk.call
        longest = [longest, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t].max
      })
    })
    pb.tasks.each { |t| job.add(t) }
    job.start
    steps = timer.run_all
    svg, info = pb.output
    puts "\n  [pipeline] #{cap.triangles.length} tam giác: #{steps} lô, lô dài nhất #{(longest * 1000).round} ms"
    assert_operator steps, :>, 20
    assert_operator longest, :<, 0.6, 'mỗi lô phải ngắn để SketchUp không đơ'
    assert_equal :done, job.state
    keys = info['boxes'].keys
    %w[front top iso].each { |k| assert_includes keys, k }
    assert_equal %w[A B C], info['sections'].map { |s| s['label'] }
    %w[sec:A sec:B sec:C].each { |k| assert_includes keys, k, 'mặt cắt tự đề xuất có bản vẽ' }
    assert_operator svg.bytesize, :>, 10_000
    assert info['complete']
  end

  def test_pipeline_loi_doi_tuong_khong_trang_trang
    env = FakeEnv.new(nil)
    def env.find(_pid)
      nil
    end
    project = AL::ProjectStore.default_project
    pg = AL::ProjectStore.clean_page(project['defaults'].merge('pid' => 9, 'sheet_no' => 'A-01'))
    pb = AL::PageBuild.new(env, project, pg, :svg)
    job = AL::Job.new('r', timer: FakeTimer.new)
    pb.tasks.each { |t| job.add(t) }
    job.run_sync
    svg, info = pb.output
    assert_match(/CHƯA DỰNG ĐƯỢC HÌNH CHIẾU/, svg)
    assert_match(/đã bị xoá/, info['note'])
    refute info['complete']
  end
end
