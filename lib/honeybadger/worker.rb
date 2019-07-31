require 'forwardable'
require 'net/http'

require 'honeybadger/logging'

module Honeybadger
  # A concurrent queue to notify the backend.
  # @api private
  class Worker
    extend Forwardable

    include Honeybadger::Logging::Helper

    # Sub-class thread so we have a named thread (useful for debugging in Thread.list).
    class Thread < ::Thread; end

    # Used to signal the worker to shutdown.
    SHUTDOWN = :__hb_worker_shutdown!

    # The number to multiply the current throttle interval by, resulting in an
    # exponential backoff. 1.05 will reach an interval of 2 minutes after
    # around 100 429 responses from the server.
    THROTTLE_MULTIPLIER = 1.05

    def initialize(config)
      @config = config
      @throttle = 0
      @throttle_interval = 0
      @mutex = Mutex.new
      @marker = ConditionVariable.new
      @queue = Queue.new
      @shutdown = false
      @start_at = nil
    end

    def push(msg)
      return false unless start

      if queue.size > config.max_queue_size
        warn(sprintf('Dropping notice; reached max queue size of %s', queue.size))
        return
      end

      queue.push(msg)
    end

    def send_now(msg)
      handle_response(msg, notify_backend(msg))
    end

    def shutdown
      d { 'shutting down worker' }

      mutex.synchronize do
        @shutdown = true
        @pid = nil
        queue.push(SHUTDOWN)
      end

      return true unless thread

      r = true
      unless Thread.current.eql?(thread)
        begin
          r = !!thread.join
        ensure
          shutdown! unless r
        end
      end

      r
    end

    def shutdown!
      mutex.synchronize do
        @shutdown = true
        @pid = nil
        queue.clear
      end

      d { 'killing worker thread' }

      if thread
        Thread.kill(thread)
        thread.join # Allow ensure blocks to execute.
      end

      true
    end

    # Blocks until queue is processed up to this point in time.
    def flush
      mutex.synchronize do
        if thread && thread.alive?
          queue.push(marker)
          marker.wait(mutex)
        end
      end
    end

    def start
      return false unless can_start?

      mutex.synchronize do
        @shutdown = false
        @start_at = nil

        return true if thread && thread.alive?

        @pid = Process.pid
        @thread = Thread.new { run }
      end

      true
    end

    private

    attr_reader :config, :queue, :pid, :mutex, :marker,
      :thread, :throttle, :throttle_interval

    def_delegator :config, :backend

    def can_start?
      mutex.synchronize do
        return true unless @shutdown
        return false unless @start_at
        Time.now.to_i >= @start_at
      end
    end

    def suspend(interval)
      mutex.synchronize { @start_at = Time.now.to_i + interval }

      # Must be performed last since this may kill the current thread.
      shutdown!
    end

    def run
      begin
        d { 'worker started' }
        loop do
          case msg = queue.pop
          when SHUTDOWN then break
          when ConditionVariable then signal_marker(msg)
          else work(msg)
          end
        end
      ensure
        d { 'stopping worker' }
      end
    rescue Exception => e
      error {
        msg = "error in worker thread (shutting down) class=%s message=%s\n\t%s"
        sprintf(msg, e.class, e.message.dump, Array(e.backtrace).join("\n\t"))
      }
    ensure
      release_marker
    end

    def work(msg)
      send_now(msg)
      sleep(throttle_interval)
    rescue StandardError => e
      error {
        msg = "Error in worker thread class=%s message=%s\n\t%s"
        sprintf(msg, e.class, e.message.dump, Array(e.backtrace).join("\n\t"))
      }
      sleep(1)
    end

    def notify_backend(payload)
      debug { sprintf('worker notifying backend id=%s', payload.id) }
      backend.notify(:notices, payload)
    end

    def calc_throttle_interval
      (throttle.times.reduce(1) {|a,_| a *= THROTTLE_MULTIPLIER } - 1).round(3)
    end

    def inc_throttle
      mutex.synchronize do
        @throttle += 1
        @throttle_interval = calc_throttle_interval
        throttle
      end
    end

    def dec_throttle
      mutex.synchronize do
        return nil if throttle == 0
        @throttle -= 1
        @throttle_interval = calc_throttle_interval
        throttle
      end
    end

    def handle_response(msg, response)
      debug { sprintf('worker response code=%s message=%s', response.code, response.message.to_s.dump) }

      case response.code
      when 429, 503
        throttle = inc_throttle
        warn { sprintf('Error report failed: project is sending too many errors. id=%s code=%s throttle=%s interval=%s', msg.id, throttle, response.code, throttle_interval) }
      when 402
        warn { sprintf('Error report failed: payment is required. id=%s code=%s', msg.id, response.code) }
        suspend(3600)
      when 403
        warn { sprintf('Error report failed: API key is invalid. id=%s code=%s', msg.id, response.code) }
        suspend(3600)
      when 201
        if throttle = dec_throttle
          info { sprintf('Success ⚡ https://app.honeybadger.io/notice/%s id=%s code=%s throttle=%s interval=%s', msg.id, msg.id, response.code, throttle_interval, response.code) }
        else
          info { sprintf('Success ⚡ https://app.honeybadger.io/notice/%s id=%s code=%s', msg.id, msg.id, response.code) }
        end
      when :stubbed
        info { sprintf('Success ⚡ Development mode is enabled; this error will be reported if it occurs after you deploy your app. id=%s', msg.id) }
      when :error
        warn { sprintf('Error report failed: an unknown error occurred. code=%s error=%s', response.code, response.message.to_s.dump) }
      else
        warn { sprintf('Error report failed: unknown response from server. code=%s', response.code) }
      end
    end

    # Release the marker. Important to perform during cleanup when shutting
    # down, otherwise it could end up waiting indefinitely.
    def release_marker
      signal_marker(marker)
    end

    def signal_marker(marker)
      mutex.synchronize do
        marker.signal
      end
    end
  end
end
