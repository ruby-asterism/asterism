# Asterism::ROS: a minimal ROS 2 node over rmw_zenoh's wire format
# (doc/ruby_asterism/design.md ch. 5; topics R1, services R2, message types
# R3). The message and service types are generated from .msg / .srv files
# (tools/asterism_msggen.rb) and loaded when the application asks for them.
#
#   s = Asterism::Zenoh::Session.open("tcp/192.0.2.2:7447")
#   node = Asterism::ROS::Node.new(s, "fmruby_talker")
#   str = Asterism::ROS.require_type("std_msgs/msg/String")
#   pub = node.publisher("/chatter", str)
#   sub = node.subscription("/chatter_back", "std_msgs/msg/String")  # by name
#   add = Asterism::ROS.require_type("example_interfaces/srv/AddTwoInts")
#   node.service("/add_two_ints_fmrb", add) { |req| { sum: req.a + req.b } }
#   cli = node.client("/add_two_ints", add)
#   node.subscribe("/cmd", "std_msgs/msg/String") { |msg, info| puts msg.data }
#   node.every(1.0) { pub << { data: "tick" } }
#   loop do
#     node.poll                                   # session.poll, services, then the
#                                                 # subscribe and every blocks
#     pub << { data: "hello" }                    # or pub.publish(str.new(data: "hello"))
#     sub.each_pending { |msg, info| puts msg.data }   # info: Attachment or nil
#   end
#   cli.call(a: 2, b: 3).sum                      # waits (polling), or
#   cli.call(request: {a: 2, b: 3}, timeout: 5.0) # the request as a Hash
#   c = cli.call_async(a: 2, b: 3); c.done?; c.value
#   node.close
#
# What goes on the wire (rmw_zenoh_cpp 0.2.x, ROS 2 Jazzy):
# - data key: <domain>/<topic without the outer slashes>/<DDS type name>/<type hash>
#   e.g. 0/chatter/std_msgs::msg::dds_::String_/RIHS01_df66...
# - payload: CDR (Asterism::CDR)
# - attachment (required by rmw_zenoh subscribers; a sample without one is
#   dropped): int64 sequence number, int64 source time (ns since the epoch),
#   both little endian, then the GID as a one-byte length (16) and 16 bytes.
# - liveliness tokens, which make the node and its topics appear in
#   `ros2 node list` / `ros2 topic list`:
#     @ros2_lv/<domain>/<zid>/<nid>/<nid>/NN/<enclave>/<namespace>/<node>
#     @ros2_lv/<domain>/<zid>/<nid>/<id>/MP|MS/<enclave>/<namespace>/<node>/
#       <topic>/<DDS type name>/<type hash>/<qos>
#   with "/" written as "%" in enclave, namespace and topic ("%" alone for "/").
# - services: the server is a complete queryable on
#   <domain>/<service>/<DDS service type>/<service type hash>, the client
#   gets that key with target ALL_COMPLETE and no consolidation. Request and
#   reply both carry the attachment above: the client's sequence number and
#   GID go out with the request, and the reply carries them back (with the
#   server's time), which is how the client pairs them. Tokens SS (server)
#   and SC (client), shaped like MP / MS.
#
# Nothing here depends on the host: it uses an Asterism::Zenoh::Session
# (put with attachment:, subscribe, liveliness, zid) and Asterism::CDR.
module Asterism
  # (asterism.rb defines both; this file is also loaded on its own, with
  # cdr.rb, by the type tools.)
  class Error < StandardError; end
  class TimeoutError < Error; end

  module ROS
    LIVELINESS_ROOT = "@ros2_lv"
    # rmw_zenoh's QoS chunk for the default profile (reliable, volatile,
    # keep last 10): fields that equal the default are left empty.
    DEFAULT_QOS = "::,10:,:,:,,"
    GID_SIZE = 16

    # A name chunk of a liveliness token: "/" becomes "%", "" or "/" is "%".
    def self.mangle(name)
      s = name.to_s
      return "%" if s.empty? || s == "/"
      out = "".dup
      i = 0
      n = s.bytesize
      while i < n
        c = s.byteslice(i, 1)
        out << (c == "/" ? "%" : c)
        i += 1
      end
      out
    end

    # Drops one leading and one trailing "/".
    def self.strip_slashes(name)
      s = name.to_s
      s = s.byteslice(1, s.bytesize - 1) if s.bytesize > 0 && s.byteslice(0, 1) == "/"
      s = s.byteslice(0, s.bytesize - 1) if s.bytesize > 0 && s.byteslice(s.bytesize - 1, 1) == "/"
      s
    end

    # A full topic name: absolute names stay, relative ones go under the
    # namespace. "~" and substitutions are not supported.
    def self.resolve(topic, namespace)
      t = topic.to_s
      raise ArgumentError, "empty topic name" if t.empty?
      return t if t.byteslice(0, 1) == "/"
      ns = namespace.to_s
      ns == "/" || ns.empty? ? "/" + t : ns + "/" + t
    end

    # Nanoseconds since the epoch, or 0 when there is no clock.
    def self.now_ns
      if Object.const_defined?(:Time)
        t = ::Time.now
        t.to_i * 1_000_000_000 + t.usec * 1000
      else
        0
      end
    rescue
      0
    end

    # 16 bytes derived from a string (32-bit FNV-1a, four lanes with
    # different seeds; small enough not to overflow a 64-bit Integer).
    # rmw_zenoh hashes the entity's liveliness key the same way (with XXH3);
    # receivers only use the GID to tell publishers apart.
    def self.gid_for(key)
      out = "".dup
      lane = 0
      while lane < 4
        h = 0x811c9dc5 ^ (lane * 0x9e3779b9 & 0xffffffff)
        i = 0
        n = key.bytesize
        while i < n
          h = ((h ^ key.getbyte(i)) * 0x01000193) & 0xffffffff
          i += 1
        end
        out << ::Asterism::CDR.le_bytes(h, 4)
        lane += 1
      end
      out
    end

    # A service call got no answer in time (or nobody serves that name). An
    # Asterism::TimeoutError (so an Asterism::Error); its old name
    # Asterism::ROS::Timeout still works, with a deprecation warning.
    class TimeoutError < ::Asterism::TimeoutError; end

    # The old name Asterism::ROS::Timeout (deprecated): see
    # Asterism.const_missing.
    def self.const_missing(name)
      if name == :Timeout
        ::Asterism.deprecated("Asterism::ROS::Timeout", "Asterism::ROS::TimeoutError")
        return TimeoutError
      end
      super
    end

    # Milliseconds from an arbitrary origin (the board's clock when there is
    # one), and a short pause; the same helpers Asterism's calls use.
    def self.now_ms
      ::Asterism.now_ms
    end

    def self.pause(ms)
      ::Asterism.pause(ms)
    end

    # The attachment of a sample: sequence number, source time, publisher GID.
    class Attachment
      attr_reader :sequence, :stamp_ns, :gid

      def initialize(sequence, stamp_ns, gid)
        @sequence = sequence
        @stamp_ns = stamp_ns
        @gid = gid
      end

      # For pattern matching: case info in {sequence:, gid:}.
      def deconstruct_keys(_keys)
        { sequence: @sequence, stamp_ns: @stamp_ns, gid: @gid }
      end

      def encode
        g = @gid.to_s
        ::Asterism::CDR.le_bytes(@sequence, 8) + ::Asterism::CDR.le_bytes(@stamp_ns, 8) +
          ::Asterism::CDR.le_bytes(g.bytesize, 1) + g
      end

      # nil when the bytes are not an attachment of this shape.
      def self.decode(bytes)
        return nil if bytes.nil? || bytes.bytesize < 17
        glen = bytes.getbyte(16)
        return nil if bytes.bytesize < 17 + glen
        new(le_int(bytes, 0), le_int(bytes, 8), bytes.byteslice(17, glen))
      end

      def self.le_int(bytes, at)
        top = bytes.getbyte(at + 7)
        v = top >= 0x80 ? top - 0x100 : top
        i = 6
        while i >= 0
          v = (v << 8) | bytes.getbyte(at + i)
          i -= 1
        end
        v
      end
    end

    # Where Asterism::ROS.require_type looks for generated types
    # (<dir>/<pkg>/<msg|srv>/<Name>.rb, tools/asterism_msggen.rb). The
    # application may add its own directories (or set them on CRuby).
    TYPE_PATH = ["/usr/share/asterism/msgs"]

    # The type has no generated file in TYPE_PATH.
    class UnknownType < ::Asterism::Error; end

    def self.type_path
      TYPE_PATH
    end

    # Loads a generated message or service type by its ROS name
    # ("geometry_msgs/msg/Twist", "example_interfaces/srv/AddTwoInts") and
    # returns it (Asterism::ROS::GeometryMsgs::Twist). The file loads the
    # types it is made of first. A type already defined (loaded before, or
    # written in Ruby by the application) is returned without a file.
    def self.require_type(name)
      parts = name.to_s.split("/")
      if parts.size != 3 || (parts[1] != "msg" && parts[1] != "srv")
        raise ArgumentError, "bad type name #{name.inspect} (want pkg/msg/Name or pkg/srv/Name)"
      end
      t = type_constant(parts[0], parts[2])
      return t if t
      found = nil
      TYPE_PATH.each do |dir|
        path = "#{dir}/#{parts[0]}/#{parts[1]}/#{parts[2]}.rb"
        found = path if found.nil? && File.exist?(path)
      end
      load_type_file(found) if found
      t = type_constant(parts[0], parts[2])
      raise UnknownType, "no generated type #{name} in #{TYPE_PATH.join(', ')}" if t.nil?
      t
    end

    # On mruby the file is evaluated in this VM (Kernel#eval): unlike
    # require, which runs each file in a Sandbox task of its own that stays
    # for the life of the VM, this keeps only the compiled code (measured in
    # report/r3.md). CRuby requires it.
    def self.load_type_file(path)
      if RUBY_ENGINE == "ruby"
        require File.expand_path(path)
      else
        src = File.open(path, "r") { |f| f.read }
        eval(src)
      end
      nil
    end

    # Asterism::ROS::<Pkg>::<Name>, or nil.
    def self.type_constant(pkg, name)
      mod_name = "".dup  # a fresh String: literals may be frozen (Ruby 4)
      pkg.split("_").each do |w|
        mod_name << w.byteslice(0, 1).upcase << w.byteslice(1, w.bytesize - 1) if w.bytesize > 0
      end
      mod_sym = mod_name.to_sym
      return nil unless ::Asterism::ROS.const_defined?(mod_sym, false)
      mod = ::Asterism::ROS.const_get(mod_sym)
      sym = name.to_sym
      return nil unless mod.const_defined?(sym, false)
      mod.const_get(sym)
    end

    # A type given as a generated type or its ROS name (String).
    def self.type_of(type)
      type.is_a?(::String) ? require_type(type) : type
    end

    # For the generated types' from: a Hash of fields with Symbol keys
    # (String keys are turned into Symbols). Anything else raises TypeError.
    def self.fields_of(v, type)
      raise TypeError, "#{type::ROS_NAME} from #{v.class}: want a Hash or a #{type::ROS_NAME}" unless v.is_a?(::Hash)
      out = {}
      v.each { |k, x| out[k.is_a?(::Symbol) ? k : k.to_s.to_sym] = x }
      out
    end

    # The base of the generated message types (Request / Response of a
    # service too). A type adds ROS_NAME, TYPE_NAME, TYPE_HASH, FIELDS, an
    # accessor per field, initialize(**fields) and the CDR steps
    # write(w, msg) / read(r); the rest is here.
    class Message
      # A message from nil (all defaults), a Hash of fields (Symbol or
      # String keys; missing fields take their defaults, unknown ones raise
      # ArgumentError) or a message of this type (itself).
      def self.from(v)
        return v if v.is_a?(self)
        return new if v.nil?
        new(**::Asterism::ROS.fields_of(v, self))
      end

      # CDR bytes (with the 4-byte header) of a message or a Hash.
      def self.encode(msg)
        w = ::Asterism::CDR::Writer.new
        write(w, from(msg))
        w.to_s
      end

      def self.decode(bytes)
        read(::Asterism::CDR::Reader.new(bytes))
      end

      # The fields as a Hash (nested messages as Hashes too).
      def to_h
        h = {}
        fs = self.class::FIELDS
        i = 0
        while i < fs.size
          h[fs[i]] = ::Asterism::ROS::Message.plain(__send__(fs[i]))
          i += 1
        end
        h
      end

      def self.plain(v)
        if v.is_a?(::Asterism::ROS::Message)
          v.to_h
        elsif v.is_a?(::Array) && v.size > 0 && v[0].is_a?(::Asterism::ROS::Message)
          v.map { |e| e.to_h }
        else
          v
        end
      end

      # For pattern matching: case msg in {linear: {x:}, angular: {z:}}.
      # Nested messages stay messages (they match the same way).
      def deconstruct_keys(keys)
        h = {}
        fs = self.class::FIELDS
        i = 0
        while i < fs.size
          f = fs[i]
          h[f] = __send__(f) if keys.nil? || keys.include?(f)
          i += 1
        end
        h
      end

      def ==(other)
        other.class == self.class && to_h == other.to_h
      end

      def inspect
        "#<#{self.class::ROS_NAME} #{to_h.inspect}>"
      end

      alias to_s inspect
    end

    class Node
      attr_reader :name, :namespace, :domain, :zid, :key, :session

      # session: an open Asterism::Zenoh::Session. Declares the node's
      # liveliness token at once.
      def initialize(session, name, namespace: "/", domain: 0, enclave: "/")
        @session = session
        @name = name.to_s
        raise ArgumentError, "bad node name #{@name.inspect}" if @name.empty? || @name.include?("/")
        @namespace = namespace.to_s
        @domain = domain.to_i
        @enclave = enclave.to_s
        @zid = session.zid
        @nid = 0
        @next_id = 1
        @entities = []
        @services = []
        @handled = []  # subscriptions with a block
        @timers = []
        @key = "#{LIVELINESS_ROOT}/#{@domain}/#{@zid}/#{@nid}/#{@nid}/NN/" \
               "#{::Asterism::ROS.mangle(@enclave)}/#{::Asterism::ROS.mangle(@namespace)}/#{@name}"
        @token = session.liveliness(@key)
      end

      def publisher(topic, type, qos: DEFAULT_QOS)
        e = ::Asterism::ROS::Publisher.new(self, @session, topic, ::Asterism::ROS.type_of(type), qos)
        @entities << e
        e
      end

      def subscription(topic, type, qos: DEFAULT_QOS, depth: 16)
        e = ::Asterism::ROS::Subscription.new(self, @session, topic, ::Asterism::ROS.type_of(type), qos, depth)
        @entities << e
        e
      end

      # Serves `service` (a name) with the block: it gets the request (an
      # object of type::Request) and returns the response (a type::Response
      # or a Hash of its fields). The block runs from node.poll (or
      # service.handle_pending), never behind the application's back.
      def service(service, type, qos: DEFAULT_QOS, depth: 8, &handler)
        raise ArgumentError, "service needs a block" unless handler
        e = ::Asterism::ROS::Service.new(self, @session, service, ::Asterism::ROS.type_of(type), qos, depth, handler)
        @entities << e
        @services << e
        e
      end

      def client(service, type, qos: DEFAULT_QOS)
        e = ::Asterism::ROS::Client.new(self, @session, service, ::Asterism::ROS.type_of(type), qos)
        @entities << e
        e
      end

      # Subscribes and gives each message (and its Attachment, or nil) to
      # the block, from node.poll. Returns the Subscription (close ends it).
      # The block runs on the update loop's stack: do not wait in it (no
      # service call, no proxy call); start a call_async and look at it
      # later instead. Without a block, the same as subscription: a
      # Subscription to take from with each_pending.
      def subscribe(topic, type, qos: DEFAULT_QOS, depth: 16, &handler)
        return subscription(topic, type, qos: qos, depth: depth) unless handler
        e = subscription(topic, type, qos: qos, depth: depth)
        e.handler = handler
        @handled << e
        e
      end

      # Calls the block every `seconds` (or every ms: milliseconds; the first
      # time one period from now), from node.poll. Returns a Timer (cancel).
      # It keeps the period; after a long stall it starts again from now
      # instead of firing the missed times at once. As for subscribe: do not
      # wait in the block.
      def every(seconds = nil, ms: nil, &blk)
        raise ArgumentError, "every needs a block" unless blk
        raise ArgumentError, "every: give the period once (seconds, or ms:)" if !seconds.nil? && !ms.nil?
        raise ArgumentError, "every: a period is needed (seconds, or ms:)" if seconds.nil? && ms.nil?
        t = ::Asterism::ROS::Timer.new(self, seconds, blk, ms)
        @timers << t
        t
      end

      def cancel_timer(timer)
        @timers.delete(timer)
        nil
      end

      # node.call("/add_two_ints", AddTwoInts, a: 1, b: 2) -> response.
      # The request as keywords, as a Hash or message (positional or
      # request:); the time limit as timeout: (seconds) or timeout_ms:. A
      # client per service name is made on first use and kept.
      def call(service, type, req = nil, request: nil, timeout: nil, timeout_ms: nil, **fields)
        @clients ||= {}
        c = @clients[service]
        if c.nil? || c.closed?
          c = client(service, type)
          @clients[service] = c
        end
        c.call(req, request: request, timeout: timeout, timeout_ms: timeout_ms, **fields)
      end

      # Polls the session (Asterism::Zenoh::Session#poll), answers the
      # requests that came in for this node's services, then gives the
      # messages that came in to the subscribe blocks and fires the timers
      # that are due. Returns what session.poll returns (false once the
      # session is closed).
      def poll(steps = 8)
        ok = pump(steps)
        deliver
        fire_timers
        ok
      end

      # What a waiting service call polls: the session and the services, not
      # the subscribe / every blocks (those run from node.poll only).
      # @api private
      def pump(steps = 8)
        ok = @session.poll(steps)
        i = 0
        while i < @services.size
          @services[i].handle_pending
          i += 1
        end
        ok
      end

      # While loops, not each with a block: the application's blocks are
      # called from here, and nothing else should stand between them and
      # the update loop on the stack. @api private
      def deliver
        i = 0
        while i < @handled.size
          sub = @handled[i]
          if sub.closed?
            @handled.delete_at(i)
            next
          end
          got = sub.each_pending
          j = 0
          while j < got.size
            handle(sub, got[j][0], got[j][1])
            j += 1
          end
          i += 1
        end
      end

      # @api private
      def fire_timers
        return if @timers.empty?
        now = ::Asterism::ROS.now_ms
        due = []
        i = 0
        while i < @timers.size
          due << @timers[i] if @timers[i].due?(now)
          i += 1
        end
        i = 0
        while i < due.size
          fire(due[i], now)
          i += 1
        end
      end

      # One message for one subscribe block, one timer firing (CRuby routes
      # what they raise to on_error). @api private
      def handle(sub, msg, info)
        sub.handler.call(msg, info)
      end

      def fire(timer, now)
        timer.fire(now)
      end

      # Withdraws the node and its publishers, subscriptions, services and
      # clients. Idempotent.
      def close
        @entities.each { |e| e.close }
        @entities = []
        @services = []
        @handled = []
        @timers = []
        @clients = {}
        @token.close if @token
        @token = nil
        nil
      end

      def closed?
        @token.nil?
      end

      # For the entities: [data key, liveliness token key] of a topic.
      # @api private
      def entity_keys(kind, topic, type, qos)
        full = ::Asterism::ROS.resolve(topic, @namespace)
        data = "#{@domain}/#{::Asterism::ROS.strip_slashes(full)}/#{type::TYPE_NAME}/#{type::TYPE_HASH}"
        id = @next_id
        @next_id += 1
        token = "#{LIVELINESS_ROOT}/#{@domain}/#{@zid}/#{@nid}/#{id}/#{kind}/" \
                "#{::Asterism::ROS.mangle(@enclave)}/#{::Asterism::ROS.mangle(@namespace)}/#{@name}/" \
                "#{::Asterism::ROS.mangle(full)}/#{type::TYPE_NAME}/#{type::TYPE_HASH}/#{qos}"
        [data, token]
      end
    end

    class Publisher
      attr_reader :topic_key, :token_key, :gid, :sequence

      def initialize(node, session, topic, type, qos)
        @session = session
        @type = type
        @topic_key, @token_key = node.entity_keys("MP", topic, type, qos)
        @gid = ::Asterism::ROS.gid_for(@token_key)
        @sequence = 0
        @token = session.liveliness(@token_key)
      end

      # msg: a message of the type, or a Hash of its fields (missing ones
      # take their defaults).
      def publish(msg)
        raise ::Asterism::Zenoh::ClosedError, "publisher closed" if @token.nil?
        # Read once (a second thread may publish meanwhile on CRuby).
        seq = @sequence + 1
        @sequence = seq
        att = ::Asterism::ROS::Attachment.new(seq, ::Asterism::ROS.now_ns, @gid)
        @session.put(@topic_key, @type.encode(msg), attachment: att.encode)
        nil
      end

      # pub << { linear: { x: 0.1 } }
      def <<(msg)
        publish(msg)
        self
      end

      def close
        @token.close if @token
        @token = nil
        nil
      end
    end

    class Subscription
      attr_reader :topic_key, :token_key, :errors
      # The block of node.subscribe (nil for node.subscription).
      attr_accessor :handler

      def initialize(node, session, topic, type, qos, depth)
        @type = type
        @topic_key, @token_key = node.entity_keys("MS", topic, type, qos)
        @errors = 0
        @sub = session.subscribe(@topic_key, depth: depth)
        @token = session.liveliness(@token_key)
      end

      # Yields each message received so far (decoded) and its Attachment (nil
      # when the sample had none). Samples that do not decode are counted in
      # errors and skipped. Returns the number yielded; without a block, an
      # Array of [msg, attachment].
      def each_pending
        out = []
        @sub.each_pending.each do |entry|
          msg = begin
            @type.decode(entry[1])
          rescue ::Asterism::CDR::DecodeError
            @errors += 1
            nil
          end
          next if msg.nil?
          out << [msg, ::Asterism::ROS::Attachment.decode(entry[2])]
        end
        return out unless block_given?
        out.each { |m| yield m[0], m[1] }
        out.size
      end

      # Messages waiting / received so far / dropped because the queue was
      # full (the counters of the Zenoh subscriber underneath).
      def pending
        @sub.pending
      end

      def received
        @sub.received
      end

      def dropped
        @sub.dropped
      end

      def close
        @sub.close
        @token.close if @token
        @token = nil
        nil
      end

      def closed?
        @token.nil?
      end
    end

    # node.every: a block called every period, from node.poll.
    class Timer
      # period: seconds (as given, or ms / 1000.0); period_ms: the same in
      # milliseconds; fired: how many times it ran.
      attr_reader :period, :period_ms, :fired

      # @api private (node.every makes it)
      def initialize(node, seconds, blk, ms = nil)
        @period_ms = ms.nil? ? (seconds * 1000).round : ms.round
        raise ArgumentError, "the period must be positive" unless @period_ms > 0
        @node = node
        @period = ms.nil? ? seconds : ms / 1000.0
        @blk = blk
        @next = ::Asterism::ROS.now_ms + @period_ms
        @fired = 0
      end

      def due?(now_ms)
        now_ms >= @next
      end

      # Keeps the period without drifting; after a long stall it starts
      # again from now instead of firing the missed times at once.
      def fire(now_ms)
        @next += @period_ms
        @next = now_ms + @period_ms if @next <= now_ms
        @fired += 1
        @blk.call
      end

      def cancel
        @node.cancel_timer(self)
      end

      def inspect
        "#<Asterism::ROS::Timer every #{@period} s>"
      end
    end
  end
