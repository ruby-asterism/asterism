# Asterism::Transfer: a file carried between two machines in pieces, over
# calls to an exposed object, that comes through lost, repeated and
# reordered pieces, a connection that drops for a while and a receiver
# that is stopped and started again -- and arrives whole or not at all.
#
# One source for every machine: the boards load it at run time (it is not
# compiled into the mrbgem, so an mruby VM that does not carry files pays
# nothing for it: require "/usr/share/asterism/transfer/transfer" on Family
# mruby), CRuby loads it through lib/asterism/transfer.rb.
#
# The receiver is an Inbox exposed with caller: :from; the machine's own
# application decides what a file may be (a kind), who may send it, where
# it goes once whole, by overriding the hooks below. The sender is a
# Sender, stepped from the application's update loop: one call on its way
# at a time (or a few, window:), never waiting in one go.
#
# The calls (docs: the receiver's position is the truth):
#
#   begin(kind, meta)  meta {"name", "size", "sha256" (hex, of the whole
#                      file), ...the kind's own}. -> {"id", "piece" (the
#                      largest piece this receiver takes), "window" (how
#                      many pieces may be on their way at once), "pos" (the
#                      bytes it already holds of this very file: 0, or
#                      where it stopped)}. The receiver chooses piece and
#                      window (the room a call has, its own memory, the
#                      kind); the sender keeps within both (a receiver that
#                      names no window is sent one piece at a time). The same sender beginning the same file
#                      (name, size and sha256 alike) again goes on where it
#                      stopped -- after a lost answer, a dropped connection,
#                      or this receiver's application started again (the
#                      piece file and a note of the file stay where they
#                      were written). Refused (Refused) for a kind or a sender
#                      the hooks do not take, or a file that does not fit;
#                      Busy while another node's file is coming in. The
#                      meta may carry what the kind wants besides (the
#                      kind "file" of Family mruby: "overwrite").
#   chunk(id, pos, bytes)  -> the position the receiver holds now. Taken at
#                      that position only: a piece before it (already here)
#                      is read past, a piece after it (one went missing) is
#                      not taken; either way the answer says where to go on
#                      from, so a piece may arrive any number of times.
#   commit(id)         all bytes are here: the whole is checked against the
#                      sha256 of begin, then handed to the kind (received).
#                      -> the kind's answer; {"status" => "refused",
#                      "reason"} when the sha256 does not match (nothing is
#                      placed); {"status" => "more", "pos"} when bytes are
#                      still missing. Asked again for the same id, the same
#                      answer.
#   cancel(id)         drops it (and its files); the sender's Sender#cancel.
#
#   Unknown            raised by chunk / commit for an id this receiver
#                      does not have (any more): the sender begins again.
#
# A file that stops coming: after STALE_MS another node may begin (and the
# held one is dropped); after keep_ms (KEEP_MS) its files are deleted.
# Only one file at a time.
module Asterism
  module Transfer
    # The receiver will not take it: the sender gives up (the message says why).
    class Refused < StandardError; end
    # Another node's file is coming in: the sender may try again later.
    class Busy < StandardError; end
    # The receiver has no such file (any more): the sender begins again.
    class Unknown < StandardError; end

    # A call carries 4 KB in all on zenoh-pico (Z_FRAG_MAX_SIZE), its key
    # and the arguments' framing included; a larger one is dropped without
    # an error (the caller waits until its time is out).
    CALL_BYTES = 4096
    # What a chunk call needs besides its key and the piece (the request's
    # map, the id and the position: under 40 bytes), with a margin.
    CALL_SPARE = 160
    # The piece a sender sends when the receiver names none (an older
    # receiver), and the largest a receiver names.
    PIECE = 3072
    PIECE_MAX = 3840
    # The pieces on their way at once that a receiver names when its
    # application does not say (Inbox#window), and the most a sender keeps
    # on their way whatever the receiver says (a node's calls wait in a
    # queue of 32 on zenoh-pico).
    WINDOW = 4
    WINDOW_MAX = 16
    # The key length a receiver that does not know its own path assumes.
    KEY_GUESS = 128
    # Where this file and sha256.rb are on the boards.
    DIR = "/usr/share/asterism/transfer"

    def self.now_ms
      ::Asterism.now_ms
    end

    # The largest piece a chunk call on a key of key_bytes carries: the 4 KB
    # of a call less the key and CALL_SPARE, in steps of 256, 512 to
    # PIECE_MAX.
    def self.piece_for_key(key_bytes)
      n = ((CALL_BYTES - CALL_SPARE - key_bytes) / 256) * 256
      return PIECE_MAX if n > PIECE_MAX
      n < 512 ? 512 : n
    end

    # A String of hex digits, n of them.
    def self.hex?(s, n)
      return false unless s.is_a?(String) && s.bytesize == n
      i = 0
      while i < n
        c = s.getbyte(i)
        return false unless (c >= 48 && c <= 57) || (c >= 97 && c <= 102)
        i += 1
      end
      true
    end

    # A name with no way out of the receiver's directory: letters, digits,
    # _ and -, up to 40 bytes.
    def self.plain_name?(name)
      return false unless name.is_a?(String)
      return false if name.empty? || name.bytesize > 40
      i = 0
      while i < name.bytesize
        c = name.getbyte(i)
        ok = (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95 || c == 45
        return false unless ok
        i += 1
      end
      true
    end

    # A file name another machine may give (a receiver's kind that places
    # files under a directory of its own, the kind "file"): no way out of
    # that directory (no "/", "\\" or ".."), not hidden (no "." first),
    # no control characters, 1 to 48 bytes (UTF-8 is fine). The piece file
    # beside it ("<name>.<kind>.part") keeps within 63 bytes.
    def self.file_name?(name)
      return false unless name.is_a?(String)
      n = name.bytesize
      return false if n == 0 || n > 48
      return false if name.getbyte(0) == 46
      i = 0
      while i < n
        c = name.getbyte(i)
        return false if c < 32 || c == 127 || c == 47 || c == 92
        return false if c == 46 && i + 1 < n && name.getbyte(i + 1) == 46
        i += 1
      end
      true
    end

    # name with " (k)" put before its extension: "foo.txt" -> "foo(1).txt",
    # "foo" -> "foo(1)" (the receiver keeps the file there and places the
    # new one beside it).
    def self.numbered(name, k)
      dot = nil
      i = name.bytesize - 1
      while i > 0
        if name.getbyte(i) == 46
          dot = i
          break
        end
        i -= 1
      end
      return "#{name}(#{k})" if dot.nil?
      "#{name.byteslice(0, dot)}(#{k})#{name.byteslice(dot, name.bytesize - dot)}"
    end

    # The name to place under dir (it ends in "/"): name itself when there is
    # no such file there, else the first of name(1), name(2), ... that is free.
    def self.free_name(dir, name)
      return name unless ::File.exist?("#{dir}#{name}")
      k = 1
      while k < 10000
        n = numbered(name, k)
        return n unless ::File.exist?("#{dir}#{n}")
        k += 1
      end
      nil
    end

    def self.to_hex(bin)
      out = ""
      i = 0
      while i < bin.bytesize
        out << format("%02x", bin.getbyte(i))
        i += 1
      end
      out
    end

    # SHA-256 in pieces: update(bytes), hexdigest. CRuby's Digest, mbedTLS
    # where the build has it (MbedTLS::Digest), else the plain Ruby one
    # (sha256.rb; slow, for builds with neither).
    class SHA256
      def self.engine
        if Object.const_defined?(:Digest) && ::Digest.const_defined?(:SHA256)
          :digest
        elsif Object.const_defined?(:MbedTLS) && ::MbedTLS.const_defined?(:Digest)
          :mbedtls
        else
          :ruby
        end
      end

      # The digest of a file, read a block at a time.
      def self.file(path, block = 4096)
        d = new
        ::File.open(path, "r") do |f|
          while (b = f.read(block))
            break if b.empty?
            d.update(b)
          end
        end
        d.hexdigest
      end

      def initialize(engine = nil)
        @engine = engine || SHA256.engine
        if @engine == :digest
          @d = ::Digest::SHA256.new
        elsif @engine == :mbedtls
          @d = ::MbedTLS::Digest.new(:sha256)
        else
          require "#{::Asterism::Transfer::DIR}/sha256" unless ::Asterism::Transfer.const_defined?(:PlainSHA256)
          @d = ::Asterism::Transfer::PlainSHA256.new
        end
      end

      attr_reader :engine

      def update(bytes)
        @d.update(bytes)
        self
      end

      def hexdigest
        return @d.hexdigest if @engine == :digest
        return ::Asterism::Transfer.to_hex(@d.finish) if @engine == :mbedtls
        @d.hexdigest
      end
    end

    # ------------------------------------------------------------- receiver

    # The receiving side. Expose it (or a subclass) with caller: :from:
    #
    #   Asterism.expose("inbox", inbox, methods: Asterism::Transfer::Inbox::METHODS, caller: :from)
    #
    # and call tick from the update loop. The hooks to override:
    #
    #   refused(kind, from, meta)  why this is not taken (nil: taken)
    #   name_ok?(kind, name)       whether the name is one this kind takes
    #                              (plain_name?: letters, digits, _ and -)
    #   room(kind, meta)           bytes free where this file goes (nil: not
    #                              known; it is then refused where it stops
    #                              being written)
    #   part_path(kind, name)      where the piece file is written (default
    #                              "<dir><name>.<kind>.part"; a kind may write
    #                              it beside the place it goes, so that the
    #                              commit has only to rename it). The note
    #                              of the file ("<dir><name>.<kind>.xfer")
    #                              stays in dir
    #   window(kind, meta)         how many pieces may be on their way at once
    #                              (default the window: given to new)
    #   received(t)                the file is whole at t["part"]: put it where
    #                              it belongs -> the answer to commit (a Hash)
    #
    # The piece named to a sender is the largest a call to this inbox carries
    # (path=, "<node>/<app>/<object>": the key is known; else KEY_GUESS), at
    # most the piece: given to new.
    class Inbox
      METHODS = { "begin" => 2, "chunk" => 3, "commit" => 1, "cancel" => 1 }
      # Without a piece for this long, another node may begin.
      STALE_MS = 10000
      # Without a piece for this long, the held file is deleted.
      KEEP_MS = 60000

      attr_accessor :logger, :path
      attr_reader :dir, :keep_ms

      # dir: where the files are written (it ends in "/"). piece: the largest
      # piece taken. window: the pieces on their way at once a sender is
      # told (the window hook's default). keep_ms: how long a file that
      # stopped coming is kept.
      def initialize(dir, piece: PIECE_MAX, window: WINDOW, keep_ms: KEEP_MS, stale_ms: STALE_MS)
        @dir = dir
        @piece = piece
        @window = window
        @keep_ms = keep_ms
        @stale_ms = stale_ms
        @t = nil
        @done = nil
        @last_id = ::Asterism::Transfer.now_ms
        @logger = Object.const_defined?(:Log) ? ::Log : nil
        @last_call = -100000
      end

      # ---- hooks ----

      def refused(kind, from, meta)
        nil
      end

      def name_ok?(kind, name)
        ::Asterism::Transfer.plain_name?(name)
      end

      def room(kind, meta)
        nil
      end

      def part_path(kind, name)
        "#{@dir}#{name}.#{kind}.part"
      end

      def window(kind, meta)
        @window
      end

      def received(t)
        { "status" => "received" }
      end

      # ---- the calls ----

      def begin(kind, meta, from: nil)
        @last_call = now_ms
        k = kind.to_s
        m = meta.is_a?(Hash) ? meta : {}
        why = refused(k, from, m)
        raise Refused, why if why
        name = m["name"]
        size = m["size"]
        sha = m["sha256"]
        raise Refused, "not a name for a file: #{name}" unless name_ok?(k, name)
        raise Refused, "size #{size} is not a size" unless size.is_a?(Integer) && size > 0
        raise Refused, "sha256 is not 64 hex digits" unless ::Asterism::Transfer.hex?(sha, 64)
        t = @t
        if t && t["from"] == from && t["kind"] == k && t["name"] == name && t["size"] == size && t["sha256"] == sha
          open_part(t)
          t["at"] = now_ms
          t["meta"] = m
          info("transfer: #{from} goes on with #{k} #{name} at #{t['got']} of #{size} bytes")
          return { "id" => t["id"], "piece" => piece_for(from), "window" => window_for(k, m), "pos" => t["got"] }
        end
        if t
          if t["from"] != from && now_ms - t["at"] <= @stale_ms
            raise Busy, "busy: a file from #{t['from']} is coming in"
          end
          drop("#{from} begins another")
        end
        left = room(k, m)
        if left && size > left
          raise Refused, "#{size} bytes do not fit (#{left} bytes free)"
        end
        @done = nil if @done && @done["from"] == from
        t = { "id" => new_id, "from" => from, "kind" => k, "name" => name, "size" => size, "sha256" => sha,
              "meta" => m, "got" => 0, "part" => part_path(k, name), "note" => "#{@dir}#{name}.#{k}.xfer",
              "file" => nil, "digest" => nil, "at" => now_ms, "gaps" => 0, "again" => 0 }
        remove(t["part"])
        write_note(t)
        @t = t
        open_part(t)
        piece = piece_for(from)
        win = window_for(k, m)
        info("transfer: #{from} sends #{k} #{name} (#{size} bytes) to #{t['part']}, pieces of #{piece} bytes, " \
             "#{win} at a time")
        { "id" => t["id"], "piece" => piece, "window" => win, "pos" => 0 }
      end

      def chunk(id, pos, data, from: nil)
        t = current(id, from)
        bytes = data.to_s
        got = t["got"]
        n = bytes.bytesize
        p = pos.is_a?(Integer) ? pos : -1
        raise Refused, "not a position: #{pos}" if p < 0
        t["at"] = now_ms
        if p > got
          t["gaps"] += 1
          return got
        end
        if p + n <= got
          t["again"] += 1
          return got
        end
        bytes = bytes.byteslice(got - p, n - (got - p)).to_s if p < got
        if got + bytes.bytesize > t["size"]
          drop("a piece past #{t['size']} bytes")
          raise Refused, "the piece goes past #{t['size']} bytes"
        end
        open_part(t)
        begin
          t["file"].write(bytes)
        rescue => e
          drop("cannot write: #{e.message}")
          raise Refused, "cannot write at #{got} (#{e.message})"
        end
        t["digest"].update(bytes)
        t["got"] = got + bytes.bytesize
      end

      def commit(id, from: nil)
        @last_call = now_ms
        d = @done
        return d["answer"] if d && d["id"] == id && d["from"] == from
        t = current(id, from)
        return { "status" => "more", "pos" => t["got"] } if t["got"] < t["size"]
        close_part(t)
        sha = t["digest"].hexdigest
        @t = nil
        remove(t["note"])
        if sha != t["sha256"]
          remove(t["part"])
          warn("transfer: #{t['kind']} #{t['name']} from #{from}: sha256 #{sha[0, 12]}..., " \
               "#{t['sha256'][0, 12]}... was sent; not placed")
          answer = { "status" => "refused",
                     "reason" => "the sha256 of the #{t['size']} bytes that came does not match (#{sha[0, 12]}...)" }
        else
          info("transfer: #{t['kind']} #{t['name']} from #{from} is whole (#{t['size']} bytes, sha256 matches; " \
               "#{t['gaps']} gap(s), #{t['again']} piece(s) again)")
          answer = received(t)
        end
        @done = { "id" => id, "from" => from, "answer" => answer, "t" => t }
        answer
      end

      def cancel(id, from: nil)
        @last_call = now_ms
        t = @t
        if t && t["id"] == id && t["from"] == from
          drop("cancelled by #{from}")
          return true
        end
        false
      end

      # ---- the application's side ----

      # Call from the update loop: a file that stopped coming is deleted
      # once keep_ms has gone by.
      def tick
        t = @t
        drop("no piece for #{@keep_ms} ms") if t && now_ms - t["at"] > @keep_ms
        nil
      end

      # A call came in a moment ago (the application may poll more often).
      def busy?(ms = 2000)
        now_ms - @last_call < ms
      end

      # The file coming in (a Hash), nil when none.
      def current_file
        @t
      end

      # The last committed one: {"id", "from", "answer", "t"}.
      def last_done
        @done
      end

      # The application ends: the files stay, for a start again to go on.
      def close
        t = @t
        close_part(t) if t
        nil
      end

      # The application starts: a file held when it last ended is taken up
      # again (counted from now for keep_ms), the others are deleted.
      def resume_held
        names = held_notes
        i = 0
        while i < names.size
          path = "#{@dir}#{names[i]}"
          t = read_note(path)
          if t && @t.nil?
            got = ::File.exist?(t["part"]) ? ::File.size(t["part"]) : 0
            got = t["size"] if got > t["size"]
            t["got"] = got
            t["at"] = now_ms
            @t = t
            info("transfer: held #{t['kind']} #{t['name']} from #{t['from']} (#{got} of #{t['size']} bytes)")
          else
            remove(path)
            remove(t ? t["part"] : "#{path.byteslice(0, path.bytesize - 5)}.part")
          end
          i += 1
        end
        nil
      end

      # ---- inside ----

      def now_ms
        ::Asterism::Transfer.now_ms
      end

      def info(msg)
        @logger.info(msg) if @logger
      end

      def warn(msg)
        @logger.warn(msg) if @logger
      end

      # The largest piece a call from this sender carries here.
      def piece_for(from)
        key = @path ? "asterism/#{@path}/call/#{from}".bytesize : KEY_GUESS
        n = ::Asterism::Transfer.piece_for_key(key)
        n < @piece ? n : @piece
      end

      def window_for(kind, meta)
        w = window(kind, meta)
        w = 1 unless w.is_a?(Integer) && w >= 1
        w > WINDOW_MAX ? WINDOW_MAX : w
      end

      def new_id
        id = now_ms
        id = @last_id + 1 if id <= @last_id
        @last_id = id
        id
      end

      def current(id, from)
        @last_call = now_ms
        t = @t
        raise Unknown, "no file #{id} is coming in from #{from}" unless t && t["id"] == id && t["from"] == from
        t
      end

      # The piece file open for appending, and the digest of what it holds.
      def open_part(t)
        return if t["file"]
        d = SHA256.new
        got = 0
        if t["got"] > 0 && ::File.exist?(t["part"])
          ::File.open(t["part"], "r") do |f|
            while got < t["got"]
              b = f.read(t["got"] - got > 4096 ? 4096 : t["got"] - got)
              break if b.nil? || b.empty?
              d.update(b)
              got += b.bytesize
            end
          end
        end
        if got != t["got"]
          # shorter than noted: start over
          remove(t["part"])
          d = SHA256.new
          got = 0
        end
        t["got"] = got
        t["digest"] = d
        t["file"] = ::File.open(t["part"], got > 0 ? "a" : "w")
      end

      def close_part(t)
        f = t["file"]
        return unless f
        t["file"] = nil
        f.close
      rescue => e
        warn("transfer: close: #{e.message}")
      end

      def drop(why)
        t = @t
        return nil unless t
        @t = nil
        warn("transfer: #{t['kind']} #{t['name']} from #{t['from']} dropped at #{t['got']} of #{t['size']} bytes: #{why}")
        close_part(t)
        remove(t["part"])
        remove(t["note"])
        nil
      end

      def remove(path)
        ::File.delete(path) if ::File.exist?(path)
      rescue => e
        warn("transfer: delete #{path}: #{e.message}")
      end

      # The note beside the piece file: who sends what (JSON, one line).
      def write_note(t)
        h = { "from" => t["from"], "kind" => t["kind"], "name" => t["name"], "size" => t["size"],
              "sha256" => t["sha256"], "meta" => t["meta"] }
        ::File.open(t["note"], "w") { |f| f.write(::JSON.generate(h)) }
      end

      def read_note(path)
        text = ::File.open(path, "r") { |f| f.read }
        h = ::JSON.parse(text.to_s)
        return nil unless h.is_a?(Hash) && h["size"].is_a?(Integer)
        k = h["kind"].to_s
        return nil unless name_ok?(k, h["name"])
        { "id" => new_id, "from" => h["from"], "kind" => k, "name" => h["name"], "size" => h["size"],
          "sha256" => h["sha256"], "meta" => h["meta"].is_a?(Hash) ? h["meta"] : {}, "got" => 0,
          "part" => part_path(k, h["name"]), "note" => path, "file" => nil, "digest" => nil, "at" => now_ms,
          "gaps" => 0, "again" => 0 }
      rescue => e
        warn("transfer: #{path}: #{e.message}")
        nil
      end

      def held_notes
        out = []
        names = ::Dir.entries(@dir.byteslice(0, @dir.bytesize - 1))
        i = 0
        while i < names.size
          n = names[i].to_s
          out << n if n.bytesize > 5 && n.byteslice(n.bytesize - 5, 5) == ".xfer"
          i += 1
        end
        out
      rescue => e
        warn("transfer: #{@dir}: #{e.message}")
        []
      end
    end

    # --------------------------------------------------------------- sender

    # The sending side of one file. Made with the receiver's path
    # ("<node>/<app>/<object>"), the kind, the local file and the meta the
    # kind wants; call step from the update loop until done?. Then ok? and
    # answer (commit's answer: the kind's), or reason.
    #
    # The receiver's position is the truth: every answer says where it
    # stands and the next piece goes from there. A call that fails (no
    # answer in time, the connection gone, the receiver busy or started
    # again) is tried again after a wait that doubles (RETRY_MS up to
    # RETRY_MAX_MS), by beginning again -- the receiver answers where it
    # stopped. tries failures in a row without a byte of progress end it.
    #
    # The receiver names the piece size and how many pieces may be on their
    # way at once (begin's answer); piece: and window: are only the most
    # this sender goes to (a receiver that names no window gets one piece
    # at a time, as before).
    class Sender
      RETRY_MS = 200
      RETRY_MAX_MS = 4000
      TRIES = 8
      CALL_TIMEOUT_MS = 10000

      attr_accessor :logger
      attr_reader :path, :size, :sha256, :answer, :reason, :stats, :pos, :id, :kind, :piece, :window

      def initialize(to, kind, path, meta: {}, name: nil, piece: PIECE_MAX, window: WINDOW_MAX,
                     timeout_ms: CALL_TIMEOUT_MS, tries: TRIES, sha256: nil)
        @to = to
        @kind = kind
        @path = path
        @piece_max = piece
        @window_max = window < 1 ? 1 : window
        @window = 1
        @timeout_ms = timeout_ms
        @tries_max = tries
        @logger = Object.const_defined?(:Log) ? ::Log : nil
        @size = ::File.size(path)
        @sha256 = sha256 || SHA256.file(path)
        @meta = {}
        meta.each { |k, v| @meta[k] = v }
        @meta["name"] = name if name
        @meta["size"] = @size
        @meta["sha256"] = @sha256
        @state = :begin
        @id = nil
        @piece = piece
        @pos = 0           # what the receiver holds, as last told
        @next = 0          # the next byte to send
        @inflight = []     # [future, pos, length] in the order sent
        @fut = nil         # begin / commit on its way
        @retry_at = nil
        @tries = 0
        @answer = nil
        @reason = nil
        @file = nil
        @file_pos = 0
        @cache = []        # [pos, bytes] of the last pieces read
        @stats = { "calls" => 0, "pieces" => 0, "again" => 0, "retries" => 0, "begins" => 0, "resumed_at" => [] }
        @t0 = now_ms
      end

      def done?
        @state == :done || @state == :failed
      end

      def ok?
        @state == :done
      end

      # commit was asked at least once: the receiver may have the whole
      # file (and have acted on it) even when the answer never came.
      def committing?
        @committing == true
      end

      def took_ms
        now_ms - @t0
      end

      # One step: issues the calls there is room for, takes the answers in.
      # Never waits.
      def step
        return if done?
        if @retry_at
          return if now_ms < @retry_at
          @retry_at = nil
          @state = :begin
        end
        if @state == :begin
          return call_begin if @fut.nil?
          return unless @fut.done?
          v = take(@fut)
          @fut = nil
          return if v.nil?
          begun(v)
        elsif @state == :chunk
          pump
        elsif @state == :commit
          return call_commit if @fut.nil?
          return unless @fut.done?
          v = take(@fut)
          @fut = nil
          return if v.nil?
          committed(v)
        end
        nil
      end

      # Gives up on purpose: the receiver is asked to drop what it holds of
      # this file (its piece file and note; nothing is placed), without
      # waiting for its answer. -> false when already done.
      def cancel
        return false if done?
        id = @id
        if id
          begin
            call("cancel", id)
          rescue ::Asterism::Error
            nil
          end
        end
        finish_failed("cancelled")
        @cancelled = true
        true
      end

      def cancelled?
        @cancelled == true
      end

      # Stops (the application ends, or gives up): the file is closed.
      def close
        close_file
        @state = :failed if !done?
        @reason ||= "stopped"
      end

      # ---- the test's hook ----

      # What happens to the piece at pos (length n) on its way: nil (sent),
      # :drop (not sent; the next one is), :twice (sent two times), :swap
      # (the next piece is sent before it). For the fault tests.
      def fault(pos, n)
        nil
      end

      # ---- inside ----

      def now_ms
        ::Asterism::Transfer.now_ms
      end

      def info(msg)
        @logger.info(msg) if @logger
      end

      def proxy
        ::Asterism[@to, timeout_ms: @timeout_ms].async
      end

      def call(method, *args)
        @stats["calls"] += 1
        proxy.asterism_call(method, *args)
      end

      def call_begin
        @stats["begins"] += 1
        @inflight = []
        @fut = call("begin", @kind, @meta)
      rescue ::Asterism::Error => e
        failed_call(e)
      end

      def call_commit
        @committing = true
        @fut = call("commit", @id)
      rescue ::Asterism::Error => e
        failed_call(e)
      end

      # The answer of a future, or nil after dealing with its failure.
      def take(f)
        f.value
      rescue ::Asterism::RemoteError => e
        cls = e.remote_class.to_s
        if ends_with?(cls, "Refused")
          finish_failed(e.remote_message)
        elsif ends_with?(cls, "Unknown")
          info("transfer: #{@to} has no file #{@id} (any more); beginning again")
          @state = :begin
          @inflight = []
        else
          failed_call(e)
        end
        nil
      rescue ::Asterism::Error => e
        failed_call(e)
        nil
      end

      def int(v)
        v.is_a?(Integer) ? v : 0
      end

      def ends_with?(s, tail)
        s.bytesize >= tail.bytesize && s.byteslice(s.bytesize - tail.bytesize, tail.bytesize) == tail
      end

      # A call failed: wait, then begin again (asking where the receiver is).
      def failed_call(e)
        @fut = nil
        @inflight = []
        @tries += 1
        msg = e.respond_to?(:remote_message) ? e.remote_message.to_s : e.message.to_s
        if @tries > @tries_max
          return finish_failed("#{@to}: gave up after #{@tries - 1} tries (#{msg})")
        end
        wait = RETRY_MS
        i = 1
        while i < @tries && wait < RETRY_MAX_MS
          wait *= 2
          i += 1
        end
        wait = RETRY_MAX_MS if wait > RETRY_MAX_MS
        @stats["retries"] += 1
        info("transfer: #{@to}: #{msg}; asking again in #{wait} ms (try #{@tries})")
        @retry_at = now_ms + wait
        nil
      end

      def begun(v)
        r = v.is_a?(Hash) ? v : {}
        @id = r["id"]
        p = int(r["piece"])
        @piece = p > 0 && p < @piece_max ? p : @piece_max
        w = int(r["window"])
        w = 1 if w < 1
        @window = w < @window_max ? w : @window_max
        if @stats["begins"] == 1
          info("transfer: #{@to} takes pieces of #{@piece} bytes, #{@window} at a time")
        end
        pos = int(r["pos"])
        pos = 0 if pos < 0 || pos > @size
        if @stats["begins"] > 1 || pos > 0
          @stats["resumed_at"] << pos
          info("transfer: #{@to} holds #{pos} of #{@size} bytes; going on from there")
        end
        progress(pos)
        @next = pos
        @state = pos >= @size ? :commit : :chunk
        pump if @state == :chunk
      end

      def progress(pos)
        @tries = 0 if pos > @pos
        @pos = pos
      end

      # Keeps up to window pieces on their way; takes their answers in order.
      def pump
        while !@inflight.empty?
          f = @inflight[0][0]
          break unless f.done?
          ent = @inflight.shift
          v = take(f)
          return if v.nil?
          held = int(v)
          progress(held) if held > @pos
          if held < ent[1] + ent[2] && held < @size
            # the receiver stands before the end of this piece: go on from
            # where it is (the pieces still on their way are read past or
            # not taken there)
            @stats["again"] += 1
            @next = held
            @inflight = []
            break
          end
        end
        if @pos >= @size && @inflight.empty?
          @state = :commit
          close_file
          return call_commit
        end
        while @inflight.size < @window && @next < @size
          send_from(@next)
        end
      end

      def send_from(pos)
        n = @size - pos
        n = @piece if n > @piece
        what = fault(pos, n)
        if what == :drop
          @next = pos + n
          return if @next >= @size
          pos = @next
          n = @size - pos
          n = @piece if n > @piece
          what = nil
        end
        if what == :swap && pos + n < @size
          m = @size - (pos + n)
          m = @piece if m > @piece
          send_piece(pos + n, m)
          send_piece(pos, n)
          @next = pos + n + m
          return
        end
        send_piece(pos, n)
        send_piece(pos, n) if what == :twice
        @next = pos + n
      end

      def send_piece(pos, n)
        data = read_at(pos, n)
        return finish_failed("cannot read #{@path} at #{pos}") if data.nil?
        @stats["pieces"] += 1
        @inflight << [call("chunk", @id, pos, data), pos, n]
      rescue ::Asterism::Error => e
        failed_call(e)
      end

      def committed(v)
        r = v.is_a?(Hash) ? v : {}
        if r["status"].to_s == "more"
          @next = int(r["pos"])
          @pos = @next
          @state = :chunk
          return pump
        end
        @answer = r
        @state = :done
        close_file
        nil
      end

      def finish_failed(why)
        @reason = why.to_s
        @state = :failed
        @fut = nil
        @inflight = []
        close_file
        nil
      end

      # The bytes at pos: from the last pieces read, else from the file (read
      # on from where it is, or opened again and read up to pos: the boards'
      # files have no seek).
      def read_at(pos, n)
        i = 0
        while i < @cache.size
          c = @cache[i]
          return c[1] if c[0] == pos && c[1].bytesize == n
          i += 1
        end
        if @file && @file_pos != pos && seek_to(pos)
          @file_pos = pos
        end
        if @file.nil? || @file_pos > pos
          close_file
          @file = ::File.open(@path, "r")
          @file_pos = 0
          @file_pos = pos if pos > 0 && seek_to(pos)
        end
        while @file_pos < pos
          k = pos - @file_pos
          k = 4096 if k > 4096
          b = @file.read(k)
          return nil if b.nil? || b.empty?
          @file_pos += b.bytesize
        end
        data = @file.read(n)
        return nil if data.nil? || data.bytesize != n
        @file_pos += n
        data = data.b if data.respond_to?(:b)
        @cache << [pos, data]
        @cache.shift while @cache.size > @window + 2
        data
      end

      # Moves the file to pos where the File has seek (CRuby, and the boards'
      # that have it); false where it has none (then it is read up to pos).
      def seek_to(pos)
        return false unless @file.respond_to?(:seek)
        @file.seek(pos)
        true
      rescue ScriptError, StandardError
        false
      end

      def close_file
        f = @file
        @file = nil
        @file_pos = 0
        f.close if f
      rescue
        nil
      end
    end
  end
end
