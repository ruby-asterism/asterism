# An application's status: a small Hash of its own that changes while it
# runs (how many tables are open, who is seated, a battery level), told by
# the application itself.
#
#   Asterism.status(tables: 3, humans: 2)      # sets those fields, keeps the others
#   Asterism.status({ "mahjong1" => {...} })   # the whole status (a Hash)
#   Asterism.status                            # => {"tables" => 3, ...} or nil
#   Asterism.status_of("games", "games")       # another application's, or nil
#
# Key: asterism/<node>/<app>/@status (docs/protocol.md 8). The application
# answers queries there with its status, and puts it on the same key when
# it changes (only then: the same status again puts nothing), at connect
# and after a lost connection comes back. An application that never set a
# status declares nothing there and answers nothing.
#
# The value is a MessagePack map with str keys; the values are any values
# of the protocol nested at most MAX_DEPTH levels below the map, and the
# whole map packs into MAX_BYTES at most. It is not the profile
# (profile.rb): a profile says once what a node is; a status changes.
module Asterism
  module Status
    KEY = "@status"
    MAX_BYTES = 1024  # the packed map
    MAX_DEPTH = 4     # levels of arrays and maps below the map

    # A received status, cleaned: the entries with a non-empty str key; nil
    # when it is not a map or packs into more than MAX_BYTES.
    def self.check(h)
      return nil unless h.is_a?(Hash)
      out = {}
      h.each { |k, v| out[k] = v if k.is_a?(String) && !k.empty? }
      begin
        return nil if ::MessagePack.pack(out).bytesize > MAX_BYTES
      rescue
        return nil
      end
      out
    end

    # [node, app, status] of a notice put on asterism/<node>/<app>/@status
    # (key and payload as a subscriber gets them), or nil when it is not one.
    def self.parse(key, payload)
      parts = key.to_s.split("/")
      return nil unless parts.size == 4 && parts[0] == ROOT && parts[3] == KEY
      st = check(Codec.unpack(payload))
      st ? [parts[1], parts[2], st] : nil
    end

    # The checks of Asterism.status: a copy with String keys, or
    # ArgumentError with the reason.
    # @api private
    def self.check!(h)
      raise ArgumentError, "status: expected a Hash, got #{h.class}" unless h.is_a?(Hash)
      out = {}
      h.each do |k, v|
        key = k.is_a?(Symbol) ? k.to_s : k
        unless key.is_a?(String) && !key.empty?
          raise ArgumentError, "status: the keys are Strings or Symbols (not empty), got #{k.inspect}"
        end
        raise ArgumentError, "status #{key}: nested deeper than #{MAX_DEPTH} levels" if too_deep?(v, 1)
        begin
          out[key] = Codec.check(v)
        rescue EncodeError => e
          raise ArgumentError, "status #{key}: #{e.message}"
        end
      end
      n = Codec.pack(out).bytesize
      raise ArgumentError, "status: #{n} bytes packed (#{MAX_BYTES} at most)" if n > MAX_BYTES
      out
    end

    # @api private
    def self.too_deep?(v, level)
      if v.is_a?(Array) || v.is_a?(Hash)
        return true if level > MAX_DEPTH
        if v.is_a?(Array)
          v.each { |e| return true if too_deep?(e, level + 1) }
        else
          v.each { |k, e| return true if too_deep?(k, level + 1) || too_deep?(e, level + 1) }
        end
      end
      false
    end
  end

  # This application's status. With a Hash, it is the whole status; with
  # keywords, those fields change (nil removes one) and the others stay;
  # both: the keywords on top of the Hash. Returns the status. Without
  # arguments, returns it (nil when none was set). Raises ArgumentError for
  # a status it does not accept (see Asterism::Status).
  #
  # Kept across connect and close (it belongs to the process, or the VM on
  # a board). While connected, a change is put on asterism/<node>/<app>/@status;
  # setting the same status again puts nothing.
  def self.status(h = nil, **fields)
    if h.nil? && fields.empty?
      return @status ? @status.dup : nil
    end
    base = h.nil? ? (@status ? @status.dup : {}) : Status.check!(h)
    fields.each do |k, v|
      if v.nil?
        base.delete(k.to_s)
      else
        base[k.to_s] = v
      end
    end
    @status = Status.check!(base)
    tell_status(false)
    @status.dup
  end

  # Another application's status (Asterism::Status.check has cleaned it),
  # or nil when it does not answer in time (no status set, an older
  # version of Asterism, an application that is gone). timeout: in seconds
  # (or timeout_ms:), 2.0 by default. Waits like a call (polling, answering
  # calls meanwhile); raises Disconnected when not connected. This
  # application's own status comes without the network.
  def self.status_of(node, app, timeout: nil, timeout_ms: nil)
    f = status_async(node, app, timeout, timeout_ms)
    begin
      raw = f.raw_value
    rescue Disconnected
      raise
    rescue Error
      return nil # no answer in time, or not MessagePack
    end
    Status.check(raw)
  end

  # @api private
  def self.status_async(node, app, timeout, timeout_ms)
    node = check_name("node", node)
    app = check_name("app", app)
    ms = time_ms("Asterism.status_of", timeout, timeout_ms, nil, DEFAULT_TIMEOUT_MS)
    path = "#{node}/#{app}/#{Status::KEY}"
    if @session && node == @node && app == @app
      return Future.answered(path, "status", Codec.pack(@status)) if @status
      return Future.answered(path, "status", Codec.pack(nil))
    end
    begin
      g = session!.get("#{ROOT}/#{path}", timeout_ms: ms)
    rescue Asterism::Zenoh::Error => e
      lost_if_closed(e.message)
      raise Disconnected, e.message
    end
    Future.new(path, "status", g, now_ms + ms, ms)
  end

  # The applications alive now ("<node>/<app>", from their liveliness
  # tokens; this one included) whose path matches the pattern (* is one
  # chunk, ** any number).
  def self.apps(pattern = "*/*")
    list = []
    return list unless @session
    own = "#{@node}/#{@app}"
    list << own if glob?(pattern, own)
    @apps.each_key { |path| list << path if path != own && glob?(pattern, path) }
    list
  end

  # Puts the status on its key while connected: when it changed since the
  # last put of this connection, or always with force (a connection that
  # came back). Declares the status queryable with the first put.
  # @api private
  def self.tell_status(force)
    s = @session
    return unless s && @status
    bytes = Codec.pack(@status)
    return if !force && !@status_put.nil? && @status_put == bytes
    key = "#{ROOT}/#{@node}/#{@app}/#{Status::KEY}"
    @status_queryable ||= s.queryable(key, depth: 4)
    s.put(key, bytes)
    @status_put = bytes
  rescue Asterism::Zenoh::Error
    nil # the next poll notices a lost connection
  end

  # @api private
  def self.answer_status
    qa = @status_queryable
    return unless qa && qa.pending > 0
    queries = qa.each_pending
    i = 0
    while i < queries.size
      q = queries[i]
      i += 1
      begin
        q.reply("#{ROOT}/#{@node}/#{@app}/#{Status::KEY}", Codec.pack(@status || {}))
      ensure
        begin
          q.finish
        rescue Asterism::Zenoh::Error
          # the session went away meanwhile
        end
      end
    end
  end
end
