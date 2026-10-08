# The object layer (Asterism.connect / expose / []) with blocks and a
# receiving thread (CRuby only). Asterism.connect without a block,
# Asterism.poll and the rest of the polled API work as on the boards.
#
#   Asterism.connect("tcp/192.0.2.2:7447", node: "mypc", app: "demo") do |net|
#     net.expose("screen", Screen.new, methods: [:say])
#     net.on_join  { |node| puts "joined #{node}" }
#     net.on_leave { |node| puts "left #{node}" }
#     net["fmruby-aaaaaa/demo/screen"].say("hello")
#     net.each("*/demo/info").map(&:status)
#     net.run                             # answer calls until Ctrl-C
#   end
#
# Locking: the object layer is one connection per process with its state in
# the Asterism module, written for one thread. Every entry into it (polling,
# answering, calling, exposing, listing) holds Asterism::LOCK, so the
# receiving thread and the application's threads take turns. A call that
# waits for its answer while the receiving thread runs does not poll; it
# waits for the receiving thread's ticks (Asterism::Runner#wait_until).
require "monitor"

module Asterism
  # Held by every entry into the object layer (reentrant).
  LOCK = Monitor.new

  # The polled API, entered under LOCK. Prepended to the Asterism module's
  # singleton class, so the shared methods themselves are not changed.
  module Locked
    %i[expose unexpose poll nodes [] call_async meta connected? exposed on_join on_leave].each do |m|
      define_method(m) do |*args, **kw, &blk|
        ::Asterism::LOCK.synchronize { super(*args, **kw, &blk) }
      end
    end

    # With a block: yields an Asterism::Net and closes when the block ends
    # (also on an exception); returns the block's value. Without a block,
    # as before (returns Asterism).
    def connect(locator, node:, app:, mode: nil, listen: nil, config: nil, &blk)
      ::Asterism::LOCK.synchronize do
        super(locator, node: node, app: app, mode: mode, listen: listen, config: config)
        # The Net of a connection that was lost (not closed) belongs to the
        # old session.
        old = @net
        @net = nil
        old&.release
      end
      return self unless blk
      net = ::Asterism.net
      begin
        blk.call(net)
      ensure
        net.close
      end
    end

    # Stops the receiving thread first (outside the lock: it may be inside
    # a tick), then closes.
    def close
      net = @net
      @net = nil
      net&.release
      ::Asterism::LOCK.synchronize { super }
    end

    # The on_join / on_leave blocks (called from Asterism.poll): with a Net,
    # what they raise goes to its on_error and the other blocks still run.
    def tell(where, blk, node)
      net = @net
      return super unless net
      net.runner.guard(where) { super }
    end

    # Lists under the lock, yields outside it (the block may make calls).
    def each(pattern = "**", &blk)
      list = ::Asterism::LOCK.synchronize { super(pattern, &nil) }
      return list unless blk
      list.each(&blk)
      list.size
    end

    # A call waiting for its answer. On the receiving thread, or when it
    # does not run: polls, as on the boards. On another thread while it
    # runs: waits for its ticks to bring the answer.
    def wait_until(&cond)
      loop do
        r = @net&.runner
        if r && r.running? && !r.current?
          r.wait_until(&cond)
          return if ::Asterism::LOCK.synchronize(&cond)
          # The receiving thread stopped before the answer: poll here.
        else
          return ::Asterism::LOCK.synchronize { super(&cond) }
        end
      end
    end
  end
  singleton_class.prepend(Locked)

  class Future
    # Prepended: done? reads the connection state, under the lock.
    module Locked
      def done?
        ::Asterism::LOCK.synchronize { super }
      end
    end
    prepend Locked
  end

  # The connection of this process (Asterism is one per process) as an
  # object, with a receiving thread. nil when not connected.
  def self.net
    LOCK.synchronize do
      return nil unless connected?
      @net ||= Net.new
    end
  end

  # The block API of the object layer. Made by Asterism.connect with a
  # block, or Asterism.net after a connect without one.
  class Net
    attr_reader :runner

    def initialize
      @runner = Runner.new(::Asterism.instance_variable_get(:@session), lock: ::Asterism::LOCK, name: "asterism")
      # One tick: Asterism.poll (answers the calls, tells on_join /
      # on_leave); false once the connection is gone.
      @runner.add { ::Asterism.poll ? 0 : false }
    end

    def node_id = ::Asterism.node_id
    def app = ::Asterism.app
    def connected? = ::Asterism.connected?
    def lost_reason = ::Asterism.lost_reason
    def nodes = ::Asterism.nodes
    def exposed = ::Asterism.exposed

    # Asterism.expose: methods: an Array of names or a Hash name => number
    # of arguments. The object's methods run on the receiving thread (or in
    # run, or in whatever polls).
    def expose(name, obj, methods:)
      ::Asterism.expose(name, obj, methods: methods)
    end

    def unexpose(name)
      ::Asterism.unexpose(name)
    end

    # A proxy for <node>/<app>/<object>; timeout in seconds.
    def [](path, timeout: nil)
      ::Asterism[path, Zenoh.ms(timeout, ::Asterism::DEFAULT_TIMEOUT_MS)]
    end
    alias proxy []

    # The exposed objects alive now matching the pattern, as proxies. With
    # a block, yields each and returns their number; without, an
    # Enumerator (net.each("*/demo/info").map(&:status)).
    def each(pattern = "**", &blk)
      return enum_for(:each, pattern) unless blk
      ::Asterism.each(pattern, &blk)
    end
    include Enumerable

    # on_join { |node| } / on_leave { |node| }: Asterism.on_join /
    # on_leave, the same as on the boards (called from Asterism.poll), here
    # on the receiving thread. What they raise goes to on_error.
    def on_join(&blk)
      ::Asterism.on_join(&blk)
      self
    end

    def on_leave(&blk)
      ::Asterism.on_leave(&blk)
      self
    end

    # on_error { |error, where| }: what on_join / on_leave blocks raise.
    # (An exposed method that raises is answered to its caller as a
    # RemoteError, as before; it does not come here.)
    def on_error(&blk)
      @runner.on_error(&blk)
      self
    end

    # Answers calls on a thread of its own. Returns self.
    def start
      @runner.start
      self
    end

    def stop
      @runner.stop
      self
    end

    # Answers calls on this thread until stop, the connection closing, or
    # Ctrl-C. Returns nil.
    def run
      @runner.run
    end

    def running?
      @runner.running?
    end

    def poll
      ::Asterism.poll
    end

    # Stops the receiving thread and closes the connection (Asterism.close).
    def close
      ::Asterism.close
      nil
    end

    # For Asterism.close: stop receiving and forget the session.
    def release
      @runner.close
    end

    def inspect
      "#<Asterism::Net #{node_id}/#{app}#{running? ? ' running' : ''}>"
    end
  end
end
