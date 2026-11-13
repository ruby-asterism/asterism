# The object layer (Asterism.connect / Connection) with blocks and a
# receiving thread (CRuby only). A connection without a block, polled with
# net.poll, works as on the boards.
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
# Each connection has its own receiving thread (start / run). A program may
# hold several connections, each one application.
#
# Locking: the object layer is written for one thread. Every entry into a
# connection (polling, answering, calling, exposing, listing) holds
# Asterism::LOCK, one for all the connections of the process (a call
# waiting on one connection answers the calls of the others, so they share
# it), so the receiving threads and the application's threads take turns.
# A call that waits for its answer while its connection's receiving thread
# runs does not poll; it waits for that thread's ticks
# (Asterism::Runner#wait_until).
require "monitor"

module Asterism
  # Held by every entry into the object layer (reentrant), for every
  # connection of the process.
  LOCK = Monitor.new

  # Module functions that read or change the connections, under LOCK.
  module LockedModule
    %i[connections poll_all profile_defaults register unregister connection_of pump_others].each do |m|
      define_method(m) do |*args, **kw, &blk|
        ::Asterism::LOCK.synchronize { super(*args, **kw, &blk) }
      end
    end

    # With a block: yields the connection and closes it when the block ends
    # (also on an exception); returns the block's value. Without a block,
    # returns the connection (as on the boards).
    def connect(locator = nil, node: nil, app:, mode: nil, listen: nil, config: nil, connect_timeout: nil,
                check_timeout: nil, credentials: nil, &blk)
      conn = super(locator, node: node, app: app, mode: mode, listen: listen, config: config,
                            connect_timeout: connect_timeout, check_timeout: check_timeout, credentials: credentials)
      return conn unless blk
      conn.runner # what the blocks raise goes to on_error from here on
      begin
        blk.call(conn)
      ensure
        conn.close
      end
    end
  end
  singleton_class.prepend(LockedModule)

  class Connection
    # The portable API, entered under LOCK. Prepended, so the shared methods
    # themselves are not changed.
    module Locked
      %i[initialize expose unexpose poll pump nodes [] call_async meta connected? reconnecting? exposed
         on_join on_leave off_join off_leave on_app_join on_app_leave off_app_join off_app_leave
         profile profile_async status app_profile_async apps session publish unpublish published
         topic_put define_type subscribe unsubscribe pubs_get].each do |m|
        define_method(m) do |*args, **kw, &blk|
          ::Asterism::LOCK.synchronize { super(*args, **kw, &blk) }
        end
      end

      # Stops the receiving thread first (outside the lock: it may be inside
      # a tick), then closes.
      def close
        r = @runner
        @runner = nil
        @zenoh = nil
        r&.close
        ::Asterism::LOCK.synchronize { super }
      end

      # The on_join / on_leave (and on_app_*) blocks (called from poll): once
      # the connection has its receiving side (runner: a connect with a
      # block, start, run, on_error), what they raise goes to its on_error
      # and the other blocks still run.
      def tell(where, blk, node, app = nil)
        r = @runner
        return super unless r
        r.guard(where) { super }
      end

      # A subscription's block (called from poll): the same.
      def tell_sample(blk, value, info)
        r = @runner
        return super unless r
        r.guard("subscribe") { super }
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
          r = @runner
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
    prepend Locked

    # Enumerable over the exposed objects alive now, as proxies
    # (net.map(&:asterism_path), net.count): each with the default pattern.
    include Enumerable

    # The receiving side of this connection (made on first use): one tick
    # is poll (answers the calls, tells on_join / on_leave, hands values to
    # the subscriptions); false once the connection is gone. @api private
    def runner
      ::Asterism::LOCK.synchronize do
        @runner ||= begin
          r = Runner.new(@session, lock: ::Asterism::LOCK, name: "asterism #{@node_id}/#{@app}")
          r.add { poll ? 0 : false }
          r
        end
      end
    end

    # The session as a Zenoh::Connection (the block API of
    # Asterism::Zenoh.open) on the same receiving thread as the objects:
    # subscribe / queryable blocks run there, between the calls answered.
    # For a ROS 2 node on the same session:
    # Asterism::ROS::Connection.new(net.zenoh).node("name"). The session
    # stays the connection's: net.zenoh.close does nothing (shared?),
    # net.close closes it. Disconnected when not connected.
    def zenoh
      ::Asterism::LOCK.synchronize do
        s = session
        @zenoh = nil if @zenoh && !@zenoh.session.equal?(s)
        @zenoh ||= ::Asterism::Zenoh::Connection.new(s, runner: runner)
      end
    end

    # on_status(pattern = "*/*") { |node, app, status| }: the statuses put
    # by the applications whose "<node>/<app>" matches the pattern (Zenoh
    # wildcards: * one chunk, ** several), as they change, on the receiving
    # thread. Only changes come: ask status_of for the one there now.
    # Returns the subscription (close it to stop).
    def on_status(pattern = "*/*", &blk)
      raise ArgumentError, "on_status needs a block" unless blk
      zenoh.subscribe("#{::Asterism::ROOT}/#{pattern}/#{::Asterism::Status::KEY}") do |sample|
        got = ::Asterism::Status.parse(sample.key, sample.payload)
        blk.call(*got) if got
      end
    end

    # on_error { |error, where| }: what the on_join / on_leave and
    # subscription blocks raise. (An exposed method that raises is answered
    # to its caller as a RemoteError; it does not come here.)
    def on_error(&blk)
      runner.on_error(&blk)
      self
    end

    # Answers calls on a thread of its own. Returns self.
    def start
      runner.start
      self
    end

    def stop
      @runner&.stop
      self
    end

    # Answers calls on this thread until stop, the connection closing, or
    # Ctrl-C. Returns nil.
    def run
      runner.run
    end

    def running?
      r = @runner
      r ? r.running? : false
    end

    def inspect
      state = if @session then running? ? " running" : ""
              elsif @lost then " lost"
              else " closed"
              end
      "#<Asterism::Connection #{@node_id}/#{@app}#{state}>"
    end
  end

  class Future
    # Prepended: done? reads the connection state, under the lock.
    module Locked
      def done?
        ::Asterism::LOCK.synchronize { super }
      end
    end
    prepend Locked
  end
end
