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
    %i[expose unexpose poll nodes [] call_async meta connected? exposed].each do |m|
      define_method(m) do |*args, **kw, &blk|
        ::Asterism::LOCK.synchronize { super(*args, **kw, &blk) }
      end
    end

    # With a block: yields an Asterism::Net and closes when the block ends
    # (also on an exception); returns the block's value. Without a block,
    # as before (returns Asterism).
    def connect(locator, node:, app:, mode: nil, listen: nil, &blk)
      ::Asterism::LOCK.synchronize { super(locator, node: node, app: app, mode: mode, listen: listen) }
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
      @join = []
      @leave = []
      @known = []
      @runner.add { tick }
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

    # on_join { |node| }: a node (other than this one) appeared: its node
    # token or one of its objects. The nodes there already are reported on
    # the first ticks after connecting. Runs on the receiving thread.
    def on_join(&blk)
      ::Asterism::LOCK.synchronize { @join << blk }
      self
    end

    # on_leave { |node| }: a node is gone (no token and no object left).
    # When the connection is lost, every node known until then leaves.
    def on_leave(&blk)
      ::Asterism::LOCK.synchronize { @leave << blk }
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

    private

    # One tick, with LOCK held: poll (answers the calls), then tell the
    # node changes. false once the connection is gone (after telling that
    # every node left).
    def tick
      lost = !::Asterism.poll
      now = lost ? [] : ::Asterism.nodes
      now.shift # this node
      joined = now - @known
      left = @known - now
      @known = now
      joined.each { |n| @join.each { |b| @runner.guard("on_join") { b.call(n) } } }
      left.each { |n| @leave.each { |b| @runner.guard("on_leave") { b.call(n) } } }
      return false if lost
      joined.size + left.size
    end
  end
end
