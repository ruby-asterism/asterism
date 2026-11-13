# Asterism::Transfer::Endpoint (CRuby): an Inbox answering at
# <node>/<app>/<object> (default <node>/transfer/inbox, where a Family
# mruby machine's transfer app answers) on a plain Zenoh connection.
#
# A program whose application has another name (a console, app "console")
# still wants to receive where the machines send (`asend <node> <file>`
# sends to <node>/transfer/inbox). A second Asterism connection does that
# with the object layer itself:
#
#   rx = Asterism.connect(router, node: "console", app: "transfer")
#   rx.expose("inbox", inbox, methods: Asterism::Transfer::Inbox::METHODS, caller: :from)
#
# The endpoint is the same on a Zenoh connection that is there already
# (one without an Asterism application of its own): it declares that
# application's and that object's liveliness tokens and answers its calls
# and its meta with the object layer's encoding (docs/protocol.md), the
# caller's node ID from the key passed as from: (caller: :from). Nothing
# else is exposed there.
#
#   conn = Asterism::Zenoh.open("tcp/127.0.0.1:7447")   # or net.zenoh
#   ep = Asterism::Transfer::Endpoint.new(conn, inbox, node: "console").start
#   conn.start                                         # its receiving thread answers
#   loop { ep.tick; sleep 0.5 }
#   ep.close
#
# The inbox's calls run under one lock (the receiving thread answers, the
# program ticks and reads it from its own): synchronize { ... } for more.
module Asterism
  module Transfer
    class Endpoint
      DOC = "Files in pieces with resending (Asterism::Transfer): begin, chunk, commit, cancel"
      METHOD_DOCS = {
        "begin" => { args: %w[kind meta], doc: "starts a file: meta {name, size, sha256, ...}; -> {id, piece, window, pos}" },
        "chunk" => { args: %w[id pos bytes], doc: "a piece at pos; -> the position this receiver holds" },
        "commit" => { args: %w[id], doc: "the file is all here: checks its sha256 and places it" },
        "cancel" => { args: %w[id], doc: "drops what is held of the file" }
      }.freeze

      attr_reader :inbox, :path

      def initialize(conn, inbox, node:, app: "transfer", object: "inbox")
        @conn = conn
        @inbox = inbox
        @node = node
        @app = app
        @object = object
        @path = "#{node}/#{app}/#{object}"
        @prefix = "#{::Asterism::ROOT}/#{@path}/"
        @lock = Monitor.new
        @tokens = []
        @queryable = nil
        inbox.path = @path
      end

      def start
        @tokens << @conn.liveliness("#{::Asterism::ROOT}/#{@node}/#{@app}")
        @tokens << @conn.liveliness("#{::Asterism::ROOT}/#{@path}")
        @queryable = @conn.queryable("#{::Asterism::ROOT}/#{@path}/**", depth: 32) { |q| answer(q) }
        self
      end

      def tick
        synchronize { @inbox.tick }
      end

      def synchronize(&blk)
        @lock.synchronize(&blk)
      end

      def close
        @queryable&.close
        @queryable = nil
        @tokens.each { _1.close rescue nil }
        @tokens.clear
        synchronize { @inbox.close }
      end

      # One query: <prefix>meta, or <prefix>call/<caller>.
      def answer(q)
        rest = q.key.to_s.delete_prefix(@prefix)
        return if rest == q.key.to_s
        if rest == "meta"
          q.reply("#{@prefix}meta", ::Asterism::Codec.pack(meta))
        elsif rest.start_with?("call/")
          from = rest.delete_prefix("call/")
          return unless ::Asterism.valid_name?(from)
          q.reply("#{@prefix}call/#{from}", dispatch(q.payload.to_s, from))
        elsif rest == "call"
          q.reply("#{@prefix}call", ::Asterism.error_reply("protocol", "Asterism::Error",
                                                          "#{@node}/#{@app} speaks Asterism protocol " \
                                                          "#{::Asterism::PROTOCOL}: call #{@prefix}call/<caller>"))
        end
      end

      # The meta (docs/protocol.md 5).
      def meta
        methods = Inbox::METHODS.map do |m, n|
          d = METHOD_DOCS[m]
          { "name" => m, "arity" => n, "args" => d[:args], "doc" => d[:doc] }
        end
        { "methods" => methods, "doc" => DOC }
      end

      # The packed reply to a call from the node from.
      def dispatch(payload, from)
        req = ::Asterism.parse_request(::Asterism::Codec.unpack(payload))
        return ::Asterism.error_reply("malformed", "ArgumentError", ::Asterism::MALFORMED) unless req
        name, args, kw = req
        arity = Inbox::METHODS[name]
        unless arity
          return ::Asterism.error_reply("not_exposed", "NoMethodError",
                                        "undefined method '#{name}' for #{@path} (not exposed)")
        end
        if args.size != arity
          return ::Asterism.error_reply("arguments", "ArgumentError",
                                        "wrong number of arguments (given #{args.size}, expected #{arity})")
        end
        unless kw.empty?
          return ::Asterism.error_reply("arguments", "ArgumentError", "#{@path} takes no keyword arguments")
        end
        value =
          begin
            synchronize { @inbox.public_send(name, *args, from: from) }
          rescue StandardError => e
            return ::Asterism.error_reply("raised", e.class.to_s, e.message)
          end
        begin
          ::Asterism::Codec.pack({ "value" => value })
        rescue ::Asterism::EncodeError => e
          ::Asterism.error_reply("unsendable", "Asterism::EncodeError", "the return value: #{e.message}")
        end
      end
    end
  end
end
