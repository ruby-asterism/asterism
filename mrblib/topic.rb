# Data an application streams on its own keys (docs/protocol.md 9-11):
# topics it declares, the values it puts on them, and the subscriptions of
# the readers.
#
#   net = Asterism.connect(router, node: "linux", app: "demo")
#   imu = net.publish("imu", type: :vector3, unit: "m/s2", ts: true)
#   imu.put([0.1, 0.0, 9.8])                  # MessagePack, no encoding
#   cam = net.publish("camera", type: :image, encoding: "image/jpeg")
#   cam.put(jpeg_bytes)                       # the bytes as they are
#   net.define_type("mygame/board.strokes", [["pts", "int[]"], ["color", "str"]])
#
#   net.subscribe("*/demo/imu") { |v, info| p [v, info.seq, info.lost] }
#   net.pubs_of("linux", "demo")              # => {"imu" => {"t" => 2, ...}}
#
# Keys: a value goes on asterism/<node>/<app>/<name> (a declared Zenoh
# publisher: the key travels as a number), with no encoding when it is
# MessagePack and the encoding given at publish otherwise; the attachment
# is the MessagePack array [seq] or [seq, sender's time in ms since 1970]
# (ts: true). The declarations are put on asterism/<node>/<app>/@pubs each
# time they change, and answered by the application's own profile,
# asterism/<node>/<app>/@profile (status.rb): ?status, ?pubs, ?types.
#
# Shared places (docs/protocol.md 17): data with no single owner goes on
# a node's asterism/<node>/@shared/<name> or the network's
# asterism/@shared/<name>. The sender declares it in its own @pubs
# ("<node>/@shared/<name>", "@shared/<name>"), and each value's attachment
# is [seq, ms or nil, "<node>/<app>"], so that the readers count the
# numbers per sender and read the type from the sender's declarations.
#
#   t = net.publish("spectate/t1/state", shared: :node, type: "mygame/table")
#   net.subscribe("*/@shared/spectate/**") { |v, info| p [info.from, info.lost] }
#   net.publishers_of("linux/@shared/spectate/t1/state")  # => {"linux/room01" => {...}}
#   net.type_of(info)                         # the sender's type of that key
#
# Subscription blocks run from Connection#poll only, never from the polling
# inside a waiting call (the values wait in the subscription's queue).
module Asterism
  # The types of a topic's values: the built-in ones by number (their
  # shapes are in docs/protocol.md 10), an application's own by name.
  module Types
    NUMBER = 1   # a Float or an Integer
    VECTOR3 = 2  # [x, y, z]
    POSE = 3     # [x, y, z, qx, qy, qz, qw] (ROS 2's Pose order)
    IMAGE = 4    # the bytes, in the topic's encoding (image/jpeg, image/png)
    STATE = 5    # a String or an Integer (a scene, on / off)
    LOG = 6      # a log record (docs/v3.md)
    TEXT = 7     # a String
    # The built-in types by name; the number is the index + 1.
    NAMES = ["number", "vector3", "pose", "image", "state", "log", "text"]
    # The basic types of a field of an application's own type.
    BASIC = ["int", "float", "str", "bin", "bool", "any"]
    NAME_MAX = 128   # bytes of a type's name and a field's name
    FIELDS_MAX = 64  # fields of one type

    # The number of a built-in type from its name (a Symbol or String),
    # or nil.
    def self.number(name)
      s = name.to_s
      i = 0
      while i < NAMES.size
        return i + 1 if NAMES[i] == s
        i += 1
      end
      nil
    end

    # The "t" of a declaration from publish's type: (nil: no type).
    # @api private
    def self.topic_type!(t)
      return nil if t.nil?
      if t.is_a?(Integer)
        return t if t >= 1 && t <= NAMES.size
        raise ArgumentError, "type: #{t} is not a built-in type (1 to #{NAMES.size})"
      end
      if t.is_a?(Symbol)
        n = number(t)
        return n if n
        raise ArgumentError, "type: :#{t} is not a built-in type (#{NAMES.join(', ')}); " \
                             "an application's own type is a String"
      end
      return name!("type:", t) if t.is_a?(String)
      raise ArgumentError, "type: expects a Symbol, an Integer or a String, got #{t.class}"
    end

    # @api private
    def self.name!(what, s)
      s = s.to_s if s.is_a?(Symbol)
      raise ArgumentError, "#{what} expects a String, got #{s.class}" unless s.is_a?(String)
      raise ArgumentError, "#{what} empty" if s.empty?
      raise ArgumentError, "#{what} #{s.bytesize} bytes (#{NAME_MAX} at most)" if s.bytesize > NAME_MAX
      s
    end

    # A field's type as it is sent: a built-in number as given, or a
    # String as given (a Symbol as its name): a built-in type's name
    # ("vector3"), a basic type ("int"), another application type; "[]" at
    # the end for an array of it ("vector3[]", "int[]").
    # @api private
    def self.field_type!(t)
      if t.is_a?(Integer)
        return t if t >= 1 && t <= NAMES.size
        raise ArgumentError, "field type #{t} is not a built-in type (1 to #{NAMES.size})"
      end
      s = name!("field type:", t)
      base = s
      base = base[0, base.size - 2] while base.end_with?("[]")
      raise ArgumentError, "field type #{s.inspect}: no type before []" if base.empty?
      s
    end

    # A definition from define_type: {"f" => [[name, type], ...], "d" => desc}.
    # @api private
    def self.definition!(fields, desc)
      raise ArgumentError, "define_type: fields: expects an Array of [name, type]" unless fields.is_a?(Array)
      raise ArgumentError, "define_type: more than #{FIELDS_MAX} fields" if fields.size > FIELDS_MAX
      list = []
      fields.each do |f|
        unless f.is_a?(Array) && f.size == 2
          raise ArgumentError, "define_type: each field is [name, type], got #{f.inspect}"
        end
        list << [name!("field name:", f[0]), field_type!(f[1])]
      end
      d = { "f" => list }
      unless desc.nil?
        raise ArgumentError, "define_type: desc: expects a String" unless desc.is_a?(String)
        raise ArgumentError, "define_type: desc: at most #{::Asterism::DOC_MAX} bytes" if desc.bytesize > ::Asterism::DOC_MAX
        d["d"] = desc
      end
      d
    end

    # A received map of definitions, cleaned: the definitions with a str
    # name and an "f" that is an array of [str, int or str] pairs, and "d"
    # when it is a str. nil when it is not a map.
    def self.check(h)
      return nil unless h.is_a?(Hash)
      out = {}
      h.each do |name, d|
        next unless name.is_a?(String) && !name.empty? && d.is_a?(Hash) && d["f"].is_a?(Array)
        ok = true
        d["f"].each do |f|
          ok = false unless f.is_a?(Array) && f.size == 2 && f[0].is_a?(String) &&
                            (f[1].is_a?(Integer) || (f[1].is_a?(String) && !f[1].empty?))
        end
        next unless ok
        c = { "f" => d["f"] }
        c["d"] = d["d"] if d["d"].is_a?(String)
        out[name] = c
      end
      out
    end
  end

  # The declarations of the topics (asterism/<node>/<app>/@pubs).
  module Pubs
    KEY = "@pubs"
    # The chunk of the shared places: asterism/@shared/... (the network's)
    # and asterism/<node>/@shared/... (a node's).
    SHARED = "@shared"
    UNIT_MAX = 64 # bytes of a unit
    # Zenoh's encodings with a fixed number (Zenoh 1.x), the number is the
    # position: zenoh/bytes is 0, image/jpeg 17. One String, split when an
    # encoding is first looked up.
    ENCODINGS = "zenoh/bytes zenoh/string zenoh/serialized application/octet-stream text/plain " \
                "application/json text/json application/cdr application/cbor application/yaml text/yaml " \
                "text/json5 application/python-serialized-object application/protobuf " \
                "application/java-serialized-object application/openmetrics-text image/png image/jpeg " \
                "image/gif image/bmp image/webp application/xml application/x-www-form-urlencoded " \
                "text/html text/xml text/css text/javascript text/markdown text/csv application/sql " \
                "application/coap-payload application/json-patch+json application/json-seq " \
                "application/jsonpath application/jwt application/mp4 application/soap+xml " \
                "application/yang audio/aac audio/flac audio/mp4 audio/ogg audio/vorbis video/h261 " \
                "video/h263 video/h264 video/h265 video/h266 video/mp4 video/ogg video/raw video/vp8 " \
                "video/vp9"

    # The fixed number of an encoding ("image/jpeg" or with a schema,
    # "text/plain;charset=utf-8"), or nil when it has none.
    def self.encoding_id(name)
      s = name.to_s
      cut = s.index(";")
      s = s[0, cut] if cut
      list = (@names ||= ENCODINGS.split(" "))
      i = 0
      while i < list.size
        return i if list[i] == s
        i += 1
      end
      nil
    end

    # The name of an encoding number, or nil.
    def self.encoding_name(id)
      list = (@names ||= ENCODINGS.split(" "))
      id.is_a?(Integer) && id >= 0 && id < list.size ? list[id] : nil
    end

    # Where a declaration's entry puts its values (docs/protocol.md 17):
    # [nil, nil, name] for a topic of the application's own ("imu",
    # "board1/strokes": asterism/<node>/<app>/<name>), [:node, node, name]
    # for "<node>/@shared/<name>" (asterism/<node>/@shared/<name>),
    # [:global, nil, name] for "@shared/<name>" (asterism/@shared/<name>).
    # nil for anything else (an empty chunk, a chunk that is not a name,
    # another verbatim chunk).
    def self.place(entry)
      return nil unless entry.is_a?(String) && !entry.empty?
      return nil if entry.start_with?("/") || entry.end_with?("/")
      parts = entry.split("/")
      if parts[0] == SHARED
        rest = parts[1, parts.size - 1]
        return names?(rest) ? [:global, nil, rest.join("/")] : nil
      end
      if parts.size > 2 && parts[1] == SHARED
        rest = parts[2, parts.size - 2]
        return ::Asterism.valid_name?(parts[0]) && names?(rest) ? [:node, parts[0], rest.join("/")] : nil
      end
      names?(parts) ? [nil, nil, entry] : nil
    end

    # The entry of a topic in the declarations: its name for the
    # application's own, "<node>/@shared/<name>" or "@shared/<name>".
    def self.entry(shared, node, name)
      return name if shared.nil?
      shared == :global ? "#{SHARED}/#{name}" : "#{node}/#{SHARED}/#{name}"
    end

    # The key a declared entry of <node>/<app> puts its values on, below
    # asterism/ ("linux/demo/imu", "linux/@shared/spectate/t1/state",
    # "@shared/lobby"), or nil when the entry is not one.
    def self.path(node, app, entry)
      pl = place(entry)
      return nil if pl.nil?
      pl[0].nil? ? "#{node}/#{app}/#{entry}" : entry
    end

    # @api private
    def self.names?(list)
      return false if list.empty?
      list.each { |c| return false unless ::Asterism.valid_name?(c) }
      true
    end

    # A received map of declarations, cleaned: the entries whose name is a
    # topic of the application's own or a shared one (place), whose
    # declaration is a map, with the known keys that pass ("t" an int above
    # 0 or a str, "e" an int, "u" and "d" str, "ts" true). With node (the
    # node of the application that declared them), an entry of another
    # node's shared place is left out too. nil when it is not a map.
    def self.check(h, node = nil)
      return nil unless h.is_a?(Hash)
      out = {}
      h.each do |name, d|
        next unless d.is_a?(Hash)
        pl = place(name)
        next if pl.nil? || (node && pl[0] == :node && pl[1] != node)
        c = {}
        t = d["t"]
        c["t"] = t if (t.is_a?(Integer) && t > 0) || (t.is_a?(String) && !t.empty?)
        e = d["e"]
        c["e"] = e if e.is_a?(Integer) && e > 0
        c["u"] = d["u"] if d["u"].is_a?(String)
        c["d"] = d["d"] if d["d"].is_a?(String)
        c["ts"] = true if d["ts"] == true
        out[name] = c
      end
      out
    end

    # [node, app, declarations] of a put on asterism/<node>/<app>/@pubs, or
    # nil when it is not one.
    def self.parse(key, payload)
      parts = key.to_s.split("/")
      return nil unless parts.size == 4 && parts[0] == ::Asterism::ROOT && parts[3] == KEY
      d = check(::Asterism::Codec.unpack(payload), parts[1])
      d ? [parts[1], parts[2], d] : nil
    end
  end

  # A declared topic (Connection#publish). put sends a value; close withdraws
  # the declaration.
  class Topic
    # The sequence number goes back to 0 after this (below 2^31, so that
    # every board's Integer holds it).
    SEQ_MAX = 2147483647

    # name: as given to publish (below @shared/ for a shared one); key: the
    # whole key; shared: nil (the application's own), :node or :global;
    # entry: the name in the declarations ("imu", "<node>/@shared/<name>",
    # "@shared/<name>").
    attr_reader :name, :key, :encoding, :connection, :shared, :entry

    # @api private
    def initialize(connection, name, key, publisher, decl, encoding, ts, shared = nil, entry = nil, from = nil)
      @connection = connection
      @name = name
      @key = key
      @publisher = publisher
      @decl = decl
      @encoding = encoding
      @ts = ts
      @seq = 0
      @shared = shared
      @entry = entry || name
      @from = from
    end

    # The declaration as sent in @pubs ({"t" => 2, "u" => "m/s2", ...}).
    def declaration
      @decl.dup
    end

    # The sequence number the next put sends.
    def seq
      @seq
    end

    # Whether the sender's time goes with each value (ts: true).
    def ts?
      @ts
    end

    # Sends a value: any value MessagePack carries (EncodeError otherwise),
    # or for a topic with an encoding, the bytes (a String) as they are.
    # Raises Disconnected when the connection is closed (or the topic is).
    def put(value)
      @connection.topic_put(self, value)
    end

    def close
      @connection.unpublish(self)
    end

    def closed?
      @publisher.nil?
    end

    def inspect
      "#<Asterism::Topic #{@key}#{closed? ? ' closed' : ''}>"
    end

    # @api private
    def publisher
      @publisher
    end

    # @api private
    def decl_raw
      @decl
    end

    # The attachment of the next value, and the number after it.
    # @api private
    # [seq] or [seq, ms] for the application's own topic; [seq, ms or nil,
    # "<node>/<app>"] for a shared one (docs/protocol.md 9.3).
    def attachment
      ms = @ts ? ::Asterism.wall_ms : nil
      return ::MessagePack.pack([@seq, ms, @from]) if @shared
      ::MessagePack.pack(ms.nil? ? [@seq] : [@seq, ms])
    end

    # @api private
    def advance
      @seq = @seq >= SEQ_MAX ? 0 : @seq + 1
    end

    # @api private
    def closed!
      @publisher = nil
    end
  end

  # What comes with each value to a subscription's block (|v, info|): where
  # it came from, its number and times, and how many were missed before it.
  class SampleInfo
    # key: the whole key (asterism/<node>/<app>/<name>, or a shared place's
    # asterism/<node>/@shared/<name> / asterism/@shared/<name>); path: the
    # key below asterism/. shared: nil for an application's own topic,
    # :node or :global for a shared place. name: the topic's name (below
    # @shared/ for a shared one; it may hold "/"). from: the sender,
    # "<node>/<app>" (for a shared place as its attachment tells it, nil
    # when it does not); node, app: its parts (a node's shared place without
    # a sender: the key's node, app nil). seq: the sender's sequence number
    # (nil when the value came without one). time: the sender's time in ms
    # since 1970 (nil unless the topic sends it, ts: true). encoding:
    # "msgpack" for a MessagePack value, else the Zenoh encoding
    # ("image/jpeg"). timestamp: the router's time (an
    # Asterism::Zenoh::Timestamp), nil when no router stamped it. lost: how
    # many values of this key (and, on a shared place, of this sender) did
    # not come between the last one and this (0 for the first). restarted:
    # true when the number went back (the sender connected again or
    # started over); lost then counts the values of the new run before this
    # one.
    attr_reader :key, :path, :node, :app, :name, :seq, :time, :encoding, :timestamp, :lost, :shared, :from

    # @api private
    def initialize(key, node, app, name, seq, time, encoding, timestamp, lost, restarted,
                   path = nil, shared = nil, from = nil)
      @key = key
      @node = node
      @app = app
      @name = name
      @seq = seq
      @time = time
      @encoding = encoding
      @timestamp = timestamp
      @lost = lost
      @restarted = restarted
      @path = path || "#{node}/#{app}/#{name}"
      @shared = shared
      @from = from || (shared.nil? && node && app ? "#{node}/#{app}" : nil)
    end

    def restarted?
      @restarted
    end

    def to_h
      { key: @key, path: @path, shared: @shared, from: @from, node: @node, app: @app, name: @name, seq: @seq,
        time: @time, encoding: @encoding, timestamp: @timestamp, lost: @lost, restarted: @restarted }
    end

    def inspect
      by = @shared ? " from #{@from || '?'}" : ""
      "#<Asterism::SampleInfo #{@path}#{by} seq=#{@seq.inspect} lost=#{@lost}#{@restarted ? ' restarted' : ''} " \
        "#{@encoding}>"
    end
  end

  # A subscription (Connection#subscribe). close ends it.
  class Subscription
    # Sequence numbers are compared within half of their range: a step
    # forward smaller than this is a step, anything else a restart (the
    # numbers wrap at Topic::SEQ_MAX).
    HALF = 1073741824

    attr_reader :path, :connection

    # @api private
    def initialize(connection, path, zsub, blk)
      @connection = connection
      @path = path
      @zsub = zsub
      @blk = blk
      @last = {}
      @received = 0
      @malformed = 0
    end

    # The values handed to the block so far.
    def received
      @received
    end

    # Values left out because they were not MessagePack (no encoding, and
    # not one value of docs/protocol.md 3.1).
    def malformed
      @malformed
    end

    # Values the queue had no room for (it holds depth: values between two
    # polls).
    def dropped
      @zsub ? @zsub.dropped : 0
    end

    def close
      @connection.unsubscribe(self)
    end

    def closed?
      @zsub.nil?
    end

    def inspect
      "#<Asterism::Subscription #{@path}#{closed? ? ' closed' : ''}>"
    end

    # @api private
    def zsub
      @zsub
    end

    # @api private
    def block
      @blk
    end

    # @api private
    def closed!
      @zsub = nil
    end

    # The values waiting, as [[value, info], ...] (the bad ones left out).
    # @api private
    def take
      z = @zsub
      out = []
      return out unless z && z.pending > 0
      samples = z.each_sample
      i = 0
      while i < samples.size
        got = unwrap(samples[i])
        i += 1
        out << got if got
      end
      out
    end

    # [value, info] of one Zenoh sample, or nil (a delete, or not
    # MessagePack).
    # @api private
    def unwrap(sm)
      return nil if sm.kind == :delete
      payload = sm.payload
      enc = sm.encoding
      if enc.nil? || enc == "" || enc == "zenoh/bytes"
        value = ::Asterism::Codec.unpack(payload)
        if value.nil? && !(payload && payload.bytesize == 1 && payload.getbyte(0) == 0xc0)
          @malformed += 1
          return nil
        end
        enc = "msgpack"
      else
        value = payload
      end
      key = sm.key
      root = ::Asterism::ROOT
      rest = key.start_with?("#{root}/") ? key[root.size + 1, key.size] : key
      parts = rest.split("/")
      shared = nil
      if parts[0] == ::Asterism::Pubs::SHARED
        shared = :global
        node = nil
        app = nil
        name = parts.size > 1 ? parts[1, parts.size - 1].join("/") : nil
      elsif parts.size > 2 && parts[1] == ::Asterism::Pubs::SHARED
        shared = :node
        node = parts[0]
        app = nil
        name = parts[2, parts.size - 2].join("/")
      else
        node = parts[0]
        app = parts[1]
        name = parts.size > 2 ? parts[2, parts.size - 2].join("/") : nil
      end
      seq = nil
      time = nil
      from = nil
      att = sm.attachment
      if att && !att.empty?
        a = ::Asterism::Codec.unpack(att)
        if a.is_a?(Array) && a[0].is_a?(Integer) && a[0] >= 0 && a[0] <= Topic::SEQ_MAX
          seq = a[0]
          time = a[1] if a[1].is_a?(Integer)
          from = ::Asterism::Subscription.sender(a[2]) if shared
        end
      end
      if from
        cut = from.index("/")
        node = from[0, cut]
        app = from[cut + 1, from.size - cut - 1]
      end
      # The numbers of a shared key are counted per sender.
      lane = from ? "#{key}\n#{from}" : key
      lost = 0
      restarted = false
      unless seq.nil?
        prev = @last[lane]
        unless prev.nil?
          d = seq - prev
          d += Topic::SEQ_MAX + 1 if d < 0
          if d > 0 && d < HALF
            lost = d - 1
          else
            restarted = true
            lost = seq
          end
        end
        @last[lane] = seq
      end
      @received += 1
      [value, ::Asterism::SampleInfo.new(key, node, app, name, seq, time, enc, sm.timestamp, lost, restarted,
                                         rest, shared, from)]
    end

    # The sender of a shared value from its attachment: "<node>/<app>" when
    # it is a str of two names, else nil.
    # @api private
    def self.sender(s)
      return nil unless s.is_a?(String)
      cut = s.index("/")
      return nil if cut.nil?
      n = s[0, cut]
      a = s[cut + 1, s.size - cut - 1]
      ::Asterism.valid_name?(n) && ::Asterism.valid_name?(a) ? s : nil
    end
  end

  # A topic's name: key chunks separated by "/", each a name.
  # @api private
  def self.check_topic_name(name)
    s = name.is_a?(Symbol) ? name.to_s : name
    raise ArgumentError, "invalid topic name: #{name.inspect}" unless s.is_a?(String)
    bad = s.empty? || s.start_with?("/") || s.end_with?("/")
    unless bad
      s.split("/").each { |c| bad = true unless valid_name?(c) }
    end
    raise ArgumentError, "invalid topic name: #{name.inspect}" if bad
    s
  end

  # The place of publish's shared: nil (the application's own), :node or
  # :global (a Symbol or a String).
  # @api private
  def self.shared_place!(shared)
    return nil if shared.nil? || shared == false
    s = shared.to_s
    return :node if s == "node"
    return :global if s == "global"
    raise ArgumentError, "shared: expects :node or :global (or nil), got #{shared.inspect}"
  end

  # The sender's time: milliseconds since 1970 (nil where there is no
  # clock of the day).
  # @api private
  def self.wall_ms
    return nil unless Object.const_defined?(:Time)
    t = Time.now
    t.to_i * 1000 + t.usec / 1000
  end

  class Connection
    # Declares a topic of this application, asterism/<node>/<app>/<name>
    # (name: chunks separated by "/", each a name of docs/protocol.md 2.1),
    # and returns it (an Asterism::Topic; topic.put(value) sends). type: a
    # built-in type (:vector3, or its number) or an application's own type
    # (a String, "mygame/board.strokes"); unit:, desc: Strings for the
    # readers; ts: true sends the sender's time with each value; encoding: a
    # Zenoh encoding with a fixed number ("image/jpeg"): the values are then
    # Strings sent as they are, not MessagePack. Publishing a name again
    # replaces the topic (its numbers start again at 0). The declaration is
    # put on asterism/<node>/<app>/@pubs. Raises ArgumentError for what it
    # does not accept and Disconnected when not connected. The topics end
    # with the connection.
    #
    # shared: puts the values on a shared place instead (docs/protocol.md
    # 17): :node, this node's asterism/<node>/@shared/<name>; :global, the
    # network's asterism/@shared/<name>. The topic is still declared in this
    # application's @pubs ("<node>/@shared/<name>", "@shared/<name>"), with
    # this application's types, and each value says its sender
    # ("<node>/<app>") in the attachment. Other applications may put on the
    # same key; the router decides who may (the node's place: its own node;
    # the network's: whom the roles allow).
    def publish(name, type: nil, unit: nil, desc: nil, ts: false, encoding: nil, shared: nil)
      s = session!
      name = ::Asterism.check_topic_name(name)
      place = ::Asterism.shared_place!(shared)
      entry = ::Asterism::Pubs.entry(place, @node_id, name)
      decl = {}
      t = ::Asterism::Types.topic_type!(type)
      decl["t"] = t unless t.nil?
      enc = nil
      unless encoding.nil?
        enc = encoding.to_s
        id = ::Asterism::Pubs.encoding_id(enc)
        if id.nil?
          raise ArgumentError, "encoding: #{enc.inspect} is not one of Zenoh's encodings with a number " \
                               "(image/jpeg, image/png, text/plain, application/cdr, ...)"
        end
        if id == 0
          raise ArgumentError, "encoding: zenoh/bytes is how a MessagePack value goes; leave encoding: out " \
                               "(a binary String is sent as a MessagePack bin)"
        end
        decl["e"] = id
      end
      unless unit.nil?
        raise ArgumentError, "unit: expects a String, got #{unit.class}" unless unit.is_a?(String)
        raise ArgumentError, "unit: at most #{::Asterism::Pubs::UNIT_MAX} bytes" if unit.bytesize > ::Asterism::Pubs::UNIT_MAX
        decl["u"] = unit unless unit.empty?
      end
      unless desc.nil?
        raise ArgumentError, "desc: expects a String, got #{desc.class}" unless desc.is_a?(String)
        raise ArgumentError, "desc: at most #{::Asterism::DOC_MAX} bytes" if desc.bytesize > ::Asterism::DOC_MAX
        decl["d"] = desc unless desc.empty?
      end
      raise ArgumentError, "ts: expects true or false" unless ts == true || ts == false
      decl["ts"] = true if ts
      old = @topics[entry] # replaced in place: the order of @pubs stays
      close_topic(old) if old
      key = place ? "#{::Asterism::ROOT}/#{entry}" : "#{::Asterism::ROOT}/#{@node_id}/#{@app}/#{name}"
      begin
        zp = enc ? s.publisher(key, encoding: enc) : s.publisher(key)
      rescue ::Asterism::Zenoh::Error
        if old
          @topics.delete(entry)
          tell_pubs(false)
        end
        raise
      end
      topic = ::Asterism::Topic.new(self, name, key, zp, decl, enc, ts, place, entry, place ? path : nil)
      @topics[entry] = topic
      app_queryable(s)
      tell_pubs(false)
      topic
    rescue ::Asterism::Zenoh::Error => e
      lost_if_closed(e.message)
      raise ::Asterism::Disconnected, e.message
    end

    # Withdraws a topic (a Topic, or its name with the shared: it was
    # published with, or its entry as published lists it): its declaration
    # leaves @pubs. True when there was one.
    def unpublish(topic, shared: nil)
      tbl = @topics || {}
      is_topic = topic.is_a?(::Asterism::Topic)
      name = if is_topic
               topic.entry
             else
               ::Asterism::Pubs.entry(::Asterism.shared_place!(shared), @node_id, topic.to_s)
             end
      cur = tbl[name]
      if cur.nil? || (is_topic && !cur.equal?(topic))
        close_topic(topic) if is_topic
        return false
      end
      tbl.delete(name)
      close_topic(cur)
      tell_pubs(false)
      true
    end

    # The entries of this application's topics: the names of its own, and
    # "<node>/@shared/<name>" / "@shared/<name>" for the shared ones.
    def published
      @topics ? @topics.keys : []
    end

    # @api private
    def close_topic(topic)
      zp = topic.publisher
      topic.closed!
      zp.close if zp
    rescue ::Asterism::Zenoh::Error
      nil
    end

    # @api private
    def topic_put(topic, value)
      zp = topic.publisher
      raise ::Asterism::Disconnected, "topic #{topic.entry} is closed" if zp.nil?
      if topic.encoding
        unless value.is_a?(String)
          raise ArgumentError, "topic #{topic.name} (#{topic.encoding}): put expects the bytes, a String"
        end
        bytes = value
      else
        bytes = ::Asterism::Codec.pack(value)
      end
      begin
        zp.put(bytes, attachment: topic.attachment)
      rescue ::Asterism::Zenoh::Error => e
        lost_if_closed(e.message)
        raise ::Asterism::Disconnected, e.message
      end
      topic.advance
      nil
    end

    # The declarations as sent: {name => {"t", "e", "u", "d", "ts"}}.
    # @api private
    def pubs_hash
      h = {}
      (@topics || {}).each { |name, t| h[name] = t.decl_raw }
      h
    end

    # Puts the declarations on asterism/<node>/<app>/@pubs while connected:
    # when they changed since the last put of this connection, or always with
    # force (a connection that came back) once there were any.
    # @api private
    def tell_pubs(force)
      s = @session
      return unless s
      tbl = @topics || {}
      return if tbl.empty? && @pubs_put.nil?
      bytes = ::Asterism::Codec.pack(pubs_hash)
      return if !force && !@pubs_put.nil? && @pubs_put == bytes
      s.put("#{::Asterism::ROOT}/#{@node_id}/#{@app}/#{::Asterism::Pubs::KEY}", bytes)
      @pubs_put = bytes
    rescue ::Asterism::Zenoh::Error
      nil # the next poll notices a lost connection
    end

    # Defines an application type (docs/protocol.md 10), told to the readers
    # by asterism/<node>/<app>/@profile?types. name: a String
    # ("mygame/board.strokes"); fields: [[name, type], ...], each type a
    # built-in one (its number, or its name: "vector3", :vector3), a basic
    # one ("int", "float", "str", "bin", "bool") or another application
    # type's name, with "[]" at the end for an array ("vector3[]", "int[]",
    # "mygame/point[]"), repeated for arrays of arrays ("int[][]"); "any"
    # for a value of any shape; names are sent as written. desc: a text.
    # Defining a name again replaces it. The types are the connection's
    # (kept after close, to read). Returns the definition as sent
    # ({"f" => [...], "d" => ...}).
    def define_type(name, fields, desc: nil)
      name = ::Asterism::Types.name!("define_type: name:", name)
      d = ::Asterism::Types.definition!(fields, desc)
      @types[name] = d
      s = @session
      app_queryable(s) if s
      d
    end

    # Another application's topics: {entry => {"t", "e", "u", "d", "ts"}}
    # (Asterism::Pubs.check has cleaned it; an entry is a topic's name, or
    # "<node>/@shared/<name>" / "@shared/<name>" for a shared one: place
    # tells which), {} when it answers without any,
    # nil when nobody answers in time. Waits like status_of.
    def pubs_of(node, app, timeout: nil, timeout_ms: nil)
      raw = app_profile_part(node, app, "pubs", timeout, timeout_ms)
      return nil if raw.nil?
      ::Asterism::Pubs.check(raw.key?("pubs") ? raw["pubs"] : {}, node.to_s)
    end

    # Another application's own types: {name => {"f" => [...], "d" => ...}}
    # (Asterism::Types.check), {} when it answers without any, nil when
    # nobody answers in time. Waits like status_of.
    def types_of(node, app, timeout: nil, timeout_ms: nil)
      raw = app_profile_part(node, app, "types", timeout, timeout_ms)
      return nil if raw.nil?
      ::Asterism::Types.check(raw.key?("types") ? raw["types"] : {})
    end

    # The applications that declare a shared key, from their @pubs: path is
    # "@shared/<name>" or "<node>/@shared/<name>" (node may be *, any node).
    # Returns {"<node>/<app>" => declaration} (cleaned as pubs_of does; this
    # application's own among them), {} when nobody declares it. Asks every
    # application's profile (of that node, for a node's place) at once and
    # waits for the answers until timeout: (seconds, 2.0 by default) or the
    # query ends. Raises ArgumentError for a path that is not a shared key and
    # Disconnected when not connected.
    def publishers_of(path, timeout: nil, timeout_ms: nil)
      p = path.to_s
      star = p.start_with?("*/")
      pl = ::Asterism::Pubs.place(star ? "x#{p[1, p.size - 1]}" : p)
      if pl.nil? || pl[0].nil?
        raise ArgumentError, "publishers_of: expected @shared/<name> or <node>/@shared/<name>, got #{path.inspect}"
      end
      node = pl[0] == :node && !star ? pl[1] : nil
      ms = ::Asterism.time_ms("Connection#publishers_of", timeout, timeout_ms, nil, ::Asterism::DEFAULT_TIMEOUT_MS)
      out = {}
      add = lambda do |n, a, pubs|
        return if pubs.nil?
        pubs.each do |entry, d|
          q = ::Asterism::Pubs.place(entry)
          next if q.nil? || q[0] != pl[0] || q[2] != pl[2]
          next if q[0] == :node && node && q[1] != node
          out["#{n}/#{a}"] = d
        end
      end
      add.call(@node_id, @app, ::Asterism::Pubs.check(pubs_hash, @node_id)) if @session
      g = pubs_get(node, ms)
      deadline = ::Asterism.now_ms + ms
      wait_until do
        ended = g.done?
        g.each_reply.each do |r|
          parts = r[0].to_s.split("/")
          next unless parts.size == 4 && parts[0] == ::Asterism::ROOT
          raw = ::Asterism::Codec.unpack(r[1])
          next unless raw.is_a?(Hash)
          add.call(parts[1], parts[2], ::Asterism::Pubs.check(raw["pubs"], parts[1]))
        end
        ended || ::Asterism.now_ms >= deadline || !connected?
      end
      out
    end

    # @api private
    def pubs_get(node, ms)
      session!.get("#{::Asterism::ROOT}/#{node || '*'}/*/#{::Asterism::Profile::KEY}", timeout_ms: ms, params: "pubs")
    rescue ::Asterism::Zenoh::Error => e
      lost_if_closed(e.message)
      raise ::Asterism::Disconnected, e.message
    end

    # The declaration of the topic a value came on, as its sender declared
    # it (info: the Asterism::SampleInfo of the value): the sender's entry
    # for that key in its @pubs ({"t", "e", "u", "d", "ts"}). On a shared
    # key every sender declares the key with its own declaration, so this
    # asks the sender (info.from). nil when the sender is not known, does not
    # answer, or does not declare the key. Waits like pubs_of.
    def declaration_of(info, timeout: nil, timeout_ms: nil)
      got = sender_parts(info, "pubs", timeout, timeout_ms)
      got ? got[0] : nil
    end

    # The type of the values on a key as their sender declared it (info: a
    # SampleInfo): a built-in type's number, or for an application type
    # [name, definition] with the definition from the sender's own types
    # ({"f" => [...], "d" => ...}; nil when it does not tell it). Two senders
    # on a shared key may give the same type name different definitions;
    # each value is read with its own sender's. nil when there is no type
    # or the sender does not answer. Waits like types_of (one query).
    def type_of(info, timeout: nil, timeout_ms: nil)
      got = sender_parts(info, "pubs;types", timeout, timeout_ms)
      return nil if got.nil?
      t = got[0]["t"]
      return t unless t.is_a?(String)
      types = got[1] || {}
      [t, types[t]]
    end

    # [the sender's declaration of info's key, the sender's types], or nil.
    # @api private
    def sender_parts(info, parts, timeout, timeout_ms)
      from = info.from
      return nil if from.nil?
      cut = from.index("/")
      n = from[0, cut]
      a = from[cut + 1, from.size - cut - 1]
      raw = app_profile_part(n, a, parts, timeout, timeout_ms)
      return nil if raw.nil?
      pubs = ::Asterism::Pubs.check(raw["pubs"], n) || {}
      entry = info.shared ? info.path : info.name
      d = pubs[entry]
      return nil if d.nil?
      [d, ::Asterism::Types.check(raw["types"])]
    end

    # @api private
    def app_profile_part(node, app, part, timeout, timeout_ms)
      f = app_profile_async(node, app, part, timeout, timeout_ms)
      begin
        raw = f.raw_value
      rescue ::Asterism::Disconnected
        raise
      rescue ::Asterism::Error
        return nil # no answer in time, or not MessagePack
      end
      raw.is_a?(Hash) ? raw : nil
    end

    # Subscribes to the values on asterism/<path> (path: <node>/<app>/<name>,
    # Zenoh wildcards allowed: * one chunk, ** any number; or a shared place,
    # <node>/@shared/<name> and @shared/<name>: "*/@shared/spectate/**",
    # "@shared/lobby/**". Wildcards do not reach into @shared: "**" and
    # "<node>/**" get only applications' own topics). The block gets
    # each value and an Asterism::SampleInfo (|v, info|; |v| is fine too):
    # the value decoded from MessagePack, or the bytes (a String) when it
    # came with an encoding. Blocks run from poll. This application's own
    # values do not come back to it (another connection of the program gets
    # them, as any other application). depth: the values kept between two
    # polls (Asterism::Zenoh::DEFAULT_DEPTH). Returns the
    # Asterism::Subscription (close it to stop); it ends with the connection.
    def subscribe(path, depth: nil, &blk)
      raise ArgumentError, "subscribe needs a block" unless blk
      s = session!
      p = path.to_s
      if p.empty? || p.start_with?("/") || p.end_with?("/")
        raise ArgumentError, "subscribe: expected <node>/<app>/<name> (wildcards allowed), got #{path.inspect}"
      end
      key = "#{::Asterism::ROOT}/#{p}"
      begin
        zs = depth.nil? ? s.subscribe(key) : s.subscribe(key, depth: depth)
      rescue ::Asterism::Zenoh::Error => e
        lost_if_closed(e.message)
        raise ::Asterism::Disconnected, e.message
      end
      sub = ::Asterism::Subscription.new(self, p, zs, blk)
      @subscriptions << sub
      sub
    end

    # Ends a subscription. True when it was open.
    def unsubscribe(sub)
      list = @subscriptions || []
      z = sub.zsub
      sub.closed!
      list.delete(sub)
      return false if z.nil?
      begin
        z.close
      rescue ::Asterism::Zenoh::Error
        nil
      end
      true
    end

    # Hands the values that came to the subscriptions' blocks (from poll).
    # @api private
    def deliver_samples
      list = @subscriptions
      return if list.nil? || list.empty?
      subs = list.dup
      i = 0
      while i < subs.size
        sub = subs[i]
        i += 1
        next if sub.closed?
        got = sub.take
        j = 0
        while j < got.size
          break if sub.closed?
          tell_sample(sub.block, got[j][0], got[j][1])
          j += 1
        end
      end
    end

    # One value for one block (CRuby routes what it raises to on_error).
    # @api private
    def tell_sample(blk, value, info)
      blk.call(value, info)
    end

    # Forgets the topics and subscriptions of a connection that ends (its
    # session closes their Zenoh entities).
    # @api private
    def release_data
      (@topics || {}).each_value { |t| t.closed! }
      @topics = {}
      (@subscriptions || []).each { |sub| sub.closed! }
      @subscriptions = []
      @pubs_put = nil
    end
  end
end
