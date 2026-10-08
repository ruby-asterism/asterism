# Asterism::ROS with blocks, a receiving thread, timers, Enumerators and
# pattern matching (CRuby only). Asterism::ROS::Node and node.poll work as
# on the boards; this is a layer on top of them.
#
#   Asterism::ROS.connect("tcp/192.0.2.2:7447", domain: 0) do |ros|
#     node = ros.node("ruby_talker")
#     chatter = node.publisher("/chatter", "std_msgs/msg/String")
#     chatter << { data: "hello from Ruby" }
#     node.subscribe("/odom", "nav_msgs/msg/Odometry") { |odom| p odom.pose.pose.position.x }
#     node.every(0.1) { chatter << { data: Time.now.to_s } }
#     node.service("/add_ruby", "example_interfaces/srv/AddTwoInts") { |req| { sum: req.a + req.b } }
#     p node.call("/add_two_ints", "example_interfaces/srv/AddTwoInts", a: 1, b: 2).sum
#     node.topic("/scan", "sensor_msgs/msg/LaserScan").each.lazy.first(1)
#     ros.spin
#   end
#
# Locking: each connection has one lock (its Runner's). A tick (services
# answered, subscription blocks, timers) holds it; so do the calls that
# change a node (making publishers, subscriptions, services, clients) and
# publishing. A service call made on another thread while the connection
# spins waits for the ticks (Asterism::Runner#wait_until) instead of
# polling by itself.
module Asterism
  module ROS
    # Opens a Zenoh session and makes a Connection for nodes on it. domain:
    # the ROS domain of the nodes made by ros.node. type_path: directories
    # with generated types to add to Asterism::ROS::TYPE_PATH. The other
    # options go to Asterism::Zenoh::Session.open. With a block: yields the
    # Connection, closes it when the block ends and returns its value.
    def self.connect(locator = nil, domain: 0, type_path: nil, interval: Runner::DEFAULT_INTERVAL, **opts)
      Array(type_path).each { |d| TYPE_PATH << File.expand_path(d) unless TYPE_PATH.include?(File.expand_path(d)) }
      zconn = ::Asterism::Zenoh.open(locator, interval: interval, **opts)
      conn = Connection.new(zconn, domain: domain)
      return conn unless block_given?
      begin
        yield conn
      ensure
        conn.close
      end
    end

    # The ROS side of a Zenoh connection: makes nodes and spins them.
    class Connection
      attr_reader :zenoh, :domain

      def initialize(zconn, domain: 0)
        @zenoh = zconn
        @domain = domain.to_i
        @nodes = []
      end

      def session = @zenoh.session
      def runner = @zenoh.runner

      # An Asterism::ROS::Node on this connection, with the block API
      # (subscribe, every, topic; services answered while it spins).
      def node(name, namespace: "/", enclave: "/")
        runner.lock.synchronize do
          n = Node.new(session, name, namespace: namespace, domain: @domain, enclave: enclave)
          n.extend(Spinning)
          n.asterism_spin_on(runner)
          @nodes << n
          n
        end
      end

      def nodes = @nodes.dup

      # Spins on this thread (services, subscription blocks, timers) until
      # stop, the connection closing, or Ctrl-C. Returns nil.
      def spin
        runner.run
      end
      alias run spin

      # Spins on a thread of its own. Returns self.
      def start
        runner.start
        self
      end

      def stop
        runner.stop
        self
      end

      def running? = runner.running?

      # on_error { |error, where| }: what subscription, timer and service
      # blocks raise (the service request then gets no answer).
      def on_error(&blk)
        runner.on_error(&blk)
        self
      end

      # Stops spinning, withdraws the nodes and closes the session.
      def close
        runner.stop
        @nodes.each { |n| n.close rescue ::Asterism::Zenoh::Error }
        @nodes = []
        @zenoh.close
        nil
      end

      def inspect
        "#<Asterism::ROS::Connection domain #{@domain}#{running? ? ' spinning' : ''}>"
      end
    end

    # A service block raised; it was reported through on_error already.
    class ServiceFailed < ::StandardError; end

    # Added to the nodes a Connection makes (Node#extend). The methods of
    # Node keep their meaning; these come on top.
    module Spinning
      def asterism_spin_on(runner)
        @asterism_runner = runner
        @asterism_timers = []
        node = self
        @asterism_task = runner.add do
          next false unless node.poll
          node.asterism_fire_timers
        end
      end

      # As Node#poll. A service block that raised was reported (on_error)
      # and its request left unanswered; polling goes on.
      def poll(steps = 8)
        super
      rescue ::Asterism::ROS::ServiceFailed
        !@session.closed?
      end

      def asterism_runner = @asterism_runner

      # The calls that change the node take the connection's lock.
      %i[subscription client close].each do |m|
        define_method(m) do |*args, **kw, &blk|
          @asterism_runner.lock.synchronize { super(*args, **kw, &blk) }
        end
      end

      # As Node#publisher; publishing takes the lock too (a timer on the
      # receiving thread and the application may publish at once).
      def publisher(topic, type, qos: DEFAULT_QOS)
        r = @asterism_runner
        r.lock.synchronize do
          pub = super
          pub.extend(LockedPublisher)
          pub.instance_variable_set(:@asterism_lock, r.lock)
          pub
        end
      end

      # As Node#service: the block answers while the connection spins (or
      # from node.poll). What it raises goes to on_error and that request
      # gets no answer.
      def service(name, type, qos: DEFAULT_QOS, depth: 8, &handler)
        raise ArgumentError, "service needs a block" unless handler
        r = @asterism_runner
        where = "service #{name}"
        wrapped = proc do |req|
          handler.call(req)
        rescue StandardError => e
          r.report(e, where)
          raise ::Asterism::ROS::ServiceFailed, e.message
        end
        r.lock.synchronize { super(name, type, qos: qos, depth: depth, &wrapped) }
      end

      # With a block: each message (and its Attachment, or nil) is given to
      # it while the connection spins; returns the Subscription. Without: a
      # Subscription whose each waits for messages (an Enumerator).
      def subscribe(topic, type, qos: DEFAULT_QOS, depth: 16, &blk)
        r = @asterism_runner
        r.lock.synchronize do
          sub = subscription(topic, type, qos: qos, depth: depth)
          sub.extend(Stream)
          sub.asterism_stream_on(r, session)
          sub.asterism_handle(&blk) if blk
          sub
        end
      end

      # A topic to iterate: each subscribes for the iteration and withdraws
      # after it (node.topic("/scan", "sensor_msgs/msg/LaserScan").each.lazy.first(1)).
      def topic(topic, type, qos: DEFAULT_QOS, depth: 16)
        Topic.new(self, topic, type, qos, depth)
      end

      # Calls the block every `seconds` while the connection spins (the
      # first time one period from now). Returns a Timer (cancel).
      def every(seconds, &blk)
        raise ArgumentError, "every needs a block" unless blk
        raise ArgumentError, "the period must be positive" unless seconds.to_f > 0
        t = Timer.new(self, seconds.to_f, blk)
        @asterism_runner.lock.synchronize { @asterism_timers << t }
        t
      end

      def asterism_cancel(timer)
        @asterism_runner.lock.synchronize { @asterism_timers.delete(timer) }
      end

      # On the receiving thread, with the lock held.
      def asterism_fire_timers
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        n = 0
        @asterism_timers.dup.each do |t|
          next unless t.due?(now)
          n += 1
          @asterism_runner.guard("every #{t.period}") { t.fire(now) }
        end
        n
      end

      # Node#call with the time limit in seconds as well: timeout: 2.0.
      def call(service, type, request = nil, timeout: nil, timeout_ms: nil, **fields)
        ms = timeout_ms || ::Asterism::Zenoh.ms(timeout, Client::DEFAULT_TIMEOUT_MS)
        c = @asterism_runner.lock.synchronize do
          @clients ||= {}
          cl = @clients[service]
          if cl.nil? || cl.closed?
            cl = client(service, type)
            @clients[service] = cl
          end
          cl
        end
        c.call(request, timeout_ms: ms, **fields)
      end
    end

    module LockedPublisher
      def publish(msg)
        @asterism_lock.synchronize { super }
      end
    end

    # Added to the subscriptions node.subscribe makes.
    module Stream
      include Enumerable

      def asterism_stream_on(runner, session)
        @asterism_runner = runner
        @asterism_session = session
        @asterism_task = nil
      end

      def asterism_handle(&blk)
        r = @asterism_runner
        sub = self
        where = "subscribe #{@topic_key}"
        @asterism_task = r.add do
          got = sub.each_pending
          got.each { |m| r.guard(where) { blk.call(m[0], m[1]) } }
          got.size
        end
      end

      # Yields each message (and its Attachment) as it comes, waiting for
      # the next; ends when the subscription or the session closes, or after
      # timeout seconds. Without a block, an Enumerator.
      def each(timeout: nil, &blk)
        return enum_for(:each, timeout: timeout) unless blk
        raise ::Asterism::Error, "this subscription has a block; its messages go there" if @asterism_task
        deadline = timeout && (Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout)
        loop do
          got = each_pending
          got.each { |m| blk.call(m[0], m[1]) }
          break if closed? || @asterism_session.closed?
          break if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep(::Asterism::Zenoh::ENUM_STEP) if got.empty?
        end
        self
      end

      def closed?
        @token.nil?
      end

      def close
        @asterism_runner.remove(@asterism_task) if @asterism_task
        @asterism_task = nil
        super
      end
    end

    # node.topic: subscribes while it is iterated.
    class Topic
      include Enumerable

      attr_reader :name, :type

      def initialize(node, name, type, qos, depth)
        @node = node
        @name = name
        @type = type
        @qos = qos
        @depth = depth
      end

      # Yields each message and its Attachment, from a subscription made
      # for this iteration (withdrawn when it ends: break, first(n), the
      # time running out). Without a block, an Enumerator.
      def each(timeout: nil, &blk)
        return enum_for(:each, timeout: timeout) unless blk
        sub = @node.subscribe(@name, @type, qos: @qos, depth: @depth)
        begin
          sub.each(timeout: timeout, &blk)
        ensure
          sub.close
        end
        self
      end

      def inspect
        "#<Asterism::ROS::Topic #{@name}>"
      end
    end

    # node.every
    class Timer
      attr_reader :period, :fired

      def initialize(node, period, blk)
        @node = node
        @period = period
        @blk = blk
        @next = Process.clock_gettime(Process::CLOCK_MONOTONIC) + period
        @fired = 0
      end

      def due?(now)
        now >= @next
      end

      # Keeps the period without drifting; after a long stall it starts
      # again from now instead of firing the missed times at once.
      def fire(now)
        @next += @period
        @next = now + @period if @next <= now
        @fired += 1
        @blk.call
      end

      def cancel
        @node.asterism_cancel(self)
        nil
      end
    end

    class Client
      # Prepended: a call made on another thread while the connection
      # spins waits for the ticks instead of polling the node by itself.
      # (Calls from a board's update loop are on one thread; here the
      # application may call from several.)
      module Waiting
        # Taken while a request goes out: the sequence number a request
        # carries and the one its Call waits for must be the same, also
        # when several threads call through one client.
        SEND_LOCK = Mutex.new

        def call_async(*args, **kw)
          SEND_LOCK.synchronize { super }
        end

        def wait_for(c)
          loop do
            r = ::Asterism::Runner.for(@session)
            if r && r.running? && !r.current?
              r.wait_until { c.done? }
              return if c.done?
            else
              return r ? r.lock.synchronize { super } : super
            end
          end
        end
      end
      prepend Waiting
    end

    # Pattern matching on messages (CRuby): case msg in {linear: {x:}}.
    class Message
      def deconstruct_keys(keys)
        fs = self.class::FIELDS
        h = {}
        fs.each { |f| h[f] = __send__(f) if keys.nil? || keys.include?(f) }
        h
      end
    end

    class Attachment
      def deconstruct_keys(_keys)
        { sequence: @sequence, stamp_ns: @stamp_ns, gid: @gid }
      end
    end
  end
end
