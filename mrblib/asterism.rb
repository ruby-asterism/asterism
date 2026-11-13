# Asterism: Ruby objects on other machines, called like local ones.
#
#   net = Asterism.connect("tcp/192.0.2.2:7447", node: "fmruby-bbbbbb", app: "demo")
#   net.expose("apu", apu, methods: [:play, :stop])
#   p = net["linux/demo/apu"]          # <node>/<app>/<object>
#   p.play("cde")                      # waits for the answer (2 s by default;
#                                      # net["...", timeout: 5.0])
#   net.poll                           # call regularly (answers incoming calls)
#
# A connection (an Asterism::Connection) is one application: its Zenoh
# session, its liveliness token, its objects, its status, topics and types,
# its own profile. A program may hold several (one per application it is),
# also as the same node:
#
#   game = Asterism.connect(router, node: "host", app: "games")
#   room = Asterism.connect(router, node: "host", app: "room01")
#   Asterism.poll_all                  # or game.poll and room.poll
#
# On a board each connection costs a TLS link and a router seat
# (docs/protocol.md 1.1); one is the usual.
#
# Keys and payloads: protocol 2 (docs/protocol.md):
#   asterism/<node>/<app>/<object>/call/<caller>
#                     get: {"method" => name, "protocol" => 2, "args" => [...],
#                     "kwargs" => {...}}
#                     reply {"value" => v} or
#                     {"error" => {"kind" => k, "class" => c, "message" => m}}
#   asterism/<node>/<app>/<object>/meta
#                     get: reply {"methods" => [{"name" => n, "arity" => a,
#                     "args" => [...], "doc" => "..."}, ...], "doc" => "..."}
#   asterism/<node>/<app>/protocol/2  liveliness: the application is up, and
#                                     the protocol it speaks
#   asterism/<node>/<app>/<object>    liveliness: the object is exposed
#   asterism/<node>/@profile          get: reply the node's profile (profile.rb)
#   asterism/<node>/<app>/@profile    get: reply the application's own profile, its
#                                     status, topics and types (status.rb, topic.rb)
#   asterism/<node>/<app>/@status     put: the application's status when it changes
#   asterism/<node>/<app>/@pubs       put: the application's topics when they change
#   asterism/<node>/<app>/<name>      put: a value of a topic (Connection#publish)
#
# Everything is polled: nothing runs behind the application's back. A call
# that waits for its answer keeps polling meanwhile and answers the calls
# that come in (on every connection of the program), so two machines, or
# two connections of one program, calling each other do not lock up.
module Asterism
  ROOT = "asterism"
  # The version of the wire protocol this implementation speaks (and the
  # only one: protocol 1 and protocol 0 are not spoken).
  PROTOCOL = 2
  # The chunk before the protocol's number in an application's token,
  # asterism/<node>/<app>/protocol/<n> (docs/protocol.md 6.1).
  PROTOCOL_CHUNK = "protocol"
  # The time limit of a call (net[path] without timeout:), in seconds and
  # in milliseconds.
  DEFAULT_TIMEOUT = 2.0
  DEFAULT_TIMEOUT_MS = 2000
  # How long Asterism.connect looks for another copy of the same
  # <node>/<app> (check_timeout:), in seconds.
  CHECK_TIMEOUT = 1.5
  # Waits that may be open inside each other (a call answered while waiting
  # that itself calls and waits, and so on), over all the connections of
  # the program: they share one stack.
  MAX_NESTING = 4
  # Pause between polls while a call waits (ms).
  WAIT_STEP_MS = 2
  # The longest doc text (bytes) and the most argument names a method may
  # tell in its meta (docs/protocol.md 5).
  DOC_MAX = 2048
  ARGS_MAX = 16

  # Every Asterism error is an Asterism::Error (the Zenoh bindings define
  # it; Asterism::Zenoh::Error and the ROS errors are under it too).
  class Error < StandardError; end

  # A value that MessagePack cannot carry (only nil, true, false, Integer,
  # Float, String, Symbol (sent as a String), Array and Hash can be sent).
  class EncodeError < Error; end

  # No answer within the time limit (the object is gone, or slow).
  # Asterism::ROS::TimeoutError is one too. (Its old name Asterism::Timeout
  # still works, with a deprecation warning.)
  class TimeoutError < Error; end

  # The connection is closed or was lost (Asterism::Zenoh::Error inside).
  class Disconnected < Error; end

  # The remote method raised, or could not be called (not exposed, wrong
  # number of arguments). remote_class is the class name on the other side,
  # remote_kind what happened, as a protocol word (a String): "raised" (the
  # method raised; remote_class is then the callee language's own name),
  # "not_exposed", "no_object", "arguments", "malformed", "unsendable",
  # "nesting", "protocol" (docs/protocol.md 4.4); nil when the answer did
  # not say.
  class RemoteError < Error
    attr_reader :remote_class, :remote_message, :remote_kind

    def initialize(remote_class, remote_message, remote_kind = nil)
      @remote_class = remote_class.to_s
      @remote_message = remote_message.to_s
      @remote_kind = remote_kind.nil? ? nil : remote_kind.to_s
      super("#{@remote_class}: #{@remote_message}")
    end
  end

  # What Connection#current_call returns while an exposed method runs for a
  # call: who called and what. from is the calling node's ID (a String),
  # verified how far that is checked: :claimed (the caller named itself in
  # the call's key; a router's access control is what makes the name
  # binding, docs/protocol.md 4.7) or :local (a call from this same
  # application, which does not go on the network). object is the exposed
  # object's name, method the method's name (Strings).
  class CurrentCall
    attr_reader :from, :verified, :object, :method

    def initialize(from, verified, object, method)
      @from = from
      @verified = verified
      @object = object
      @method = method
    end

    def inspect
      "#<Asterism::CurrentCall #{@object}.#{@method} from #{@from} (#{@verified})>"
    end

    def to_s
      inspect
    end
  end

  # The old names of renamed constants: Asterism::Timeout (deprecated) is
  # TimeoutError. A constant alias would shadow Ruby's Timeout module inside
  # `module Asterism`, and cannot warn.
  def self.const_missing(name)
    if name == :Timeout
      deprecated("Asterism::Timeout", "Asterism::TimeoutError")
      return TimeoutError
    end
    super
  end

  # ------------------------------------------------------------ values

  module Codec
    MAX_DEPTH = 16

    # The value as it will be sent (Symbols become Strings), or EncodeError.
    # A String goes as a MessagePack str, a binary String (String#b) as a
    # bin: the MessagePack module decides by the String's encoding
    # (ASCII-8BIT on CRuby, the binary flag on mruby).
    def self.check(v, depth = 0)
      raise ::Asterism::EncodeError, "value nested too deep (max #{MAX_DEPTH})" if depth > MAX_DEPTH
      if v.nil? || v == true || v == false || v.is_a?(Integer) || v.is_a?(Float) || v.is_a?(String)
        v
      elsif v.is_a?(Symbol)
        v.to_s
      elsif v.is_a?(Array)
        v.map { |e| check(e, depth + 1) }
      elsif v.is_a?(Hash)
        h = {}
        v.each { |k, x| h[check(k, depth + 1)] = check(x, depth + 1) }
        h
      else
        raise ::Asterism::EncodeError, "cannot send a #{v.class} (only nil, true, false, Integer, " \
                           "Float, String, Symbol, Array, Hash)"
      end
    end

    def self.pack(v)
      ::MessagePack.pack(check(v))
    end

    # A String for a text field of the protocol (an error's class and
    # message): always a str, also when it came as a binary String.
    def self.text(s)
      "#{s}"
    end

    # nil when the bytes are not exactly one MessagePack value of the types
    # above (the MessagePack module refuses trailing bytes, ext types and
    # integers outside int64).
    def self.unpack(bytes)
      return nil if bytes.nil? || bytes.empty?
      ::MessagePack.unpack(bytes)
    rescue
      nil
    end
  end

  # ------------------------------------------------------------ clock

  # Milliseconds and a short pause. PicoRuby's Machine when it is there,
  # otherwise Time and sleep.
  # @api private
  def self.now_ms
    if machine?
      ::Machine.board_millis
    else
      (Time.now.to_f * 1000).to_i
    end
  end

  # @api private
  def self.pause(ms)
    if machine?
      ::Machine.delay_ms(ms)
    else
      sleep(ms / 1000.0)
    end
  end

  # @api private
  def self.machine?
    @machine = (Object.const_defined?(:Machine) && ::Machine.respond_to?(:delay_ms)) if @machine.nil?
    @machine
  end

  # ------------------------------------------------------------ names

  # A node, app or object name: one key chunk, no wildcard or special
  # characters.
  # @api private
  def self.check_name(what, name)
    s = name.to_s
    bad = s.empty? || s.start_with?("@")
    ["/", "*", "$", "?", "#"].each { |c| bad = true if s.include?(c) }
    raise ArgumentError, "invalid #{what} name: #{name.inspect}" if bad
    s
  end

  # Whether s can be a node, app or object name (check_name without raising).
  # @api private
  def self.valid_name?(s)
    return false if s.nil? || s.empty? || s.start_with?("@")
    !(s.include?("/") || s.include?("*") || s.include?("$") || s.include?("?") || s.include?("#"))
  end

  # "node/app/object" -> [node, app, object]
  # @api private
  def self.split_path(path)
    parts = path.to_s.split("/")
    raise ArgumentError, "expected <node>/<app>/<object>, got #{path.inspect}" unless parts.size == 3
    check_name("node", parts[0])
    check_name("app", parts[1])
    check_name("object", parts[2])
    parts
  end

  # Glob over "/"-separated chunks: * is one chunk, ** any number of them.
  # @api private
  def self.glob?(pattern, path)
    glob_parts?(pattern.split("/"), 0, path.split("/"), 0)
  end

  # @api private
  def self.glob_parts?(pat, i, parts, j)
    while i < pat.size
      if pat[i] == "**"
        k = j
        while k <= parts.size
          return true if glob_parts?(pat, i + 1, parts, k)
          k += 1
        end
        return false
      end
      return false if j >= parts.size
      return false unless pat[i] == "*" || pat[i] == parts[j]
      i += 1
      j += 1
    end
    j == parts.size
  end

  # ------------------------------------------------------------ connections

  # Opens a connection: one application on the network, and returns it (an
  # Asterism::Connection; its methods are the whole API: expose, [],
  # poll, status, publish, subscribe, close, ...). locator, mode: and
  # listen: go to Asterism::Zenoh::Session.open (client of a router by
  # default; mode: :peer with or without listen: for no router), and so do
  # config: (a Hash of "key/path" => value or a JSON5 String, e.g. TLS
  # certificates; the boards take the TLS keys only) and connect_timeout:
  # (seconds; CRuby's asterism-zenoh only, the boards raise ArgumentError)
  # when they are given. credentials: a .tar from an Asterism console
  # (Asterism::Credentials, a path or a loaded one): its certificates go to
  # zenoh (mutual TLS), and locator and node: default to its router and
  # name. node: is this machine's ID and app: this application's name.
  # check_timeout: how long to look for another copy of the same
  # <node>/<app> (seconds, CHECK_TIMEOUT). Raises Disconnected when it
  # cannot connect, and Error when the same <node>/<app> is already on the
  # network (or open in this program).
  #
  # A program may open several connections, each its own application
  # (another app:, the same node: or another). Each has its own Zenoh
  # session: on a board, a TLS link and a router seat each.
  def self.connect(locator = nil, node: nil, app:, mode: nil, listen: nil, config: nil, connect_timeout: nil,
                   check_timeout: nil, credentials: nil)
    Connection.new(locator, node: node, app: app, mode: mode, listen: listen, config: config,
                            connect_timeout: connect_timeout, check_timeout: check_timeout,
                            credentials: credentials)
  end

  # The connections of this program that are open, or lost with their
  # on_leave blocks still to be told (in the order they were opened).
  def self.connections
    (@connections || []).dup
  end

  # Polls every connection of this program (Connection#poll each). True
  # while one of them is connected.
  def self.poll_all
    list = connections
    any = false
    i = 0
    while i < list.size
      any = true if list[i].poll
      i += 1
    end
    any
  end

  # @api private
  def self.register(conn)
    (@connections ||= []) << conn
  end

  # @api private
  def self.unregister(conn)
    list = @connections
    return unless list
    i = 0
    while i < list.size
      if list[i].equal?(conn)
        list.delete_at(i)
      else
        i += 1
      end
    end
  end

  # The connected connection of node/app in this program, or nil.
  # @api private
  def self.connection_of(node, app)
    list = @connections || []
    i = 0
    while i < list.size
      c = list[i]
      return c if c.node_id == node && c.app == app && c.connected?
      i += 1
    end
    nil
  end

  # Reserves node/app for a connection being opened: Error when a
  # connection of this program has it, or is being opened with it.
  # @api private
  def self.claim(node, app)
    path = "#{node}/#{app}"
    claims = (@claims ||= {})
    if connection_of(node, app) || claims[path]
      raise Error, "#{path} is already connected in this program"
    end
    claims[path] = true
  end

  # @api private
  def self.unclaim(node, app)
    @claims.delete("#{node}/#{app}") if @claims
  end

  # The key of the application token of node/app: it says the protocol the
  # application speaks (docs/protocol.md 6.1).
  # @api private
  def self.app_token_key(node, app)
    "#{ROOT}/#{node}/#{app}/#{PROTOCOL_CHUNK}/#{PROTOCOL}"
  end

  # The protocol an application token says, from its chunks after
  # "asterism/": [node, app, "protocol", "<n>"] says n; [node, app] (the
  # token of protocol 1, which had no number) says 1; anything else is not
  # an application token (nil).
  # @api private
  def self.token_protocol(parts)
    return 1 if parts.size == 2
    return nil unless parts.size == 4 && parts[2] == PROTOCOL_CHUNK
    digits(parts[3])
  end

  # The non-negative Integer a chunk of decimal digits says (no sign, no
  # leading zero, at most 9 digits), or nil. Without a Regexp (PicoRuby
  # has none).
  # @api private
  def self.digits(s)
    return nil if s.nil? || s.empty? || s.size > 9
    return nil if s.size > 1 && s[0] == "0"
    n = 0
    i = 0
    while i < s.size
      c = s.getbyte(i)
      return nil if c < 48 || c > 57
      n = n * 10 + (c - 48)
      i += 1
    end
    n
  end

  # A new run id (docs/protocol.md 9.3): 16 random bits. Kernel#rand where
  # there is one (CRuby; mruby-random; PicoRuby's picoruby-rng, on the
  # boards their hardware generator); otherwise the clock mixed with salt
  # (a connection's object_id).
  # @api private
  def self.new_run_id(salt = 0)
    begin
      return rand(65536)
    rescue NoMethodError
      nil
    end
    (now_ms % 65536 + (salt % 65536) * 251) % 65536
  end

  # Says msg once per key (a String) on the program's warning output.
  # @api private
  def self.warn_text_once(key, msg)
    told = (@told ||= {})
    return false if told[key]
    @told = told = {} if told.size >= 256
    told[key] = true
    if respond_to?(:warn, true)
      warn(msg)
    else
      puts(msg)
    end
    true
  end

  # While a call waits on one connection, the others answer their calls
  # (another connection of this program may be the one called).
  # @api private
  def self.pump_others(conn)
    list = @connections
    return if list.nil? || list.size < 2
    list = list.dup
    i = 0
    while i < list.size
      c = list[i]
      i += 1
      c.pump unless c.equal?(conn)
    end
  end

  # The waits open inside each other (all connections: one stack).
  # @api private
  def self.depth
    @depth || 0
  end

  # @api private
  def self.enter_wait
    if depth >= MAX_NESTING
      # Kept, so that a method that lets it out is answered as "nesting".
      @nesting_error = Error.new("calls nested too deep (max #{MAX_NESTING})")
      raise @nesting_error
    end
    @depth = depth + 1
  end

  # @api private
  def self.leave_wait
    @depth = depth - 1
  end

  # @api private
  def self.nesting_error?(e)
    !@nesting_error.nil? && e.equal?(@nesting_error)
  end

  # The depth of the liveliness watch behind each / nodes. The tokens alive
  # when it is declared (every node and object on the network) come in one
  # burst: 64 on the boards (the ring comes from the VM's pool), the
  # binding's deeper default where it has one (CRuby: 1024).
  # @api private
  def self.watch_depth
    d = Asterism::Zenoh::DEFAULT_WATCH_DEPTH
    d > 64 ? d : 64
  end

  # Whether Asterism itself is closing s (SharedSession#close).
  # @api private
  def self.releasing?(s)
    !@releasing.nil? && @releasing.equal?(s)
  end

  # Closes s for a connection (the one close SharedSession lets through).
  # @api private
  def self.close_session(s)
    @releasing = s
    begin
      s.close
    ensure
      @releasing = nil
    end
  end

  # Extended onto the session of each connection: the session belongs to
  # the connection, so a close from anyone else (the application, a library
  # that was handed connection.session) does nothing. Connection#close and
  # a lost connection close it.
  module SharedSession
    def close
      return super if ::Asterism.releasing?(self)
      ::Asterism.warn_once(self, "asterism: a connection's session belongs to it; its close is ignored " \
                                 "(Connection#close closes it)")
      nil
    end
  end

  # ------------------------------------------------------------ calls (shared)

  # A method's {args:, doc:, arity:} at expose: [the number of arguments
  # checked, its meta fields {"args", "doc"}].
  # @api private
  def self.method_doc(m, h)
    args = nil
    doc = nil
    arity = nil
    h.each do |k, v|
      ks = k.to_s
      if ks == "args" then args = v
      elsif ks == "doc" then doc = v
      elsif ks == "arity" then arity = v
      else raise ArgumentError, "#{m}: unknown key #{ks} (args:, doc:, arity:)"
      end
    end
    out = {}
    unless args.nil?
      raise ArgumentError, "#{m}: args: expects an Array of names" unless args.is_a?(Array)
      raise ArgumentError, "#{m}: args: at most #{ARGS_MAX} names" if args.size > ARGS_MAX
      names = []
      args.each do |a|
        raise ArgumentError, "#{m}: args: expects names, got #{a.inspect}" unless a.is_a?(String) || a.is_a?(Symbol)
        a = a.to_s
        raise ArgumentError, "#{m}: args: an empty name" if a.empty? || a.bytesize > 64
        names << a
      end
      out["args"] = names
    end
    unless doc.nil?
      raise ArgumentError, "#{m}: doc: expects a String" unless doc.is_a?(String)
      raise ArgumentError, "#{m}: doc: at most #{DOC_MAX} bytes" if doc.bytesize > DOC_MAX
      out["doc"] = doc
    end
    n = if !arity.nil? then arity.to_i
        elsif !args.nil? then args.size
        else -1
        end
    if n >= 0 && !args.nil? && args.size != n
      raise ArgumentError, "#{m}: #{args.size} names in args: for #{n} arguments"
    end
    [n, out]
  end

  # The request of a call: a map with the method's name, the protocol the
  # caller speaks, and the arguments and keyword arguments when there are
  # any (absent means none).
  # @api private
  def self.request(method, args, kwargs)
    req = { "method" => method.to_s, "protocol" => PROTOCOL }
    req["args"] = args unless args.nil? || args.empty?
    req["kwargs"] = kwargs unless kwargs.nil? || kwargs.empty?
    req
  end

  MALFORMED = "malformed call (expected a map {\"method\" => name, \"args\" => [...], \"kwargs\" => {...}})"

  # [method, args, kwargs] of a decoded request, or nil when it is not one:
  # a map with "method" (a non-empty str), "args" (an array, absent: none)
  # and "kwargs" (a map with str keys, absent: none). Other keys are
  # ignored (room for later additions).
  # @api private
  def self.parse_request(req)
    return nil unless req.is_a?(Hash)
    m = req["method"]
    return nil unless m.is_a?(String) && !m.empty?
    args = req.key?("args") ? req["args"] : []
    return nil unless args.is_a?(Array)
    kw = req.key?("kwargs") ? req["kwargs"] : {}
    return nil unless kw.is_a?(Hash)
    keys = kw.keys
    i = 0
    while i < keys.size
      return nil unless keys[i].is_a?(String)
      i += 1
    end
    [m, args, kw]
  end

  # @api private
  def self.invoke(obj, name, args, kw)
    if kw.empty?
      obj.public_send(name, *args)
    else
      opts = {}
      kw.each { |k, v| opts[k.to_sym] = v }
      obj.public_send(name, *args, **opts)
    end
  end

  # {"error" => {"kind", "class", "message"}}, packed.
  # @api private
  def self.error_reply(kind, klass, message)
    ::MessagePack.pack({ "error" => { "kind" => kind, "class" => Codec.text(klass), "message" => Codec.text(message) } })
  end

  # ------------------------------------------------------------ the connection

  # One application on the network (Asterism.connect). Holds everything of
  # it: the Zenoh session, the liveliness token and watch, the exposed
  # objects, the calls waiting, the status, topics, types and
  # subscriptions, the on_join / on_leave blocks. Its methods are the
  # Asterism API; close ends it (and with it everything declared on it).
  class Connection
    # node_id, app: this application's names. run_id: the run id of this
    # connection, 16 random bits picked when it opened, sent with each value
    # of its topics (docs/protocol.md 9.3): a reader that sees another run
    # id knows the sender connected again.
    attr_reader :node_id, :app, :run_id

    # Asterism.connect. @api private
    def initialize(locator, node:, app:, mode:, listen:, config:, connect_timeout:, check_timeout:, credentials:)
      if credentials
        locator, config, creds = ::Asterism::Credentials.merge(credentials, locator, config)
        node ||= creds.name
      end
      node = ::Asterism.check_name("node", node)
      app = ::Asterism.check_name("app", app)
      check_ms = ::Asterism.time_ms("Asterism.connect check_timeout:", check_timeout, nil, nil,
                                    (::Asterism::CHECK_TIMEOUT * 1000).round)
      opts = { mode: mode, listen: listen }
      opts[:config] = config unless config.nil?
      opts[:connect_timeout] = connect_timeout unless connect_timeout.nil?
      # The program's own connections first (at once), then the network's
      # (open_checked: on CRuby without the lock, so that the program's
      # other connections go on meanwhile).
      ::Asterism.claim(node, app)
      begin
        s = open_checked(locator, opts, node, app, check_ms)
        attach(s, node, app)
      ensure
        ::Asterism.unclaim(node, app)
      end
    end

    # A session opened to locator, with no other copy of node/app on the
    # network (protocol.md 6.3). Touches nothing of the program's.
    # @api private
    def open_checked(locator, opts, node, app, check_ms)
      begin
        s = ::Asterism::Zenoh::Session.open(locator, **opts)
      rescue ::Asterism::Zenoh::Error => e
        raise ::Asterism::Disconnected, e.message
      end
      begin
        found = already_there?(s, node, app, check_ms)
      rescue ::Asterism::Zenoh::Error => e
        s.close
        raise ::Asterism::Disconnected, e.message
      end
      if found
        s.close
        raise ::Asterism::Error, "#{node}/#{app} is already on the network"
      end
      s
    end

    # Declares this application on s and joins the program's connections.
    # @api private
    def attach(s, node, app)
      root = ::Asterism::ROOT
      begin
        @app_token = s.liveliness(::Asterism.app_token_key(node, app))
        @queryable = s.queryable("#{root}/#{node}/#{app}/**", depth: 32)
        @watch = s.liveliness_watch("#{root}/**", depth: ::Asterism.watch_depth)
        @profile_queryable = s.queryable("#{root}/#{node}/#{::Asterism::Profile::KEY}", depth: 4)
      rescue ::Asterism::Zenoh::Error => e
        s.close
        raise ::Asterism::Disconnected, e.message
      end
      s.extend(::Asterism::SharedSession) # connection.session: only the connection closes it
      @session = s
      @node_id = node
      @app = app
      @objects = {}  # name => [object, {method name => arity}, token, caller keyword or nil,
                     #          {method name => meta fields}, the object's doc or nil]
      @alive = {}    # "node/app/object" => node (from liveliness)
      @apps = {}     # "node/app" => node (from liveliness)
      @app_protocols = {} # "node/app" => the protocol its token says
      @proxies = {}
      @lost = nil
      @known = []    # the other nodes told to on_join so far
      @known_set = {} # the same, as node => true
      @known_apps = {} # "node/app" => true: the other applications told to on_app_join
      @node_list = [node] # what nodes returns (this node first), rebuilt on a change
      @nodes_changed = false # liveliness changed since tell_nodes last compared
      @was_reconnecting = false
      @status = nil
      @status_put = nil
      @types = {}
      @topics = {}
      @seq_of = {} # a withdrawn topic's entry => its next number (publish goes on from it)
      @subscriptions = []
      @pubs_put = nil
      @app_queryable = nil
      @protocols = {} # node => the protocol its profile says (0: none said), asked
                      # when none of its applications' tokens is known
      @run_id = ::Asterism.new_run_id(object_id)
      ::Asterism.register(self)
      tell_profile # for those who follow the profiles (the reply is the queryable's)
    end

    # Whether node/app is alive already (its application token or an object:
    # a second copy of the same application). Waits for the answer (a router
    # answers at once), at most check_ms. @api private
    def already_there?(s, node, app, check_ms = 1500)
      get_ms = check_ms > 1000 ? check_ms - 500 : check_ms
      g = s.liveliness_get("#{::Asterism::ROOT}/#{node}/#{app}/**", timeout_ms: get_ms)
      t0 = ::Asterism.now_ms
      found = false
      while true
        s.poll
        ended = g.done? # before taking the replies (see Future#collect)
        found = true if g.each_reply.size > 0
        break if found || ended || ::Asterism.now_ms - t0 > check_ms
        ::Asterism.pause(::Asterism::WAIT_STEP_MS)
      end
      found
    end

    def connected?
      return false if @session.nil?
      if @session.closed?
        lost("the connection was lost")
        return false
      end
      true
    end

    # True while the connection is lost and the Zenoh binding opens it again
    # by itself (a client of a router: zenoh-pico built with reconnection on
    # the boards, zenoh-c on CRuby). connected? stays true meanwhile, and once
    # the router is back everything declared before is there again: the
    # application token, the exposed objects, the liveliness watch, the
    # topics, and what the application declared on its session. Meanwhile
    # the other nodes leave (on_leave) and join again after it, calls raise
    # Disconnected or time out, and puts reach nobody.
    def reconnecting?
      s = @session
      return false if s.nil?
      s.respond_to?(:reconnecting?) ? s.reconnecting? : false
    end

    # "<node>/<app>": this application's path.
    def path
      "#{@node_id}/#{@app}"
    end

    # Why the connection went away (nil while connected or after close).
    def lost_reason
      @lost
    end

    # Closes the connection (and with it every exposed object, topic and
    # subscription), and forgets the on_join / on_leave blocks. Idempotent.
    # A closed connection is not opened again: Asterism.connect makes a new
    # one.
    def close
      release
      @known = nil
      @known_apps = nil
      @on_join = nil
      @on_leave = nil
      @on_app_join = nil
      @on_app_leave = nil
      ::Asterism.unregister(self)
      nil
    end

    # @api private
    def release
      s = @session
      @session = nil
      @objects = {}
      @alive = {}
      @apps = {}
      @app_protocols = {}
      @node_list = nil
      @nodes_changed = true
      @proxies = {}
      ::Asterism.close_session(s) if s
      @app_token = nil
      @queryable = nil
      @watch = nil
      @profile_queryable = nil
      @app_queryable = nil
      @status_put = nil
      release_data
    end

    # The Zenoh session of the connection (an Asterism::Zenoh::Session), for
    # what the object layer does not do: put and subscribe, a ROS 2 node
    # (Asterism::ROS::Node.new(net.session, ...)), anything of the Zenoh
    # API. A ROS 2 node on this session is part of this application's node
    # (the same Zenoh ID).
    #
    # The session stays the connection's: its close does nothing (it warns
    # once); Connection#close closes it, and with it everything declared on
    # it (the application's subscribers, publishers, ROS 2 nodes). Polling
    # it (session.poll, node.poll) is fine: Connection#poll polls it too,
    # each entity keeps what came for it. Raises Disconnected when not
    # connected (as the calls do).
    def session
      raise ::Asterism::Disconnected, (@lost || "not connected") unless connected?
      @session
    end

    # @api private: the session without the check of a lost connection.
    def session!
      raise ::Asterism::Disconnected, (@lost || "not connected") unless @session
      @session
    end

    # The connection went away: closed, but the next poll still tells
    # on_leave about every node known until then.
    # @api private
    def lost(reason)
      @lost = reason
      release
    end

    def inspect
      state = if @session then ""
              elsif @lost then " lost"
              else " closed"
              end
      "#<Asterism::Connection #{@node_id}/#{@app}#{state}>"
    end

    def to_s
      inspect
    end

    # ---------------------------------------------------------- exposing

    # Makes obj callable from other machines as <node>/<app>/<name>. Only the
    # listed methods can be called. methods: is an Array of names, or a Hash
    # name => number of arguments (checked before calling; -1 for any), or
    # name => {args: [names], doc: "text"} (docs/protocol.md 5): the
    # arguments' names (their number is the number checked, unless arity:
    # says otherwise) and what the method does, both told in the meta for
    # the readers that show them (asterism mcp, the command line). doc: a
    # text about the object itself, also in the meta.
    # caller: a keyword name (caller: :from): each call passes the calling
    # node's ID (current_call.from) to the method as that keyword, and a
    # call that brings the keyword itself is refused (an "arguments"
    # error), so the value is always the one Asterism took from the call.
    def expose(name, obj, methods:, caller: nil, doc: nil)
      s = session!
      name = ::Asterism.check_name("object", name)
      table = {}
      info = {}
      if methods.is_a?(Hash)
        methods.each do |m, n|
          if n.is_a?(Hash)
            d = ::Asterism.method_doc(m, n)
            table[m.to_s] = d[0]
            info[m.to_s] = d[1]
          else
            table[m.to_s] = n.to_i
          end
        end
      else
        methods.each { |m| table[m.to_s] = -1 }
      end
      raise ArgumentError, "no method to expose" if table.empty?
      unless doc.nil?
        raise ArgumentError, "doc: expects a String, got #{doc.class}" unless doc.is_a?(String)
        raise ArgumentError, "doc: at most #{::Asterism::DOC_MAX} bytes" if doc.bytesize > ::Asterism::DOC_MAX
      end
      table.each_key do |m|
        raise ArgumentError, "#{obj.class} has no public method #{m}" unless obj.respond_to?(m)
      end
      kw = nil
      unless caller.nil?
        unless caller.is_a?(Symbol) || caller.is_a?(String)
          raise ArgumentError, "caller: expects a keyword name (caller: :from), got #{caller.inspect}"
        end
        kw = caller.to_s
        raise ArgumentError, "caller: expects a keyword name (caller: :from), got #{caller.inspect}" if kw.empty?
      end
      unexpose(name)
      token = s.liveliness("#{::Asterism::ROOT}/#{@node_id}/#{@app}/#{name}")
      @objects[name] = [obj, table, token, kw, info, doc]
      "#{@node_id}/#{@app}/#{name}"
    rescue ::Asterism::Zenoh::Error => e
      raise ::Asterism::Disconnected, e.message
    end

    def unexpose(name)
      entry = @objects ? @objects.delete(name.to_s) : nil
      entry[2].close if entry
      !entry.nil?
    end

    def exposed
      @objects ? @objects.keys : []
    end

    # ---------------------------------------------------------- polling

    # Call from the application's update loop. Answers the calls that came
    # in, follows who is alive, calls the on_join / on_leave blocks and hands
    # the values that came to the subscriptions' blocks (subscribe).
    # false once the connection is closed. (Asterism.poll_all polls every
    # connection of the program.)
    #
    # Cheap when nothing came: each queue is looked at by its count first,
    # and the list of nodes (and the comparison behind on_join / on_leave)
    # is made again only after a liveliness change.
    def poll
      ok = @session ? pump : false
      tell_nodes
      deliver_samples if @session
      # A lost connection leaves the program once on_leave told everything.
      ::Asterism.unregister(self) if @session.nil? && @known.nil?
      ok
    end

    # ---------------------------------------------------------- nodes coming and going

    # on_join { |node| }: another node appeared (one of its applications or
    # objects). The nodes there already join on the first polls after
    # connecting. on_leave { |node| }: a node is gone (no token and no object
    # left); when the connection is lost, every node known until then leaves.
    #
    # The blocks run from poll only, never from the polling inside a
    # waiting call. What a block raises comes out of poll (on CRuby with a
    # receiving thread: to on_error). close forgets them.
    def on_join(&blk)
      raise ArgumentError, "on_join needs a block" unless blk
      (@on_join ||= []) << blk
      self
    end

    def on_leave(&blk)
      raise ArgumentError, "on_leave needs a block" unless blk
      (@on_leave ||= []) << blk
      self
    end

    # Removes a block given to on_join / on_leave (keep the Proc to remove
    # it: h = proc { |n| ... }; net.on_join(&h); net.off_join(h)).
    # on_* adds a block; on_error (CRuby) is the only one that replaces.
    def off_join(blk)
      @on_join.delete(blk) if @on_join
      self
    end

    def off_leave(blk)
      @on_leave.delete(blk) if @on_leave
      self
    end

    # on_app_join { |node, app| }: an application of another node appeared
    # (its token asterism/<node>/<app>); on_app_leave { |node, app| }: it is
    # gone. A node may run several applications (and one program may be
    # several of them): each comes and goes on its own, and the node stays
    # (on_join / on_leave) while one of them or an object is there. The
    # applications there already join on the first polls after connecting;
    # when the connection is lost, every application known until then
    # leaves. Called from poll, as on_join; close forgets them.
    def on_app_join(&blk)
      raise ArgumentError, "on_app_join needs a block" unless blk
      (@on_app_join ||= []) << blk
      self
    end

    def on_app_leave(&blk)
      raise ArgumentError, "on_app_leave needs a block" unless blk
      (@on_app_leave ||= []) << blk
      self
    end

    def off_app_join(blk)
      @on_app_join.delete(blk) if @on_app_join
      self
    end

    def off_app_leave(blk)
      @on_app_leave.delete(blk) if @on_app_leave
      self
    end

    # Compares the applications alive now with those told before and calls
    # the on_app_* blocks for the difference (this application left out).
    # @api private
    def tell_apps
      known = @known_apps
      return if known.nil?
      now = {}
      if @session
        own = "#{@node_id}/#{@app}"
        keys = @apps.keys
        i = 0
        while i < keys.size
          now[keys[i]] = true unless keys[i] == own
          i += 1
        end
      end
      joined = []
      left = []
      keys = now.keys
      i = 0
      while i < keys.size
        joined << keys[i] unless known[keys[i]]
        i += 1
      end
      keys = known.keys
      i = 0
      while i < keys.size
        left << keys[i] unless now[keys[i]]
        i += 1
      end
      @known_apps = @session ? now : nil
      tell_apps_each("on_app_join", @on_app_join, joined)
      tell_apps_each("on_app_leave", @on_app_leave, left)
    end

    # @api private
    def tell_apps_each(where, blocks, names)
      return if blocks.nil? || names.empty?
      i = 0
      while i < names.size
        cut = names[i].index("/")
        node = names[i][0, cut]
        app = names[i][cut + 1, names[i].size]
        j = 0
        while j < blocks.size
          tell(where, blocks[j], node, app)
          j += 1
        end
        i += 1
      end
    end

    # Compares the nodes alive now with those told before and calls the
    # blocks for the difference.
    # @api private
    def tell_nodes
      known = @known
      return if known.nil?
      # Nothing came on the liveliness watch since the last comparison (and
      # the connection is neither new nor lost): nothing can have changed.
      return unless @nodes_changed
      @nodes_changed = false
      tell_apps
      now = []
      now_set = {}
      if @session
        list = node_list
        i = 1 # list[0] is this node
        while i < list.size
          n = list[i]
          now << n
          now_set[n] = true
          i += 1
        end
      end
      known_set = @known_set || {}
      joined = []
      left = []
      i = 0
      while i < now.size
        joined << now[i] unless known_set[now[i]]
        i += 1
      end
      i = 0
      while i < known.size
        left << known[i] unless now_set[known[i]]
        i += 1
      end
      # After a loss, everything has been told: nothing more to compare.
      if @session
        @known = now
        @known_set = now_set
      else
        @known = nil
        @known_set = nil
      end
      i = 0
      while i < left.size
        @protocols.delete(left[i]) if @protocols
        i += 1
      end
      tell_each("on_join", @on_join, joined)
      tell_each("on_leave", @on_leave, left)
    end

    # While loops, not each with a block: the blocks are the application's,
    # and nothing else stands between them and the update loop on the stack.
    # @api private
    def tell_each(where, blocks, names)
      return if blocks.nil? || names.empty?
      i = 0
      while i < names.size
        j = 0
        while j < blocks.size
          tell(where, blocks[j], names[i])
          j += 1
        end
        i += 1
      end
    end

    # One block for one node, or one application (CRuby routes what it
    # raises to on_error).
    # @api private
    def tell(_where, blk, node, app = nil)
      if app.nil?
        blk.call(node)
      else
        blk.call(node, app)
      end
    end

    # Answers what came (calls, profiles) and follows liveliness; false
    # once the connection is gone. @api private
    def pump
      s = @session
      return false unless s
      unless s.poll
        lost("the connection was lost")
        return false
      end
      back_again(s)
      answer_calls
      answer_profile
      answer_app_profile
      follow_liveliness
      follow_pubs
      !@session.nil?
    rescue ::Asterism::Zenoh::Error => e
      lost_if_closed(e.message)
      !@session.nil?
    end

    # After the binding opened a lost connection again: tell the profile, the
    # status and the topics again (a put made while the router was away
    # reached nobody).
    # @api private
    def back_again(s)
      now = s.respond_to?(:reconnecting?) && s.reconnecting?
      was = @was_reconnecting
      @was_reconnecting = now
      return unless was && !now
      tell_profile
      tell_status(true)
      tell_pubs(true)
    end

    # A Zenoh error during a call or a poll: the connection is gone only when
    # the session says it is closed. While the binding reconnects, the
    # session (and everything declared on it) stays.
    # @api private
    def lost_if_closed(reason)
      s = @session
      lost(reason) if s.nil? || s.closed?
    end

    # Polls until the block is true. Answers incoming calls meanwhile, on
    # this connection and on the program's others.
    # @api private
    def wait_until
      ::Asterism.enter_wait
      begin
        until yield
          break unless pump
          ::Asterism.pump_others(self)
          break if yield
          ::Asterism.pause(::Asterism::WAIT_STEP_MS)
        end
      ensure
        ::Asterism.leave_wait
      end
    end

    # @api private
    def follow_liveliness
      w = @watch
      return unless w && w.pending > 0
      # Array forms instead of blocks called from C (see Future#collect).
      events = w.each_pending
      @nodes_changed = true if events.size > 0
      if events.size > 0 && w.dropped > 0
        ::Asterism.warn_once(w, "asterism: #{w.dropped} liveliness changes dropped (more than " \
                                "#{::Asterism.watch_depth} at once); each and nodes may miss some objects")
      end
      cut = ::Asterism::ROOT.length + 1
      i = 0
      while i < events.size
        key = events[i][0]
        alive = events[i][1]
        i += 1
        rest = key[cut, key.length].to_s
        parts = rest.split("/")
        if parts.size == 3 # an object: asterism/<node>/<app>/<object>
          if alive
            @alive[rest] = parts[0]
          else
            @alive.delete(rest)
          end
          next
        end
        # An application: asterism/<node>/<app>/protocol/<n> (or protocol
        # 1's asterism/<node>/<app>).
        pr = ::Asterism.token_protocol(parts)
        next if pr.nil?
        name = "#{parts[0]}/#{parts[1]}"
        if alive
          @apps[name] = parts[0]
          @app_protocols[name] = pr
          app_protocol_seen(name, pr)
        else
          @apps.delete(name)
          @app_protocols.delete(name)
          # What the readers keep of it goes with it (protocol.md 8.5, 9.4).
          forget_app(name)
        end
      end
      @node_list = nil
    end

    # The node IDs alive now, this one first.
    def nodes
      return [] unless @session
      node_list.dup
    end

    # The list behind nodes, made again only after a liveliness change (the
    # caller must not change it). @api private
    def node_list
      list = @node_list
      return list if list
      list = [@node_id]
      seen = { @node_id => true }
      names = @apps.values
      i = 0
      while i < names.size
        n = names[i]
        unless seen[n]
          seen[n] = true
          list << n
        end
        i += 1
      end
      owners = @alive.values
      i = 0
      while i < owners.size
        n = owners[i]
        unless seen[n]
          seen[n] = true
          list << n
        end
        i += 1
      end
      @node_list = list
    end

    # The exposed objects alive now whose <node>/<app>/<object> matches the
    # pattern (* is one chunk, ** any number), this application's own
    # included. With a block, yields a proxy for each and returns their
    # number (1.0 will return the connection instead, as Ruby's each
    # returns its receiver; use the Array form for the count); else returns
    # them (an Array).
    def each(pattern = "**")
      paths = []
      if @session
        seen = {}
        @objects.each_key do |name|
          path = "#{@node_id}/#{@app}/#{name}"
          if ::Asterism.glob?(pattern, path)
            paths << path
            seen[path] = true
          end
        end
        @alive.each_key { |path| paths << path if !seen[path] && ::Asterism.glob?(pattern, path) }
      end
      proxies = paths.map { |path| self[path] }
      return proxies unless block_given?
      proxies.each { |px| yield px }
      proxies.size
    end

    # A proxy for <node>/<app>/<object> (calls go out on this connection).
    # Nothing is sent until a method is called on it. timeout: the time
    # limit of its calls in seconds (2.0), or timeout_ms:. (net[path, ms],
    # the time as a positional argument, is deprecated.)
    def [](path, *args, timeout: nil, timeout_ms: nil)
      if args.size > 1
        raise ArgumentError, "Connection#[]: wrong number of arguments (given #{args.size + 1}, expected 1)"
      end
      timeout_ms = ::Asterism.time_ms("Connection#[]", timeout, timeout_ms, args[0], ::Asterism::DEFAULT_TIMEOUT_MS)
      ::Asterism.split_path(path)
      @proxies ||= {}
      key = "#{path}|#{timeout_ms}"
      @proxies[key] ||= ::Asterism::Proxy.new(self, path.to_s, timeout_ms)
    end

    # ---------------------------------------------------------- calling

    # Starts a call; returns a Future. Raises EncodeError (before sending)
    # and Disconnected.
    # @api private
    def call_async(path, method, args, kwargs, timeout_ms)
      parts = ::Asterism.split_path(path)
      payload = ::Asterism::Codec.pack(::Asterism.request(method, args, kwargs))
      if parts[0] == @node_id && parts[1] == @app && @session
        # This application's own object: no network (a session does not see
        # its own queryable), same encoding and checks as a remote call.
        return ::Asterism::Future.answered(path, method, dispatch(parts[2], payload, @node_id, :local))
      end
      begin
        s = session!
        # The caller's node ID is the key's last chunk (docs/protocol.md 4.1).
        g = s.get("#{::Asterism::ROOT}/#{path}/call/#{@node_id}", timeout_ms: timeout_ms, payload: payload)
      rescue ::Asterism::Zenoh::Error => e
        lost_if_closed(e.message)
        raise ::Asterism::Disconnected, e.message
      end
      ::Asterism::Future.new(self, path, method, g, ::Asterism.now_ms + timeout_ms, timeout_ms)
    end

    # @api private
    def call(path, method, args, kwargs, timeout_ms)
      call_async(path, method, args, kwargs, timeout_ms).value
    end

    # The meta reply of path: {"methods" => [{"name" => n, "arity" => a}, ...]}.
    # @api private
    def meta(path, timeout_ms = ::Asterism::DEFAULT_TIMEOUT_MS)
      parts = ::Asterism.split_path(path)
      if parts[0] == @node_id && parts[1] == @app && @session
        m = meta_of(parts[2])
        unless m
          raise ::Asterism::RemoteError.new("NameError", "no object #{parts[2]} exposed by #{@node_id}/#{@app}",
                                            "no_object")
        end
        return m
      end
      begin
        g = session!.get("#{::Asterism::ROOT}/#{path}/meta", timeout_ms: timeout_ms)
      rescue ::Asterism::Zenoh::Error => e
        lost_if_closed(e.message)
        raise ::Asterism::Disconnected, e.message
      end
      f = ::Asterism::Future.new(self, path, "meta", g, ::Asterism.now_ms + timeout_ms, timeout_ms)
      f.raw_value
    end

    # ---------------------------------------------------------- answering

    # The call being answered now on this connection (an
    # Asterism::CurrentCall: who called, which object and method), while an
    # exposed method runs for a call; nil outside one. Calls answered while
    # that method waits for its own call are on top of it until they end.
    def current_call
      stack = call_stack
      stack.empty? ? nil : stack[stack.size - 1]
    end

    # The calls being answered, innermost last (CRuby: per thread).
    # @api private
    def call_stack
      @call_stack ||= []
    end

    # @api private
    def answer_calls
      qa = @queryable
      return unless qa && qa.pending > 0
      # Without a block, so that a handler that waits (and so polls) does not
      # re-enter the queryable's iteration.
      queries = qa.each_pending
      i = 0
      while i < queries.size
        q = queries[i]
        i += 1
        begin
          answer(q)
        ensure
          begin
            q.finish
          rescue ::Asterism::Zenoh::Error
            # the session went away meanwhile
          end
        end
      end
    end

    # asterism/<node>/<app>/<object>/call/<caller> and
    # asterism/<node>/<app>/<object>/meta; the node and app may come as
    # wildcards (the query matched this application's queryable).
    # @api private
    def answer(q)
      parts = q.key.split("/")
      n = parts.size
      return unless n == 5 || n == 6
      obj = parts[3]
      kind = parts[4]
      prefix = "#{::Asterism::ROOT}/#{@node_id}/#{@app}/"
      if kind == "meta"
        return unless n == 5
        names = obj == "*" ? @objects.keys : [obj]
        names.each do |nm|
          m = meta_of(nm)
          q.reply("#{prefix}#{nm}/meta", ::Asterism::Codec.pack(m)) if m
        end
      elsif kind == "call" && ::Asterism.valid_name?(obj)
        if n == 5
          # A protocol 0 call (no caller chunk): refused, so that its sender
          # learns why at once instead of waiting.
          q.reply("#{prefix}#{obj}/call",
                  ::Asterism.error_reply("protocol", "Asterism::Error",
                                         "#{@node_id}/#{@app} speaks Asterism protocol #{::Asterism::PROTOCOL}: call " \
                                         "asterism/<node>/<app>/<object>/call/<caller> with a map " \
                                         "{\"method\", \"args\", \"kwargs\"} (asterism 0.7.0 and later)"))
        elsif ::Asterism.valid_name?(parts[5])
          q.reply("#{prefix}#{obj}/call/#{parts[5]}", dispatch(obj, q.payload, parts[5], :claimed))
        end
      end
    end

    # @api private
    def meta_of(name)
      entry = @objects[name]
      return nil unless entry
      list = []
      info = entry[4] || {}
      entry[1].each do |m, n|
        e = { "name" => m, "arity" => n }
        extra = info[m]
        extra.each { |k, v| e[k] = v } if extra
        list << e
      end
      out = { "methods" => list }
      out["doc"] = entry[5] if entry[5]
      out
    end

    # Runs a call on an exposed object; returns the packed reply. from is
    # the caller's node ID, verified how it is known (CurrentCall).
    # @api private
    def dispatch(obj_name, payload, from, verified)
      raw = ::Asterism::Codec.unpack(payload)
      if raw.is_a?(Hash)
        # The protocol first: a caller of another protocol may send another
        # shape of request (docs/protocol.md 4.3 step 3).
        pr = raw["protocol"]
        unless pr.is_a?(Integer) && pr == ::Asterism::PROTOCOL
          said = pr.is_a?(Integer) ? "protocol #{pr}" : "no protocol (protocol 1 or older)"
          return ::Asterism.error_reply("protocol", "Asterism::Error",
                                        "#{@node_id}/#{@app} speaks Asterism protocol #{::Asterism::PROTOCOL}, " \
                                        "the call says #{said}")
        end
      end
      req = ::Asterism.parse_request(raw)
      return ::Asterism.error_reply("malformed", "ArgumentError", ::Asterism::MALFORMED) unless req
      entry = @objects[obj_name]
      unless entry
        return ::Asterism.error_reply("no_object", "NameError", "no object #{obj_name} exposed by #{@node_id}/#{@app}")
      end
      name = req[0]
      args = req[1]
      kw = req[2]
      arity = entry[1][name]
      if arity.nil?
        return ::Asterism.error_reply("not_exposed", "NoMethodError",
                                      "undefined method '#{name}' for #{@node_id}/#{@app}/#{obj_name} (not exposed)")
      end
      if arity >= 0 && args.size != arity
        return ::Asterism.error_reply("arguments", "ArgumentError",
                                      "wrong number of arguments (given #{args.size}, expected #{arity})")
      end
      ckw = entry[3]
      if ckw
        if kw.key?(ckw)
          return ::Asterism.error_reply("arguments", "ArgumentError",
                                        "#{ckw}: is given by Asterism, not by the caller " \
                                        "(#{@node_id}/#{@app}/#{obj_name} is exposed with caller: :#{ckw})")
        end
        kw[ckw] = from
      end
      stack = call_stack
      stack << ::Asterism::CurrentCall.new(from, verified, obj_name, name)
      begin
        value = ::Asterism.invoke(entry[0], name, args, kw)
      rescue => e
        return ::Asterism.error_reply(::Asterism.nesting_error?(e) ? "nesting" : "raised", e.class.to_s, e.message)
      ensure
        stack.pop
      end
      begin
        ::Asterism::Codec.pack({ "value" => value })
      rescue ::Asterism::EncodeError => e
        ::Asterism.error_reply("unsendable", "Asterism::EncodeError", "the return value: #{e.message}")
      end
    end
  end
end
