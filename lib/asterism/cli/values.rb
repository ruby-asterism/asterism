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
#
# The shared places (docs/protocol.md 17: asterism/<node>/@shared/<name>
# and asterism/@shared/<name>) are read too: a key there has no owner
# application, several applications may put on it, and each value names
# its sender ("<node>/<app>", the attachment's third element). A shared
# value is shown with its sender ("from"), its numbers are counted per
# key and sender, and Store keeps the latest value of each sender. As in
# Zenoh, * and ** never match a part that starts with @: a pattern names
# @shared itself (games/@shared/**, */@shared/spectate/**, @shared/**).
require "json"

module Asterism
  class CLI
    module Values
      PREFIX = "asterism/"
      # The part of a shared place's keys (docs/protocol.md 17).
      SHARED = "@shared"
      # Characters a part of a key cannot have (2.1); * and ** are whole
      # parts.
      BAD = /[*$?#]/

      module_function

      # The pattern (node/app/object/more, * and ** as whole parts; or a
      # shared place's node/@shared/name..., @shared/name...) checked;
      # ArgumentError otherwise.
      def check_pattern!(pattern)
        parts = pattern.to_s.split("/", -1)
        bad = parts.empty? || parts.each_with_index.any? do |p, i|
          next false if p == SHARED && (i.zero? || (i == 1 && parts[0] != SHARED))
          p.empty? || p.start_with?("@") || (p.match?(BAD) && !%w[* **].include?(p))
        end
        if bad
          raise ArgumentError, "#{pattern.inspect}: a key's parts are names, * (one part) or ** (any parts); " \
                               "a shared place's keys are node/@shared/... or @shared/..."
        end
        pattern
      end

      # The Zenoh key expression of a pattern.
      def key_expr(pattern)
        "#{PREFIX}#{pattern}"
      end

      # Whether key (without asterism/) matches pattern: * one part, ** any
      # parts, neither a part that starts with @ (verbatim, as Zenoh's).
      def match?(pattern, key)
        glob_parts?(pattern.split("/"), 0, key.split("/"), 0)
      end

      def glob_parts?(pat, i, parts, j)
        while i < pat.size
          if pat[i] == "**"
            k = j
            while k <= parts.size
              return true if glob_parts?(pat, i + 1, parts, k)
              break if k < parts.size && parts[k].start_with?("@")
              k += 1
            end
            return false
          end
          return false if j >= parts.size
          ok = pat[i] == parts[j] || (pat[i] == "*" && !parts[j].start_with?("@"))
          return false unless ok
          i += 1
          j += 1
        end
        j == parts.size
      end

      # Whether a key (without asterism/) is in a shared place: @shared its
      # first part (the network's) or its second (a node's).
      def shared?(key)
        parts = key.split("/", 3)
        parts[0] == SHARED || parts[1] == SHARED
      end

      # The sender "<node>/<app>" of a value on key, from its attachment
      # (the third element, docs/protocol.md 17.3); nil when key is not a
      # shared one (an application's own keys do not read it), or there is
      # no such sender.
      def sender(key, att)
        return nil if att.nil? || att.empty? || !shared?(key)
        a = begin
          ::MessagePack.unpack(att.to_s.b)
        rescue StandardError
          nil
        end
        a.is_a?(Array) ? ::Asterism::Subscription.sender(a[2]) : nil
      end

      # Where a value's numbers are counted and its latest value kept: the
      # key, and for a shared one with a sender the key and the sender.
      def lane(key, from)
        from ? "#{key}\n#{from}" : key
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
      # attachment, "from" (a shared value's sender), "seq", "sent" (the
      # sender's time) and, when seq (a Values::Seq) is given, "lost" (when
      # some were) and "restarted" (the sender started its numbers again),
      # counted per sender on a shared key.
      def entry(key, payload, t = Time.now, encoding: nil, attachment: nil, seq: nil)
        value, format = decode(payload, encoding)
        e = { "key" => key.delete_prefix(PREFIX), "t" => time(t), "bytes" => payload.to_s.bytesize,
              "format" => format, "value" => value }
        e.merge!(numbers(e["key"], attachment, seq))
      end

      # {"from", "seq", "sent", "lost", "restarted"} of an attachment, each
      # when there is one.
      def numbers(key, attachment, seq = nil)
        n, ms = Values.attachment(attachment)
        out = {}
        return out if n.nil?
        from = Values.sender(key, attachment)
        out["from"] = from if from
        out["seq"] = n
        out["sent"] = time(Time.at(ms / 1000, ms % 1000, :millisecond)) if ms
        if seq
          lost, restarted = seq.see(Values.lane(key, from), n)
          out["lost"] = lost if lost.positive?
          out["restarted"] = true if restarted
        end
        out
      end

      # The sequence numbers seen, key by key (a shared key's sender by
      # sender, Values.lane): how many values were lost before each
      # (docs/protocol.md 9.4, as Asterism::Subscription reads them).
      # Thread safe.
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

      # The latest put of each key (of each sender on a shared key), as
      # received since it was made: at most max_keys keys and max_total
      # payload bytes (the key received
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
          %w[from seq sent].each { |k| rec[k] = num[k] if num[k] }
          lane = Values.lane(key, num["from"])
          @lock.synchronize do
            lost = (@lost[lane] || 0) + num["lost"].to_i
            @lost[lane] = lost
            rec["lost"] = lost if lost.positive?
            old = @keys.delete(lane)
            @total -= old["kept"] == false ? 0 : old["bytes"] if old
            @keys[lane] = rec
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
        # from before (kept, marked), those on its own keys and those it
        # sent to a shared place.
        def left(app)
          prefix = "#{app}/"
          @lock.synchronize do
            @keys.each_value { |r| r["left"] = true if Store.app_of(r) == app || (r["from"].nil? && r["key"].start_with?(prefix)) }
          end
          self
        end

        # The application a record is of: its sender on a shared key (nil
        # when it named none), else its key's "<node>/<app>".
        def self.app_of(rec)
          return rec["from"] if rec["from"] || Values.shared?(rec["key"])
          rec["key"].split("/")[0, 2].join("/")
        end

        def size
          @lock.synchronize { @keys.size }
        end

        # The keys kept (a shared key once for each of its senders).
        def keys
          @lock.synchronize { @keys.values.map { _1["key"] } }
        end

        # The records whose keys match (sorted by key); with wait (seconds),
        # until one matches or the time is up.
        def match(pattern, wait: 0)
          deadline = @clock.call + wait.to_f
          @lock.synchronize do
            loop do
              got = @keys.values.select { Values.match?(pattern, _1["key"]) }
              return got.sort_by { [_1["key"], _1["from"].to_s] } unless got.empty?
              left = deadline - @clock.call
              return [] if left <= 0
              @cond.wait(@lock, left)
            end
          end
        end

        # What asterism_values answers: {"since", "values" => [{"key", "t",
        # "age_s", "app", "bytes", "format", "value"(, "from", "seq", "sent",
        # "lost", "truncated")}]} (from the sender of a shared key's value,
        # one entry for each sender; seq and sent from the attachment of
        # the latest value, lost the values missed on the key, or of that
        # sender, since the start; app of the sender, left out for a shared
        # value that named none), with
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
            app = Store.app_of(r)
            h = { "key" => r["key"], "t" => Values.time(r["t"]), "age_s" => (now - r["mono"]).round(1) }
            if app
              here = alive.key?(app) ? alive[app] : (alive[app] = @alive.call(app) ? true : false)
              h["app"] = here ? (r["left"] ? "restarted" : "alive") : "gone"
            end
            h["bytes"] = r["bytes"]
            h["format"] = r["format"]
            %w[from seq sent lost].each { |k| h[k] = r[k] if r.key?(k) }
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
