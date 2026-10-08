# The receiving loop behind the block API of the CRuby layer (CRuby only;
# the boards poll from their update loop instead).
#
# A Runner belongs to one Zenoh session. It holds tasks: small procs that
# take what has arrived (each_pending of the shared API) and hand it to the
# application's blocks. Every round of tasks (a tick) runs with the runner's
# lock held, so the shared, single-threaded layers are never entered by two
# threads at once. zenoh-c's own threads never call Ruby: they only fill the
# channels the tasks empty.
#
#   runner.start    ticks on a thread of its own (until stop or close)
#   runner.run      ticks on the calling thread (until stop, close or Ctrl-C)
#   runner.stop     ends either; joins the thread unless called from it
#
# A thread that waits for an answer while the runner ticks (proxy calls,
# ROS service calls) does not poll by itself: it waits on the runner's
# condition variable, and checks after each tick whether its answer came
# (wait_until). The runner's own thread, and any thread while the runner
# does not tick, poll as the shared layers always do.
require "monitor"

module Asterism
  class Runner
    # Pause between ticks when nothing arrived (seconds).
    DEFAULT_INTERVAL = 0.002
    # Longest a waiting thread sleeps before it checks again on its own.
    WAIT_SLICE = 0.05

    @registry = {}.compare_by_identity
    @registry_lock = Mutex.new

    class << self
      # The runner of a Zenoh session (nil when it has none).
      def for(session)
        @registry_lock.synchronize { @registry[session] }
      end

      def register(session, runner)
        @registry_lock.synchronize { @registry[session] = runner }
      end

      def unregister(session, runner)
        @registry_lock.synchronize { @registry.delete(session) if @registry[session].equal?(runner) }
      end
    end

    attr_reader :lock, :session

    # session: the Asterism::Zenoh::Session the tasks read from. lock: the
    # Monitor guarding the layer the tasks call into (the object layer has a
    # process-wide one). on_closed is called once, on the ticking thread,
    # when the session is found closed.
    def initialize(session, lock: Monitor.new, interval: DEFAULT_INTERVAL, name: "asterism")
      @session = session
      @lock = lock
      @cond = @lock.new_cond
      @interval = interval
      @name = name
      @tasks = []
      @error_handler = nil
      @thread = nil
      @ticking = nil     # the thread inside start / run
      @stop = false
      @closed = false
      self.class.register(session, self)
    end

    # Adds a task: a proc called every tick with the lock held. It returns
    # the number of things it handled (0 or nil when nothing came), and
    # false once the session is found closed. Returns the task, for remove.
    def add(task = nil, &blk)
      t = task || blk
      @lock.synchronize { @tasks << t }
      t
    end

    def remove(task)
      @lock.synchronize { @tasks.delete(task) }
      nil
    end

    # on_error { |error, where| }: errors raised by the application's blocks
    # (StandardError) go here instead of stopping the runner. Without a
    # handler they are printed with warn. where: what the block was for
    # (e.g. "subscribe demo/**").
    def on_error(&blk)
      @error_handler = blk
      self
    end

    # Runs the application's block; reports what it raises instead of
    # letting it out. Returns the block's value, or nil when it raised.
    def guard(where)
      yield
    rescue StandardError => e
      report(e, where)
      nil
    end

    def report(error, where)
      if @error_handler
        begin
          @error_handler.call(error, where)
        rescue StandardError => e2
          warn "asterism: on_error raised #{e2.class}: #{e2.message}"
        end
      else
        warn "asterism: #{where}: #{error.class}: #{error.message}"
      end
    end

    # One round of the tasks. Returns the number of things handled, or nil
    # once the session is closed.
    def tick
      n = 0
      closed = false
      @lock.synchronize do
        begin
          @tasks.dup.each do |t|
            r = begin
              t.call
            rescue ::Asterism::Zenoh::Error
              false # the session went away under the task
            rescue StandardError => e
              report(e, "receiver")
              0
            end
            if r == false
              closed = true
              break
            end
            n += r if r.is_a?(Integer)
          end
        ensure
          @cond.broadcast
        end
      end
      if closed
        @closed = true
        @stop = true
        return nil
      end
      n
    end

    # Ticks on a thread of its own. Returns self. Does nothing when already
    # ticking.
    def start
      @lock.synchronize do
        return self if @ticking
        @stop = false
        @thread = Thread.new { loop_ticks }
        @thread.name = "#{@name} receiver" if @thread.respond_to?(:name=)
        @ticking = @thread
      end
      self
    end

    # Ticks on the calling thread until stop, the session closing, or
    # Ctrl-C (which returns nil instead of raising). Raises Error when the
    # runner already ticks on another thread.
    def run
      @lock.synchronize do
        raise ::Asterism::Error, "already running (stop it first)" if @ticking
        @stop = false
        @ticking = Thread.current
      end
      begin
        loop_ticks
      rescue Interrupt
        nil
      ensure
        @lock.synchronize do
          @ticking = nil if @ticking.equal?(Thread.current)
          @cond.broadcast
        end
      end
      nil
    end

    # Ends start / run after the current tick. From another thread it waits
    # for the receiving thread to end (unless that thread is inside a tick
    # this thread is waiting for). Idempotent.
    def stop
      @stop = true
      th = @thread
      if th && !th.equal?(Thread.current) && !@lock.mon_owned?
        th.join
      end
      @lock.synchronize do
        @thread = nil if @thread.equal?(th) && !(th && th.alive?)
        @cond.broadcast
      end
      self
    end

    # Stops and forgets the session. The caller closes the session after.
    def close
      stop
      self.class.unregister(@session, self)
      nil
    end

    # True while start or run ticks.
    def running?
      t = @ticking
      !t.nil? && t.alive? && !@stop
    end

    # True on the thread that ticks.
    def current?
      @ticking.equal?(Thread.current)
    end

    def closed?
      @closed
    end

    # For a thread other than the ticking one: waits until the block is
    # true, checking it after each tick with the lock held. Returns when the
    # block is true, or when the runner stops (the caller then looks at its
    # own state, e.g. a time limit or a closed session). The block also sees
    # its own deadline: it is checked at least every WAIT_SLICE seconds.
    def wait_until
      @lock.synchronize do
        until yield
          break unless running?
          @cond.wait(WAIT_SLICE)
        end
      end
    end

    def inspect
      "#<Asterism::Runner #{@name} #{running? ? 'running' : 'stopped'}>"
    end

    private

    def loop_ticks
      until @stop
        n = tick
        break if n.nil?
        sleep(@interval) if n == 0 && !@stop
      end
    ensure
      @lock.synchronize do
        @ticking = nil if @ticking.equal?(Thread.current)
        @thread = nil if @thread.equal?(Thread.current)
        @cond.broadcast
      end
    end
  end
end
