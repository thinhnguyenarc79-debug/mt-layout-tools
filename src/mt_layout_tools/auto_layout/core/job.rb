# encoding: UTF-8
require 'fiber'

module MTDesign
  module LayoutTools
    module AutoLayout
      # Tác vụ dài chia thành lát ~120 ms trên CHÍNH luồng SketchUp (Fiber + UI.start_timer, không dùng Thread):
      # giữa các lát SketchUp vẫn vẽ lại màn hình và nhận thao tác, người dùng có thể huỷ.
      class Job
        class Cancelled < StandardError; end

        SLICE = 0.12

        attr_reader :progress_text, :progress_pct

        def initialize(name = 'job', &block)
          @name = name
          @block = block
          @cancel = false
          @progress_text = ''
          @progress_pct = 0
          @last = now
          @fiber = nil
        end

        def now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def cancel!
          @cancel = true
        end

        def cancelled?
          @cancel
        end

        def progress(text, pct = nil)
          @progress_text = text
          @progress_pct = pct.to_f.clamp(0, 100).round if pct
          tick
        end

        # Gọi thường xuyên trong vòng lặp nặng: hết lát thời gian thì nhường cho SketchUp.
        def tick
          raise Cancelled, 'Đã huỷ.' if @cancel
          return unless @fiber && now - @last >= SLICE

          Fiber.yield
          @last = now
          raise Cancelled, 'Đã huỷ.' if @cancel
        end

        # Chạy hết trong 1 lần (dùng cho test ngoài SketchUp).
        def run_sync
          @block.call(self)
        end

        # Chạy từng lát bằng UI.start_timer. on_step(job) mỗi lát; on_done(result) / on_error(exception).
        def run_async(on_step:, on_done:, on_error:)
          @fiber = Fiber.new { @block.call(self) }
          step = lambda do
            begin
              @last = now
              result = @fiber.resume
              if @fiber.alive?
                on_step.call(self)
                UI.start_timer(0, false) { step.call }
              else
                on_done.call(result)
              end
            rescue Exception => e # rubocop:disable Lint/RescueException – mọi lỗi trong Fiber phải được báo, không nuốt
              on_error.call(e)
            end
          end
          UI.start_timer(0, false) { step.call }
          self
        end
      end
    end
  end
end
