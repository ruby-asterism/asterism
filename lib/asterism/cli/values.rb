# The values the applications put on their own keys (their topics,
# asterism/<node>/<app>/<name>, docs/protocol.md 9: a game table's state, a
# log, a camera's pictures), for `asterism object get / echo` and the MCP
# bridge's asterism_values. A put is not kept anywhere and a get has no
# answer for it (an application's queryable answers only the key shapes of
# 4.3), so the latest value is only what a subscriber received and kept:
# Values::Store keeps it, a key at a time, within limits.
#
# Each value is read with what came along (9.2, 9.3): its encoding (none:
# MessagePack; else the bytes as they are, image/jpeg) and the attachment
# [seq] or [seq, sender's ms], from which Values::Seq counts the values
# lost between two of a key. This reads the Zenoh samples itself rather
# than through Connection#subscribe: it shows what is on the wire, the
# payload's size and a value that is not MessagePack too (as text or its
# size), where Connection#subscribe leaves those out.
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

      # Zenoh's default encoding: what a MessagePack value goes with (it is
      # sent with none).
      DEFAULT_ENCODING = "zenoh/bytes"
      # The encodings whose bytes are JSON text, and those that are text.
      JSON_ENCODINGS = %w[application/json text/json application/json-seq application/json-patch+json
                          text/json5].freeze
      TEXT_ENCODINGS = %w[application/yaml application/xml application/sql application/jsonpath
                          application/jwt].freeze
      # The encodings an MCP client takes as an image (MCP's image content).
      IMAGE_ENCODINGS = %w[image/png image/jpeg image/gif image/webp].freeze

      # [value, format] of a payload. No encoding (or Zenoh's default):
      # MessagePack (Asterism's own, 3.1), format "msgpack"; else, for a
      # sender that does not follow the protocol, JSON text ("json"), UTF-8
      # text ("text"), else "(n bytes)" ("bytes"). With an encoding (9.2):
      # format is the encoding without its schema ("image/jpeg"), and the
      # value JSON for the JSON ones, the text for text ones, else
      # "(n bytes)". The value is what JSON can hold (bytes inside as
      # "(n bytes)").
      def decode(payload, encoding = nil)
        bytes = payload.to_s.b
        enc = encoding.to_s
        enc = "" if enc == DEFAULT_ENCODING || enc.start_with?("#{DEFAULT_ENCODING};")
        return decode_encoded(bytes, enc) unless enc.empty?
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

      # [value, format] of the bytes of a value with an encoding (enc, not
      # Zenoh's default).
      def decode_encoded(bytes, enc)
        name = enc.split(";", 2)[0]
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        texty = name.start_with?("text/") || JSON_ENCODINGS.include?(name) || TEXT_ENCODINGS.include?(name)
        return ["(#{bytes.bytesize} bytes)", name] unless texty && text.valid_encoding?
        if JSON_ENCODINGS.include?(name)
          begin
            return [json_safe(JSON.parse(text)), name]
          rescue JSON::ParserError
            nil
          end
        end
        [text, name]
      end

      # [seq, sender's ms] of an attachment (9.3), nil for each part that
      # is not there (no attachment, or not of that shape).
      def attachment(att)
        return [nil, nil] if att.nil? || att.empty?
        a = begin
          ::MessagePack.unpack(att.to_s.b)
        rescue StandardError
          nil
        end
        return [nil, nil] unless a.is_a?(Array) && a[0].is_a?(Integer) && a[0] >= 0 && a[0] <= ::Asterism::Topic::SEQ_MAX
        [a[0], a[1].is_a?(Integer) ? a[1] : nil]
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
      # (without asterism/), "t", "bytes", "format", "value"} and, from the
      # attachment, "seq", "sent" (the sender's time) and, when seq (a
      # Values::Seq) is given, "lost" (when some were) and "restarted"
      # (the sender started its numbers again).
      def entry(key, payload, t = Time.now, encoding: nil, attachment: nil, seq: nil)
        value, format = decode(payload, encoding)
        e = { "key" => key.delete_prefix(PREFIX), "t" => time(t), "bytes" => payload.to_s.bytesize,
              "format" => format, "value" => value }
        e.merge!(numbers(e["key"], attachment, seq))
      end

      # {"seq", "sent", "lost", "restarted"} of an attachment, each when
      # there is one.
      def numbers(key, attachment, seq = nil)
        n, ms = Values.attachment(attachment)
        out = {}
        return out if n.nil?
        out["seq"] = n
        out["sent"] = time(Time.at(ms / 1000, ms % 1000, :millisecond)) if ms
        if seq
          lost, restarted = seq.see(key, n)
          out["lost"] = lost if lost.positive?
          out["restarted"] = true if restarted
        end
        out
      end

      # The sequence numbers seen, key by key: how many values were lost
      # before each (docs/protocol.md 9.4, as Asterism::Subscription
      # reads them). Thread safe.
      class Seq
        def initialize
          @last = {}
          @lock = Mutex.new
        end

        # [lost, restarted] of number n on key: lost 0 for the first one;
        # a step back (or one of half the range or more) is a sender that
        # started again (lost: n, the values before it in its new run).
        def see(key, n)
          @lock.synchronize do
            prev = @last[key]
            @last[key] = n
            return [0, false] if prev.nil?
            d = n - prev
            d += ::Asterism::Topic::SEQ_MAX + 1 if d.negative?
            return [d - 1, false] if d.positive? && d < ::Asterism::Subscription::HALF
            [n, true]
          end
        end
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
        # The most images an answer hands over (answer_images).
        MAX_IMAGES = 4

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
          @seq = Seq.new
          @lost = {} # key => the values lost on it since the start
          @lock = Mutex.new
          @cond = ConditionVariable.new
        end

        # A put received (key with or without asterism/), with its encoding
        # and attachment when it had them. An image (IMAGE_ENCODINGS) kept
        # keeps its bytes too, for answer_images.
        def put(key, payload, encoding: nil, attachment: nil)
          key = key.delete_prefix(PREFIX)
          payload = payload.to_s
          size = payload.bytesize
          rec = if size > @max_bytes
                  { "value" => "(#{size} bytes: too large to keep)", "format" => "dropped", "kept" => false }
                else
                  v, f = Values.decode(payload, encoding)
                  r = { "value" => v, "format" => f }
                  r["raw"] = payload.b if IMAGE_ENCODINGS.include?(f)
                  r
                end
          rec.merge!("key" => key, "bytes" => size, "t" => @now.call, "mono" => @clock.call, "left" => false)
          num = Values.numbers(key, attachment, @seq)
          rec["seq"] = num["seq"] if num["seq"]
          rec["sent"] = num["sent"] if num["sent"]
          @lock.synchronize do
            lost = (@lost[key] || 0) + num["lost"].to_i
            @lost[key] = lost
            rec["lost"] = lost if lost.positive?
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
        # "age_s", "app", "bytes", "format", "value"(, "seq", "sent", "lost",
        # "truncated")}]} (seq and sent from the attachment of the latest
        # value, lost the values missed on the key since the start), with
        # "more" when more keys matched than an answer lists, "forgotten"
        # when the limits made it forget keys, and "note" when nothing came.
        def answer(pattern = "**", wait: 0)
          answer_images(pattern, wait: wait, images: 0)[0]
        end

        # [answer, images]: the answer, and the bytes of at most images
        # values that are images (IMAGE_ENCODINGS) among those it lists,
        # [[format, bytes], ...]; each such value's entry says "image" =>
        # its place in that list (0 first).
        def answer_images(pattern = "**", wait: 0, images: MAX_IMAGES)
          Values.check_pattern!(pattern)
          wait = wait.to_f.clamp(0, MAX_WAIT)
          recs = match(pattern, wait: wait)
          pics = []
          now = @clock.call
          alive = {}
          out = { "since" => Values.time(@since) }
          out["values"] = recs.first(MAX_ANSWER).map do |r|
            app = r["key"].split("/")[0, 2].join("/")
            here = alive.key?(app) ? alive[app] : (alive[app] = @alive.call(app) ? true : false)
            h = { "key" => r["key"], "t" => Values.time(r["t"]), "age_s" => (now - r["mono"]).round(1),
                  "app" => here ? (r["left"] ? "restarted" : "alive") : "gone", "bytes" => r["bytes"],
                  "format" => r["format"] }
            %w[seq sent lost].each { |k| h[k] = r[k] if r.key?(k) }
            if r["raw"] && pics.size < images
              h["image"] = pics.size
              pics << [r["format"], r["raw"]]
            end
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
          [out, pics]
        end
      end
    end
  end
end
