# Data an application streams on its own keys (docs/protocol.md 9-11):
# topics it declares, the values it puts on them, and the subscriptions of
# the readers.
#
#   imu = Asterism.publish("imu", type: :vector3, unit: "m/s2", ts: true)
#   imu.put([0.1, 0.0, 9.8])                  # MessagePack, no encoding
#   cam = Asterism.publish("camera", type: :image, encoding: "image/jpeg")
#   cam.put(jpeg_bytes)                       # the bytes as they are
#   Asterism.define_type("mygame/board.strokes", [["pts", "int[]"], ["color", "str"]])
#
#   Asterism.subscribe("*/demo/imu") { |v, info| p [v, info.seq, info.lost] }
#   Asterism.pubs_of("linux", "demo")         # => {"imu" => {"t" => 2, ...}}
#
# Keys: a value goes on asterism/<node>/<app>/<name> (a declared Zenoh
# publisher: the key travels as a number), with no encoding when it is
# MessagePack and the encoding given at publish otherwise; the attachment
# is the MessagePack array [seq] or [seq, sender's time in ms since 1970]
# (ts: true). The declarations are put on asterism/<node>/<app>/@pubs each
# time they change, and answered by the application's own profile,
# asterism/<node>/<app>/@profile (status.rb): ?status, ?pubs, ?types.
#
# Subscription blocks run from Asterism.poll only, never from the polling
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

    # A received map of declarations, cleaned: the entries with a str name
    # whose declaration is a map, with the known keys that pass ("t" an int
    # above 0 or a str, "e" an int, "u" and "d" str, "ts" true). nil when
    # it is not a map.
    def self.check(h)
      return nil unless h.is_a?(Hash)
      out = {}
      h.each do |name, d|
        next unless name.is_a?(String) && !name.empty? && d.is_a?(Hash)
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
      d = check(::Asterism::Codec.unpack(payload))
      d ? [parts[1], parts[2], d] : nil
    end
  end

  # A declared topic (Asterism.publish). put sends a value; close withdraws
  # the declaration.
  class Topic
    # The sequence number goes back to 0 after this (below 2^31, so that
    # every board's Integer holds it).
    SEQ_MAX = 2147483647

    attr_reader :name, :key, :encoding

    # @api private
    def initialize(name, key, publisher, decl, encoding, ts)
      @name = name
      @key = key
      @publisher = publisher
      @decl = decl
      @encoding = encoding
      @ts = ts
      @seq = 0
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
      ::Asterism.topic_put(self, value)
    end

    def close
      ::Asterism.unpublish(self)
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
    def attachment
      if @ts
        ms = ::Asterism.wall_ms
        return ::MessagePack.pack(ms.nil? ? [@seq] : [@seq, ms])
      end
      ::MessagePack.pack([@seq])
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
    # key: the whole key (asterism/<node>/<app>/<name>); node, app, name:
    # its parts (name may hold "/"). seq: the sender's sequence number (nil
    # when the value came without one). time: the sender's time in ms since
    # 1970 (nil unless the topic sends it, ts: true). encoding: "msgpack"
    # for a MessagePack value, else the Zenoh encoding ("image/jpeg").
    # timestamp: the router's time (an Asterism::Zenoh::Timestamp), nil
    # when no router stamped it. lost: how many values of this key did not
    # come between the last one and this (0 for the first). restarted:
    # true when the number went back (the sender connected again or
    # started over); lost then counts the values of the new run before
    # this one.
    attr_reader :key, :node, :app, :name, :seq, :time, :encoding, :timestamp, :lost

    # @api private
    def initialize(key, node, app, name, seq, time, encoding, timestamp, lost, restarted)
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
    end

    def restarted?
      @restarted
    end

    def path
      "#{@node}/#{@app}/#{@name}"
    end

    def to_h
      { key: @key, node: @node, app: @app, name: @name, seq: @seq, time: @time, encoding: @encoding,
        timestamp: @timestamp, lost: @lost, restarted: @restarted }
    end

    def inspect
      "#<Asterism::SampleInfo #{path} seq=#{@seq.inspect} lost=#{@lost}#{@restarted ? ' restarted' : ''} " \
        "#{@encoding}>"
    end
  end

  # A subscription (Asterism.subscribe). close ends it.
  class Subscription
    # Sequence numbers are compared within half of their range: a step
    # forward smaller than this is a step, anything else a restart (the
    # numbers wrap at Topic::SEQ_MAX).
    HALF = 1073741824

    attr_reader :path

    # @api private
    def initialize(path, zsub, blk)
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
      ::Asterism.unsubscribe(self)
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
      node = parts[0]
      app = parts[1]
      name = parts.size > 2 ? parts[2, parts.size - 2].join("/") : nil
      seq = nil
      time = nil
      att = sm.attachment
      if att && !att.empty?
        a = ::Asterism::Codec.unpack(att)
        if a.is_a?(Array) && a[0].is_a?(Integer) && a[0] >= 0 && a[0] <= Topic::SEQ_MAX
          seq = a[0]
          time = a[1] if a[1].is_a?(Integer)
        end
      end
      lost = 0
      restarted = false
      unless seq.nil?
        prev = @last[key]
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
        @last[key] = seq
      end
      @received += 1
      [value, ::Asterism::SampleInfo.new(key, node, app, name, seq, time, enc, sm.timestamp, lost, restarted)]
    end
  end

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
  def self.publish(name, type: nil, unit: nil, desc: nil, ts: false, encoding: nil)
    s = session!
    name = check_topic_name(name)
    decl = {}
    t = Types.topic_type!(type)
    decl["t"] = t unless t.nil?
    enc = nil
    unless encoding.nil?
      enc = encoding.to_s
      id = Pubs.encoding_id(enc)
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
      raise ArgumentError, "unit: at most #{Pubs::UNIT_MAX} bytes" if unit.bytesize > Pubs::UNIT_MAX
      decl["u"] = unit unless unit.empty?
    end
    unless desc.nil?
      raise ArgumentError, "desc: expects a String, got #{desc.class}" unless desc.is_a?(String)
      raise ArgumentError, "desc: at most #{DOC_MAX} bytes" if desc.bytesize > DOC_MAX
      decl["d"] = desc unless desc.empty?
    end
    raise ArgumentError, "ts: expects true or false" unless ts == true || ts == false
    decl["ts"] = true if ts
    @topics ||= {}
    old = @topics[name] # replaced in place: the order of @pubs stays
    close_topic(old) if old
    key = "#{ROOT}/#{@node}/#{@app}/#{name}"
    begin
      zp = enc ? s.publisher(key, encoding: enc) : s.publisher(key)
    rescue Asterism::Zenoh::Error
      if old
        @topics.delete(name)
        tell_pubs(false)
      end
      raise
    end
    topic = Topic.new(name, key, zp, decl, enc, ts)
    @topics[name] = topic
    app_queryable(s)
    tell_pubs(false)
    topic
  rescue Asterism::Zenoh::Error => e
    lost_if_closed(e.message)
    raise Disconnected, e.message
  end

  # Withdraws a topic (a Topic, or its name): its declaration leaves
  # @pubs. True when there was one.
  def self.unpublish(topic)
    tbl = @topics || {}
    name = topic.is_a?(Topic) ? topic.name : topic.to_s
    cur = tbl[name]
    if cur.nil? || (topic.is_a?(Topic) && !cur.equal?(topic))
      close_topic(topic) if topic.is_a?(Topic)
      return false
    end
    tbl.delete(name)
    close_topic(cur)
    tell_pubs(false)
    true
  end

  # The names of this application's topics.
  def self.published
    @topics ? @topics.keys : []
  end

  # @api private
  def self.close_topic(topic)
    zp = topic.publisher
    topic.closed!
    zp.close if zp
  rescue Asterism::Zenoh::Error
    nil
  end

  # @api private
  def self.topic_put(topic, value)
    zp = topic.publisher
    raise Disconnected, "topic #{topic.name} is closed" if zp.nil?
    if topic.encoding
      raise ArgumentError, "topic #{topic.name} (#{topic.encoding}): put expects the bytes, a String" unless value.is_a?(String)
      bytes = value
    else
      bytes = Codec.pack(value)
    end
    begin
      zp.put(bytes, attachment: topic.attachment)
    rescue Asterism::Zenoh::Error => e
      lost_if_closed(e.message)
      raise Disconnected, e.message
    end
    topic.advance
    nil
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

  # The declarations as sent: {name => {"t", "e", "u", "d", "ts"}}.
  # @api private
  def self.pubs_hash
    h = {}
    (@topics || {}).each { |name, t| h[name] = t.decl_raw }
    h
  end

  # Puts the declarations on asterism/<node>/<app>/@pubs while connected:
  # when they changed since the last put of this connection, or always with
  # force (a connection that came back) once there were any.
  # @api private
  def self.tell_pubs(force)
    s = @session
    return unless s
    tbl = @topics || {}
    return if tbl.empty? && @pubs_put.nil?
    bytes = Codec.pack(pubs_hash)
    return if !force && !@pubs_put.nil? && @pubs_put == bytes
    s.put("#{ROOT}/#{@node}/#{@app}/#{Pubs::KEY}", bytes)
    @pubs_put = bytes
  rescue Asterism::Zenoh::Error
    nil # the next poll notices a lost connection
  end

  # The sender's time: milliseconds since 1970 (nil where there is no
  # clock of the day).
  # @api private
  def self.wall_ms
    return nil unless Object.const_defined?(:Time)
    t = Time.now
    t.to_i * 1000 + t.usec / 1000
  end

  # Defines an application type (docs/protocol.md 10), told to the readers
  # by asterism/<node>/<app>/@profile?types. name: a String
  # ("mygame/board.strokes"); fields: [[name, type], ...], each type a
  # built-in one (its number, or its name: "vector3", :vector3), a basic
  # one ("int", "float", "str", "bin", "bool") or another application
  # type's name, with "[]" at the end for an array ("vector3[]", "int[]",
  # "mygame/point[]"), repeated for arrays of arrays ("int[][]"); "any"
  # for a value of any shape; names are sent as written. desc: a text. Defining
  # a name again replaces it. Kept across connect and close. Returns the
  # definition as sent ({"f" => [...], "d" => ...}).
  def self.define_type(name, fields, desc: nil)
    name = Types.name!("define_type: name:", name)
    d = Types.definition!(fields, desc)
    (@types ||= {})[name] = d
    s = @session
    app_queryable(s) if s
    d
  end

  # Another application's topics: {name => {"t", "e", "u", "d", "ts"}}
  # (Asterism::Pubs.check has cleaned it), {} when it answers without any,
  # nil when nobody answers in time. Waits like status_of.
  def self.pubs_of(node, app, timeout: nil, timeout_ms: nil)
    raw = app_profile_part(node, app, "pubs", timeout, timeout_ms)
    return nil if raw.nil?
    Pubs.check(raw.key?("pubs") ? raw["pubs"] : {})
  end

  # Another application's own types: {name => {"f" => [...], "d" => ...}}
  # (Asterism::Types.check), {} when it answers without any, nil when
  # nobody answers in time. Waits like status_of.
  def self.types_of(node, app, timeout: nil, timeout_ms: nil)
    raw = app_profile_part(node, app, "types", timeout, timeout_ms)
    return nil if raw.nil?
    Types.check(raw.key?("types") ? raw["types"] : {})
  end

  # @api private
  def self.app_profile_part(node, app, part, timeout, timeout_ms)
    f = app_profile_async(node, app, part, timeout, timeout_ms)
    begin
      raw = f.raw_value
    rescue Disconnected
      raise
    rescue Error
      return nil # no answer in time, or not MessagePack
    end
    raw.is_a?(Hash) ? raw : nil
  end

  # Subscribes to the values on asterism/<path> (path: <node>/<app>/<name>,
  # Zenoh wildcards allowed: * one chunk, ** any number). The block gets
  # each value and an Asterism::SampleInfo (|v, info|; |v| is fine too):
  # the value decoded from MessagePack, or the bytes (a String) when it
  # came with an encoding. Blocks run from Asterism.poll. This
  # application's own values do not come back to it. depth: the values
  # kept between two polls (Asterism::Zenoh::DEFAULT_DEPTH). Returns the
  # Asterism::Subscription (close it to stop); it ends with the connection.
  def self.subscribe(path, depth: nil, &blk)
    raise ArgumentError, "subscribe needs a block" unless blk
    s = session!
    p = path.to_s
    if p.empty? || p.start_with?("/") || p.end_with?("/")
      raise ArgumentError, "subscribe: expected <node>/<app>/<name> (wildcards allowed), got #{path.inspect}"
    end
    key = "#{ROOT}/#{p}"
    begin
      zs = depth.nil? ? s.subscribe(key) : s.subscribe(key, depth: depth)
    rescue Asterism::Zenoh::Error => e
      lost_if_closed(e.message)
      raise Disconnected, e.message
    end
    sub = Subscription.new(p, zs, blk)
    (@subscriptions ||= []) << sub
    sub
  end

  # Ends a subscription. True when it was open.
  def self.unsubscribe(sub)
    list = @subscriptions || []
    z = sub.zsub
    sub.closed!
    list.delete(sub)
    return false if z.nil?
    begin
      z.close
    rescue Asterism::Zenoh::Error
      nil
    end
    true
  end

  # Hands the values that came to the subscriptions' blocks (from poll).
  # @api private
  def self.deliver_samples
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
  def self.tell_sample(blk, value, info)
    blk.call(value, info)
  end

  # Forgets the topics and subscriptions of a connection that ends (its
  # session closes their Zenoh entities).
  # @api private
  def self.release_data
    (@topics || {}).each_value { |t| t.closed! }
    @topics = {}
    (@subscriptions || []).each { |sub| sub.closed! }
    @subscriptions = []
    @pubs_put = nil
  end
end
