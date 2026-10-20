# The command line of the gem (exe/asterism): look at an Asterism network
# from CRuby, and call an object when asked to. Its commands are a noun and
# a verb, as ros2's are:
#
#   asterism node list   --router tcp/192.0.2.2:7447
#   asterism node info   games --credentials admin.tar
#   asterism app list / app info games/games
#   asterism object list 'games/games/*' / object info games/games/othello1
#   asterism object find join             # the objects that have join
#   asterism status get  games/games      # echo: as it changes, hz: how often
#   asterism object get  games/games/othello1 state   # the next put there
#   asterism call        games/games/othello1 view '"<token>"'
#   asterism ping / watch / tree / mcp    # as before
#   asterism completion bash              # the shell's Tab completion
#
# The older commands (nodes, objects, echo) stay, with the same output.
# `-o json` / `-o yaml` (and --json, as before) on every command that reads.
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
require_relative "cli/text"
require_relative "cli/hz"
require_relative "cli/complete"
require_relative "cli/values"

module Asterism
  class CLI
    # The nouns and their verbs: verb => [its arguments, what it does].
    NOUNS = {
      "node" => {
        "list" => ["", "the nodes, a name a line"],
        "info" => ["NODE", "one node: its profile, applications (with their statuses) and objects"]
      },
      "app" => {
        "list" => ["", "the applications, node/app a line"],
        "info" => ["NODE/APP", "one application: its status and its objects"]
      },
      "object" => {
        "list" => ["[PATTERN]", "the objects, node/app/object a line (PATTERN: * and ** for whole parts)"],
        "info" => ["PATH", "one object (node/app/object): its description and its methods"],
        "find" => ["METHOD", "the objects that have the method (* as a wildcard)"],
        "get" => ["PATH [KEY]", "the next value the application puts on PATH/KEY (its own keys; KEY: ** " \
                                "by default; --timeout 5.0)"],
        "echo" => ["PATH [KEY]", "the values it puts there as they come (the text: what changed; --once: " \
                                 "the first; --raw: each whole)"]
      },
      "status" => {
        "get" => ["NODE/APP", "an application's status, now"],
        "echo" => ["NODE/APP", "its status, then each change as it comes (--once: now, once)"],
        "hz" => ["NODE/APP", "how often it changes: the rate, the intervals' min / max / std dev"]
      }
    }.freeze

    # The commands without a noun: name => [its arguments, what it does].
    COMMANDS = {
      "call" => ["PATH METHOD [ARG...]", "calls a method; each ARG is JSON, else a Ruby literal, else text"],
      "ping" => ["PATH", "round trips: PATH node/app/object (its meta) or node (its profile); " \
                         "--call METHOD [ARG...] times a call instead"],
      "watch" => ["", "nodes, applications and objects coming and going, and status changes"],
      "tree" => ["", "nodes > applications (with their status) > objects (--methods: their methods)"],
      "mcp" => ["", "an MCP server on stdio (needs the mcp gem): the listings as tools, and the methods " \
                    "--allow names"],
      "completion" => ["bash|zsh", "the shell's Tab completion: source <(asterism completion bash)"],
      "version" => ["", "the gem's version"]
    }.freeze

    # The older names, kept with their output.
    ALIASES = {
      "nodes" => "the nodes, their applications (with their statuses) and profiles, in one listing",
      "objects" => "[PATTERN] the objects with their descriptions and methods (object info of each)",
      "echo" => "ping"
    }.freeze

    # The options that take a value (what __complete skips over).
    VALUE_OPTIONS = %w[--router --credentials --peer --node --app -o --output --timeout --settle --duration --count
                       --interval --call --kwargs --allow --period --window].freeze

    def self.usage
      col = 30
      line = lambda do |name, args, what|
        Text.wrap_text(what, 80, first: "  #{"#{name} #{args}".strip.ljust(col - 3)} ").join("\n")
      end
      nouns = NOUNS.flat_map { |n, verbs| verbs.map { |v, (a, w)| line.("#{n} #{v}", a, w) } }
      cmds = COMMANDS.map { |c, (a, w)| line.(c, a, w) }
      <<~TEXT
        Usage: asterism NOUN VERB [ARG...] [options]    (asterism NOUN: its verbs)

        Commands (they only read, except call):
        #{nouns.join("\n")}

        #{cmds.join("\n")}

        Where the network is (one of them):
          --router LOCATOR     a router without TLS, e.g. tcp/192.0.2.2:7447
          --credentials TAR    a console's .tar (mutual TLS; its router and name)
        With none of --router, --credentials, --peer, the environment's
        ASTERISM_CREDENTIALS and ASTERISM_ROUTER are used instead.

        Output: text; -o json or -o yaml (the same content) on the commands that read
        (--json is -o json). On a terminal the text has colours (NO_COLOR=1: none) and
        the terminal's width; otherwise it is plain, 80 columns wide (or COLUMNS).

        Older names, kept: nodes (all the nodes in one listing), objects [PATTERN]
        (object info of each), echo (ping).
      TEXT
    end

    USAGE = usage

    # The verbs of a noun, for `asterism NOUN`.
    def self.noun_usage(noun)
      verbs = NOUNS.fetch(noun).map do |v, (a, w)|
        Text.wrap_text(w, 80, first: "  #{"#{noun} #{v} #{a}".strip.ljust(27)} ").join("\n")
      end
      "Usage: asterism #{noun} VERB [ARG...] [options]\n\n#{verbs.join("\n")}\n\n" \
        "asterism #{noun} VERB --help: its options; asterism --help: every command\n"
    end

    def self.start(argv, out: $stdout, err: $stderr, env: ENV)
      new(out: out, err: err, env: env).run(argv.dup)
    end

    def initialize(out: $stdout, err: $stderr, env: ENV)
      @out = out
      @err = err
      @env = env
      @lock = Mutex.new
      @last_status = {}
      @opts = { timeout: 2.0, settle: 1.5, format: nil, count: 5, interval: 0.2, allow: [], period: 1.0,
                window: 1000 }
    end

    def run(argv)
      cmd = argv.shift
      case cmd
      when nil, "help", "-h", "--help"
        if cmd == "help" && NOUNS.key?(argv.first)
          @out.puts CLI.noun_usage(argv.first)
          return 0
        end
        @out.puts USAGE
        return cmd.nil? ? 2 : 0
      when "version", "--version", "-v"
        @out.puts "asterism #{::Asterism::VERSION}"
        return 0
      when "__complete"
        return cmd_complete(argv)
      end
      key = cmd
      if NOUNS.key?(cmd)
        verb = argv.first
        if verb.nil? || %w[-h --help].include?(verb) || verb.start_with?("-")
          @out.puts CLI.noun_usage(cmd)
          return %w[-h --help].include?(verb) ? 0 : 2
        end
        unless NOUNS[cmd].key?(verb)
          @err.puts "asterism: #{cmd} has no verb #{verb.inspect}\n\n#{CLI.noun_usage(cmd)}"
          return 2
        end
        argv.shift
        key = "#{cmd} #{verb}"
      elsif !(COMMANDS.key?(cmd) || ALIASES.key?(cmd))
        @err.puts "asterism: unknown command #{cmd.inspect}\n\n#{USAGE}"
        return 2
      end
      rest = parser(key).parse(argv)
      send("cmd_#{key == 'echo' ? 'ping' : key.tr(' ', '_')}", rest)
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

    # The options of a command (key: "tree", "node info", ...).
    def parser(key)
      OptionParser.new do |o|
        args = (NOUNS.dig(*key.split(" ")) || COMMANDS[key] || [""])[0]
        o.banner = "Usage: asterism #{key} #{args} [options]".squeeze(" ")
        unless key == "completion"
          o.on("--router LOCATOR", "a router (tcp/HOST:7447)") { @opts[:router] = _1 }
          o.on("--credentials TAR", "a console's .tar") { @opts[:credentials] = _1 }
          o.on("--peer LOCATOR", "a direct peer link to a node listening there (no router)") { @opts[:peer] = _1 }
          o.on("--node NAME", "this node's ID (default: the certificate's name, or cli-<6 hex>)") { @opts[:node] = _1 }
          o.on("--app NAME", "this application's name (default: cli-<4 hex>)") { @opts[:app] = _1 }
          unless key == "mcp"
            o.on("-o", "--output FORMAT", %w[json yaml], "json or yaml instead of text (the same content)") do
              @opts[:format] = _1.to_sym
            end
            o.on("--json", "JSON instead of text (-o json)") { @opts[:format] = :json }
          end
          if key == "object get"
            o.on("--timeout SECONDS", Float, "how long to wait for a put (5.0)") { @opts[:put_timeout] = _1 }
          else
            o.on("--timeout SECONDS", Float, "time limit of each get or call (2.0)") { @opts[:timeout] = _1 }
          end
          o.on("--settle SECONDS", Float, "how long to wait for the tokens at connect (1.5)") { @opts[:settle] = _1 }
        end
        case key
        when "tree"
          o.on("--methods", "list each object's methods (else how many)") { @opts[:methods] = true }
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
        when "object echo"
          o.on("--once", "the first put, then stop") { @opts[:once] = true }
          o.on("--raw", "each value whole (the text; else what changed)") { @opts[:raw] = true }
          o.on("--duration SECONDS", Float, "stop after this long (default: until Ctrl-C)") { @opts[:duration] = _1 }
        when "status echo"
          o.on("--once", "the status now, once, then stop") { @opts[:once] = true }
          o.on("--duration SECONDS", Float, "stop after this long (default: until Ctrl-C)") { @opts[:duration] = _1 }
        when "status hz"
          o.on("--period SECONDS", Float, "how often to print (1.0)") { @opts[:period] = _1 }
          o.on("--window N", Integer, "how many of the last intervals count (1000)") { @opts[:window] = _1 }
          o.on("--duration SECONDS", Float, "stop after this long (default: until Ctrl-C)") { @opts[:duration] = _1 }
        end
      end
    end

    # ------------------------------------------------------------ the tables, for __complete

    def noun?(w)
      NOUNS.key?(w)
    end

    def nouns
      NOUNS.keys
    end

    def verbs(noun)
      NOUNS.fetch(noun).keys
    end

    def command_words
      NOUNS.keys + COMMANDS.keys + ALIASES.keys + ["help"]
    end

    # [key, its arguments] of the positional words (nil when they name no
    # command).
    def command_key(pos)
      return [nil, []] if pos.empty?
      if NOUNS.key?(pos[0])
        return [nil, []] unless pos[1] && NOUNS[pos[0]].key?(pos[1])
        return ["#{pos[0]} #{pos[1]}", pos[2..]]
      end
      return [pos[0], pos[1..]] if COMMANDS.key?(pos[0]) || ALIASES.key?(pos[0]) || pos[0] == "help"
      [nil, []]
    end

    def option_takes_value?(w)
      VALUE_OPTIONS.include?(w)
    end

    def options_for(key)
      return [] if key == "help"
      parser(key).top.list.flat_map { |sw| sw.respond_to?(:long) ? sw.long + sw.short : [] } + ["--help"]
    end

    # ------------------------------------------------------------ connecting

    # [router, credentials, peer]: the command line's, or, when it names
    # none of them, ASTERISM_ROUTER and ASTERISM_CREDENTIALS from the
    # environment (all or nothing, so a router given on the line never meets
    # a .tar from the environment).
    def network(env = @env)
      given = [@opts[:router], @opts[:credentials], @opts[:peer]]
      return given if given.any?

      router = env["ASTERISM_ROUTER"].to_s
      creds = env["ASTERISM_CREDENTIALS"].to_s
      [router.empty? ? nil : router, creds.empty? ? nil : creds, nil]
    end

    # Connects, starts the receiving thread, waits for the tokens and yields
    # the Net and a Survey.
    def connect(app_prefix: "cli")
      router, creds, peer = network
      if router.nil? && creds.nil? && peer.nil?
        raise ArgumentError, "where is the network? --router tcp/HOST:7447 or --credentials FILE.tar " \
                             "(or ASTERISM_CREDENTIALS / ASTERISM_ROUTER)"
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

    # -o json or -o yaml (or --json) given: the data instead of the text.
    def structured?
      !@opts[:format].nil?
    end

    # The data as -o asks: JSON (pretty, as --json always was) or YAML (the
    # same content: what the JSON holds, as YAML).
    def emit(v)
      @opts[:format] == :yaml ? @out.write(yaml(v)) : @out.puts(JSON.pretty_generate(v))
    end

    # One record of a stream (watch, status echo / hz, call): a JSON line,
    # or a YAML document ("---" before each).
    def emit_line(v)
      @opts[:format] == :yaml ? @out.write(yaml(v)) : @out.puts(JSON.generate(v))
    end

    def yaml(v)
      require "yaml"
      YAML.dump(JSON.parse(JSON.generate(v)))
    end

    # ------------------------------------------------------------ nodes

    def cmd_nodes(_rest)
      connect do |_net, sv|
        tree = sv.tree(meta: false)
        if structured?
          emit(tree.map { |n| n.merge("apps" => n["apps"].map { |a| a.except("objects") }) })
        elsif tree.empty?
          @out.puts "(no other node is visible)"
        else
          tree.each do |n|
            @out.puts node_line(n)
            n["apps"].each do |a|
              k = a["objects"].size
              @out.puts "  #{paint(a['app'], :app)}#{paint("  #{count(k, 'object')}", :note) unless k.zero?}"
              status_block(a, 4)
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
        if structured?
          emit(paths.map do |p|
            h = { "path" => p, "methods" => metas[p] }
            h["doc"] = sv.object_doc(p) if sv.object_doc(p)
            h
          end)
        elsif paths.empty?
          @out.puts "(no object matches #{pattern})"
        else
          paths.each { |p| object_entry(p, metas[p], sv.object_doc(p)) }
        end
      end
      0
    end

    # ------------------------------------------------------------ tree

    def cmd_tree(_rest)
      connect do |_net, sv|
        tree = sv.tree
        if structured?
          emit(tree)
        elsif tree.empty?
          @out.puts "(no other node is visible)"
        else
          tree.each do |n|
            @out.puts node_line(n)
            n["apps"].each do |a|
              @out.puts "  #{paint(a['app'], :app)}"
              status_block(a, 4)
              a["objects"].each do |o|
                ms = o["methods"]
                @out.puts "    #{paint(o['name'], :object)}  #{paint(ms ? count(ms.size, 'method') : '(no meta)', :note)}"
                method_list(ms, 6) if ms && @opts[:methods] && !ms.empty?
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
        @err.puts "asterism: watching (Ctrl-C to stop)" unless structured?
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
      if structured?
        h = { "t" => t.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"), "event" => kind, "path" => path }
        h["what"] = what if what
        h["status"] = status if status
        h["profile"] = profile if profile
        h["now"] = true if now
        @lock.synchronize { emit_line(h) }
      else
        @lock.synchronize do
          text = event_text(t, kind, path, what, status, profile, now)
          @out.puts text if text
        end
      end
      @out.flush
    end

    # The lines of one event (nil: nothing to tell). A status is told whole
    # (indented under the event) the first time it is seen, else only what
    # changed, a line for each change. An application or a node that leaves
    # takes its statuses along, so they are told whole when they are back.
    def event_text(t, kind, path, what, status, profile, now)
      head = "#{paint(t.strftime('%H:%M:%S.%L'), :time)} #{paint(EVENT_MARKS[kind], kind.to_sym)} "
      case kind
      when "status"
        status = json_safe(status)
        old = @last_status[path]
        @last_status[path] = status
        label = "status #{paint(path, :app)}"
        if old.nil? || !old.is_a?(Hash) || !status.is_a?(Hash)
          lines = Text.status_lines(status, style.width, Text.width(head))
          return "#{head}#{label}#{paint(' (now)', :note) if now}\n#{lines.join("\n")}"
        end
        changes = Text.status_diff(old, status)
        return nil if changes.empty?
        changes.map { |c| "#{head}#{label} #{change_text(c)}" }.join("\n")
      when "profile" then "#{head}profile #{paint(path, :node)}#{profile_text(profile)}"
      else
        forget_statuses(path) if kind == "leave"
        "#{head}#{what} #{paint(path, WHAT_ROLES.fetch(what, :object))}"
      end
    end

    EVENT_MARKS = { "join" => "+", "leave" => "-", "status" => "~", "profile" => "*" }.freeze
    WHAT_ROLES = { "node" => :node, "app" => :app, "object" => :object }.freeze

    def change_text(c)
      case c[0]
      when "+" then paint(c, :join)
      when "-" then paint(c, :leave)
      else c
      end
    end

    def forget_statuses(path)
      @last_status.delete_if { |k, _| k == path || k.start_with?("#{path}/") }
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
          @out.puts "#{path} #{what}: #{ok ? format('%.1f ms', dt) : 'no answer'}" unless structured?
        end
      end
      if structured?
        emit({ "path" => path, "what" => what, "count" => @opts[:count], "answered" => times.size,
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
          structured? ? emit_line({ "value" => json_safe(v) }) : @out.puts(v.inspect)
        rescue ::Asterism::RemoteError => e
          if structured?
            emit_line({ "error" => { "kind" => e.remote_kind, "class" => e.remote_class,
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

    def style
      @style ||= Style.new(@out, @env)
    end

    def paint(text, *styles)
      style.paint(text, *styles)
    end

    def count(n, what)
      "#{n} #{what}#{'s' unless n == 1}"
    end

    def profile_text(pr)
      return "" unless pr
      parts = [pr["kind"], pr["host"]].compact.join("/")
      name = pr["name"] ? " \"#{pr['name']}\"" : ""
      "  #{paint("(#{parts})", :note)}#{name}"
    end

    def node_line(n)
      "#{paint(n['node'], :node)}#{profile_text(n['profile'])}"
    end

    # An application's status (when it has one) under "status:", indented.
    def status_block(app, indent)
      return unless app.key?("status")
      @out.puts "#{' ' * indent}#{paint('status:', :note)}"
      Text.status_lines(json_safe(app["status"]), style.width, indent + 2).each { @out.puts _1 }
    end

    # The methods' signatures wrapped to the width, indented.
    def method_list(list, indent)
      sigs = list.map { paint(signature(_1), :method) }
      Text.wrap(sigs, style.width, first: " " * indent, sep: "  ").each { @out.puts _1 }
    end

    # One object of `objects`: its path, its description, then its methods:
    # one a line with their descriptions, the descriptions in one column and
    # wrapped (a signature too long for the column has its description on
    # the next line); or, when none has one, the signatures wrapped.
    def object_entry(path, methods, doc)
      @out.puts paint(path, :object)
      Text.wrap_text(doc, style.width, first: "  ").each { @out.puts _1 } if doc
      unless methods
        @out.puts "  #{paint('(no meta: not answered in time, or not allowed)', :note)}"
        return
      end
      return method_list(methods, 2) unless methods.any? { _1["doc"] }

      sigs = methods.map { signature(_1) }
      col = 2 + [sigs.map { Text.width(_1) }.max, SIGNATURE_COLUMN].min + 2
      methods.zip(sigs).each do |m, sig|
        head = "  #{paint(sig, :method)}"
        unless m["doc"]
          @out.puts head
          next
        end
        sw = 2 + Text.width(sig)
        if sw + 2 > col
          @out.puts head
          head = " " * col
        else
          head += " " * (col - sw)
        end
        Text.wrap_text(m["doc"], style.width, first: head, rest: " " * col).each { @out.puts _1 }
      end
    end

    # The widest signature the description column makes room for.
    SIGNATURE_COLUMN = 24

    # name(arg, arg) with the names the meta tells, else name(2) / name(*).
    def signature(m)
      return "#{m['name']}(#{m['args'].join(', ')}#{', *' if m['arity'].negative?})" if m["args"]
      m["arity"].negative? ? "#{m['name']}(*)" : "#{m['name']}(#{m['arity']})"
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
require_relative "cli/nouns"
