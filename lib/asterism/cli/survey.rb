# What `asterism nodes / objects / tree` and the MCP bridge read from the
# network, on a connection that is already open (Asterism.connect): the
# applications and objects from the liveliness tokens, then the meta of
# the objects, the nodes' profiles and the applications' statuses
# (docs/protocol.md 5, 7, 8) with one get for each node or application.
#
# Not one wildcard get for all (asterism/*/*/@profile): behind a router's
# access control a query must fit the rules of every node it would reach
# (a game host may answer asterism/games/*/@profile, not asterism/*/*/@profile),
# so a wildcard over the nodes is refused where the plain keys pass. The
# gets go out at once and are read as their replies come (zenoh-c fills
# them on its own threads), so a listing costs one time limit at most,
# whatever the number of nodes. What a router refuses is simply not there,
# and the listing says so instead of calling a node gone.
module Asterism
  class CLI
    class Survey
      # What watch subscribes to (puts are routed per subscriber, so the
      # wildcards pass where the rules let them through).
      PROFILES_ALL = "asterism/*/@profile"
      STATUS_ALL = "asterism/*/*/@status"
      STEP = 0.005

      attr_reader :timeout

      # own: this connection's "<node>/<app>", left out of the listings.
      def initialize(timeout: 2.0, own: nil)
        @timeout = timeout
        @own = own || "#{::Asterism.node_id}/#{::Asterism.app}"
        @object_docs = {}
      end

      # Waits for the tokens alive at connect to come in (they come in one
      # burst from the router): until the applications stop changing for
      # quiet seconds, at most max seconds.
      def settle(max = 1.5, quiet: 0.3)
        t0 = now
        last = nil
        since = now
        loop do
          cur = [::Asterism.apps, ::Asterism.each("**").size]
          if cur != last
            last = cur
            since = now
          end
          break if now - since >= quiet || now - t0 >= max
          sleep 0.02
        end
      end

      # The applications alive, "<node>/<app>", sorted (this one left out).
      def apps(pattern = "*/*")
        (::Asterism.apps(pattern) - [@own]).sort
      end

      # The nodes that have an application or an object alive (sorted).
      def nodes
        (apps.map { _1.split("/")[0] } + objects.map { _1.split("/")[0] }).uniq.sort
      end

      # The objects alive, "<node>/<app>/<object>", sorted (this
      # application's own left out).
      def objects(pattern = "**")
        ::Asterism.each(pattern).map(&:asterism_path).reject { _1.start_with?("#{@own}/") }.sort
      end

      # {path => [{"name", "arity"}, ...]} for the paths given (an object
      # that does not answer its meta in time is left out). One get per
      # application (asterism/<node>/<app>/*/meta), then one for each object
      # it did not bring.
      def metas(paths)
        return {} if paths.empty?
        out = {}
        apps = paths.map { _1.split("/")[0, 2].join("/") }.uniq
        gets(apps.map { "asterism/#{_1}/*/meta" }).each_value do |replies|
          replies.each do |key, payload|
            path = key.delete_prefix("asterism/").delete_suffix("/meta")
            m = meta_list(payload, path)
            out[path] = m if m && paths.include?(path)
          end
        end
        missing = paths - out.keys
        unless missing.empty?
          gets(missing.map { "asterism/#{_1}/meta" }).each do |key, replies|
            path = key.delete_prefix("asterism/").delete_suffix("/meta")
            m = replies.first && meta_list(replies.first[1], path)
            out[path] = m if m
          end
        end
        out
      end

      # {node => profile without the icon} of the nodes that answered (one
      # get per node, all at once).
      def profiles(list = nodes)
        out = {}
        gets(list.map { "asterism/#{_1}/@profile" }, params: "icon=0").each do |key, replies|
          pr = replies.first && ::Asterism::Profile.check(::Asterism::Codec.unpack(replies.first[1]))
          out[key.split("/")[1]] = pr if pr
        end
        out
      end

      # {"<node>/<app>" => status} of the applications that answered (one
      # get per application on its own profile, ?status, all at once).
      def statuses(list = apps)
        out = {}
        gets(list.map { "asterism/#{_1}/@profile" }, params: "status").each do |key, replies|
          raw = replies.first && ::Asterism::Codec.unpack(replies.first[1])
          st = raw.is_a?(Hash) && ::Asterism::Status.check(raw["status"])
          parts = key.split("/")
          out["#{parts[1]}/#{parts[2]}"] = st if st
        end
        out
      end

      # The tree: [{"node", "profile", "apps" => [{"app", "status",
      # "objects" => [{"name", "methods"}]}]}]. meta: false leaves the
      # methods out (no meta gets); node: (and app:) narrow it to one node
      # (one application).
      def tree(meta: true, node: nil, app: nil)
        scope = node && "#{node}/#{app || '*'}"
        objs = scope ? objects("#{scope}/*") : objects
        app_list = scope ? apps(scope) : apps
        threads = []
        node_list = (app_list.map { _1.split("/")[0] } + objs.map { _1.split("/")[0] }).uniq
        threads << Thread.new { profiles(node_list) }
        threads << Thread.new { statuses(app_list) }
        threads << Thread.new { meta ? metas(objs) : {} }
        prof, stat, met = threads.map(&:value)
        by_node = Hash.new { |h, k| h[k] = {} }
        app_list.each { |a| n, ap = a.split("/"); by_node[n][ap] ||= [] }
        objs.each do |o|
          n, ap, name = o.split("/")
          (by_node[n][ap] ||= []) << name
        end
        by_node.keys.sort.map do |n|
          apps = by_node[n].keys.sort.map do |ap|
            h = { "app" => ap }
            h["status"] = stat["#{n}/#{ap}"] if stat.key?("#{n}/#{ap}")
            h["objects"] = by_node[n][ap].sort.map do |name|
              e = { "name" => name }
              e["methods"] = met["#{n}/#{ap}/#{name}"] if met.key?("#{n}/#{ap}/#{name}")
              d = object_doc("#{n}/#{ap}/#{name}")
              e["doc"] = d if d
              e
            end
            h
          end
          h = { "node" => n }
          h["profile"] = prof[n] if prof[n]
          h["apps"] = apps
          h
        end
      end

      # Sends a get on each key at once and waits for all of them (at most
      # the time limit): {key => [[reply key, payload], ...]}.
      def gets(keys, params: nil)
        s = ::Asterism.session
        ms = (@timeout * 1000).round
        pending = keys.to_h { |k| [k, s.get(k, timeout_ms: ms, params: params)] }
        out = keys.to_h { [_1, []] }
        until pending.empty?
          pending.delete_if do |k, g|
            ended = g.done?
            out[k].concat(g.each_reply.map { |r| [r[0], r[1]] })
            ended
          end
          sleep STEP unless pending.empty?
        end
        out
      rescue ::Asterism::Zenoh::Error => e
        raise ::Asterism::Disconnected, e.message
      end

      # A meta reply's methods: [{"name", "arity"} and, when the object
      # tells them (docs/protocol.md 5), "args" (names) and "doc"]. Fields
      # of another shape are left out, unknown ones ignored.
      def meta_list(payload, path = nil)
        m = ::Asterism::Codec.unpack(payload)
        list = m.is_a?(Hash) ? m["methods"] : nil
        return nil unless list.is_a?(Array)
        @object_docs[path] = m["doc"] if path && m["doc"].is_a?(String)
        list.filter_map do |e|
          next unless e.is_a?(Hash) && e["name"]
          h = { "name" => e["name"].to_s, "arity" => e["arity"].to_i }
          args = e["args"]
          h["args"] = args if args.is_a?(Array) && args.all? { _1.is_a?(String) } &&
                              (h["arity"].negative? || args.size == h["arity"])
          h["doc"] = e["doc"] if e["doc"].is_a?(String)
          h
        end
      end

      # The text an object tells about itself in its meta (read by metas),
      # or nil.
      def object_doc(path)
        @object_docs[path]
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
