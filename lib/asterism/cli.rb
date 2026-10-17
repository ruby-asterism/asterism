# The command line of the gem (exe/asterism): look at an Asterism network
# from CRuby, and call an object when asked to.
#
#   asterism nodes   --router tcp/192.0.2.2:7447
#   asterism tree    --credentials admin.tar
#   asterism objects 'games/games/*'
#   asterism watch                         # joins, leaves, statuses as they come
#   asterism ping    games/games/othello1  # the time of a round trip (meta)
#   asterism call    games/games/othello1 view '"<token>"'
#   asterism mcp     --allow 'games/othello1.*'   # an MCP server on stdio
#
# It is one more Asterism node: it connects with Asterism.connect (as the
# certificate's name with --credentials, as cli-<6 hex digits> otherwise)
# and reads what docs/protocol.md lets anyone read. It calls a method only
# with `call` (and the MCP bridge only the methods --allow names). What it
# can see is what the router lets it see: with a console's .tar, its role.
require "asterism"
require "optparse"
require "json"
require "securerandom"
require_relative "cli/literal"
require_relative "cli/survey"
require_relative "cli/allow"

module Asterism
  class CLI
    USAGE = <<~TEXT
      Usage: asterism COMMAND [options]

      Commands (they only read, except call):
        nodes                the nodes, their applications and profiles
        objects [PATTERN]    the objects and their methods (PATTERN: node/app/object, * and **)
        tree                 nodes > applications (with their status) > objects (with their methods)
        watch                nodes, applications and objects coming and going, and status changes
        ping PATH            round trips: PATH node/app/object (its meta), or node (its profile);
                             --call METHOD [ARG...] times a call instead (echo is the same command)
        call PATH METHOD [ARG...]
                             calls a method; each ARG is JSON, else a Ruby literal, else text
        mcp                  an MCP server on stdio (needs the mcp gem): the listings as tools,
                             and the methods --allow names
        version              the gem's version

      Where the network is (one of them):
        --router LOCATOR     a router without TLS, e.g. tcp/192.0.2.2:7447
        --credentials TAR    a console's .tar (mutual TLS; its router and name)
    TEXT

    def self.start(argv, out: $stdout, err: $stderr)
      new(out: out, err: err).run(argv.dup)
    end

    def initialize(out: $stdout, err: $stderr)
      @out = out
      @err = err
      @opts = { timeout: 2.0, settle: 1.5, json: false, count: 5, interval: 0.2, allow: [] }
    end

    def run(argv)
      cmd = argv.shift
      case cmd
      when nil, "help", "-h", "--help"
        @out.puts USAGE
        return cmd.nil? ? 2 : 0
      when "version", "--version", "-v"
        @out.puts "asterism #{::Asterism::VERSION}"
        return 0
      end
      unless %w[nodes objects tree watch ping echo call mcp].include?(cmd)
        @err.puts "asterism: unknown command #{cmd.inspect}\n\n#{USAGE}"
        return 2
      end
      rest = parser(cmd).parse(argv)
      send("cmd_#{cmd == 'echo' ? 'ping' : cmd}", rest)
    rescue OptionParser::ParseError, ArgumentError => e
      @err.puts "asterism: #{e.message}"
      2
    rescue ::Asterism::Disconnected => e
      @err.puts "asterism: cannot reach the network: #{e.message}"
      1
    rescue ::Asterism::Error => e
      @err.puts "asterism: #{e.class}: #{e.message}"
      1
    rescue Interrupt
      0
    end

    def parser(cmd)
      OptionParser.new do |o|
        o.banner = "Usage: asterism #{cmd} [options]"
        o.on("--router LOCATOR", "a router (tcp/HOST:7447)") { @opts[:router] = _1 }
        o.on("--credentials TAR", "a console's .tar") { @opts[:credentials] = _1 }
        o.on("--peer LOCATOR", "a direct peer link to a node listening there (no router)") { @opts[:peer] = _1 }
        o.on("--node NAME", "this node's ID (default: the certificate's name, or cli-<6 hex>)") { @opts[:node] = _1 }
        o.on("--app NAME", "this application's name (default: cli-<4 hex>)") { @opts[:app] = _1 }
        o.on("--json", "JSON instead of text (watch: one JSON object a line)") { @opts[:json] = true }
        o.on("--timeout SECONDS", Float, "time limit of each get or call (2.0)") { @opts[:timeout] = _1 }
        o.on("--settle SECONDS", Float, "how long to wait for the tokens at connect (1.5)") { @opts[:settle] = _1 }
        case cmd
        when "watch"
          o.on("--duration SECONDS", Float, "stop after this long (default: until Ctrl-C)") { @opts[:duration] = _1 }
        when "ping", "echo"
          o.on("--count N", Integer, "round trips (5)") { @opts[:count] = _1 }
          o.on("--interval SECONDS", Float, "pause between them (0.2)") { @opts[:interval] = _1 }
          o.on("--call METHOD", "time a call of METHOD (with the ARGs after PATH) instead of the meta") { @opts[:call] = _1 }
        when "call"
          o.on("--kwargs VALUE", "keyword arguments: a JSON object or a Ruby Hash literal") { @opts[:kwargs] = _1 }
        when "mcp"
          o.on("--allow PATTERN", "methods the MCP client may call: [node/][app/]object.method, * as a wildcard " \
                                  "(repeatable)") { @opts[:allow] << _1 }
        end
      end
    end

    # ------------------------------------------------------------ connecting

    # Connects, starts the receiving thread, waits for the tokens and yields
    # the Net and a Survey.
    def connect(app_prefix: "cli")
      router = @opts[:router]
      creds = @opts[:credentials]
      peer = @opts[:peer]
      if router.nil? && creds.nil? && peer.nil?
        raise ArgumentError, "where is the network? --router tcp/HOST:7447 or --credentials FILE.tar"
      end
      node = @opts[:node]
      node ||= "#{app_prefix}-#{SecureRandom.hex(3)}" unless creds
      app = @opts[:app] || "#{app_prefix}-#{SecureRandom.hex(2)}"
      kw = { node: node, app: app }
      kw[:credentials] = creds if creds
      locator = router
      if peer
        locator = peer
        kw[:mode] = :peer
      end
      ::Asterism.profile(name: app_prefix == "mcp" ? "asterism MCP" : "asterism CLI")
      ::Asterism.connect(locator, **kw) do |net|
        net.on_error { |e, where| @err.puts "asterism: #{where}: #{e.class}: #{e.message}" }
        net.start
        survey = Survey.new(timeout: @opts[:timeout])
        survey.settle(@opts[:settle])
        yield net, survey
      end
    end

    def emit_json(v)
      @out.puts JSON.pretty_generate(v)
    end

    # ------------------------------------------------------------ nodes

    def cmd_nodes(_rest)
      connect do |_net, sv|
        tree = sv.tree(meta: false)
        if @opts[:json]
          emit_json(tree.map { |n| n.merge("apps" => n["apps"].map { |a| a.except("objects") }) })
        elsif tree.empty?
          @out.puts "(no other node is visible)"
        else
          tree.each do |n|
            @out.puts "#{n['node']}#{profile_text(n['profile'])}"
            n["apps"].each do |a|
              @out.puts "  #{a['app']}#{"  #{a['objects'].size} objects" unless a['objects'].empty?}" \
                        "#{"  status #{compact(a['status'])}" if a.key?('status')}"
            end
          end
        end
      end
      0
    end

    # ------------------------------------------------------------ objects

    def cmd_objects(rest)
      pattern = rest.shift || "**"
      connect do |_net, sv|
        paths = sv.objects(pattern)
        metas = sv.metas(paths)
        if @opts[:json]
          emit_json(paths.map do |p|
            h = { "path" => p, "methods" => metas[p] }
            h["doc"] = sv.object_doc(p) if sv.object_doc(p)
            h
          end)
        elsif paths.empty?
          @out.puts "(no object matches #{pattern})"
        else
          paths.each do |p|
            @out.puts "#{p}  #{metas.key?(p) ? methods_text(metas[p]) : '(no meta: not answered in time, or not allowed)'}"
            @out.puts "  #{sv.object_doc(p)}" if sv.object_doc(p)
            # The methods that tell what they do, one a line (doc's first line).
            (metas[p] || []).each do |m|
              @out.puts "    #{signature(m)}  #{m['doc'].lines.first.strip}" if m["doc"]
            end
          end
        end
      end
      0
    end

    # ------------------------------------------------------------ tree

    def cmd_tree(_rest)
      connect do |_net, sv|
        tree = sv.tree
        if @opts[:json]
          emit_json(tree)
        elsif tree.empty?
          @out.puts "(no other node is visible)"
        else
          tree.each do |n|
            @out.puts "#{n['node']}#{profile_text(n['profile'])}"
            n["apps"].each do |a|
              @out.puts "  #{a['app']}#{"  status #{compact(a['status'])}" if a.key?('status')}"
              a["objects"].each do |o|
                @out.puts "    #{o['name']}  #{o['methods'] ? methods_text(o['methods']) : '(no meta)'}"
              end
            end
          end
        end
      end
      0
    end

    # ------------------------------------------------------------ watch

    # Prints the changes until Ctrl-C (or --duration): nodes (Asterism's
    # on_join / on_leave), applications and objects (their liveliness
    # tokens), statuses (their puts) and profiles (their puts). The
    # statuses there at the start come first.
    def cmd_watch(_rest)
      connect do |net, sv|
        own = "#{net.node_id}/#{net.app}"
        sv.statuses.sort.each { |path, st| event("status", path, status: st, now: true) }
        net.on_join { |n| event("join", n, what: "node") }
        net.on_leave { |n| event("leave", n, what: "node") }
        net.session.liveliness_watch("asterism/**") do |key, alive|
          # The tokens alive at the start come first, in one burst: not news.
          next unless @watch_started
          path = key.delete_prefix("asterism/")
          next if path == own || path.start_with?("#{own}/")
          what = { 2 => "app", 3 => "object" }[path.count("/") + 1]
          event(alive ? "join" : "leave", path, what: what) if what
        end
        net.session.subscribe(Survey::STATUS_ALL) do |sample|
          got = ::Asterism::Status.parse(sample.key, sample.payload)
          event("status", "#{got[0]}/#{got[1]}", status: got[2]) if got && "#{got[0]}/#{got[1]}" != own
        end
        net.session.subscribe(Survey::PROFILES_ALL) do |sample|
          node = sample.key.split("/")[1]
          pr = ::Asterism::Profile.check(::Asterism::Codec.unpack(sample.payload))
          event("profile", node, profile: pr) if pr && node != net.node_id
        end
        sleep 0.3
        @watch_started = true
        @err.puts "asterism: watching (Ctrl-C to stop)" unless @opts[:json]
        deadline = @opts[:duration] && (Process.clock_gettime(Process::CLOCK_MONOTONIC) + @opts[:duration])
        loop do
          break if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          break unless net.connected?
          sleep 0.05
        end
      end
      0
    end

    def event(kind, path, what: nil, status: nil, profile: nil, now: false)
      t = Time.now
      if @opts[:json]
        h = { "t" => t.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"), "event" => kind, "path" => path }
        h["what"] = what if what
        h["status"] = status if status
        h["profile"] = profile if profile
        h["now"] = true if now
        @out.puts JSON.generate(h)
      else
        mark = { "join" => "+", "leave" => "-", "status" => "~", "profile" => "*" }[kind]
        text = case kind
               when "status" then "status #{path} #{compact(status)}#{' (now)' if now}"
               when "profile" then "profile #{path}#{profile_text(profile)}"
               else "#{what} #{path}"
               end
        @out.puts "#{t.strftime('%H:%M:%S.%L')} #{mark} #{text}"
      end
      @out.flush
    end

    # ------------------------------------------------------------ ping

    # Round trips to PATH: the meta of an object (no method runs), the
    # profile of a node, or with --call a method (with the ARGs given).
    def cmd_ping(rest)
      path = rest.shift or raise ArgumentError, "ping: which node or object? (asterism ping node/app/object)"
      args = rest.map { Literal.parse(_1) }
      chunks = path.split("/")
      raise ArgumentError, "ping: PATH is node or node/app/object" unless [1, 3].include?(chunks.size)
      raise ArgumentError, "ping: --call needs node/app/object" if @opts[:call] && chunks.size != 3
      what = @opts[:call] ? "call #{@opts[:call]}" : (chunks.size == 3 ? "meta" : "profile")
      times = []
      connect do |_net, _sv|
        ms = (@opts[:timeout] * 1000).round
        @opts[:count].times do |i|
          sleep @opts[:interval] if i.positive?
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          ok = begin
            ping_once(path, chunks, args, ms)
            true
          rescue ::Asterism::RemoteError => e
            @err.puts "asterism: #{path}: #{e.remote_kind || 'error'}: #{e.message}" if i.zero?
            true # it answered
          rescue ::Asterism::TimeoutError => e
            @err.puts "asterism: #{e.message}"
            false
          end
          dt = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
          times << dt if ok
          @out.puts "#{path} #{what}: #{ok ? format('%.1f ms', dt) : 'no answer'}" unless @opts[:json]
        end
      end
      if @opts[:json]
        emit_json({ "path" => path, "what" => what, "count" => @opts[:count], "answered" => times.size,
                    "ms" => times.map { _1.round(2) } })
      elsif times.any?
        @out.puts format("%d of %d answered: min %.1f / avg %.1f / max %.1f ms", times.size, @opts[:count],
                         times.min, times.sum / times.size, times.max)
      end
      times.empty? ? 1 : 0
    end

    def ping_once(path, chunks, args, ms)
      if @opts[:call]
        ::Asterism[path, timeout_ms: ms].asterism_call(@opts[:call], *args)
      elsif chunks.size == 3
        raw = ::Asterism.meta(path, ms)
        raise ::Asterism::Error, "malformed meta from #{path}" unless raw.is_a?(Hash)
      else
        ::Asterism.profile_async(path, false, nil, ms).raw_value
      end
    end

    # ------------------------------------------------------------ call

    def cmd_call(rest)
      path = rest.shift
      method = rest.shift
      raise ArgumentError, "call: asterism call node/app/object METHOD [ARG...]" unless path && method
      ::Asterism.split_path(path)
      args = rest.map { Literal.parse(_1) }
      kwargs = @opts[:kwargs] ? Literal.parse(@opts[:kwargs]) : {}
      raise ArgumentError, "--kwargs: expected a JSON object or a Ruby Hash" unless kwargs.is_a?(Hash)
      kwargs = kwargs.transform_keys(&:to_sym)
      code = 0
      connect do |_net, _sv|
        px = ::Asterism[path, timeout: @opts[:timeout]]
        begin
          v = px.asterism_call(method, *args, **kwargs)
          @opts[:json] ? @out.puts(JSON.generate({ "value" => json_safe(v) })) : @out.puts(v.inspect)
        rescue ::Asterism::RemoteError => e
          if @opts[:json]
            @out.puts JSON.generate({ "error" => { "kind" => e.remote_kind, "class" => e.remote_class,
                                                   "message" => e.remote_message } })
          else
            @err.puts "asterism: #{path}.#{method}: #{e.remote_kind || 'error'}: #{e.message}"
          end
          code = 1
        rescue ::Asterism::TimeoutError => e
          @err.puts "asterism: #{e.message}" \
                    "#{"\n  (with a console's .tar, the router refuses a call its role does not allow; " \
                       'it looks the same as no answer)' if @opts[:credentials]}"
          code = 1
        end
      end
      code
    end

    # ------------------------------------------------------------ mcp

    def cmd_mcp(_rest)
      begin
        require_relative "cli/mcp"
      rescue LoadError => e
        raise unless e.message.include?("mcp")
        @err.puts "asterism mcp needs the mcp gem: gem install mcp (#{e.message})"
        return 1
      end
      connect(app_prefix: "mcp") do |net, sv|
        MCPBridge.new(net, sv, allow: @opts[:allow], log: @err).run
      end
      0
    end

    # ------------------------------------------------------------ text

    def profile_text(pr)
      return "" unless pr
      parts = [pr["kind"], pr["host"]].compact.join("/")
      name = pr["name"] ? " \"#{pr['name']}\"" : ""
      "  (#{parts})#{name}"
    end

    def methods_text(list)
      list.map { |m| signature(m) }.join(" ")
    end

    # name(arg, arg) with the names the meta tells, else name(2) / name(*).
    def signature(m)
      return "#{m['name']}(#{m['args'].join(', ')}#{', *' if m['arity'].negative?})" if m["args"]
      m["arity"].negative? ? "#{m['name']}(*)" : "#{m['name']}(#{m['arity']})"
    end

    def compact(v)
      JSON.generate(json_safe(v))
    end

    # A value as JSON can hold it (bytes as a note).
    def json_safe(v)
      case v
      when Hash then v.to_h { |k, x| [k.to_s, json_safe(x)] }
      when Array then v.map { json_safe(_1) }
      when String then v.encoding == Encoding::BINARY && !v.ascii_only? ? "(#{v.bytesize} bytes)" : v
      else v
      end
    end
  end
end
