# The command table of the command line (lib/asterism/cli.rb): the nouns
# and their verbs, the commands without a noun, the older names, and what
# each command does on the network (it reads, or it calls a method).
#
# Plain Ruby with nothing required, so a program that does not load the
# Zenoh binding (a web server in front of a process that does) can read the
# table: `require "asterism/cli/commands"`.
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

    # The options that say where the network is and who this command line
    # is on it. A command line given a connection (CLI.new(net:)) has none.
    CONNECTION_OPTIONS = %w[--router --credentials --peer --node --app].freeze

    # The commands that act here rather than on the network: an MCP server
    # on stdio, a script for the shell. A command line given a connection
    # does not run them.
    LOCAL = %w[mcp completion].freeze

    # What a command does on the network. Every command only reads (the
    # tokens, metas, profiles, statuses, the values the applications put),
    # except call, and ping with --call: those run a method of an object.
    #
    #   :call   path:, method: say which
    #   :read   it only reads
    #   :local  it acts here (LOCAL)
    #
    # key: "node list", "call", "ping", ...; call: ping's --call METHOD.
    def self.kind(key, call: nil)
      return :local if LOCAL.include?(key)
      return :call if key == "call"
      return :call if %w[ping echo].include?(key) && call
      :read
    end

    # What a command line is about to do, once its words are read (before
    # it connects): the command, its kind (CLI.kind), the object and the
    # method it calls (kind :call), its positional arguments and options.
    # What CLI.new(permit:) is asked about.
    Plan = Struct.new(:key, :kind, :path, :method, :args, :options, keyword_init: true)
  end
end
