# The noun-verb commands of the command line (node, app, object, topic, status:
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
          next
        end
        # Its own types too (one more get, ?types), when it defines some.
        types = a["topics"] ? sv.topics(["#{node}/#{app}"]).dig("#{node}/#{app}", "types") : nil
        a = a.except("objects").merge("types" => types, "objects" => a["objects"]) if types && !types.empty?
        if structured?
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

    # The next value the application puts on its own keys (PATH/KEY: a put
    # is kept nowhere, so it waits for one; --timeout, 5.0 s).
    def cmd_object_get(rest)
      pattern = put_pattern!(rest, "object get")
      wait = @opts[:put_timeout] || 5.0
      raise ArgumentError, "--timeout: more than 0" unless wait.positive?
      code = 0
      connect do |net, _sv|
        q = Queue.new
        hold net.zenoh.subscribe(Values.key_expr(pattern), depth: 16) { |s| q << [s, Time.now] }
        got = pop_until(q, wait)
        if got.nil?
          @err.puts nothing_came(pattern, wait)
          code = 1
          next
        end
        e = sample_entry(*got)
        if structured?
          emit(e)
        else
          put_lines(got[1], e, nil).each { @out.puts _1 }
        end
      end
      code
    end

    # The values the application puts on its own keys, as they come: the
    # text shows a key's value whole the first time (and always with
    # --raw), then what changed; -o json / yaml each put whole.
    def cmd_object_echo(rest)
      pattern = put_pattern!(rest, "object echo")
      code = 0
      connect do |net, _sv|
        q = Queue.new
        hold net.zenoh.subscribe(Values.key_expr(pattern), depth: 256) { |s| q << [s, Time.now] }
        seen = 0
        last = {}
        seq = Values::Seq.new
        until_stopped(net) do |left|
          got = q.pop(timeout: [left || 0.2, 0.2].min)
          next unless got
          seen += 1
          e = sample_entry(*got, seq: seq)
          if structured?
            emit_line(e)
          else
            # A shared key's senders each their own (Values.lane).
            lane = Values.lane(e["key"], e["from"])
            whole = @opts[:raw] || !last.key?(lane)
            old = last[lane]
            last[lane] = e["value"]
            lines = whole ? put_lines(got[1], e, nil) : put_lines(got[1], e, old, again: true)
            lines&.each { @out.puts _1 }
          end
          @out.flush
          break if @opts[:once]
        end
        if seen.zero?
          @err.puts nothing_came(pattern, @opts[:duration])
          code = 1 if @opts[:once]
        end
      end
      code
    end

    # ------------------------------------------------------------ topic

    # The topics of the applications that match NODE/APP (* for a part;
    # */* by default): node/app/name a line, with the type.
    def cmd_topic_list(rest)
      pattern = rest.shift || "*/*"
      parts = pattern.split("/", -1)
      unless parts.size == 2 && parts.none? { _1.empty? || (_1.include?("*") && _1 != "*") }
        raise ArgumentError, "topic list: NODE/APP, * for a part (asterism topic list 'games/*')"
      end
      connect do |_net, sv|
        list = sv.topics(sv.apps(pattern)).sort.flat_map do |path, h|
          h["topics"].map do |t|
            n, a = path.split("/")
            e = { "path" => ::Asterism::Pubs.path(n, a, t["name"]) }
            e["by"] = path if t["shared"] # a shared place: the application that declares it
            e.merge(t.except("name"))
          end
        end
        if structured?
          emit(list)
        else
          list.each do |t|
            by = t["by"] ? "  #{paint("(#{t['shared']}, by #{t['by']})", :note)}" : ""
            @out.puts "#{paint_path(t['path'])}  #{paint(topic_about(t), :note)}#{by}"
          end
        end
      end
      0
    end

    # One topic (node/app/name, the name may have more parts): its
    # declaration, and the definition of its type when it is one of the
    # application's own. A shared key (node/@shared/name, @shared/name):
    # each application that declares it, with its own declaration and the
    # definition of its type from its own types (senders may define one
    # type name differently).
    def cmd_topic_info(rest)
      path = rest.shift.to_s
      pl = ::Asterism::Pubs.place(path)
      return shared_topic_info(path, pl) if pl && pl[0]
      parts = path.split("/", -1)
      if parts.size < 3 || parts.any? { _1.empty? || _1.include?("*") }
        raise ArgumentError, "topic info: PATH is node/app/name (asterism topic info games/games/othello1/state)"
      end
      app = parts[0, 2].join("/")
      name = parts[2..].join("/")
      code = 0
      connect do |_net, sv|
        h = sv.topics([app])[app]
        t = h && h["topics"].find { _1["name"] == name }
        if t.nil?
          @err.puts "asterism: no topic #{path} is declared#{h ? '' : " (#{app} does not answer)"}"
          code = 1
          next
        end
        out = { "path" => path }.merge(t.except("name"))
        d = t["type"].is_a?(String) && h["types"][t["type"]]
        out["definition"] = d if d
        if structured?
          emit(out)
        else
          @out.puts paint_path(path)
          @out.puts "  #{paint('type:', :note)} #{t['type'] || '(no type)'}"
          @out.puts "  #{paint('encoding:', :note)} #{t['encoding'] || 'msgpack'}"
          @out.puts "  #{paint('unit:', :note)} #{t['unit']}" if t["unit"]
          @out.puts "  #{paint('time:', :note)} the sender's, with each value" if t["ts"]
          Text.wrap_text(t["desc"], style.width, first: "  ").each { @out.puts _1 } if t["desc"]
          types_block({ t["type"] => d }, 2, label: "definition:") if d
        end
      end
      code
    end

    # topic info for a shared key: the publishers, each with its own
    # declaration and type definition.
    def shared_topic_info(path, pl)
      code = 0
      connect do |_net, sv|
        apps = sv.apps(pl[0] == :node ? "#{pl[1]}/*" : "*/*")
        pubs = sv.topics(apps).sort.filter_map do |app, h|
          t = h["topics"].find { _1["name"] == path }
          next unless t
          e = { "by" => app }.merge(t.except("name", "shared"))
          d = t["type"].is_a?(String) && h["types"][t["type"]]
          e["definition"] = d if d
          e
        end
        if pubs.empty?
          @err.puts "asterism: no application declares #{path}"
          code = 1
          next
        end
        if structured?
          emit({ "path" => path, "shared" => pl[0].to_s, "publishers" => pubs })
        else
          @out.puts "#{paint_path(path)}  #{paint("(#{pl[0]})", :note)}"
          pubs.each do |t|
            @out.puts "  #{paint('by', :note)} #{paint_path(t['by'])}  #{paint(topic_about(t), :note)}"
            Text.wrap_text(t["desc"], style.width, first: "    ").each { @out.puts _1 } if t["desc"]
            types_block({ t["type"] => t["definition"] }, 4, label: "definition:") if t["definition"]
          end
        end
      end
      code
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
      # (Not when it runs on a connection given to it: the program goes on.)
      Process.exit!(0) if @complete_abandoned && !embedded?
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

      # On a connection given to the command line: asked every time (its
      # program keeps what it needs; nothing is written here).
      def cached(entry, &blk)
        return blk.call if @cli.embedded?
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

    # PATH (node/app/object, * for a part) and KEY (the rest, ** by
    # default) as one pattern. A shared place's keys (docs/protocol.md
    # 17): PATH node/@shared/name... (a node's, * for the node) or
    # @shared/name... (the network's), then KEY the same way.
    def put_pattern!(rest, what)
      path = rest.shift
      key = rest.shift || "**"
      parts = path.to_s.split("/", -1)
      shared = parts[0] == Values::SHARED || parts[1] == Values::SHARED
      ok = shared ? parts.size >= 1 : parts.size == 3
      unless ok && parts.none? { _1.empty? || (_1.include?("*") && _1 != "*") }
        raise ArgumentError, "#{what}: PATH is node/app/object (* for a part), then KEY (asterism #{what} " \
                             "games/games/othello1 state); a shared place's: node/@shared/name or @shared/name " \
                             "(asterism #{what} games/@shared/spectate '*/state')"
      end
      Values.check_pattern!("#{path}/#{key}")
    end

    # Values.entry of a Zenoh sample received at t (its encoding and
    # attachment too).
    def sample_entry(sample, t, seq: nil)
      Values.entry(sample.key, sample.payload, t, encoding: sample.encoding, attachment: sample.attachment, seq: seq)
    end

    def nothing_came(pattern, seconds)
      "asterism: nothing came on #{pattern}#{seconds ? " in #{format('%g', seconds)} s" : ''} " \
        "(the router does not let this node read it, or it has not changed)"
    end

    # The lines of one put received at t: the time, the key and the value
    # whole; again (the key's value before was old): a line for each thing
    # that changed in a Hash, the value whole otherwise (nil: no change). A
    # value that is bytes in an encoding (a picture) shows as its encoding
    # and size. A line comes first when values were lost before this one,
    # or the sender started its numbers again (Values.entry). A shared
    # value's key is followed by its sender (from games/room01).
    def put_lines(t, e, old, again: false)
      head = "#{paint(t.strftime('%H:%M:%S.%L'), :time)} "
      v = e["value"]
      gap = put_gap(head, e)
      if again && old.is_a?(Hash) && v.is_a?(Hash)
        changes = Text.status_diff(old, v)
        return gap if changes.empty?
        return gap.to_a + changes.map { |c| "#{head}#{put_key(e)} #{change_text(c)}" }
      end
      return gap if again && old == v && !e["format"].include?("/")
      first = "#{head}#{put_key(e)}"
      return [*gap, "#{first} #{paint("(#{e['format']}, #{e['bytes']} bytes)", :note)}"] if bytes_value?(e)
      return [*gap, "#{first} #{Text.inline(v)}"] unless v.is_a?(Hash)
      [*gap, first, *Text.status_lines(v, style.width, Text.width(head))]
    end

    # Whether a value is bytes in an encoding (shown by its size).
    def bytes_value?(e)
      e["format"].include?("/") && e["value"] == "(#{e['bytes']} bytes)"
    end

    # [the line] saying what was lost before a value, or nil.
    def put_gap(head, e)
      if e["restarted"]
        ["#{head}#{put_key(e)} #{paint("(started again at #{e['seq']})", :note)}"]
      elsif e["lost"]
        ["#{head}#{put_key(e)} #{paint("(#{e['lost']} lost)", :note)}"]
      end
    end

    # A value's key as a line shows it, with a shared value's sender.
    def put_key(e)
      k = paint(e["key"], :object)
      e["from"] ? "#{k} #{paint('from', :note)} #{paint(e['from'], :app)}" : k
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
      types_block(a["types"], indent + 2)
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
      hold(net.zenoh.subscribe("asterism/#{path}/@status") do |sample|
        got = ::Asterism::Status.parse(sample.key, sample.payload)
        yield got[2] if got
      end)
    end

    # Yields until Ctrl-C, --duration or a lost connection (the seconds
    # left of --duration, or nil).
    def until_stopped(net)
      deadline = @opts[:duration] && (now + @opts[:duration])
      loop do
        left = deadline && (deadline - now)
        break if left && left <= 0
        break unless net.connected?
        break if stopped?
        yield left
      end
    end

    # The next item of the queue within seconds (nil: none came, or stop:
    # asked to end first).
    def pop_until(queue, seconds)
      deadline = now + seconds
      loop do
        left = deadline - now
        return nil if left <= 0 || stopped?
        got = queue.pop(timeout: [left, 0.2].min)
        return got if got
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
