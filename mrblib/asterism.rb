# Asterism: Ruby objects on other machines, called like local ones.
#
#   Asterism.connect("tcp/192.0.2.2:7447", node: "fmruby-bbbbbb", app: "demo")
#   Asterism.expose("apu", apu, methods: [:play, :stop])
#   p = Asterism["linux/demo/apu"]     # <node>/<app>/<object>
#   p.play("cde")                      # waits for the answer (2 s by default;
#                                      # Asterism["...", timeout: 5.0])
#   Asterism.poll                      # call regularly (answers incoming calls)
#
# Keys and payloads: protocol 1 (docs/protocol.md):
#   asterism/<node>/<app>/<object>/call/<caller>
#                     get: {"method" => name, "args" => [...], "kwargs" => {...}}
#                     reply {"value" => v} or
#                     {"error" => {"kind" => k, "class" => c, "message" => m}}
#   asterism/<node>/<app>/<object>/meta
#                     get: reply {"methods" => [{"name" => n, "arity" => a}, ...]}
#   asterism/<node>/<app>             liveliness: the application is up
#   asterism/<node>/<app>/<object>    liveliness: the object is exposed
#   asterism/<node>/@profile          get: reply the node's profile (profile.rb)
#
# Everything is polled: nothing runs behind the application's back. A call
# that waits for its answer keeps polling meanwhile and answers the calls
# that come in, so two machines calling each other do not lock up.
module Asterism
  ROOT = "asterism"
  # The version of the wire protocol this implementation speaks (and the
  # only one: protocol 0, the 0.x releases before 0.7.0, is not spoken).
  PROTOCOL = 1
  # The time limit of a call (Asterism[path] without timeout:), in seconds
  # and in milliseconds.
  DEFAULT_TIMEOUT = 2.0
  DEFAULT_TIMEOUT_MS = 2000
  # How long Asterism.connect looks for another copy of the same
  # <node>/<app> (check_timeout:), in seconds.
  CHECK_TIMEOUT = 1.5
  # Waits that may be open inside each other (a call answered while waiting
  # that itself calls and waits, and so on).
  MAX_NESTING = 4
  # Pause between polls while a call waits (ms).
  WAIT_STEP_MS = 2

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

  # What Asterism.current_call returns while an exposed method runs for a
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

  # ------------------------------------------------------------ connection

  # Opens the connection. locator, mode: and listen: go to
  # Asterism::Zenoh::Session.open (client of a router by default; mode: :peer
  # with or without listen: for no router), and so do config: (a Hash of
  # "key/path" => value or a JSON5 String, e.g. TLS certificates) and
  # connect_timeout: (seconds) when they are given (CRuby's asterism-zenoh
  # only; the boards raise ArgumentError). node: is this machine's ID and
  # app: this application's name. check_timeout: how long to look for
  # another copy of the same <node>/<app> (seconds, CHECK_TIMEOUT). Raises
  # Disconnected when it cannot connect, and Error when the same
  # <node>/<app> is already on the network.
  def self.connect(locator, node:, app:, mode: nil, listen: nil, config: nil, connect_timeout: nil,
                   check_timeout: nil)
    raise Error, "already connected (Asterism.close first)" if connected?
    release
    node = check_name("node", node)
    app = check_name("app", app)
    check_ms = time_ms("Asterism.connect check_timeout:", check_timeout, nil, nil, (CHECK_TIMEOUT * 1000).round)
    opts = { mode: mode, listen: listen }
    opts[:config] = config unless config.nil?
    opts[:connect_timeout] = connect_timeout unless connect_timeout.nil?
    begin
      s = Asterism::Zenoh::Session.open(locator, **opts)
    rescue Asterism::Zenoh::Error => e
      raise Disconnected, e.message
    end
    begin
      if already_there?(s, node, app, check_ms)
        s.close
        raise Error, "#{node}/#{app} is already on the network"
      end
      @app_token = s.liveliness("#{ROOT}/#{node}/#{app}")
      @queryable = s.queryable("#{ROOT}/#{node}/#{app}/**", depth: 32)
      @watch = s.liveliness_watch("#{ROOT}/**", depth: watch_depth)
      @profile_queryable = s.queryable("#{ROOT}/#{node}/#{Profile::KEY}", depth: 4)
    rescue Asterism::Zenoh::Error => e
      s.close
      raise Disconnected, e.message
    end
    s.extend(SharedSession) # Asterism.session: the application's close does not close it
    @session = s
    @node = node
    @app = app
    @objects = {}  # name => [object, {method name => arity}, token, caller keyword or nil]
    @alive = {}    # "node/app/object" => node (from liveliness)
    @apps = {}     # "node/app" => node (from liveliness)
    @proxies = {}
    @depth = 0
    @lost = nil
    @known = []    # the other nodes told to on_join so far
    @known_set = {} # the same, as node => true
    @node_list = [node] # what nodes returns (this node first), rebuilt on a change
    @nodes_changed = false # liveliness changed since tell_nodes last compared
    @was_reconnecting = false
    tell_profile   # for those who follow the profiles (the reply is the queryable's)
    self
  end

  # Whether node/app is alive already (its application token or an object:
  # a second copy of the same application). Waits for the answer (a router answers at once), at
  # most check_ms. @api private
  def self.already_there?(s, node, app, check_ms = 1500)
    get_ms = check_ms > 1000 ? check_ms - 500 : check_ms
    g = s.liveliness_get("#{ROOT}/#{node}/#{app}/**", timeout_ms: get_ms)
    t0 = now_ms
    found = false
    while true
      s.poll
      ended = g.done? # before taking the replies (see Future#collect)
      found = true if g.each_reply.size > 0
      break if found || ended || now_ms - t0 > check_ms
      pause(WAIT_STEP_MS)
    end
    found
  end

  def self.connected?
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
  # application token, the exposed objects, the liveliness watch, and what
  # the application declared on Asterism.session. Meanwhile the other nodes
  # leave (on_leave) and join again after it, calls raise Disconnected or
  # time out, and puts reach nobody.
  def self.reconnecting?
    s = @session
    return false if s.nil?
    s.respond_to?(:reconnecting?) ? s.reconnecting? : false
  end

  def self.node_id
    @node
  end

  def self.app
    @app
  end

  # Why the connection went away (nil while connected or after close).
  def self.lost_reason
    @lost
  end

  # Closes the connection (and with it every exposed object), and forgets
  # the on_join / on_leave blocks. Idempotent.
  def self.close
    release
    @known = nil
    @on_join = nil
    @on_leave = nil
    nil
  end

  # @api private
  def self.release
    s = @session
    @session = nil
    @objects = {}
    @alive = {}
    @apps = {}
    @node_list = nil
    @nodes_changed = true
    @proxies = {}
    if s
      @releasing = s
      begin
        s.close
      ensure
        @releasing = nil
      end
    end
    @app_token = nil
    @queryable = nil
    @watch = nil
    @profile_queryable = nil
  end

  # The Zenoh session of the connection (an Asterism::Zenoh::Session), for
  # what the object layer does not do: put and subscribe, a ROS 2 node
  # (Asterism::ROS::Node.new(Asterism.session, ...)), anything of the
  # Zenoh API. One connection for everything: on a router that lets each
  # pass in once, a second session would not get in, and a ROS 2 node on
  # this session is part of this node (the same Zenoh ID).
  #
  # The session stays Asterism's: its close does nothing (it warns once);
  # Asterism.close closes it, and with it everything declared on it (the
  # application's subscribers, publishers, ROS 2 nodes). After a lost
  # connection and a new Asterism.connect, take Asterism.session again and
  # declare those again. Polling it (session.poll, node.poll) is fine:
  # Asterism.poll polls it too, each entity keeps what came for it.
  # Raises Disconnected when not connected (as the calls do).
  def self.session
    raise Disconnected, (@lost || "not connected") unless connected?
    @session
  end

  # @api private (the name before 0.6.0; Asterism.session is the same)
  def self.session!
    raise Disconnected, (@lost || "not connected") unless @session
    @session
  end

  # Whether Asterism itself is closing s (SharedSession#close).
  # @api private
  def self.releasing?(s)
    !@releasing.nil? && @releasing.equal?(s)
  end

  # Extended onto the session of Asterism.connect: the session belongs to
  # Asterism, so a close from anyone else (the application, a library that
  # was handed Asterism.session) does nothing. Asterism.close and a lost
  # connection close it.
  module SharedSession
    def close
      return super if ::Asterism.releasing?(self)
      ::Asterism.warn_once(self, "asterism: Asterism.session belongs to Asterism; its close is ignored " \
                                 "(Asterism.close closes it)")
      nil
    end
  end

  # The connection went away: closed, but the next Asterism.poll still tells
  # on_leave about every node known until then.
  # @api private
  def self.lost(reason)
    @lost = reason
    release
  end

  # ------------------------------------------------------------ exposing

  # Makes obj callable from other machines as <node>/<app>/<name>. Only the
  # listed methods can be called. methods: is an Array of names, or a Hash
  # name => number of arguments (checked before calling; -1 for any).
  # caller: a keyword name (caller: :from): each call passes the calling
  # node's ID (Asterism.current_call.from) to the method as that keyword,
  # and a call that brings the keyword itself is refused (an "arguments"
  # error), so the value is always the one Asterism took from the call.
  def self.expose(name, obj, methods:, caller: nil)
    s = session!
    name = check_name("object", name)
    table = {}
    if methods.is_a?(Hash)
      methods.each { |m, n| table[m.to_s] = n.to_i }
    else
      methods.each { |m| table[m.to_s] = -1 }
    end
    raise ArgumentError, "no method to expose" if table.empty?
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
    token = s.liveliness("#{ROOT}/#{@node}/#{@app}/#{name}")
    @objects[name] = [obj, table, token, kw]
    "#{@node}/#{@app}/#{name}"
  rescue Asterism::Zenoh::Error => e
    raise Disconnected, e.message
  end

  def self.unexpose(name)
    entry = @objects ? @objects.delete(name.to_s) : nil
    entry[2].close if entry
    !entry.nil?
  end

  def self.exposed
    @objects ? @objects.keys : []
  end

  # ------------------------------------------------------------ polling

  # Call from the application's update loop. Answers the calls that came
  # in, follows who is alive and calls the on_join / on_leave blocks. false
  # once the connection is closed.
  #
  # Cheap when nothing came: each queue is looked at by its count first,
  # and the list of nodes (and the comparison behind on_join / on_leave)
  # is made again only after a liveliness change.
  def self.poll
    ok = @session ? pump : false
    tell_nodes
    ok
  end

  # ------------------------------------------------------------ nodes coming and going

  # on_join { |node| }: another node appeared (one of its applications or
  # objects). The nodes there already join on the first polls after
  # connecting. on_leave { |node| }: a node is gone (no token and no object
  # left); when the connection is lost, every node known until then leaves.
  #
  # The blocks run from Asterism.poll only, never from the polling inside a
  # waiting call. What a block raises comes out of Asterism.poll (on CRuby
  # with a receiving thread: to on_error). Asterism.close forgets them.
  def self.on_join(&blk)
    raise ArgumentError, "on_join needs a block" unless blk
    (@on_join ||= []) << blk
    self
  end

  def self.on_leave(&blk)
    raise ArgumentError, "on_leave needs a block" unless blk
    (@on_leave ||= []) << blk
    self
  end

  # Removes a block given to on_join / on_leave (keep the Proc to remove
  # it: h = proc { |n| ... }; Asterism.on_join(&h); Asterism.off_join(h)).
  # on_* adds a block; on_error (CRuby) is the only one that replaces.
  def self.off_join(blk)
    @on_join.delete(blk) if @on_join
    self
  end

  def self.off_leave(blk)
    @on_leave.delete(blk) if @on_leave
    self
  end

  # Compares the nodes alive now with those told before and calls the
  # blocks for the difference.
  # @api private
  def self.tell_nodes
    known = @known
    return if known.nil?
    # Nothing came on the liveliness watch since the last comparison (and
    # the connection is neither new nor lost): nothing can have changed.
    return unless @nodes_changed
    @nodes_changed = false
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
    tell_each("on_join", @on_join, joined)
    tell_each("on_leave", @on_leave, left)
  end

  # While loops, not each with a block: the blocks are the application's,
  # and nothing else stands between them and the update loop on the stack.
  # @api private
  def self.tell_each(where, blocks, names)
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

  # One block for one node (CRuby routes what it raises to on_error).
  # @api private
  def self.tell(_where, blk, node)
    blk.call(node)
  end

  # @api private
  def self.pump
    s = @session
    return false unless s
    unless s.poll
      lost("the connection was lost")
      return false
    end
    back_again(s)
    answer_calls
    answer_profile
    follow_liveliness
    !@session.nil?
  rescue Asterism::Zenoh::Error => e
    lost_if_closed(e.message)
    !@session.nil?
  end

  # After the binding opened a lost connection again: tell the profile
  # again (a put made while the router was away reached nobody).
  # @api private
  def self.back_again(s)
    now = s.respond_to?(:reconnecting?) && s.reconnecting?
    was = @was_reconnecting
    @was_reconnecting = now
    tell_profile if was && !now
  end

  # A Zenoh error during a call or a poll: the connection is gone only when
  # the session says it is closed. While the binding reconnects, the
  # session (and everything declared on it) stays.
  # @api private
  def self.lost_if_closed(reason)
    s = @session
    lost(reason) if s.nil? || s.closed?
  end

  # Polls until the block is true. Answers incoming calls meanwhile.
  # @api private
  def self.wait_until
    if (@depth || 0) >= MAX_NESTING
      # Kept, so that a method that lets it out is answered as "nesting".
      @nesting_error = Error.new("calls nested too deep (max #{MAX_NESTING})")
      raise @nesting_error
    end
    @depth = (@depth || 0) + 1
    begin
      until yield
        break unless pump
        break if yield
        pause(WAIT_STEP_MS)
      end
    ensure
      @depth -= 1
    end
  end

  # @api private
  def self.depth
    (@depth || 0)
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

  # @api private
  def self.follow_liveliness
    w = @watch
    return unless w && w.pending > 0
    # Array forms instead of blocks called from C (see Future#collect).
    events = w.each_pending
    @nodes_changed = true if events.size > 0
    if events.size > 0 && w.dropped > 0
      warn_once(w, "asterism: #{w.dropped} liveliness changes dropped (more than #{watch_depth} at once); " \
                   "Asterism.each and Asterism.nodes may miss some objects")
    end
    i = 0
    while i < events.size
      key = events[i][0]
      alive = events[i][1]
      i += 1
      rest = key[ROOT.length + 1, key.length].to_s
      parts = rest.split("/")
      if parts.size == 2 # an application: asterism/<node>/<app>
        if alive
          @apps[rest] = parts[0]
        else
          @apps.delete(rest)
        end
      elsif parts.size == 3 # an object: asterism/<node>/<app>/<object>
        if alive
          @alive[rest] = parts[0]
        else
          @alive.delete(rest)
        end
      end
    end
    @node_list = nil
  end

  # The node IDs alive now, this one first.
  def self.nodes
    return [] unless @session
    node_list.dup
  end

  # The list behind nodes, made again only after a liveliness change (the
  # caller must not change it). @api private
  def self.node_list
    list = @node_list
    return list if list
    list = [@node]
    seen = { @node => true }
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
  # number (1.0 will return the proxies instead, as Ruby's each returns
  # its receiver; use the Array form for the count); else returns them.
  def self.each(pattern = "**")
    paths = []
    if @session
      seen = {}
      @objects.each_key do |name|
        path = "#{@node}/#{@app}/#{name}"
        if glob?(pattern, path)
          paths << path
          seen[path] = true
        end
      end
      @alive.each_key { |path| paths << path if !seen[path] && glob?(pattern, path) }
    end
    proxies = paths.map { |path| self[path] }
    return proxies unless block_given?
    proxies.each { |px| yield px }
    proxies.size
  end

  # A proxy for <node>/<app>/<object>. Nothing is sent until a method is
  # called on it. timeout: the time limit of its calls in seconds (2.0), or
  # timeout_ms:. (Asterism[path, ms], the time as a positional argument, is
  # deprecated.)
  def self.[](path, *args, timeout: nil, timeout_ms: nil)
    raise ArgumentError, "Asterism[]: wrong number of arguments (given #{args.size + 1}, expected 1)" if args.size > 1
    timeout_ms = time_ms("Asterism[]", timeout, timeout_ms, args[0], DEFAULT_TIMEOUT_MS)
    split_path(path)
    @proxies ||= {}
    key = "#{path}|#{timeout_ms}"
    @proxies[key] ||= Proxy.new(path.to_s, timeout_ms)
  end

  # ------------------------------------------------------------ calling

  # Starts a call; returns a Future. Raises EncodeError (before sending)
  # and Disconnected.
  # @api private
  def self.call_async(path, method, args, kwargs, timeout_ms)
    parts = split_path(path)
    payload = Codec.pack(request(method, args, kwargs))
    if parts[0] == @node && parts[1] == @app && @session
      # This application's own object: no network (a session does not see
      # its own queryable), same encoding and checks as a remote call.
      return Future.answered(path, method, dispatch(parts[2], payload, @node, :local))
    end
    begin
      s = session!
      # The caller's node ID is the key's last chunk (docs/protocol.md 4.1).
      g = s.get("#{ROOT}/#{path}/call/#{@node}", timeout_ms: timeout_ms, payload: payload)
    rescue Asterism::Zenoh::Error => e
      lost_if_closed(e.message)
      raise Disconnected, e.message
    end
    Future.new(path, method, g, now_ms + timeout_ms, timeout_ms)
  end

  # The request of a call: a map with the method's name, and the arguments
  # and keyword arguments when there are any (absent means none).
  # @api private
  def self.request(method, args, kwargs)
    req = { "method" => method.to_s }
    req["args"] = args unless args.nil? || args.empty?
    req["kwargs"] = kwargs unless kwargs.nil? || kwargs.empty?
    req
  end

  # @api private
  def self.call(path, method, args, kwargs, timeout_ms)
    call_async(path, method, args, kwargs, timeout_ms).value
  end

  # The meta reply of path: {"methods" => [{"name" => n, "arity" => a}, ...]}.
  # @api private
  def self.meta(path, timeout_ms = DEFAULT_TIMEOUT_MS)
    parts = split_path(path)
    if parts[0] == @node && parts[1] == @app && @session
      m = meta_of(parts[2])
      raise RemoteError.new("NameError", "no object #{parts[2]} exposed by #{@node}/#{@app}", "no_object") unless m
      return m
    end
    begin
      g = session!.get("#{ROOT}/#{path}/meta", timeout_ms: timeout_ms)
    rescue Asterism::Zenoh::Error => e
      lost_if_closed(e.message)
      raise Disconnected, e.message
    end
    f = Future.new(path, "meta", g, now_ms + timeout_ms, timeout_ms)
    f.raw_value
  end

  # ------------------------------------------------------------ answering

  # The call being answered now (an Asterism::CurrentCall: who called,
  # which object and method), while an exposed method runs for a call; nil
  # outside one. Calls answered while that method waits for its own call
  # are on top of it until they end.
  def self.current_call
    stack = call_stack
    stack.empty? ? nil : stack[stack.size - 1]
  end

  # The calls being answered, innermost last (CRuby: per thread).
  # @api private
  def self.call_stack
    @call_stack ||= []
  end

  # @api private
  def self.answer_calls
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
        rescue Asterism::Zenoh::Error
          # the session went away meanwhile
        end
      end
    end
  end

  # asterism/<node>/<app>/<object>/call/<caller> and
  # asterism/<node>/<app>/<object>/meta; the node and app may come as
  # wildcards (the query matched this application's queryable).
  # @api private
  def self.answer(q)
    parts = q.key.split("/")
    n = parts.size
    return unless n == 5 || n == 6
    obj = parts[3]
    kind = parts[4]
    prefix = "#{ROOT}/#{@node}/#{@app}/"
    if kind == "meta"
      return unless n == 5
      names = obj == "*" ? @objects.keys : [obj]
      names.each do |nm|
        m = meta_of(nm)
        q.reply("#{prefix}#{nm}/meta", Codec.pack(m)) if m
      end
    elsif kind == "call" && valid_name?(obj)
      if n == 5
        # A protocol 0 call (no caller chunk): refused, so that its sender
        # learns why at once instead of waiting.
        q.reply("#{prefix}#{obj}/call",
                error_reply("protocol", "Asterism::Error",
                            "#{@node}/#{@app} speaks Asterism protocol #{PROTOCOL}: call " \
                            "asterism/<node>/<app>/<object>/call/<caller> with a map " \
                            "{\"method\", \"args\", \"kwargs\"} (asterism 0.7.0 and later)"))
      elsif valid_name?(parts[5])
        q.reply("#{prefix}#{obj}/call/#{parts[5]}", dispatch(obj, q.payload, parts[5], :claimed))
      end
    end
  end

  # Whether s can be a node, app or object name (check_name without raising).
  # @api private
  def self.valid_name?(s)
    return false if s.nil? || s.empty? || s.start_with?("@")
    !(s.include?("/") || s.include?("*") || s.include?("$") || s.include?("?") || s.include?("#"))
  end

  # @api private
  def self.meta_of(name)
    entry = @objects[name]
    return nil unless entry
    list = []
    entry[1].each { |m, n| list << { "name" => m, "arity" => n } }
    { "methods" => list }
  end

  MALFORMED = "malformed call (expected a map {\"method\" => name, \"args\" => [...], \"kwargs\" => {...}})"

  # Runs a call on an exposed object; returns the packed reply. from is
  # the caller's node ID, verified how it is known (CurrentCall).
  # @api private
  def self.dispatch(obj_name, payload, from, verified)
    req = parse_request(Codec.unpack(payload))
    return error_reply("malformed", "ArgumentError", MALFORMED) unless req
    entry = @objects[obj_name]
    return error_reply("no_object", "NameError", "no object #{obj_name} exposed by #{@node}/#{@app}") unless entry
    name = req[0]
    args = req[1]
    kw = req[2]
    arity = entry[1][name]
    if arity.nil?
      return error_reply("not_exposed", "NoMethodError",
                         "undefined method '#{name}' for #{@node}/#{@app}/#{obj_name} (not exposed)")
    end
    if arity >= 0 && args.size != arity
      return error_reply("arguments", "ArgumentError", "wrong number of arguments (given #{args.size}, expected #{arity})")
    end
    ckw = entry[3]
    if ckw
      if kw.key?(ckw)
        return error_reply("arguments", "ArgumentError",
                           "#{ckw}: is given by Asterism, not by the caller " \
                           "(#{@node}/#{@app}/#{obj_name} is exposed with caller: :#{ckw})")
      end
      kw[ckw] = from
    end
    stack = call_stack
    stack << CurrentCall.new(from, verified, obj_name, name)
    begin
      value = invoke(entry[0], name, args, kw)
    rescue => e
      return error_reply(e.equal?(@nesting_error) ? "nesting" : "raised", e.class.to_s, e.message)
    ensure
      stack.pop
    end
    begin
      Codec.pack({ "value" => value })
    rescue EncodeError => e
      error_reply("unsendable", "Asterism::EncodeError", "the return value: #{e.message}")
    end
  end

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
end
