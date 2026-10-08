# Asterism::Zenoh with blocks, threads and Enumerators (CRuby only). The
# polled API of asterism-zenoh (Session, each_pending, each_reply) is the
# same on the boards and stays as it is; this is a layer on top of it.
#
#   Asterism::Zenoh.open("tcp/192.0.2.2:7447") do |s|
#     s.subscribe("home/**") { |sample| puts "#{sample.key} = #{sample.payload}" }
#     s.queryable("home/pc/status") { |q| q.reply("ok") }
#     s.put("home/pc/hello", "hi")
#     s.get("home/**/status").each { |reply| p reply }
#     s.subscribe("sensor/temp").each.lazy.map { _1.payload.to_f }.first(3)
#     pub = s.publisher("home/pc/temp", encoding: "text/plain")
#     pub.on_matching { |listening| puts "someone listens: #{listening}" }
#     s.on_transport { |ev| puts "#{ev.zid} #{ev.kind}" }
#     s.run                              # until Ctrl-C (or s.start / s.stop)
#   end
#
# Blocks given to subscribe, queryable and liveliness_watch run on the
# session's receiving thread (start) or inside run; Enumerators (each, get)
# wait on the thread that iterates them. See Asterism::Runner.
module Asterism
  module Zenoh
    # Pause between looks while an Enumerator waits for data (seconds).
    ENUM_STEP = 0.002

    # Sample and Reply (the received values, with kind, encoding,
    # timestamp and the rest) are asterism-zenoh's (asterism/zenoh/values).

    # A liveliness change: key of the token, and whether it appeared.
    Liveliness = Data.define(:key, :alive) do
      alias_method :alive?, :alive
    end

    # Added to the queries a Connection's queryable hands out: reply with
    # only a payload answers on the queryable's own key (when it has no
    # wildcard) instead of the query's, which may be a pattern; payloads
    # that are not Strings are sent as to_s.
    module QueryReply
      def reply(*args, **kw)
        args[-1] = args[-1].to_s unless args.empty? || args[-1].is_a?(String)
        args.unshift(@asterism_key) if args.size == 1 && @asterism_key
        super(*args, **kw)
      end

      # reply_del without a key: the queryable's own key, as reply.
      def reply_del(key = nil, **kw)
        super(key || @asterism_key, **kw)
      end

      def reply_err(payload, **kw)
        super(payload.is_a?(String) ? payload : payload.to_s, **kw)
      end
    end

    # A payload as a String (anything else is sent as to_s).
    def self.bytes(payload)
      payload.is_a?(String) ? payload : payload.to_s
    end

    # The queryable's key when it names one key (no wildcard).
    def self.plain_key(key)
      key.include?("*") || key.include?("$") ? nil : key
    end

    def self.prepare_query(q, key)
      q.extend(QueryReply)
      q.instance_variable_set(:@asterism_key, key)
      q
    end

    # Opens a session (the arguments of Session.open) and wraps it in a
    # Connection. With a block: yields it, closes it when the block ends
    # (also on an exception) and returns the block's value.
    def self.open(locator = nil, interval: Runner::DEFAULT_INTERVAL, **opts)
      conn = Connection.new(Session.open(locator, **opts), interval: interval)
      return conn unless block_given?
      begin
        yield conn
      ensure
        conn.close
      end
    end

    # Seconds (Float) or nil -> milliseconds for the polled API.
    def self.ms(seconds, default_ms)
      return default_ms if seconds.nil?
      (seconds * 1000).round
    end

    # Waits on the calling thread until a sample comes into sub (an
    # Asterism::Zenoh::Subscriber or LivelinessWatch), yielding each.
    # Ends when sub or the session closes, or after timeout seconds.
    def self.drain(sub, session, timeout, take: :each_pending)
      deadline = timeout && (Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout)
      loop do
        got = sub.public_send(take)
        got.each { |e| yield e }
        break if sub.closed? || session.closed?
        break if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep(ENUM_STEP) if got.empty?
      end
    end

    # A session with the block API. The polled calls of the session are
    # still there (session, or the methods without a block).
    class Connection
      attr_reader :session, :runner

      def initialize(session, interval: Runner::DEFAULT_INTERVAL)
        @session = session
        @runner = Runner.new(session, interval: interval, name: "zenoh")
        # The first task: false (the runner stops) once the session closed.
        @runner.add { @session.poll ? 0 : false }
      end

      # opts: those of Session#put (attachment:, encoding:, priority:,
      # congestion_control:, express:, reliability:, timestamp:,
      # allowed_destination:). A payload that is not a String is sent as
      # to_s.
      def put(key, payload, **opts)
        @session.put(key, Zenoh.bytes(payload), **opts)
        nil
      end

      # Deletes key (subscribers get a Sample of kind :delete). opts: those
      # of Session#delete.
      def delete(key, **opts)
        @session.delete(key, **opts)
        nil
      end

      # A declared publisher (Connection::Publisher): put / delete,
      # matching?, on_matching { |listening| }. opts: those of
      # Session#publisher (encoding:, priority:, ...).
      def publisher(key, **opts)
        Publisher.new(self, @session.publisher(key, **opts), key)
      end

      # An advanced publisher (cache:, sample_miss_detection:,
      # publisher_detection: and the publisher options): late subscribers
      # with history get what it kept. Same object as publisher.
      def advanced_publisher(key, **opts)
        Publisher.new(self, @session.advanced_publisher(key, **opts), key)
      end

      # An advanced subscriber (history:, recovery:, subscriber_detection:,
      # query_timeout_ms:): like subscribe, plus on_publisher and on_miss.
      def advanced_subscriber(key, depth: 16, **opts, &blk)
        sub = AdvancedSubscription.new(self, @session.advanced_subscriber(key, depth, **opts), key)
        sub.handle(&blk) if blk
        sub
      end

      # A declared get (Connection::Querier): get { |reply| }, matching?,
      # on_matching. timeout in seconds; the rest as Session#querier.
      def querier(key, timeout: 2.0, **opts)
        Querier.new(self, @session.querier(key, timeout_ms: Zenoh.ms(timeout, 2000), **opts), key)
      end

      # on_transport(history: false) { |event| }: a TransportEvent (kind
      # :added / :removed, zid, whatami) on the receiving thread each time a
      # peer or router connects or goes. Returns an Events (close it).
      def on_transport(history: false, depth: 16, &blk)
        raise ArgumentError, "a block is needed" unless blk
        Events.new(self, @session.transport_events(depth, history: history), "on_transport", blk)
      end

      # on_link(history: false) { |event| }: a LinkEvent each time a link
      # opens or closes.
      def on_link(history: false, depth: 16, &blk)
        raise ArgumentError, "a block is needed" unless blk
        Events.new(self, @session.link_events(depth, history: history), "on_link", blk)
      end

      # With a block: every sample is given to it (as a Sample) on the
      # receiving thread; returns the Subscription (close it to stop).
      # Without: a Subscription to take from (each, each_pending).
      def subscribe(key, depth: 16, &blk)
        sub = Subscription.new(self, @session.subscribe(key, depth), key)
        sub.handle(&blk) if blk
        sub
      end

      # With a block: each query is given to it on the receiving thread and
      # finished when it returns (reply in the block with q.reply). Without:
      # a Queryable whose each yields the queries (finished after each).
      def queryable(key, depth: 16, complete: false, &blk)
        qa = Queryable.new(self, @session.queryable(key, depth, complete: complete), key)
        qa.handle(&blk) if blk
        qa
      end

      # The replies to a get: yields each Reply until every answer came or
      # timeout (seconds) ran out, and returns their number. Without a
      # block, an Enumerator (each iteration sends the get again).
      # errors: true also yields the error replies (Reply#error?); opts:
      # encoding:, priority:, congestion_control:, express:,
      # accept_replies: (Session#get).
      def get(key, timeout: 2.0, params: nil, payload: nil, attachment: nil, target: :all,
              consolidation: :none, errors: false, **opts, &blk)
        start = lambda do
          @session.get(key, Zenoh.ms(timeout, 2000), params, payload,
                       attachment: attachment, target: target, consolidation: consolidation, **opts)
        end
        return enum_for(:get_each, start, errors) unless blk
        get_each(start, errors, &blk)
      end

      # A liveliness token (close it to withdraw).
      def liveliness(key)
        @session.liveliness(key)
      end

      # With a block: yields key and alive (true when the token appeared) on
      # the receiving thread for each change; the tokens alive now come
      # first. Without: a Watch whose each yields Liveliness values.
      def liveliness_watch(key, depth: 16, &blk)
        w = Watch.new(self, @session.liveliness_watch(key, depth), key)
        w.handle(&blk) if blk
        w
      end

      # The keys of the liveliness tokens alive now (an Array; waits for
      # the answers, at most timeout seconds).
      def liveliness_get(key, timeout: 2.0)
        g = @session.liveliness_get(key, Zenoh.ms(timeout, 2000))
        keys = []
        loop do
          g.each_reply.each { |r| keys << r[0] }
          break if g.done?
          sleep(ENUM_STEP)
        end
        g.each_reply.each { |r| keys << r[0] }
        keys
      end

      # Receives on a thread of its own (blocks run there). Returns self.
      def start
        @runner.start
        self
      end

      # Stops the receiving thread (or ends run).
      def stop
        @runner.stop
        self
      end

      # Receives on this thread until stop, the connection closing, or
      # Ctrl-C. Returns nil.
      def run
        @runner.run
      end

      def running?
        @runner.running?
      end

      # on_error { |error, where| }: what the blocks raise. Without a
      # handler it is printed (warn); the receiving goes on either way.
      def on_error(&blk)
        @runner.on_error(&blk)
        self
      end

      def poll
        @session.poll
      end

      def closed?
        @session.closed?
      end

      def zid
        @session.zid
      end

      def peers
        @session.peers
      end

      # The Zenoh IDs of the peers / routers connected now.
      def peer_zids = @session.peer_zids
      def router_zids = @session.router_zids

      # What is connected now: Arrays of Transport / Link.
      def transports = @session.transports
      def links = @session.links

      # A new Timestamp from the session's clock (put(timestamp:)).
      def new_timestamp = @session.new_timestamp

      # A KeyExpr declared on the session (use it as the key afterwards).
      def declare_keyexpr(key) = @session.declare_keyexpr(key)

      # Stops receiving and closes the session (with everything declared on
      # it). Idempotent.
      def close
        @runner.close
        @session.close
        nil
      end

      def inspect
        "#<Asterism::Zenoh::Connection #{closed? ? 'closed' : zid}#{running? ? ' running' : ''}>"
      end

      private

      # Sends the get (start) and yields each Reply; error replies only
      # with errors. The done? before taking the replies: once the get is
      # done, every reply it had is already in the queue.
      def get_each(start, errors)
        g = start.call
        n = 0
        loop do
          done = g.done?
          got = g.each_result
          got.each do |r|
            next if r.error? && !errors
            n += 1
            yield r
          end
          break if done && g.pending == 0
          sleep(ENUM_STEP) if got.empty?
        end
        n
      end

      # A subscription of a Connection. Either its block gets the samples
      # (on the receiving thread), or the application takes them: each (an
      # Enumerator that waits for samples) or each_pending (what is there
      # now, as the polled API).
      class Subscription
        include Enumerable

        attr_reader :key, :subscriber

        def initialize(conn, subscriber, key)
          @conn = conn
          @subscriber = subscriber
          @key = key
          @task = nil
        end

        def handle(&blk)
          raise ArgumentError, "a block is needed" unless blk
          where = "subscribe #{@key}"
          r = @conn.runner
          @task = r.add do
            got = @subscriber.each_sample
            got.each { |s| r.guard(where) { blk.call(s) } }
            got.size
          end
          self
        end

        # Yields each Sample as it comes, waiting for the next; ends when the
        # subscription or the session closes, or after timeout seconds.
        # Without a block, an Enumerator (each.lazy.map { ... }.first(3)).
        def each(timeout: nil, &blk)
          return enum_for(:each, timeout: timeout) unless blk
          raise ::Asterism::Error, "this subscription has a block; its samples go there" if @task
          Zenoh.drain(@subscriber, @conn.session, timeout, take: :each_sample) { |s| blk.call(s) }
          self
        end

        # The samples there now as Samples (an Array), or yields them.
        def each_pending
          got = @subscriber.each_sample
          return got unless block_given?
          got.each { |s| yield s }
          got.size
        end

        def pending = @subscriber.pending
        def received = @subscriber.received
        def dropped = @subscriber.dropped
        def closed? = @subscriber.closed?

        def close
          @conn.runner.remove(@task) if @task
          @task = nil
          @subscriber.close
          nil
        end

        def inspect
          "#<Asterism::Zenoh::Connection::Subscription #{@key}#{@task ? ' (block)' : ''}>"
        end
      end

      # A queryable of a Connection: its block answers on the receiving
      # thread, or each yields the queries (each finished after the block).
      class Queryable
        include Enumerable

        attr_reader :key, :queryable

        def initialize(conn, queryable, key)
          @conn = conn
          @queryable = queryable
          @key = key
          @task = nil
        end

        def handle(&blk)
          raise ArgumentError, "a block is needed" unless blk
          where = "queryable #{@key}"
          own = Zenoh.plain_key(@key)
          r = @conn.runner
          @task = r.add do
            qs = @queryable.each_pending
            qs.each do |q|
              r.guard(where) { blk.call(Zenoh.prepare_query(q, own)) }
            ensure
              q.finish
            end
            qs.size
          end
          self
        end

        # Yields each query (Asterism::Zenoh::Query: key, params, payload,
        # attachment, reply; reply(payload) answers on the queryable's own
        # key) as it comes and finishes it after the block.
        # Ends when the queryable or the session closes, or after timeout.
        def each(timeout: nil, &blk)
          return enum_for(:each, timeout: timeout) unless blk
          raise ::Asterism::Error, "this queryable has a block; its queries go there" if @task
          own = Zenoh.plain_key(@key)
          Zenoh.drain(@queryable, @conn.session, timeout) do |q|
            blk.call(Zenoh.prepare_query(q, own))
          ensure
            q.finish
          end
          self
        end

        def pending = @queryable.pending
        def received = @queryable.received
        def dropped = @queryable.dropped
        def closed? = @queryable.closed?

        def close
          @conn.runner.remove(@task) if @task
          @task = nil
          @queryable.close
          nil
        end
      end

      # A liveliness watch of a Connection.
      class Watch
        include Enumerable

        attr_reader :key, :watch

        def initialize(conn, watch, key)
          @conn = conn
          @watch = watch
          @key = key
          @task = nil
        end

        def handle(&blk)
          raise ArgumentError, "a block is needed" unless blk
          where = "liveliness_watch #{@key}"
          r = @conn.runner
          @task = r.add do
            got = @watch.each_pending
            got.each { |e| r.guard(where) { blk.call(e[0], e[1]) } }
            got.size
          end
          self
        end

        # Yields each change as a Liveliness (key, alive), waiting for the
        # next; the tokens alive now come first.
        def each(timeout: nil, &blk)
          return enum_for(:each, timeout: timeout) unless blk
          raise ::Asterism::Error, "this watch has a block; its changes go there" if @task
          Zenoh.drain(@watch, @conn.session, timeout) { |e| blk.call(Liveliness.new(e[0], e[1])) }
          self
        end

        def closed? = @watch.closed?

        def close
          @conn.runner.remove(@task) if @task
          @task = nil
          @watch.close
          nil
        end
      end

      # A publisher (or advanced publisher) of a Connection.
      class Publisher
        attr_reader :key, :publisher

        def initialize(conn, publisher, key)
          @conn = conn
          @publisher = publisher
          @key = key.to_s
          @tasks = []
        end

        # opts: attachment:, encoding:, timestamp:. A payload that is not a
        # String is sent as to_s.
        def put(payload, **opts)
          @publisher.put(Zenoh.bytes(payload), **opts)
          nil
        end

        def delete(**opts)
          @publisher.delete(**opts)
          nil
        end

        # True when a subscriber matches the key now.
        def matching? = @publisher.matching?

        # on_matching { |listening| }: true when the first subscriber
        # appears, false when the last one goes, on the receiving thread.
        def on_matching(depth: 16, &blk)
          raise ArgumentError, "a block is needed" unless blk
          @tasks << Events.new(@conn, @publisher.matching_listener(depth), "on_matching #{@key}", blk)
          self
        end

        def closed? = @publisher.closed?

        def close
          @tasks.each(&:close)
          @tasks.clear
          @publisher.close
          nil
        end

        def inspect
          "#<Asterism::Zenoh::Connection::Publisher #{@key}>"
        end
      end

      # A querier of a Connection: the same get, sent again and again.
      class Querier
        attr_reader :key, :querier

        def initialize(conn, querier, key)
          @conn = conn
          @querier = querier
          @key = key.to_s
          @tasks = []
        end

        # Yields each Reply until every answer came or the querier's time
        # ran out; returns their number. errors: true also yields the error
        # replies. Without a block, an Enumerator.
        def get(params: nil, payload: nil, attachment: nil, encoding: nil, errors: false, &blk)
          start = -> { @querier.get(params, payload, attachment: attachment, encoding: encoding) }
          return @conn.send(:enum_for, :get_each, start, errors) unless blk
          @conn.send(:get_each, start, errors, &blk)
        end

        def matching? = @querier.matching?

        # on_matching { |answered| }: true when a queryable matches, false
        # when none does any more.
        def on_matching(depth: 16, &blk)
          raise ArgumentError, "a block is needed" unless blk
          @tasks << Events.new(@conn, @querier.matching_listener(depth), "on_matching #{@key}", blk)
          self
        end

        def closed? = @querier.closed?

        def close
          @tasks.each(&:close)
          @tasks.clear
          @querier.close
          nil
        end
      end

      # A subscription with history and recovery (advanced_subscriber).
      class AdvancedSubscription < Subscription
        def initialize(conn, subscriber, key)
          super
          @extra = []
        end

        # on_publisher { |key, alive| }: the advanced publishers on the key
        # that declared publisher_detection, as they come and go (the ones
        # there now first).
        def on_publisher(depth: 16, history: true, &blk)
          raise ArgumentError, "a block is needed" unless blk
          w = Watch.new(@conn, @subscriber.detect_publishers(depth, history: history), @key)
          w.handle(&blk)
          @extra << w
          self
        end

        # on_miss { |miss| }: samples that never came (Miss: source_zid,
        # source_eid, count); needs sample_miss_detection on the publisher.
        def on_miss(depth: 16, &blk)
          raise ArgumentError, "a block is needed" unless blk
          @extra << Events.new(@conn, @subscriber.miss_listener(depth), "on_miss #{@key}", blk)
          self
        end

        def close
          @extra.each(&:close)
          @extra.clear
          super
        end

        def inspect
          "#<Asterism::Zenoh::Connection::AdvancedSubscription #{@key}#{@task ? ' (block)' : ''}>"
        end
      end

      # The values of a listener (MatchingListener or EventListener) given
      # to a block on the receiving thread. close stops it.
      class Events
        attr_reader :listener

        def initialize(conn, listener, where, blk)
          @conn = conn
          @listener = listener
          r = conn.runner
          @task = r.add do
            got = @listener.each_pending
            got.each { |v| r.guard(where) { blk.call(v) } }
            got.size
          end
        end

        def closed? = @listener.closed?

        def close
          @conn.runner.remove(@task) if @task
          @task = nil
          @listener.close
          nil
        end
      end
    end
  end
end
