# `asterism mcp`: Asterism as tools of an MCP client (an AI assistant),
# over stdio, with the mcp gem (an optional dependency: `gem install mcp`;
# the rest of the command line does not need it).
#
#   asterism mcp --router tcp/192.0.2.2:7447 --allow 'games/othello1.*'
#
# Tools:
#   asterism_nodes     the nodes, their applications (with their statuses)
#                      and objects                         (always; reads)
#   asterism_objects   the objects and their methods (meta) (always; reads)
#   asterism_status    the applications' statuses           (always; reads)
#   <node>.<app>.<object>.<method>
#                      one per method that an --allow pattern names, made
#                      from the object's meta: the arguments' names the
#                      meta tells (docs/protocol.md 5) are the inputs and
#                      its doc the description; without names, arity n
#                      gives arg1 .. argN (any JSON value), arity -1 an
#                      array "args"; "kwargs" (an object) is the keyword
#                      arguments. Nothing is callable without --allow.
#
# The call tools follow the network: when objects appear or go, the list is
# made again and the client is told (notifications/tools/list_changed).
require "mcp"

module Asterism
  class CLI
    class MCPBridge
      REFRESH_S = 2.0
      INSTRUCTIONS = <<~TEXT.freeze
        These tools look at an Asterism network: Ruby programs and boards that expose objects to each other over
        Zenoh. Paths are <node>/<app>/<object>. asterism_nodes lists the nodes and their applications (with the
        status each application tells about itself, a JSON object of its own), asterism_objects the objects and
        their methods, asterism_status the statuses. The other tools call one method each, on the object their
        name says (<node>.<app>.<object>.<method>); only the methods this server was started to allow are there.
        A call's answer is {"value": ...}; an error says its kind (raised, not_exposed, arguments, ...).
      TEXT

      def initialize(net, survey, allow:, log: $stderr)
        @net = net
        @survey = survey
        @allow = Allow.new(allow)
        @log = log
        @call_tools = {}  # tool name => [path, method, arity, meta entry]
        @signature = nil
        @lock = Mutex.new
      end

      def run
        @server = ::MCP::Server.new(name: "asterism", version: ::Asterism::VERSION, instructions: INSTRUCTIONS,
                                    tools: read_tools)
        @transport = ::MCP::Server::Transports::StdioTransport.new(@server)
        @server.transport = @transport
        refresh
        @log.puts "asterism mcp: #{@net.node_id}/#{@net.app}; #{@call_tools.size} call tools" \
                  "#{@allow.empty? ? ' (no --allow: read-only)' : ''}"
        @refresher = Thread.new { refresh_loop }
        @transport.open
      ensure
        @refresher&.kill
      end

      # ------------------------------------------------------------ the list

      def refresh_loop
        loop do
          sleep REFRESH_S
          refresh
        rescue StandardError => e
          @log.puts "asterism mcp: refresh: #{e.class}: #{e.message}"
        end
      end

      # Makes the call tools again when the objects changed; tells the
      # client when the list did.
      def refresh
        return if @allow.empty?
        paths = @survey.objects.select { @allow.object?(_1) }
        sig = paths.sort
        return if sig == @signature
        metas = @survey.metas(paths)
        tools = {}
        metas.sort.each do |path, methods|
          methods.each do |m|
            next unless @allow.method?(path, m["name"])
            name = unique_name(tool_name(path, m["name"]), tools)
            tools[name] = [path, m["name"], m["arity"], m]
          end
        end
        # Keep trying the objects whose meta did not come.
        @signature = (paths - metas.keys).empty? ? sig : nil
        changed = @lock.synchronize do
          next false if tools == @call_tools
          @call_tools = tools
          list = read_tools + tools.map { |name, (path, _method, _arity, m)| call_tool(name, path, m) }
          @server.tools = list.to_h { [_1.name_value, _1] }
          @server.instance_variable_set(:@tool_names, @server.tools.keys)
          true
        end
        return unless changed
        @log.puts "asterism mcp: call tools: #{tools.keys.join(', ')}"
        @server.notify_tools_list_changed
      end

      def tool_name(path, method)
        "#{path.tr('/', '.')}.#{method}".gsub(/[^A-Za-z0-9_.-]/, "_")[0, 120]
      end

      def unique_name(name, taken)
        return name unless taken.key?(name)
        n = 2
        n += 1 while taken.key?("#{name}_#{n}")
        "#{name}_#{n}"
      end

      # ------------------------------------------------------------ tools

      def read_tools
        sv = @survey
        bridge = self
        [
          ::MCP::Tool.define(
            name: "asterism_nodes",
            description: "The nodes of the Asterism network, each with its profile (what runs it, a display name), " \
                         "its applications with their statuses, and the names of their objects.",
            input_schema: { properties: {} },
            annotations: { read_only_hint: true }
          ) do |server_context:|
            bridge.answer { sv.tree(meta: false) }
          end,
          ::MCP::Tool.define(
            name: "asterism_objects",
            description: "The exposed objects (<node>/<app>/<object>) and their methods with the number of " \
                         "arguments (-1: any), and the arguments' names and what each method does when the object " \
                         "tells them (args, doc). callable_as names the tool that calls a method, when this server " \
                         "allows it.",
            input_schema: { properties: { pattern: { type: "string",
                                                     description: "node/app/object with * (one part) and ** " \
                                                                  "(any parts); default **" } } },
            annotations: { read_only_hint: true }
          ) do |server_context:, pattern: "**"|
            bridge.answer { bridge.objects(pattern) }
          end,
          ::MCP::Tool.define(
            name: "asterism_status",
            description: "The statuses the applications tell about themselves (asterism/<node>/<app>/@status): " \
                         "{\"<node>/<app>\": {...}}. An application without one is not listed.",
            input_schema: { properties: { node: { type: "string" }, app: { type: "string" } } },
            annotations: { read_only_hint: true }
          ) do |server_context:, node: nil, app: nil|
            bridge.answer do
              sv.statuses.select do |k, _|
                n, a = k.split("/")
                (node.nil? || node == n) && (app.nil? || app == a)
              end
            end
          end
        ]
      end

      def objects(pattern)
        paths = @survey.objects(pattern)
        metas = @survey.metas(paths)
        by = @lock.synchronize { @call_tools.to_h { |name, (path, m, _)| [[path, m], name] } }
        paths.map do |p|
          methods = metas[p]&.map do |m|
            name = by[[p, m["name"]]]
            name ? m.merge("callable_as" => name) : m
          end
          h = { "path" => p, "methods" => methods }
          h["doc"] = @survey.object_doc(p) if @survey.object_doc(p)
          h
        end
      end

      def call_tool(name, path, meta)
        method = meta["name"]
        arity = meta["arity"]
        names = input_names(meta)
        props = {}
        required = []
        if names
          names.each do |n|
            props[n.to_sym] = { description: "the argument #{n}" }
            required << n if arity >= 0
          end
          props[:args] = { type: "array", description: "more positional arguments, if any" } if arity.negative?
        elsif arity.negative?
          props[:args] = { type: "array", description: "the positional arguments (any number)" }
        else
          arity.times do |i|
            props[:"arg#{i + 1}"] = { description: "argument #{i + 1} (any JSON value)" }
            required << "arg#{i + 1}"
          end
        end
        props[:kwargs] = { type: "object", description: "keyword arguments, if the method takes any" }
        schema = { properties: props }
        schema[:required] = required unless required.empty?
        about = [meta["doc"], (d = @survey.object_doc(path)) && "(#{path}: #{d})"].compact
        count = names ? "" : " (#{arity.negative? ? 'any number of' : arity} arguments)"
        bridge = self
        ::MCP::Tool.define(
          name: name,
          description: "#{about.empty? ? '' : "#{about.join(' ')}\n"}Calls #{method} on the Asterism object " \
                       "#{path}#{count} and returns {\"value\": ...}.",
          input_schema: schema
        ) do |server_context:, **args|
          bridge.invoke(path, method, arity, args, names)
        end
      end

      # The meta's argument names as inputs, or nil (none, or a name the
      # inputs cannot take: "args", "kwargs", a repeated one).
      def input_names(meta)
        names = meta["args"]
        return nil unless names.is_a?(Array) && !names.empty?
        return nil if names.uniq.size != names.size || names.any? { %w[args kwargs].include?(_1) }
        names
      end

      # A call tool's call.
      def invoke(path, method, arity, args, names = nil)
        pos = if names
                names.map { args[_1.to_sym] } + (arity.negative? ? Array(args[:args]) : [])
              elsif arity.negative?
                Array(args[:args])
              else
                (1..arity).map { args[:"arg#{_1}"] }
              end
        if names && arity.negative?
          # Optional named arguments: the trailing ones not given are left out.
          pos.pop while !pos.empty? && pos.last.nil? && args[:args].nil?
        end
        kw = (args[:kwargs] || {}).to_h.transform_keys(&:to_sym)
        unless @lock.synchronize { @call_tools.any? { |_, t| t[0] == path && t[1] == method } }
          return error("#{path}.#{method} is not callable here (not allowed, or gone)")
        end
        v = ::Asterism[path, timeout: @survey.timeout].asterism_call(method, *pos, **kw)
        text({ "value" => v })
      rescue ::Asterism::RemoteError => e
        error({ "error" => { "kind" => e.remote_kind, "class" => e.remote_class, "message" => e.remote_message } })
      rescue ::Asterism::Error => e
        error({ "error" => { "kind" => "asterism", "class" => e.class.name, "message" => e.message } })
      end

      # The value of the block as a JSON text; an Asterism error as an
      # error result.
      def answer
        text(yield)
      rescue ::Asterism::Error => e
        error("#{e.class}: #{e.message}")
      end

      def text(v)
        ::MCP::Tool::Response.new([{ type: "text", text: JSON.generate(json_safe(v)) }])
      end

      def error(v)
        ::MCP::Tool::Response.new([{ type: "text", text: v.is_a?(String) ? v : JSON.generate(json_safe(v)) }],
                                  error: true)
      end

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
end
