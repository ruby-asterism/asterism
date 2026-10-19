# `asterism status hz`: how often an application's status changes, as
# `ros2 topic hz` tells how often a topic is published. Each change is a
# time (a monotonic clock, given or Process.clock_gettime); the intervals
# between the last ones (a window of them) give the average rate and the
# intervals' min, max and standard deviation. A put that brings the same
# status again (as after a reconnection) is not a change.
module Asterism
  class CLI
    class Hz
      attr_reader :count

      # window: how many of the last intervals count. clock: a callable
      # that returns the time in seconds (monotonic).
      def initialize(window: 1000, clock: nil)
        @window = window
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @times = []
        @last = nil
        @seeded = false
        @count = 0
        @reported = 0
      end

      # The status there at the start: what the first put is compared with
      # (not a change itself).
      def seed(status)
        @last = status
        @seeded = true
      end

      # A put of the status: a change (true) when it differs from the last
      # one seen (the first put without a seed is one).
      def put(status)
        return false if @seeded && status == @last
        @last = status
        @seeded = true
        add(@clock.call)
        true
      end

      # A change at time t (seconds).
      def add(t)
        @count += 1
        @times << t
        @times.shift while @times.size > @window + 1
      end

      # {"rate_hz", "min_s", "max_s", "std_s", "window", "count"} over the
      # intervals in the window, or nil before two changes.
      def stats
        return nil if @times.size < 2
        ints = @times.each_cons(2).map { |a, b| b - a }
        avg = ints.sum / ints.size
        var = ints.sum { (_1 - avg)**2 } / ints.size
        { "rate_hz" => avg.positive? ? 1.0 / avg : nil, "min_s" => ints.min, "max_s" => ints.max,
          "std_s" => Math.sqrt(var), "window" => ints.size, "count" => @count }
      end

      # stats when a change came since the last report (else nil): what a
      # period prints.
      def report
        return nil if @count == @reported
        s = stats
        @reported = @count if s
        s
      end

      # The lines of a report, as ros2 topic hz prints them.
      def self.text(s)
        rate = s["rate_hz"] ? format("%.3f", s["rate_hz"]) : "inf"
        ["average rate: #{rate} Hz",
         format("  min: %.3f s  max: %.3f s  std dev: %.3f s  window: %d", s["min_s"], s["max_s"], s["std_s"],
                s["window"])]
      end
    end
  end
end
