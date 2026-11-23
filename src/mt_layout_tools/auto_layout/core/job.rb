# encoding: UTF-8
module MTDesign
  module LayoutTools
    module AutoLayout
      # JOB ENGINE – máy trạng thái, KHÔNG dùng Fiber, KHÔNG dùng Thread.
      #
      # Một Job là hàng đợi các Task. Mỗi lần UI.start_timer gọi Job#step:
      #   - chạy Task hiện tại cho tới khi hết lát thời gian (SLICE) hoặc Task xong,
      #   - Task tự lưu chỉ số/trạng thái của nó rồi TRẢ VỀ bình thường (không treo ngăn xếp),
      #   - Job hẹn timer cho lần step kế tiếp. Giữa hai lần step SketchUp vẽ lại và nhận thao tác.
      # Mỗi lúc chỉ 1 step chạy (cờ @running); timer kế tiếp chỉ được hẹn sau khi step trước kết thúc.
      #
      # Giao thức Task: đối tượng có #call(job) -> true khi xong, false khi cần chạy tiếp.
      # Trong vòng lặp nặng, Task kiểm tra job.time_up? và return false để nhường.
      class Job
        class Cancelled < StandardError; end

        SLICE = 0.08 # giây cho mỗi lô

        # Task đơn giản bọc 1 khối: khối trả true/false như giao thức Task.
        class Task
          attr_reader :label

          attr_reader :label

          def initialize(label, &block)
            @label = label
            @block = block
          end

          def call(job)
            @block.call(job)
          end
        end

        def self.label_of(task)
          (task.respond_to?(:label) ? task.label : task.class.name.split('::').last).to_s
        end

        # Task chạy 1 lần rồi xong (dùng cho bước nhẹ: dàn trang, gửi kết quả).
        def self.once(label, &block)
          Task.new(label) { |job| block.call(job); true }
        end

        attr_reader :name, :progress_text, :progress_pct, :result, :error, :state, :timings

        def initialize(name = 'job', slice: SLICE, on_progress: nil, on_done: nil, on_error: nil, log: nil, timer: nil)
          @name = name
          @slice = slice
          @on_progress = on_progress
          @on_done = on_done
          @on_error = on_error
          @log = log
          @timer = timer || ->(blk) { UI.start_timer(0, false) { blk.call } }
          @queue = []
          @state = :new
          @running = false
          @cancel = false
          @progress_text = ''
          @progress_pct = 0
          @last_sent = nil
          @data = {} # chỗ các Task trao dữ liệu cho nhau
          @timings = Hash.new(0.0) # giây CPU thực chạy của từng bước (đo hiệu năng v2.16)
        end

        def [](k)
          @data[k]
        end

        def []=(k, v)
          @data[k] = v
        end

        # Thêm Task vào cuối hàng đợi (Task đang chạy có thể thêm Task con – vd. mỗi hình chiếu 1 Task).
        def add(task)
          @queue << task
          self
        end

        # Chèn Task chạy ngay sau Task hiện tại.
        def insert_next(tasks)
          @queue.insert(1, *Array(tasks))
          self
        end

        def start
          return self unless @state == :new

          @state = :running
          schedule
          self
        end

        def progress(text, pct = nil)
          @progress_text = text.to_s
          @progress_pct = pct.to_f.clamp(0, 100).round if pct
        end

        def cancel!
          @cancel = true
        end

        def cancelled?
          @cancel
        end

        def finished?
          %i[done failed cancelled].include?(@state)
        end

        # Hết lát thời gian của lô hiện tại?
        def time_up?
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - @slice_start >= @slice
        end

        # 1 lô công việc. Không bao giờ chạy lồng nhau; luôn kết thúc callback bình thường.
        def step
          return if @running || finished?

          @running = true
          @slice_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            raise Cancelled, 'Đã huỷ.' if @cancel

            until @queue.empty?
              task = @queue.first
              t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              done = task.call(self)
              @timings[Job.label_of(task)] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
              raise Cancelled, 'Đã huỷ.' if @cancel

              @queue.shift if done
              break if time_up?
            end
          rescue Cancelled => e
            @running = false
            return fail(e)
          rescue StandardError => e
            @running = false
            return fail(e)
          end
          @running = false
          if @queue.empty?
            finish(@result)
          else
            report
            schedule
          end
        end

        # Kết quả cuối: Task cuối gán job.result= (thường là lambda gửi kết quả cho giao diện).
        def result=(value)
          @result = value
        end

        def finish(result)
          return if finished?

          @state = :done
          cleanup
          @on_done&.call(result)
        end

        def fail(err)
          return if finished?

          @state = err.is_a?(Cancelled) ? :cancelled : :failed
          @error = err
          unless err.is_a?(Cancelled)
            @log&.call("JOB #{@name} LỖI: #{err.class}: #{err.message}\n  #{Array(err.backtrace).first(12).join("\n  ")}")
          end
          cleanup
          @on_error&.call(err)
        end

        # Chạy hết không qua timer (test ngoài SketchUp). Vẫn đi qua đúng step() như khi chạy thật.
        def run_sync(max_steps = 10_000_000)
          @state = :running if @state == :new
          n = 0
          until finished?
            step
            n += 1
            raise 'Job không kết thúc' if n > max_steps
          end
          raise @error if @state == :failed
          raise @error if @state == :cancelled

          @result
        end

        private

        def schedule
          @timer.call(-> { step })
        end

        def report
          cur = [@progress_text, @progress_pct]
          return if cur == @last_sent

          @last_sent = cur
          @on_progress&.call(self)
        end

        def cleanup
          @queue.clear
          @data.clear
        end
      end
    end
  end
end
