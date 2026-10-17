# The command line (exe/asterism, lib/asterism/cli.rb): the arguments
# (JSON or Ruby literals), the --allow patterns, and the commands against a
# node in another process over a peer link (or ASTERISM_TEST_ROUTER):
# nodes, objects, tree, ping, call, watch, and the MCP bridge with the mcp
# gem's client (skipped when the mcp gem is not installed).
require_relative "helper"
require "asterism/cli"
require "rbconfig"
require "open3"
require "json"
require "timeout"

class TestCLI < Minitest::Test
  include TestHelper

  L = Asterism::CLI::Literal
  EXE = File.expand_path("../exe/asterism", __dir__)
  LIB = [File.expand_path("../lib", __dir__), TestHelper.zenoh_lib].compact.flat_map { ["-I", _1] }

  # ------------------------------------------------------------ no network

  def test_literals
    assert_equal({ "seat" => 1 }, L.parse('{"seat": 1}'))
    assert_equal 1, L.parse("1")
    assert_equal "x", L.parse('"x"')
    assert_nil L.parse("null")
    assert_equal [1, :a, nil, -2.5, true], L.parse("[1, :a, nil, -2.5, true]")
    assert_equal({ seat: 1, "b" => [1] }, L.parse('{seat: 1, "b" => [1]}'))
    assert_equal "a\nb", L.parse('"a\nb"')
    assert_equal %w[x y], L.parse("%w[x y]")
    assert_equal 16, L.parse("0x10")
    assert_equal "hello", L.parse("hello"), "not JSON, not a literal: the text"
    assert_equal 'system("ls")', L.parse('system("ls")'), "a method call is not evaluated"
    assert_equal "File", L.parse("File")
    assert_equal '["a#{x}", :b]', L.parse('["a#{x}", :b]'), "no interpolation"
  end

  def test_allow_patterns
    a = Asterism::CLI::Allow.new(["games/othello1.*", "x/y/z.ok?", "mahjong*.view"])
    assert a.method?("games/games/othello1", "join")
    assert a.method?("other/games/othello1", "move"), "two parts match the last two"
    refute a.method?("games/games/othello2", "join")
    assert a.method?("x/y/z", "ok?")
    refute a.method?("x/y/z", "okk")
    assert a.method?("games/games/mahjong1", "view")
    refute a.method?("games/games/mahjong1", "join")
    assert a.object?("games/games/mahjong2")
    refute a.object?("games/games/tally")
    assert Asterism::CLI::Allow.new(["othello1"]).method?("a/b/othello1", "anything"), "no .method: every method"
    assert Asterism::CLI::Allow.new(["*/*/*.*"]).method?("a/b/c", "d")
    assert Asterism::CLI::Allow.new([]).empty?
    assert_raises(ArgumentError) { Asterism::CLI::Allow.new(["a/b/c/d.e"]) }
    assert_raises(ArgumentError) { Asterism::CLI::Allow.new(["a//b.c"]) }
    assert_raises(ArgumentError) { Asterism::CLI::Allow.new(["a."]) }
  end

  def test_usage
    out, err = capture_io { assert_equal 2, Asterism::CLI.start(%w[nodes]) }
    assert_match(/--router/, err)
    out, = capture_io { assert_equal 0, Asterism::CLI.start(%w[help]) }
    assert_match(/Commands/, out)
    _, err = capture_io { assert_equal 2, Asterism::CLI.start(%w[frobnicate]) }
    assert_match(/unknown command/, err)
  end

  # ------------------------------------------------------------ against a node

  NODE = <<~'RUBY'
    require "asterism"
    class Calc
      def add(a, b, from: nil) = a + b
      def whoami(from: nil) = from
      def any(*a, from: nil) = a.size
      def kw(a, n: 0, from: nil) = [a, n]
      def boom(from: nil) = raise("boom")
    end
    loc, mode = ARGV
    Asterism.profile(name: "Calc node")
    Asterism.status(tables: 1, st: "wait")
    if mode == "router"
      Asterism.connect(loc, node: "calcnode", app: "calc")
    else
      Asterism.connect(nil, node: "calcnode", app: "calc", mode: :peer, listen: loc)
    end
    Asterism.expose("calc", Calc.new, methods: { add: 2, whoami: 0, any: -1, kw: 1, boom: 0 }, caller: :from)
    Asterism.expose("other", Calc.new, methods: { add: 2 }, caller: :from)
    STDOUT.puts "ready"
    STDOUT.flush
    loop do
      Asterism.poll
      r, = IO.select([STDIN], nil, nil, 0.002)
      next unless r
      line = STDIN.gets
      break if line.nil?
      Asterism.status(tables: line.to_i)
    end
    Asterism.close
  RUBY

  def with_node
    if (router = TestHelper.router)
      @where = ["--router", router]
      loc = router
      mode = "router"
    else
      loc = "tcp/127.0.0.1:#{TestHelper.free_port}"
      @where = ["--peer", loc]
      mode = "peer"
    end
    node = IO.popen([RbConfig.ruby, *LIB, "-e", NODE, loc, mode], "r+")
    assert_equal "ready", node.gets&.strip
    yield node
  ensure
    if node && !node.closed?
      node.close_write rescue nil
      node.read rescue nil
      node.close rescue nil
    end
  end

  def cli(*args)
    out, err, st = Open3.capture3(RbConfig.ruby, *LIB, EXE, *args, *@where, "--settle", "1.0")
    [out, err, st.exitstatus]
  end

  def test_commands
    with_node do |node|
      out, err, code = cli("nodes", "--json")
      assert_equal 0, code, err
      tree = JSON.parse(out)
      calc = tree.find { _1["node"] == "calcnode" }
      assert calc, out
      assert_equal "Calc node", calc["profile"]["name"]
      assert_equal [{ "app" => "calc", "status" => { "tables" => 1, "st" => "wait" } }], calc["apps"]

      out, err, code = cli("objects", "calcnode/*/calc")
      assert_equal 0, code, err
      assert_equal "calcnode/calc/calc  add(2) whoami(0) any(*) kw(1) boom(0)", out.strip

      out, err, code = cli("tree", "--json")
      assert_equal 0, code, err
      apps = JSON.parse(out).find { _1["node"] == "calcnode" }["apps"]
      assert_equal %w[calc other], apps[0]["objects"].map { _1["name"] }
      assert_equal [{ "name" => "add", "arity" => 2 }], apps[0]["objects"][1]["methods"]

      out, err, code = cli("ping", "calcnode/calc/calc", "--count", "3", "--interval", "0.05", "--json")
      assert_equal 0, code, err
      assert_equal 3, JSON.parse(out)["answered"]
      out, err, code = cli("echo", "calcnode", "--count", "2", "--interval", "0")
      assert_equal 0, code, err
      assert_match(/2 of 2 answered/, out)

      out, err, code = cli("call", "calcnode/calc/calc", "add", "2", "3")
      assert_equal [0, "5"], [code, out.strip], err
      out, _, code = cli("call", "calcnode/calc/calc", "kw", "[1, :a]", "--kwargs", "{n: 4}", "--json")
      assert_equal [0, { "value" => [[1, "a"], 4] }], [code, JSON.parse(out)]
      out, _, code = cli("call", "calcnode/calc/calc", "whoami", "--node", "cli-test")
      assert_equal [0, '"cli-test"'], [code, out.strip], "the caller is this node"
      _, err, code = cli("call", "calcnode/calc/calc", "boom")
      assert_equal 1, code
      assert_match(/raised: RuntimeError: boom/, err)
      _, err, code = cli("call", "calcnode/calc/calc", "secret")
      assert_equal 1, code
      assert_match(/not_exposed/, err)

      # watch: the status there at the start, then a change.
      cmd = [RbConfig.ruby, *LIB, EXE, "watch", "--json", "--duration", "4", *@where, "--settle", "1.0"]
      Open3.popen3(*cmd) do |_i, o, e, th|
        first = JSON.parse(Timeout.timeout(10) { o.gets })
        assert_equal ["status", "calcnode/calc", { "tables" => 1, "st" => "wait" }, true],
                     first.values_at("event", "path", "status", "now")
        sleep 0.8
        node.puts "7"
        node.flush
        got = nil
        Timeout.timeout(6) do
          while (l = o.gets)
            ev = JSON.parse(l)
            if ev["event"] == "status"
              got = ev
              break
            end
          end
        end
        assert_equal({ "tables" => 7, "st" => "wait" }, got && got["status"])
        th.value
        e.read
      end
    end
  end

  def test_mcp
    begin
      require "mcp"
    rescue LoadError
      skip "the mcp gem is not installed (gem install mcp)"
    end
    with_node do |_node|
      t = MCP::Client::Stdio.new(command: RbConfig.ruby,
                                 args: [*LIB, EXE, "mcp", *@where, "--settle", "1.0", "--allow", "calc/calc.add",
                                        "--allow", "calc/calc.any", "--allow", "calc/calc.boom"],
                                 read_timeout: 30)
      c = MCP::Client.new(transport: t)
      c.connect
      tools = c.tools.to_h { [_1.name, _1] }
      assert_equal %w[asterism_nodes asterism_objects asterism_status calcnode.calc.calc.add calcnode.calc.calc.any
                      calcnode.calc.calc.boom].sort, tools.keys.sort, "only the allowed methods are tools"
      assert_equal %w[arg1 arg2], tools["calcnode.calc.calc.add"].input_schema["required"]
      text = ->(r) { JSON.parse(r["result"]["content"][0]["text"]) }
      r = c.call_tool(tool: tools["calcnode.calc.calc.add"], arguments: { arg1: 20, arg2: 22 })
      assert_equal({ "value" => 42 }, text.(r))
      r = c.call_tool(tool: tools["calcnode.calc.calc.any"], arguments: { args: [1, 2, 3] })
      assert_equal({ "value" => 3 }, text.(r))
      r = c.call_tool(tool: tools["calcnode.calc.calc.boom"], arguments: {})
      assert r["result"]["isError"]
      assert_equal "raised", text.(r)["error"]["kind"]
      r = c.call_tool(tool: tools["asterism_status"], arguments: { node: "calcnode" })
      assert_equal({ "calcnode/calc" => { "tables" => 1, "st" => "wait" } }, text.(r))
      r = c.call_tool(tool: tools["asterism_objects"], arguments: { pattern: "calcnode/calc/*" })
      objs = text.(r)
      add = objs.find { _1["path"] == "calcnode/calc/calc" }["methods"].find { _1["name"] == "add" }
      assert_equal "calcnode.calc.calc.add", add["callable_as"]
      assert_equal 2, objs.size
      r = c.call_tool(tool: tools["asterism_nodes"], arguments: {})
      assert(text.(r).any? { _1["node"] == "calcnode" })
    ensure
      t&.close
    end
  end
end
