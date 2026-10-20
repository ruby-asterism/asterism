# The values the applications put on their own keys
# (asterism/<node>/<app>/<object>/<more>, docs/protocol.md 2.2: a game
# table's state, a log), for `asterism object get / echo` and the MCP
# bridge's asterism_values. A put is not kept anywhere and a get has no
# answer for it (an application's queryable answers only the key shapes of
# 4.3), so the latest value is only what a subscriber received and kept:
# Values::Store keeps it, a key at a time, within limits.
require "json"

module Asterism
  class CLI
    module Values
      PREFIX = "asterism/"
      # Characters a part of a key cannot have (2.1); * and ** are whole
      # parts.
      BAD = /[*$?#]/

      module_function

      # The pattern (node/app/object/more, * and ** as whole parts) checked;
      # ArgumentError otherwise.
      def check_pattern!(pattern)
        parts = pattern.to_s.split("/", -1)
        bad = parts.empty? || parts.any? do |p|
          p.empty? || p.start_with?("@") || (p.match?(BAD) && !%w[* **].include?(p))
        end
        raise ArgumentError, "#{pattern.inspect}: a key's parts are names, * (one part) or ** (any parts)" if bad
        pattern
      end

      # The Zenoh key expression of a pattern.
      def key_expr(pattern)
        "#{PREFIX}#{pattern}"
      end

      def match?(pattern, key)
        ::Asterism.glob?(pattern, key)
      end

      # [value, format] of a payload: MessagePack (Asterism's own, 3.1);
      # else JSON text; else UTF-8 text; else "(n bytes)". The value is
      # what JSON can hold (bytes inside as "(n bytes)").
      def decode(payload)
        bytes = payload.to_s.b
        return [nil, "empty"] if bytes.empty?
        begin
          return [json_safe(::MessagePack.unpack(bytes)), "msgpack"]
        rescue StandardError
          nil
        end
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        return ["(#{bytes.bytesize} bytes)", "bytes"] unless text.valid_encoding?
        begin
          [json_safe(JSON.parse(text)), "json"]
        rescue JSON::ParserError
          [text, "text"]
        end
      end

      def json_safe(v)
        case v
        when Hash then v.to_h { |k, x| [k.is_a?(String) ? k : k.to_s, json_safe(x)] }
        when Array then v.map { json_safe(_1) }
        when String then v.encoding == Encoding::BINARY && !v.ascii_only? ? "(#{v.bytesize} bytes)" : v
        when Float then v.finite? ? v : v.to_s
        when Integer, true, false, nil then v
        when Symbol then v.to_s
        else v.inspect
        end
      end

      def time(t)
        t.getutc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
      end

      # One put as the command line and the MCP tool show it: {"key"
      # (without asterism/), "t", "bytes", "format", "value"}.
      def entry(key, payload, t = Time.now)
        value, format = decode(payload)
        { "key" => key.delete_prefix(PREFIX), "t" => time(t), "bytes" => payload.to_s.bytesize,
          "format" => format, "value" => value }
      end

      # The latest put of each key, as received since it was made: at most
      # max_keys keys and max_total payload bytes (the key received
      # longest ago is forgotten first); a payload over max_bytes is kept
      # as its size only. Thread safe; wait blocks until a key matches.
      class Store
        MAX_KEYS = 1000
        MAX_BYTES = 256 * 1024
        MAX_TOTAL = 16 * 1024 * 1024
        # The JSON text of a value longer than this is cut in an answer.
        VALUE_CUT = 8192
        # The most keys an answer lists (the rest counted as "more").
        MAX_ANSWER = 100
        # The longest wait an answer may ask for (seconds).
        MAX_WAIT = 30

        attr_reader :since, :forgotten

        # alive: given "<node>/<app>", true when the application is on the
        # network now. clock: the monotonic seconds (for the tests).
        def initialize(max_keys: MAX_KEYS, max_bytes: MAX_BYTES, max_total: MAX_TOTAL, alive: nil,
                       clock: nil, now: nil)
          @max_keys = max_keys
          @max_bytes = max_bytes
          @max_total = max_total
          @alive = alive || ->(_app) { true }
          @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          @now = now || -> { Time.now }
          @since = @now.call
          @keys = {} # key => record, the oldest received first
          @total = 0
          @forgotten = 0
          @lock = Mutex.new
          @cond = ConditionVariable.new
        end

        # A put received (key with or without asterism/).
        def put(key, payload)
          key = key.delete_prefix(PREFIX)
          payload = payload.to_s
          size = payload.bytesize
          rec = if size > @max_bytes
                  { "value" => "(#{size} bytes: too large to keep)", "format" => "dropped", "kept" => false }
                else
                  v, f = Values.decode(payload)
                  { "value" => v, "format" => f }
                end
          rec.merge!("key" => key, "bytes" => size, "t" => @now.call, "mono" => @clock.call, "left" => false)
          @lock.synchronize do
            old = @keys.delete(key)
            @total -= old["kept"] == false ? 0 : old["bytes"] if old
            @keys[key] = rec
            @total += size unless rec["kept"] == false
            while @keys.size > @max_keys || (@total > @max_total && @keys.size > 1)
              _, gone = @keys.shift
              @total -= gone["bytes"] unless gone["kept"] == false
              @forgotten += 1
            end
            @cond.broadcast
          end
          self
        end

        # The application "<node>/<app>" left the network: its values are
        # from before (kept, marked).
        def left(app)
          prefix = "#{app}/"
          @lock.synchronize { @keys.each_value { |r| r["left"] = true if r["key"].start_with?(prefix) } }
          self
        end

        def size
          @lock.synchronize { @keys.size }
        end

        def keys
          @lock.synchronize { @keys.keys }
        end

        # The records whose keys match (sorted by key); with wait (seconds),
        # until one matches or the time is up.
        def match(pattern, wait: 0)
          deadline = @clock.call + wait.to_f
          @lock.synchronize do
            loop do
              got = @keys.values.select { Values.match?(pattern, _1["key"]) }
              return got.sort_by { _1["key"] } unless got.empty?
              left = deadline - @clock.call
              return [] if left <= 0
              @cond.wait(@lock, left)
            end
          end
        end

        # What asterism_values answers: {"since", "values" => [{"key", "t",
        # "age_s", "app", "bytes", "format", "value"(, "truncated")}]}, with
        # "more" when more keys matched than an answer lists, "forgotten"
        # when the limits made it forget keys, and "note" when nothing came.
        def answer(pattern = "**", wait: 0)
          Values.check_pattern!(pattern)
          wait = wait.to_f.clamp(0, MAX_WAIT)
          recs = match(pattern, wait: wait)
          now = @clock.call
          alive = {}
          out = { "since" => Values.time(@since) }
          out["values"] = recs.first(MAX_ANSWER).map do |r|
            app = r["key"].split("/")[0, 2].join("/")
            here = alive.key?(app) ? alive[app] : (alive[app] = @alive.call(app) ? true : false)
            h = { "key" => r["key"], "t" => Values.time(r["t"]), "age_s" => (now - r["mono"]).round(1),
                  "app" => here ? (r["left"] ? "restarted" : "alive") : "gone", "bytes" => r["bytes"],
                  "format" => r["format"] }
            text = JSON.generate(r["value"])
            if text.bytesize > VALUE_CUT
              h["value"] = "#{text.byteslice(0, VALUE_CUT).scrub('')}…"
              h["truncated"] = true
            else
              h["value"] = r["value"]
            end
            h["truncated"] = true if r["kept"] == false
            h
          end
          out["more"] = recs.size - MAX_ANSWER if recs.size > MAX_ANSWER
          out["forgotten"] = @forgotten if @forgotten.positive?
          if recs.empty?
            out["note"] = "nothing came for #{pattern}#{wait.positive? ? " in #{format('%g', wait)} s" : ''}: " \
                          "it has not been put since this server started (puts come only when a value " \
                          "changes), or the router does not let this server read it"
          end
          out
        end
      end
    end
  end
end
