# The shell's Tab completion: `asterism completion bash|zsh` prints a
# script, and the script calls the hidden `asterism __complete` on each
# Tab, which prints the candidates, one a line.
#
# The commands, the verbs and the options come from the command line's own
# tables (no network). The names on the network (nodes, node/app,
# node/app/object, an object's methods) come from the network named on the
# line (--router, --credentials, --peer) or in the environment, asked
# briefly (Complete::BUDGET: nothing comes back when it does not answer in
# time, the shell is not kept waiting) and remembered for a few seconds
# (Cache: a file per network under $XDG_CACHE_HOME/asterism, named by a
# digest of where the network is; it holds names only, never a key or a
# certificate). A name with "/" is completed a part at a time:
# `ga<Tab>` gives `games/`, `games/games/<Tab>` the objects.
require "json"
require "digest"
require "fileutils"
require "shellwords"

module Asterism
  class CLI
    class Complete
      # Seconds the network may take to answer one Tab (connecting, the
      # tokens, a meta get).
      BUDGET = 1.5
      # What a line of the output means "complete a file name here".
      FILES = ":files"

      # spec: the CLI (its command tables and option lists); source: what
      # the network names (#names, #methods(path), #all_methods), each
      # nil when it did not answer.
      def initialize(spec, source)
        @spec = spec
        @source = source
      end

      # The candidates for the last word of words (the words after
      # `asterism`, the last one the word being completed, "" for a new
      # one), those that start with it, sorted.
      def candidates(words)
        words = words.dup
        cur = words.pop || ""
        pos = []
        prev = nil
        words.each do |w|
          if prev
            prev = nil
            next
          end
          if w.start_with?("-") && w.size > 1
            prev = w if @spec.option_takes_value?(w)
            next
          end
          pos << w
        end
        key, args = @spec.command_key(pos)
        list =
          if prev then values(prev, key, args)
          elsif cur.start_with?("-") then key ? @spec.options_for(key) : []
          else positional(pos, key, args, cur)
          end
        return list if list == [FILES]
        list.select { _1.start_with?(cur) }.uniq.sort
      end

      private

      def values(opt, key, args)
        case opt
        when "-o", "--output" then %w[json yaml]
        when "--credentials" then [FILES]
        when "--call" then key == "ping" && args[0] ? methods_of(args[0]) : []
        else []
        end
      end

      def positional(pos, key, args, cur)
        return @spec.command_words if pos.empty?
        return @spec.verbs(pos[0]) if pos.size == 1 && @spec.noun?(pos[0])
        return [] unless key
        i = args.size
        case [key, i]
        when ["node info", 0] then nodes
        when ["app info", 0], ["status get", 0], ["status echo", 0], ["status hz", 0] then staged(cur, apps, 2)
        when ["object list", 0], ["object info", 0], ["object get", 0], ["object echo", 0], ["objects", 0], ["call", 0]
          staged(cur, objects, 3)
        when ["ping", 0], ["echo", 0] then (cur.include?("/") ? [] : nodes) + staged(cur, objects, 3)
        when ["object find", 0] then @source.all_methods || []
        when ["call", 1] then methods_of(args[0])
        when ["completion", 0] then %w[bash zsh]
        when ["help", 0] then @spec.nouns
        else []
        end
      end

      def methods_of(path)
        path.count("/") == 2 ? (@source.methods(path) || []) : []
      end

      def names
        @names ||= @source.names || { "apps" => [], "objects" => [] }
      end

      def objects
        names["objects"]
      end

      # The applications, with those that only objects tell of.
      def apps
        (names["apps"] + objects.map { _1.split("/")[0, 2].join("/") }).uniq
      end

      def nodes
        (apps + objects).map { _1.split("/")[0] }.uniq
      end

      # The next part of the paths (depth parts each) that start with cur:
      # the parts up to the one cur is in, with "/" after it when more come.
      def staged(cur, paths, depth)
        k = cur.count("/")
        return [] if k >= depth
        paths.filter_map do |p|
          s = p.split("/")
          next if s.size < depth
          c = s[0..k].join("/")
          c += "/" if k + 1 < depth
          c if c.start_with?(cur)
        end
      end

      public

      # The words of a command line up to the cursor (bash's COMP_LINE cut
      # at COMP_POINT): the words after the command, the last one the word
      # being completed ("" after a space). An open quote is closed.
      def self.split_line(line)
        words = begin
          Shellwords.split(line)
        rescue ArgumentError
          begin
            Shellwords.split("#{line}\"")
          rescue ArgumentError
            Shellwords.split("#{line}'")
          end
        end
        words << "" if line.match?(/\s\z/) || words.empty?
        words.drop(1)
      end

      # Bash splits the word being completed at ":" and "=" (COMP_WORDBREAKS):
      # the candidates without what comes before the last of them in cur.
      def self.bash_trim(cands, cur)
        cut = cur.rindex(/[:=]/)
        return cands unless cut
        cands.map { _1.start_with?(cur[0..cut]) ? _1[(cut + 1)..] : _1 }
      end

      # ------------------------------------------------------------ the cache

      # What __complete remembers of a network for a few seconds: a JSON
      # file per network ({entry => {"t" => seconds, "v" => value}}), the
      # directory 0700 and the files 0600. The network's identity is a
      # digest of where it is (router, the credentials file's path, peer);
      # nothing else about it is written.
      class Cache
        TTL = 20

        def initialize(dir:, network:, ttl: TTL, clock: -> { Time.now.to_f })
          @dir = dir
          @ttl = ttl
          @clock = clock
          id = network.map { _1.to_s }.join("\n")
          @file = File.join(dir, "#{Digest::SHA256.hexdigest(id)[0, 24]}.json")
        end

        attr_reader :file

        # The cache directory: $XDG_CACHE_HOME/asterism, else
        # ~/.cache/asterism.
        def self.dir(env)
          base = env["XDG_CACHE_HOME"].to_s
          base = File.join(Dir.home, ".cache") if base.empty?
          File.join(base, "asterism")
        rescue ArgumentError
          nil
        end

        # The entry's value when it is fresh, else the block's (kept unless
        # it is nil: what did not answer is asked again next time).
        def fetch(entry)
          data = read
          e = data[entry]
          now = @clock.call
          return e["v"] if e.is_a?(Hash) && e["t"].is_a?(Numeric) && now - e["t"] < @ttl && now >= e["t"]
          v = yield
          return v if v.nil?
          data = read.reject { |_, x| !x.is_a?(Hash) || !x["t"].is_a?(Numeric) || now - x["t"] >= @ttl }
          data[entry] = { "t" => now, "v" => v }
          write(data)
          v
        end

        private

        def read
          h = JSON.parse(File.read(@file))
          h.is_a?(Hash) ? h : {}
        rescue StandardError
          {}
        end

        def write(data)
          FileUtils.mkdir_p(@dir, mode: 0o700)
          tmp = "#{@file}.#{Process.pid}.tmp"
          File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { _1.write(JSON.generate(data)) }
          File.rename(tmp, @file)
        rescue StandardError
          begin
            File.unlink(tmp) if tmp
          rescue StandardError
            nil
          end
          nil
        end
      end

      # ------------------------------------------------------------ the scripts

      BASH = <<~'BASH'
        # asterism's Tab completion for bash: source <(asterism completion bash)
        # (or put that line in ~/.bashrc). Each Tab runs `asterism __complete`;
        # the names on the network come from the network named on the line
        # (--router, --credentials, --peer) or in ASTERISM_CREDENTIALS /
        # ASTERISM_ROUTER, asked briefly and remembered for a few seconds.
        _asterism() {
          local cur=${COMP_WORDS[COMP_CWORD]}
          local IFS=$'\n'
          local out
          out=$(asterism __complete --bash "${COMP_LINE:0:COMP_POINT}" 2>/dev/null)
          if [[ $out == ":files" ]]; then
            compopt -o filenames 2>/dev/null
            COMPREPLY=($(compgen -f -- "$cur"))
            return 0
          fi
          COMPREPLY=($out)
          local c
          for c in "${COMPREPLY[@]}"; do
            if [[ $c == */ ]]; then
              compopt -o nospace 2>/dev/null
              break
            fi
          done
          return 0
        }
        complete -F _asterism asterism
      BASH

      ZSH = <<~'ZSH'
        # asterism's Tab completion for zsh: source <(asterism completion zsh)
        # after compinit (or put that line in ~/.zshrc). Each Tab runs
        # `asterism __complete`; the names on the network come from the network
        # named on the line (--router, --credentials, --peer) or in
        # ASTERISM_CREDENTIALS / ASTERISM_ROUTER, asked briefly and remembered
        # for a few seconds.
        _asterism() {
          local -a cands slash plain
          cands=("${(@f)$(asterism __complete -- "${(@)words[2,CURRENT]}" 2>/dev/null)}")
          cands=(${cands:#})
          if [[ ${cands[1]} == ":files" ]]; then
            _files
            return
          fi
          slash=(${(M)cands:#*/})
          plain=(${cands:#*/})
          (( ${#plain} )) && compadd -- "${plain[@]}"
          (( ${#slash} )) && compadd -S '' -- "${slash[@]}"
          return 0
        }
        compdef _asterism asterism
      ZSH
    end
  end
end