end

module Asterism
  module ROS
    # The server side of a service (node.service). A complete queryable on
    # the service key, plus the SS token.
    class Service
      attr_reader :service_key, :token_key, :handled, :errors

      def initialize(node, session, service, type, qos, depth, handler)
        @type = type
        @handler = handler
        @service_key, @token_key = node.entity_keys("SS", service, type, qos)
        @handled = 0
        @errors = 0
        @queryable = session.queryable(@service_key, depth: depth, complete: true)
        @token = session.liveliness(@token_key)
      end

      # Answers the requests waiting now with the block given to
      # node.service. A request that cannot be decoded, or has no attachment
      # (rmw_zenoh clients always send one), is counted in errors and
      # finished without an answer. An exception from the block finishes
      # that request without an answer and is raised from here. Returns the
      # number answered.
      def handle_pending
        return 0 if @token.nil?
        n = 0
        # The Array form: no block called from C (stack depth, see README).
        qs = @queryable.each_pending
        begin
          qs.each do |q|
            n += 1 if answer(q)
            q.finish
          end
        ensure
          # Also the ones after a request whose block raised (finish is
          # idempotent; an unanswered query just ends for the client).
          qs.each { |q| q.finish }
        end
        n
      end

      def close
        @queryable.close
        @token.close if @token
        @token = nil
        nil
      end

      def closed?
        @token.nil?
      end

      private

      def answer(q)
        info = ::Asterism::ROS::Attachment.decode(q.attachment)
        req = nil
        begin
          req = @type::Request.decode(q.payload) if info
        rescue ::Asterism::CDR::DecodeError
          req = nil
        end
        if req.nil?
          @errors += 1
          return false
        end
        res = @handler.call(req)
        # The client's sequence number and GID go back with the reply.
        att = ::Asterism::ROS::Attachment.new(info.sequence, ::Asterism::ROS.now_ns, info.gid)
        q.reply(@service_key, @type::Response.encode(res), attachment: att.encode)
        @handled += 1
        true
      end
    end

    # A call on its way (client.call_async). done? never waits (node.poll
    # moves it on); value waits, polling the node's session.
    class Call
      attr_reader :sequence, :response, :took_ms

      def initialize(client, get, sequence, timeout_ms)
        @client = client
        @get = get
        @sequence = sequence
        @timeout_ms = timeout_ms
        @started = ::Asterism::ROS.now_ms
        @deadline = @started + timeout_ms
        @response = nil
        @finished = false
        @took_ms = nil
        @nobody = false
      end

      # took_ms in seconds (a Float; nil until done).
      def took
        @took_ms.nil? ? nil : @took_ms / 1000.0
      end

      # True once the response came, the time ran out, or no server answered.
      def done?
        collect
        @finished
      end

      # The response (type::Response); waits until done. Raises
      # Asterism::ROS::TimeoutError when there was none, and
      # Asterism::Zenoh::ClosedError when the session closed (1.0:
      # Asterism::Disconnected).
      def value
        @client.wait_for(self) unless done?
        if @response.nil?
          raise ::Asterism::Zenoh::ClosedError, "session is closed" if @client.session_closed?
          if @nobody
            raise ::Asterism::ROS::TimeoutError, "no answer from #{@client.service_name} (nobody serves it)"
          end
          raise ::Asterism::ROS::TimeoutError,
                "no answer from #{@client.service_name} within #{@timeout_ms / 1000.0} s (#{@timeout_ms} ms)"
        end
        @response
      end

      # @api private
      def collect
        return if @finished
        g = @get
        # done? before taking the replies, as in Asterism::Future#collect.
        ended = g.done?
        # The Array form, as in Asterism::Future (no block called from C).
        g.each_reply.each do |r|
          next unless @response.nil?
          info = ::Asterism::ROS::Attachment.decode(r[2])
          # rmw_zenoh pairs the reply by the sequence number it carries back.
          next if info.nil? || info.sequence != @sequence
          begin
            @response = @client.decode_response(r[1])
          rescue ::Asterism::CDR::DecodeError
            @response = nil
          end
        end
        now = ::Asterism::ROS.now_ms
        if !@response.nil? || ended || now >= @deadline
          @nobody = @response.nil? && now < @deadline
          @finished = true
          @took_ms = now - @started
        end
      end
    end

    # The client side of a service (node.client). Sends each request as a
    # get on the service key, plus the SC token.
    class Client
      # The time limit of a call, in seconds and in milliseconds.
      DEFAULT_TIMEOUT = 2.0
      DEFAULT_TIMEOUT_MS = 2000
      # Pause between polls while a call waits (ms).
      WAIT_STEP_MS = 2

      attr_reader :service_key, :token_key, :gid, :sequence, :service_name

      def initialize(node, session, service, type, qos)
        @node = node
        @session = session
        @type = type
        @service_name = ::Asterism::ROS.resolve(service, node.namespace)
        @service_key, @token_key = node.entity_keys("SC", service, type, qos)
        @gid = ::Asterism::ROS.gid_for(@token_key)
        @sequence = 0
        @token = session.liveliness(@token_key)
      end

      # Sends the request and returns a Call at once. The request: a
      # type::Request or a Hash (positional, or request:), or the fields as
      # keywords. The time limit: timeout: (seconds) or timeout_ms: (2 s).
      # A request with a field named timeout or timeout_ms is best given as
      # request: { ... } (see README, Reserved keywords).
      def call_async(req = nil, request: nil, timeout: nil, timeout_ms: nil, **fields)
        raise ::Asterism::Zenoh::ClosedError, "client closed" if @token.nil?
        req, timeout_ms = request_and_limit("Client#call", req, request, timeout, timeout_ms, fields)
        payload = @type::Request.encode(req)
        # Read once into a local: the request and its Call carry the same
        # number even when another thread (CRuby) calls through this client
        # meanwhile.
        seq = @sequence + 1
        @sequence = seq
        att = ::Asterism::ROS::Attachment.new(seq, ::Asterism::ROS.now_ns, @gid)
        g = @session.get(@service_key, timeout_ms: timeout_ms, payload: payload, attachment: att.encode,
                         target: :all_complete, consolidation: :none)
        ::Asterism::ROS::Call.new(self, g, seq, timeout_ms)
      end

      # Sends the request and waits for the response (polling the node, so
      # this node's services keep answering meanwhile). Raises
      # Asterism::ROS::TimeoutError when no response came in time.
      def call(req = nil, request: nil, timeout: nil, timeout_ms: nil, **fields)
        call_async(req, request: request, timeout: timeout, timeout_ms: timeout_ms, **fields).value
      end

      # The request and the time limit (ms) from call's arguments. A
      # keyword that is also a field of the request type is ambiguous: a
      # field named timeout stays a field (as before 0.4.0), timeout_ms
      # stays the time limit, and both warn (request: { ... } says which).
      # @api private
      def request_and_limit(where, req, request, timeout, timeout_ms, fields)
        raise ArgumentError, "#{where}: give the request once (positional or request:)" if !req.nil? && !request.nil?
        req = request if req.nil?
        if req.nil?
          names = @type::Request::FIELDS
          if !timeout.nil? && names.include?(:timeout)
            ::Asterism.deprecated("#{where} with a request field named timeout as a keyword",
                                  "request: { timeout: ... } (timeout: is the time limit in seconds)",
                                  "it is taken as the field here, as before 0.4.0")
            fields[:timeout] = timeout
            timeout = nil
          end
          if !timeout_ms.nil? && names.include?(:timeout_ms)
            ::Asterism.deprecated("#{where} with a request field named timeout_ms as a keyword",
                                  "request: { timeout_ms: ... } and timeout: for the time limit",
                                  "timeout_ms: is taken as the time limit here")
          end
          req = fields
        end
        [req, ::Asterism.time_ms(where, timeout, timeout_ms, nil, DEFAULT_TIMEOUT_MS)]
      end

      # Polls the node's session and services (not its subscribe / every
      # blocks) until the call is done. @api private
      def wait_for(c)
        until c.done?
          break unless @node.pump
          break if c.done?
          ::Asterism::ROS.pause(WAIT_STEP_MS)
        end
      end

      def session_closed?
        @session.closed?
      end

      def decode_response(bytes)
        @type::Response.decode(bytes)
      end

      def close
        @token.close if @token
        @token = nil
        nil
      end

      def closed?
        @token.nil?
      end
    end
  end
end
