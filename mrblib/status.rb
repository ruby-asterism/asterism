# An application's status: a small Hash of its own that changes while it
# runs (how many tables are open, who is seated, a battery level), told by
# the application itself.
#
#   net.status(tables: 3, humans: 2)           # sets those fields, keeps the others
#   net.status({ "mahjong1" => {...} })        # the whole status (a Hash)
#   net.status                                 # => {"tables" => 3, ...} or nil
#   net.status_of("games", "games")            # another application's, or nil
#
# The status is one part of the application's own profile,
# asterism/<node>/<app>/@profile (docs/protocol.md 8): the application
# answers queries there with {"status" => ..., "pubs" => ...} (the topics,
# topic.rb), or with the one part a query names (?status, ?pubs, ?types).
# It puts the status on asterism/<node>/<app>/@status when it changes (only
# then: the same status again puts nothing) and after a lost
# connection comes back. An application with neither a status, a topic nor
# a type of its own declares nothing there and answers nothing.
#
# The value is a MessagePack map with str keys; the values are any values
# of the protocol nested at most MAX_DEPTH levels below the map, and the
# whole map packs into MAX_BYTES at most. It is not the node's profile
# (profile.rb): that says once what a node is; a status changes.
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

    # The checks of Connection#status: a copy with String keys, or
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

  # The parts a query of an application's profile asks for: its
  # parameters split on ";", each part's name before "="; the known names
  # are status, pubs and types. None of them: status and pubs.
  # @api private
  def self.app_profile_parts(params)
    want = []
    unless params.nil? || params.empty?
      params.split(";").each do |pair|
        n = pair.split("=")[0].to_s
        want << n if (n == "status" || n == "pubs" || n == "types") && !want.include?(n)
      end
    end
    want.empty? ? ["status", "pubs"] : want
  end

  class Connection
    # This application's status. With a Hash, it is the whole status; with
    # keywords, those fields change (nil removes one) and the others stay;
    # both: the keywords on top of the Hash. Returns the status. Without
    # arguments, returns it (nil when none was set). Raises ArgumentError for
    # a status it does not accept (see Asterism::Status).
    #
    # The status is the connection's (each connection is one application).
    # A change is put on asterism/<node>/<app>/@status; setting the same
    # status again puts nothing. After close it is still there to read and
    # set, but goes nowhere.
    def status(h = nil, **fields)
      if h.nil? && fields.empty?
        return @status ? @status.dup : nil
      end
      base = h.nil? ? (@status ? @status.dup : {}) : ::Asterism::Status.check!(h)
      fields.each do |k, v|
        if v.nil?
          base.delete(k.to_s)
        else
          base[k.to_s] = v
        end
      end
      @status = ::Asterism::Status.check!(base)
      tell_status(false)
      @status.dup
    end

    # Another application's status (Asterism::Status.check has cleaned it),
    # or nil when it does not answer in time or has no status (an
    # application that is gone, one without a status). timeout: in seconds
    # (or timeout_ms:), 2.0 by default. Waits like a call (polling, answering
    # calls meanwhile); raises Disconnected when not connected. This
    # application's own status comes without the network.
    def status_of(node, app, timeout: nil, timeout_ms: nil)
      raw = app_profile_part(node, app, "status", timeout, timeout_ms)
      raw.nil? ? nil : ::Asterism::Status.check(raw["status"])
    end

    # A query of asterism/<node>/<app>/@profile (part: "status", "pubs",
    # "types", or nil for the default reply) -> a Future.
    # @api private
    def app_profile_async(node, app, part, timeout, timeout_ms)
      node = ::Asterism.check_name("node", node)
      app = ::Asterism.check_name("app", app)
      ms = ::Asterism.time_ms("Connection##{part || 'profile'}_of", timeout, timeout_ms, nil,
                              ::Asterism::DEFAULT_TIMEOUT_MS)
      path = "#{node}/#{app}/#{::Asterism::Profile::KEY}"
      what = part || "profile"
      if @session && node == @node_id && app == @app
        return ::Asterism::Future.answered(path, what, ::Asterism::Codec.pack(app_profile_hash(part)))
      end
      begin
        g = session!.get("#{::Asterism::ROOT}/#{path}", timeout_ms: ms, params: part)
      rescue ::Asterism::Zenoh::Error => e
        lost_if_closed(e.message)
        raise ::Asterism::Disconnected, e.message
      end
      ::Asterism::Future.new(self, path, what, g, ::Asterism.now_ms + ms, ms)
    end

    # The applications alive now ("<node>/<app>", from their liveliness
    # tokens; this one included, and the program's other connections as
    # the applications they are) whose path matches the pattern (* is one
    # chunk, ** any number).
    def apps(pattern = "*/*")
      list = []
      return list unless @session
      own = "#{@node_id}/#{@app}"
      list << own if ::Asterism.glob?(pattern, own)
      @apps.each_key { |path| list << path if path != own && ::Asterism.glob?(pattern, path) }
      list
    end

    # Puts the status on asterism/<node>/<app>/@status while connected: when
    # it changed since the last put of this connection, or always with force
    # (a connection that came back). Declares the application's profile
    # queryable with the first put.
    # @api private
    def tell_status(force)
      s = @session
      return unless s && @status
      bytes = ::Asterism::Codec.pack(@status)
      return if !force && !@status_put.nil? && @status_put == bytes
      app_queryable(s)
      s.put("#{::Asterism::ROOT}/#{@node_id}/#{@app}/#{::Asterism::Status::KEY}", bytes)
      @status_put = bytes
    rescue ::Asterism::Zenoh::Error
      nil # the next poll notices a lost connection
    end

    # Declares the queryable asterism/<node>/<app>/@profile once this
    # application has something to tell there (a status, a topic, a type):
    # an application with none of them declares nothing (and costs nothing).
    # @api private
    def app_queryable(s)
      @app_queryable ||= s.queryable("#{::Asterism::ROOT}/#{@node_id}/#{@app}/#{::Asterism::Profile::KEY}", depth: 4)
    end

    # The reply of asterism/<node>/<app>/@profile: the parts asked for
    # (part: one name, or the parameters of a query), each left out when
    # this application has none.
    # @api private
    def app_profile_hash(params)
      h = {}
      ::Asterism.app_profile_parts(params).each do |n|
        if n == "status"
          h["status"] = @status if @status
        elsif n == "pubs"
          h["pubs"] = pubs_hash if @topics && !@topics.empty?
        elsif @types && !@types.empty?
          h["types"] = @types
        end
      end
      h
    end

    # @api private
    def answer_app_profile
      qa = @app_queryable
      return unless qa && qa.pending > 0
      queries = qa.each_pending
      i = 0
      while i < queries.size
        q = queries[i]
        i += 1
        begin
          q.reply("#{::Asterism::ROOT}/#{@node_id}/#{@app}/#{::Asterism::Profile::KEY}",
                  ::Asterism::Codec.pack(app_profile_hash(q.params)))
        ensure
          begin
            q.finish
          rescue ::Asterism::Zenoh::Error
            # the session went away meanwhile
          end
        end
      end
    end
  end
end
