# The noun-verb commands of the command line (node, app, object, status:
# lib/asterism/cli.rb's NOUNS), `completion` and the hidden `__complete`
# (lib/asterism/cli/complete.rb).
module Asterism
  class CLI
    # ------------------------------------------------------------ node

    def cmd_node_list(_rest)
      connect do |_net, sv|
        names = sv.nodes
        structured? ? emit(names) : names.each { @out.puts paint(_1, :node) }
      end
      0
    end

    def cmd_node_info(rest)
      node = rest.shift
      raise ArgumentError, "node info: which node? (asterism node info NODE)" unless node && !node.empty?
      raise ArgumentError, "node info: NODE is a node's name (no /)" if node.include?("/")
      code = 0
      connect do |_net, sv|
        entry = sv.tree(node: node).first
        if entry.nil?
          @err.puts "asterism: no node #{node} is visible"
          code = 1
        elsif structured?
          emit(entry)
        else
          @out.puts paint(entry["node"], :node)
          if entry["profile"]
            pr = entry["profile"].except("icon")
            Text.wrap(pr.map { |k, v| Text.pair(k, v) }, style.width, first: "  #{paint('profile:', :note)} ",
                                                                       rest: "    ", break_long: false)
                .each { @out.puts _1 }
          end
          entry["apps"].each { |a| app_block(a["app"], a, 2) }
        end
      end
      code
    end

    # ------------------------------------------------------------ app

    def cmd_app_list(_rest)
      connect do |_net, sv|
        names = sv.apps
        structured? ? emit(names) : names.each { @out.puts paint_path(_1) }
      end
      0
    end

    def cmd_app_info(rest)
      node, app = app_path!(rest, "app info").split("/")
      code = 0
      connect do |_net, sv|
        a = sv.tree(node: node, app: app).first&.dig("apps")&.find { _1["app"] == app }
        if a.nil?
          @err.puts "asterism: no application #{node}/#{app} is visible"
          code = 1
        elsif structured?
          emit({ "node" => node }.merge(a))
        else
          app_block("#{node}/#{app}", a, 0)
        end
      end
      code
    end

    # ------------------------------------------------------------ object

    def cmd_object_list(rest)
      pattern = rest.shift || "**"
      connect do |_net, sv|
        paths = sv.objects(pattern)
        structured? ? emit(paths) : paths.each { @out.puts paint_path(_1) }
      end
      0
    end

    def cmd_object_info(rest)
      path = rest.shift
      unless path && path.split("/", -1).size == 3 && path.split("/").none? { _1.empty? || _1.include?("*") }
        raise ArgumentError, "object info: PATH is node/app/object (a pattern: asterism object list PATTERN)"
      end
      code = 0
      connect do |_net, sv|
        if sv.objects(path).empty?
          @err.puts "asterism: no object #{path} is visible"
          code = 1
          next
        end
        methods = sv.metas([path])[path]
        if structured?
          h = { "path" => path, "methods" => methods }
          h["doc"] = sv.object_doc(path) if sv.object_doc(path)
          emit(h)
        else
          object_entry(path, methods, sv.object_doc(path))
        end
      end
      code
    end

    def cmd_object_find(rest)
      want = rest.shift
      raise ArgumentError, "object find: which method? (asterism object find METHOD; * as a wildcard)" unless want
      found = []
      connect do |_net, sv|
        paths = sv.objects
        metas = sv.metas(paths)
        paths.each do |p|
          ms = (metas[p] || []).select { File.fnmatch?(want, _1["name"]) }
          found << { "path" => p, "methods" => ms } unless ms.empty?
        end
        structured? ? emit(found) : found.each { @out.puts paint_path(_1["path"]) }
      end
      0
    end

    # ------------------------------------------------------------ status

    def cmd_status_get(rest)
      path = app_path!(rest, "status get")
      code = 0
      connect do |_net, sv|
        st = sv.statuses([path])[path]
        if st.nil?
          @err.puts no_status(path)
          code = 1
        elsif structured?
          emit(json_safe(st))
        else
          Text.status_lines(json_safe(st), style.width).each { @out.puts _1 }
        end
      end
      code
    end

    # The status, then each change as it comes (the text: what changed, as
    # watch tells it); --once: the status now, once.
    def cmd_status_echo(rest)
      path = app_path!(rest, "status echo")
      code = 0
      connect do |net, sv|
        q = Queue.new
        subscribe_status(net, path) { |st| q << [Time.now, st] } unless @opts[:once]
        st = sv.statuses([path])[path]
        if st
          echo_event(Time.now, path, st, true)
        elsif @opts[:once]
          @err.puts no_status(path)
          code = 1
        end
        next if @opts[:once]

        until_stopped(net) do |left|
          got = q.pop(timeout: [left || 0.2, 0.2].min)
          echo_event(got[0], path, got[1], false) if got
        end
      end
      code
    end

    # How often the status changes: every --period, when a change came, the
    # average rate and the intervals (Hz).
    def cmd_status_hz(rest)
      path = app_path!(rest, "status hz")
      raise ArgumentError, "--window: 1 or more" unless @opts[:window].positive?
      raise ArgumentError, "--period: more than 0" unless @opts[:period].positive?
      connect do |net, sv|
        hz = Hz.new(window: @opts[:window])
        lock = Mutex.new
        subscribe_status(net, path) { |st| lock.synchronize { hz.put(st) } }
        st = sv.statuses([path])[path]
        lock.synchronize { hz.seed(st) } if st
        @err.puts "asterism: #{path}: counting the status's changes (Ctrl-C to stop)" unless structured?
        nxt = now + @opts[:period]
        until_stopped(net) do |_left|
          sleep 0.05
          next if now < nxt
          nxt += @opts[:period]
          s = lock.synchronize { hz.report }
          next unless s
          if structured?
            emit_line({ "t" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"), "path" => path }.merge(s))
          else
            Hz.text(s).each { @out.puts _1 }
          end
          @out.flush
        end
      end
      0
    end

    # ------------------------------------------------------------ completion

    def cmd_completion(rest)
      case rest.shift
      when "bash" then @out.write(Complete::BASH)
      when "zsh" then @out.write(Complete::ZSH)
      else raise ArgumentError, "completion: bash or zsh (source <(asterism completion bash))"
      end
      0
    end

    # The candidates for the word being completed, one a line. The words
    # come as arguments (the last one the word being completed), after
    # "--"; or (--bash LINE) as bash's line up to the cursor.
    def cmd_complete(argv)
      bash = argv.first == "--bash"
      words = if bash
                Complete.split_line(argv[1].to_s)
              else
                argv.first == "--" ? argv.drop(1) : argv
              end
      words = [""] if words.empty?
      @complete_words = words
      cands = Complete.new(self, CompleteSource.new(self, words)).candidates(words)
      cands = Complete.bash_trim(cands, words.last) if bash && cands != [Complete::FILES]
      cands.each { @out.puts _1 }
      @out.flush
      # A connection still trying past the budget is left behind: the
      # process ends without waiting for it.
      Process.exit!(0) if @complete_abandoned
      0
    end

    # What __complete asks the network for, through the cache: the names
    # (the tokens) and an object's methods (its meta).
    class CompleteSource
      def initialize(cli, words)
        @cli = cli
        @words = words
      end

      def names
        cached("names") do
          @cli.complete_fetch { |sv| { "apps" => sv.apps, "objects" => sv.objects } }
        end
      end

      def methods(path)
        cached("methods #{path}") do
          @cli.complete_fetch { |sv| sv.metas([path])[path]&.map { _1["name"] } }
        end
      end

      def all_methods
        cached("methods") do
          @cli.complete_fetch { |sv| sv.metas(sv.objects).values.flatten.map { _1["name"] }.uniq.sort }
        end
      end

      private

      def cached(entry, &blk)
        net = @cli.complete_network(@words)
        return nil if net.none?
        dir = Complete::Cache.dir(@cli.env)
        return blk.call unless dir
        Complete::Cache.new(dir: dir, network: net).fetch(entry, &blk)
      end
    end

    attr_reader :env

    # Where the network is for __complete: the options among the words,
    # else the environment (network). [router, credentials (its full path),
    # peer]
    def complete_network(words)
      words.each_cons(2) do |a, b|
        case a
        when "--router" then @opts[:router] = b
        when "--credentials" then @opts[:credentials] = b
        when "--peer" then @opts[:peer] = b
        end
      end
      r, c, pr = network
      [r, c && File.expand_path(c), pr]
    end

    # Connects for at most Complete::BUDGET seconds and yields the Survey;
    # the block's value, or nil when the network did not answer in time.
    def complete_fetch
      @opts[:settle] = 0.6
      @opts[:timeout] = 0.6
      out = Queue.new
      th = Thread.new do
        err = @err
        @err = File.open(File::NULL, "w")
        begin
          connect { |_net, sv| out << yield(sv) }
        rescue StandardError, ScriptError
          out << nil
        ensure
          @err = err
        end
      end
      v = out.pop(timeout: Complete::BUDGET)
      if v.nil? && th.alive?
        @complete_abandoned = true
        return nil
      end
      th.join(0.5) || (@complete_abandoned = true)
      v
    end

    # ------------------------------------------------------------ helpers

    def app_path!(rest, what)
      path = rest.shift
      ok = path && path.split("/", -1).size == 2 && path.split("/").none? { _1.empty? || _1.include?("*") }
      raise ArgumentError, "#{what}: which application? (asterism #{what} NODE/APP)" unless ok
      path
    end

    def no_status(path)
      "asterism: no status from #{path} (not there, no status, or no answer in time)"
    end

    # node/app[/object] painted part by part.
    def paint_path(path)
      parts = path.split("/")
      roles = %i[node app object]
      parts.each_with_index.map { |p, i| paint(p, roles[i] || :object) }.join(paint("/", :note))
    end

    # An application (a tree's entry) under its name: its status and its
    # objects (how many methods, and the object's description).
    def app_block(name, a, indent)
      pad = " " * indent
      @out.puts "#{pad}#{paint(name, :app)}"
      status_block(a, indent + 2)
      return if a["objects"].empty?
      @out.puts "#{pad}  #{paint('objects:', :note)}"
      a["objects"].each do |o|
        ms = o["methods"]
        @out.puts "#{pad}    #{paint(o['name'], :object)}  #{paint(ms ? count(ms.size, 'method') : '(no meta)', :note)}"
        Text.wrap_text(o["doc"], style.width, first: "#{pad}      ").each { @out.puts _1 } if o["doc"]
      end
    end

    # The status's puts of one application, cleaned (Status.parse).
    def subscribe_status(net, path)
      net.session.subscribe("asterism/#{path}/@status") do |sample|
        got = ::Asterism::Status.parse(sample.key, sample.payload)
        yield got[2] if got
      end
    end

    # Yields until Ctrl-C, --duration or a lost connection (the seconds
    # left of --duration, or nil).
    def until_stopped(net)
      deadline = @opts[:duration] && (now + @opts[:duration])
      loop do
        left = deadline && (deadline - now)
        break if left && left <= 0
        break unless net.connected?
        yield left
      end
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # One record of status echo: JSON / YAML, or the text (the status whole
    # the first time, then a line for each change).
    def echo_event(t, path, status, first)
      status = json_safe(status)
      if structured?
        h = { "t" => t.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"), "path" => path, "status" => status }
        h["now"] = true if first
        emit_line(h)
      else
        text = echo_text(t, path, status, first)
        @out.puts text if text
      end
      @out.flush
    end

    # The text of one record of status echo (nil: no change).
    def echo_text(t, path, status, first)
      head = "#{paint(t.strftime('%H:%M:%S.%L'), :time)} "
      old = @echo_last
      @echo_last = status
      if first || !old.is_a?(Hash) || !status.is_a?(Hash)
        lines = Text.status_lines(status, style.width, Text.width(head))
        return "#{head}#{paint(path, :app)}#{paint(' (now)', :note) if first}\n#{lines.join("\n")}"
      end
      changes = Text.status_diff(old, status)
      return nil if changes.empty?
      changes.map { |c| "#{head}#{change_text(c)}" }.join("\n")
    end
  end
end
