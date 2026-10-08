# Asterism::ROS with a receiving thread and Enumerators (CRuby only).
# Asterism::ROS::Node, node.poll, the subscribe / every blocks and pattern
# matching on messages are the shared ones (mrblib/ros.rb), as on the
# boards; this layer runs node.poll on a receiving thread, routes what the
# blocks raise to on_error, and adds the Enumerators.
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
# Locking: each connection has one lock (its Runner's). A tick (node.poll:
# services answered, subscription blocks, timers) holds it; so do the calls
# that change a node (making publishers, subscriptions, services, clients,
# timers) and publishing. A service call made on another thread while the connection
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
        node = self
        @asterism_task = runner.add { node.poll ? 0 : false }
      end

      # As Node#pump (node.poll and waiting service calls go through it). A
      # service block that raised was reported (on_error) and its request
      # left unanswered; polling goes on.
      def pump(steps = 8)
        super
      rescue ::Asterism::ROS::ServiceFailed
        !@session.closed?
      end

      # The subscribe and every blocks (called from node.poll): what they
      # raise goes to on_error, and the others still run.
      def handle(sub, msg, info)
        @asterism_runner.guard("subscribe #{sub.topic_key}") { super }
      end

      def fire(timer, now)
        @asterism_runner.guard("every #{timer.period}") { super }
      end

      def asterism_runner = @asterism_runner

      # The calls that change the node take the connection's lock.
      %i[subscription client close every cancel_timer].each do |m|
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

      # With a block: as on the boards (Node#subscribe), the block gets each
      # message (and its Attachment, or nil) from node.poll, here while the
      # connection spins; returns the Subscription. Without: a Subscription
      # whose each waits for messages (an Enumerator).
      def subscribe(topic, type, qos: DEFAULT_QOS, depth: 16, &blk)
        r = @asterism_runner
        r.lock.synchronize do
          sub = blk ? super : subscription(topic, type, qos: qos, depth: depth)
          sub.extend(Stream)
          sub.asterism_stream_on(session)
          sub
        end
      end

      # A topic to iterate: each subscribes for the iteration and withdraws
      # after it (node.topic("/scan", "sensor_msgs/msg/LaserScan").each.lazy.first(1)).
      def topic(topic, type, qos: DEFAULT_QOS, depth: 16)
        Topic.new(self, topic, type, qos, depth)
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

      def asterism_stream_on(session)
        @asterism_session = session
      end

      # Yields each message (and its Attachment) as it comes, waiting for
      # the next; ends when the subscription or the session closes, or after
      # timeout seconds. Without a block, an Enumerator.
      def each(timeout: nil, &blk)
        return enum_for(:each, timeout: timeout) unless blk
        raise ::Asterism::Error, "this subscription has a block; its messages go there" if handler
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

    class Client
      # Prepended: a call made on another thread while the connection
      # spins waits for the ticks instead of polling the node by itself.
      # (Calls from a board's update loop are on one thread; here the
      # application may call from several.)
      # (The sequence number is read once in the shared call_async, so
      # several threads may call through one client without a lock.)
      module Waiting
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
  end
end
