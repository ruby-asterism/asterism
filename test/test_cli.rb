# The command line (exe/asterism, lib/asterism/cli.rb): the arguments
# (JSON or Ruby literals), the --allow patterns, and the commands against a
# node in another process over a peer link (or ASTERISM_TEST_ROUTER):
# nodes, objects, tree, ping, call, watch, the noun-verb commands (node,
# app, object, status; -o json / yaml), the Tab completion (__complete),
# and the MCP bridge with the mcp gem's client (skipped when the mcp gem is
# not installed). The text's layout (statuses, wrapping, colours, watch's
# differences), status hz's arithmetic, the completion's candidates and its
# cache without a network too.
require_relative "helper"
require "asterism/cli"
require "rbconfig"
require "open3"
require "json"
require "timeout"
require "stringio"
require "tmpdir"
require "yaml"

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

  def test_network_from_the_environment
    env = { "ASTERISM_CREDENTIALS" => "/x/me.tar", "ASTERISM_ROUTER" => "tls/r.example.org:7448" }
    cli = Asterism::CLI.new
    assert_equal ["tls/r.example.org:7448", "/x/me.tar", nil], cli.network(env)
    assert_equal [nil, nil, nil], cli.network({ "ASTERISM_CREDENTIALS" => "" })
    # Anything on the line wins, and the environment is then not read at all.
    cli.instance_variable_get(:@opts)[:router] = "tcp/192.0.2.2:7447"
    assert_equal ["tcp/192.0.2.2:7447", nil, nil], cli.network(env)
  end

  def test_usage
    out, err = capture_io { assert_equal 2, Asterism::CLI.start(%w[nodes]) }
    assert_match(/--router/, err)
    out, = capture_io { assert_equal 0, Asterism::CLI.start(%w[help]) }
    assert_match(/Commands/, out)
    _, err = capture_io { assert_equal 2, Asterism::CLI.start(%w[frobnicate]) }
    assert_match(/unknown command/, err)
    # Grouped by noun, the older names at the end.
    assert_match(/^  node list +the nodes/, out)
    assert_match(/^  status hz NODE\/APP +how often/, out)
    assert_match(/Older names, kept: nodes .*\n.*echo \(ping\)/, out)
    # A noun alone: its verbs.
    out, = capture_io { assert_equal 2, Asterism::CLI.start(%w[object]) }
    assert_match(/^  object find METHOD +the objects that have the method/, out)
    out, = capture_io { assert_equal 2, Asterism::CLI.start(%w[status --router tcp/192.0.2.2:7447]) }
    assert_match(/status echo/, out)
    out, = capture_io { assert_equal 0, Asterism::CLI.start(%w[help node]) }
    assert_match(/node info NODE/, out)
    _, err = capture_io { assert_equal 2, Asterism::CLI.start(%w[node frob]) }
    assert_match(/node has no verb "frob"/, err)
    _, err = capture_io { assert_equal 2, Asterism::CLI.start(%w[node list -o xml --router tcp/192.0.2.2:7447]) }
    assert_match(/invalid argument: -o xml/, err)
    _, err = capture_io { assert_equal 2, Asterism::CLI.start(%w[status get games --router tcp/192.0.2.2:7447]) }
    assert_match(/NODE\/APP/, err)
    _, err = capture_io { assert_equal 2, Asterism::CLI.start(%w[object info a/*/c --router tcp/192.0.2.2:7447]) }
    assert_match(/object list PATTERN/, err)
    out, = capture_io { assert_equal 0, Asterism::CLI.start(%w[completion bash]) }
    assert_includes out, "complete -F _asterism asterism"
    out, = capture_io { assert_equal 0, Asterism::CLI.start(%w[completion zsh]) }
    assert_includes out, "compdef _asterism asterism"
  end

  # ------------------------------------------------------------ status hz

  def test_hz
    t = 0.0
    hz = Asterism::CLI::Hz.new(window: 3, clock: -> { t })
    hz.seed({ "n" => 0 })
    refute hz.put({ "n" => 0 }), "the status there at the start again is no change"
    assert_nil hz.report
    t = 10.0
    assert hz.put({ "n" => 1 })
    assert_nil hz.stats, "one change: no interval yet"
    assert_nil hz.report
    t = 10.5
    hz.put({ "n" => 2 })
    t = 11.5
    hz.put({ "n" => 3 })
    refute hz.put({ "n" => 3 }), "the same status twice counts once"
    s = hz.report
    assert_equal 2, s["window"]
    assert_equal 3, s["count"]
    assert_in_delta 0.5, s["min_s"]
    assert_in_delta 1.0, s["max_s"]
    assert_in_delta 1 / 0.75, s["rate_hz"]
    assert_in_delta 0.25, s["std_s"]
    assert_nil hz.report, "nothing new since the last report"
    # The window keeps the last intervals only.
    [13.5, 15.5, 17.5].each { |x| t = x; hz.put({ "n" => x }) }
    s = hz.report
    assert_equal 3, s["window"]
    assert_equal 6, s["count"]
    assert_in_delta 2.0, s["min_s"]
    assert_in_delta 0.5, s["rate_hz"]
    assert_equal ["average rate: 0.500 Hz", "  min: 2.000 s  max: 2.000 s  std dev: 0.000 s  window: 3"],
                 Asterism::CLI::Hz.text(s)
  end

  # ------------------------------------------------------------ status echo's text

  def test_echo_text
    cli = Asterism::CLI.new(out: StringIO.new, env: {})
    t = Time.at(0)
    ts = t.strftime("%H:%M:%S.%L")
    pad = " " * 13
    assert_equal "#{ts} a/b (now)\n#{pad}n=0 st=wait", cli.echo_text(t, "a/b", { "n" => 0, "st" => "wait" }, true)
    assert_equal "#{ts} n 0\u21921", cli.echo_text(t, "a/b", { "n" => 1, "st" => "wait" }, false)
    assert_nil cli.echo_text(t, "a/b", { "n" => 1, "st" => "wait" }, false), "no change, no line"
    assert_equal "#{ts} +m=2\n#{ts} -st", cli.echo_text(t, "a/b", { "n" => 1, "m" => 2 }, false)
  end

  # ------------------------------------------------------------ completion

  # What the network names, for the completion's tests (counts the asks).
  class FakeSource
    attr_reader :asked

    def initialize(names = nil, methods = {})
      @names = names
      @methods = methods
      @asked = []
    end

    def names
      @asked << :names
      @names
    end

    def methods(path)
      @asked << [:methods, path]
      @methods[path]
    end

    def all_methods
      @asked << :all_methods
      @methods.values.flatten.uniq
    end
  end

  def complete(line, source = nil)
    source ||= FakeSource.new({ "apps" => %w[games/games linux/demo], "objects" => %w[games/games/mahjong1
                                                                                     games/games/othello1
                                                                                     linux/demo/screen] },
                              { "games/games/othello1" => %w[join view move], "linux/demo/screen" => %w[say] })
    words = Asterism::CLI::Complete.split_line("asterism #{line}")
    Asterism::CLI::Complete.new(Asterism::CLI.new, source).candidates(words)
  end

  def test_complete_words
    src = FakeSource.new
    assert_equal %w[app call completion echo help mcp node nodes object objects ping status tree version watch],
                 complete("", src)
    assert_equal %w[node nodes], complete("no", src)
    assert_equal %w[info list], complete("node ", src)
    assert_equal %w[echo get hz], complete("status ", src)
    assert_equal %w[find], complete("object f", src)
    assert_equal %w[json yaml], complete("node list -o ", src)
    assert_equal %w[yaml], complete("tree --output y", src)
    assert_equal [":files"], complete("tree --credentials ", src)
    assert_equal %w[--router], complete("node list --rou", src)
    assert_includes complete("status echo --", src), "--once"
    refute_includes complete("status get --", src), "--once"
    assert_includes complete("tree --", src), "--methods"
    assert_includes complete("watch --", src), "--json"
    assert_equal %w[bash zsh], complete("completion ", src)
    assert_empty complete("frob ", src)
    assert_empty src.asked, "commands, verbs and options without the network"
  end

  def test_complete_names
    assert_equal %w[games/ linux/], complete("status echo ")
    assert_equal %w[games/], complete("status echo ga")
    assert_equal %w[games/games], complete("status echo --router tcp/192.0.2.2:7447 games/")
    assert_equal %w[games/games], complete("app info games/games")
    assert_empty complete("app info games/games/"), "an application is two parts"
    assert_equal %w[games/games/mahjong1 games/games/othello1], complete("object info games/games/")
    assert_equal %w[games/games/othello1], complete("call games/games/o")
    assert_equal %w[join move view], complete("call games/games/othello1 ")
    assert_equal %w[view], complete("call games/games/othello1 v")
    assert_empty complete("call games/games/othello1 view ")
    assert_equal %w[games linux], complete("node info ")
    assert_equal %w[games games/], complete("ping ga")
    assert_equal %w[join move say view], complete("object find ")
    assert_equal %w[say], complete("ping linux/demo/screen --call ")
    assert_equal %w[games/], complete("objects g")
    # Nothing from the network: no names.
    assert_empty complete("status echo ", FakeSource.new(nil))
    assert_empty complete("call a/b/c ", FakeSource.new(nil))
  end

  def test_complete_line
    sl = Asterism::CLI::Complete.method(:split_line)
    assert_equal ["node", ""], sl.("asterism node ")
    assert_equal ["node", "li"], sl.("asterism node li")
    assert_equal [""], sl.("asterism ")
    assert_equal ["call", "a/b/c", "x y"], sl.("asterism call a/b/c 'x y"), "an open quote is closed"
    assert_equal %w[27448 x], Asterism::CLI::Complete.bash_trim(%w[tcp/127.0.0.1:27448 x], "tcp/127.0.0.1:2")
  end

  def test_complete_cache
    Dir.mktmpdir do |dir|
      t = 1000.0
      net_a = ["tcp/192.0.2.2:7447", nil, nil]
      net_b = [nil, "/home/someone/me.tar", nil]
      cache = ->(net) { Asterism::CLI::Complete::Cache.new(dir: File.join(dir, "asterism"), network: net, ttl: 20,
                                                           clock: -> { t }) }
      asks = 0
      ask = ->(v) { asks += 1; v }
      assert_equal ["a"], cache.(net_a).fetch("names") { ask.(["a"]) }
      assert_equal ["a"], cache.(net_a).fetch("names") { ask.(["x"]) }
      assert_equal 1, asks, "remembered"
      assert_equal ["b"], cache.(net_b).fetch("names") { ask.(["b"]) }
      assert_equal 2, asks, "another network has its own"
      refute_equal cache.(net_a).file, cache.(net_b).file
      assert_equal %w[m], cache.(net_a).fetch("methods a/b/c") { ask.(%w[m]) }
      t += 19
      assert_equal ["a"], cache.(net_a).fetch("names") { ask.(["x"]) }
      assert_equal 3, asks
      t += 2
      assert_equal ["new"], cache.(net_a).fetch("names") { ask.(["new"]) }, "past its time it is asked again"
      assert_equal 4, asks
      assert_nil cache.(net_a).fetch("methods x/y/z") { ask.(nil) }
      assert_nil cache.(net_a).fetch("methods x/y/z") { ask.(nil) }
      assert_equal 6, asks, "no answer is not remembered"
      data = JSON.parse(File.read(cache.(net_a).file))
      assert_equal ["names"], data.keys, "old entries are dropped"
      assert_equal 0o600, File.stat(cache.(net_a).file).mode & 0o777
      assert_equal 0o700, File.stat(File.join(dir, "asterism")).mode & 0o777
      text = Dir.glob(File.join(dir, "asterism", "*")).map { File.read(_1) }.join
      refute_includes text, "me.tar", "where the network is: a digest only"
      refute_includes text, "192.0.2.2"
      assert_equal File.join("/c", "asterism"), Asterism::CLI::Complete::Cache.dir({ "XDG_CACHE_HOME" => "/c" })
    end
  end

  # ------------------------------------------------------------ the text's layout

  T = Asterism::CLI::Text
  Style = Asterism::CLI::Style

  # An output that says it is a terminal of cols columns.
  class FakeTTY < StringIO
    def initialize(cols) = (super(); @cols = cols)
    def tty? = true
    def winsize = [24, @cols]
  end

  def test_status_lines
    st = { "tables" => 3, "st" => "wait",
           "mahjong1" => { "st" => "wait", "members" => 0, "humans" => 0, "cpus" => 4, "ais" => 0, "away" => 0 } }
    assert_equal ["  tables=3 st=wait", "  mahjong1: st=wait members=0 humans=0 cpus=4 ais=0 away=0"],
                 T.status_lines(st, 80, 2)
    # Wrapped under the first value; key=value never broken.
    assert_equal ["mahjong1: st=wait members=0", "          humans=0 cpus=4", "          ais=0 away=0"],
                 T.status_lines({ "mahjong1" => st["mahjong1"] }, 30)
    # Deeper Hashes, arrays with Hashes, plain arrays, empty Hashes.
    deep = { "a" => { "b" => 1, "c" => { "d" => { "e" => [1, 2] } } },
             "seats" => [{ "n" => "x", "cpu" => true }, nil, { "who" => { "id" => 1 }, "z" => 2 }],
             "e" => {}, "list" => %w[a b] }
    assert_equal ["a:", "  b=1", "  c:", "    d: e=[1, 2]", "seats:", "  - n=x cpu=true", "  - nil",
                  "  - who: id=1", "    z=2", "e: {}", "list=[a, b]"], T.status_lines(deep, 80)
    assert_equal ["  {}"], T.status_lines({}, 80, 2)
  end

  def test_long_values
    assert_equal %(s="two words"), T.pair("s", "two words")
    long = T.inline("x" * 100)
    assert_equal 60, T.width(long)
    assert long.end_with?("\u2026")
    arr = T.inline((1..40).to_a)
    assert T.width(arr) <= 60, arr
    assert_match(/\A\[1, 2, .*, \u2026\+\d+\]\z/, arr)
    assert_equal 40, arr[/\+(\d+)\]/, 1].to_i + arr.count(","), "what is left out is counted"
    jp = T.inline("\u9EBB\u96C0" * 40)
    assert_includes 59..60, T.width(jp), "wide characters take two columns"
    # A long value has a line of its own, whole.
    lines = T.status_lines({ "a" => 1, "b" => "y" * 50 }, 30)
    assert_equal ["a=1", "b=#{'y' * 50}"], lines
    assert_equal "(3 bytes)", Asterism::CLI.new.json_safe("\xff\x00\x01".b), "bytes as a note"
  end

  def test_wrap
    words = %w[Joins the table as a member and returns the token for the calls after.]
    lines = T.wrap(words, 30, first: "  join(name)  ")
    assert_equal ["  join(name)  Joins the table", "              as a member and", "              returns the",
                  "              token for the", "              calls after."], lines
    assert(lines.all? { T.width(_1) <= 30 })
    # Text without spaces (Japanese) is broken between characters.
    jp = T.wrap_text("\u3042" * 30, 20, first: "  ")
    assert_equal [20, 20, 20, 8], jp.map { T.width(_1) }
    # Paragraphs start new lines.
    assert_equal ["- one two", "  three"], T.wrap_text("one\ntwo\n\nthree", 20, first: "- ")
  end

  def test_status_diff
    old = { "tables" => 3, "m" => { "members" => 0, "x" => 1, "st" => "wait" } }
    new = { "tables" => 3, "m" => { "members" => 1, "st" => "play" }, "n" => { "a" => 1 } }
    assert_equal ["m.members 0\u21921", "m.st wait\u2192play", "-m.x", "+n={a=1}"], T.status_diff(old, new)
    assert_equal [], T.status_diff(old, old)
    assert_equal ["m {members=0 x=1 st=wait}\u21922"], T.status_diff(old.slice("m"), { "m" => 2 })
  end

  def test_style
    pipe = Style.new(StringIO.new, {})
    refute pipe.color?
    assert_equal 80, pipe.width
    assert_equal "x", pipe.paint("x", :node)
    assert_equal 120, Style.new(StringIO.new, { "COLUMNS" => "120" }).width
    tty = Style.new(FakeTTY.new(100), { "COLUMNS" => "120" })
    assert tty.color?
    assert_equal 100, tty.width, "a terminal's own width"
    assert_equal "\e[1;34mx\e[0m", tty.paint("x", :node)
    refute Style.new(FakeTTY.new(100), { "NO_COLOR" => "1" }).color?
    assert Style.new(FakeTTY.new(100), { "NO_COLOR" => "" }).color?, "an empty NO_COLOR is not set"
    assert_equal 2, T.width(tty.paint("ab", :app)), "colours take no columns"
  end

  # watch's text: the first status whole, then only what changed (in colour
  # on a terminal); a status gone with its application is whole again.
  def test_watch_text
    out = FakeTTY.new(80)
    cli = Asterism::CLI.new(out: out, env: { "NO_COLOR" => "1" })
    t = Time.at(0)
    ev = ->(*a, **k) { cli.event_text(t, *a, k[:what], k[:status], nil, k[:now] || false) }
    ts = t.strftime("%H:%M:%S.%L")
    pad = " " * 15
    first = ev.("status", "games/games", status: { "tables" => 1, "mahjong1" => { "st" => "wait", "members" => 0 } },
                now: true)
    assert_equal "#{ts} ~ status games/games (now)\n#{pad}tables=1\n#{pad}mahjong1: st=wait members=0", first
    two = ev.("status", "games/games", status: { "tables" => 1, "mahjong1" => { "st" => "wait", "members" => 1 },
                                                 "mahjong2" => { "st" => "wait" } })
    assert_equal ["#{ts} ~ status games/games mahjong1.members 0\u21921",
                  "#{ts} ~ status games/games +mahjong2={st=wait}"], two.lines.map(&:chomp)
    assert_nil ev.("status", "games/games", status: { "tables" => 1, "mahjong1" => { "st" => "wait", "members" => 1 },
                                                      "mahjong2" => { "st" => "wait" } }), "no change, no line"
    gone = ev.("status", "games/games", status: { "tables" => 1 })
    assert_equal ["#{ts} ~ status games/games -mahjong1", "#{ts} ~ status games/games -mahjong2"],
                 gone.lines.map(&:chomp)
    assert_equal "#{ts} - app games/games", ev.("leave", "games/games", what: "app")
    back = ev.("status", "games/games", status: { "tables" => 2 })
    assert_equal "#{ts} ~ status games/games\n#{pad}tables=2", back
    # In colour on a terminal without NO_COLOR.
    c = Asterism::CLI.new(out: FakeTTY.new(80), env: {})
    c.event_text(t, "status", "a/b", nil, { "n" => 0 }, nil, true)
    line = c.event_text(t, "status", "a/b", nil, { "n" => 1, "m" => 1 }, nil, false)
    assert_includes line, "\e[33m~\e[0m"
    assert_includes line, "\e[32m+m=1\e[0m"
    assert_includes c.event_text(t, "join", "x", "node", nil, nil, false), "\e[32m+\e[0m node \e[1;34mx\e[0m"
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
    Asterism.expose("other", Calc.new, methods: { add: { args: %w[a b], doc: "Adds a and b." } }, caller: :from,
                    doc: "The other calculator.")
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

  # The output is a pipe: no colours, 80 columns.
  PLAIN = { "COLUMNS" => nil, "NO_COLOR" => nil }.freeze

  def cli(*args, env: PLAIN)
    out, err, st = Open3.capture3(env, RbConfig.ruby, *LIB, EXE, *args, *@where, "--settle", "1.0")
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
      assert_equal "calcnode/calc/calc\n  add(2)  whoami(0)  any(*)  kw(1)  boom(0)", out.strip
      out, = cli("objects", "calcnode/*/calc", env: { "COLUMNS" => "30" })
      assert_equal "calcnode/calc/calc\n  add(2)  whoami(0)  any(*)\n  kw(1)  boom(0)", out.strip, "COLUMNS"
      refute_includes out, "\e[", "no colours on a pipe"

      out, err, code = cli("nodes")
      assert_equal 0, code, err
      assert_includes out, "calcnode  (cruby) \"Calc node\"\n  calc  2 objects\n    status:\n      tables=1 st=wait\n"

      out, err, code = cli("tree")
      assert_equal 0, code, err
      assert_includes out, "  calc\n    status:\n      tables=1 st=wait\n    calc  5 methods\n    other  1 method\n"
      out, err, code = cli("tree", "--methods", env: { "COLUMNS" => "30" })
      assert_equal 0, code, err
      assert_includes out, "    calc  5 methods\n      add(2)  whoami(0)\n      any(*)  kw(1)  boom(0)\n" \
                           "    other  1 method\n      add(a, b)\n"

      out, err, code = cli("tree", "--json")
      assert_equal 0, code, err
      apps = JSON.parse(out).find { _1["node"] == "calcnode" }["apps"]
      assert_equal %w[calc other], apps[0]["objects"].map { _1["name"] }
      assert_equal [{ "name" => "add", "arity" => 2, "args" => %w[a b], "doc" => "Adds a and b." }],
                   apps[0]["objects"][1]["methods"]
      assert_equal "The other calculator.", apps[0]["objects"][1]["doc"]

      out, err, code = cli("objects", "calcnode/*/other")
      assert_equal 0, code, err
      assert_equal "calcnode/calc/other\n  The other calculator.\n  add(a, b)  Adds a and b.", out.strip

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

      # watch's text: the status whole, then only the key that changed.
      cmd = [PLAIN, RbConfig.ruby, *LIB, EXE, "watch", "--duration", "4", *@where, "--settle", "1.0"]
      Open3.popen3(*cmd) do |_i, o, e, th|
        lines = Timeout.timeout(10) { [o.gets, o.gets] }
        assert_match(/\A\d\d:\d\d:\d\d\.\d{3} ~ status calcnode\/calc \(now\)\n\z/, lines[0])
        assert_equal "#{' ' * 15}tables=7 st=wait\n", lines[1], lines.inspect
        sleep 0.8
        node.puts "8"
        node.flush
        lines << Timeout.timeout(6) { o.gets }
        assert_match(/\A\d\d:\d\d:\d\d\.\d{3} ~ status calcnode\/calc tables 7\u21928\n\z/, lines[2])
        th.value
        e.read
      end
    end
  end

  def test_noun_verbs
    with_node do |node|
      out, err, code = cli("node", "list")
      assert_equal 0, code, err
      assert_includes out.lines, "calcnode\n", "a name a line"
      refute_includes out, "\e[", "no colours on a pipe"
      out, = cli("app", "list")
      assert_includes out.lines, "calcnode/calc\n"
      out, = cli("object", "list", "calcnode/**")
      assert_equal "calcnode/calc/calc\ncalcnode/calc/other\n", out
      out, = cli("object", "list", "calcnode/**", "-o", "json")
      assert_equal %w[calcnode/calc/calc calcnode/calc/other], JSON.parse(out)

      out, err, code = cli("node", "info", "calcnode")
      assert_equal 0, code, err
      assert_equal "calcnode\n  profile: kind=cruby protocol=1 name=\"Calc node\" icon_hash=HASH\n  calc\n" \
                   "    status:\n      tables=1 st=wait\n    objects:\n      calc  5 methods\n" \
                   "      other  1 method\n        The other calculator.\n", out.sub(/icon_hash=\h{8}/, "icon_hash=HASH")
      j, = cli("node", "info", "calcnode", "-o", "json")
      y, = cli("node", "info", "calcnode", "-o", "yaml")
      assert_equal JSON.parse(j), YAML.safe_load(y), "-o yaml holds what -o json does"
      assert_equal "calcnode", JSON.parse(j)["node"]
      assert_equal JSON.parse(j), JSON.parse(cli("node", "info", "calcnode", "--json")[0])
      _, err, code = cli("node", "info", "nosuchnode")
      assert_equal 1, code
      assert_match(/no node nosuchnode/, err)

      out, err, code = cli("app", "info", "calcnode/calc", env: { "COLUMNS" => "40" })
      assert_equal 0, code, err
      assert_equal "calcnode/calc\n  status:\n    tables=1 st=wait\n  objects:\n    calc  5 methods\n" \
                   "    other  1 method\n      The other calculator.\n", out
      j, = cli("app", "info", "calcnode/calc", "-o", "json")
      assert_equal %w[node app status objects], JSON.parse(j).keys

      out, err, code = cli("object", "info", "calcnode/calc/other")
      assert_equal 0, code, err
      assert_equal "calcnode/calc/other\n  The other calculator.\n  add(a, b)  Adds a and b.\n", out
      j, = cli("object", "info", "calcnode/calc/other", "-o", "json")
      y, = cli("object", "info", "calcnode/calc/other", "-o", "yaml")
      assert_equal({ "path" => "calcnode/calc/other", "doc" => "The other calculator.",
                     "methods" => [{ "name" => "add", "arity" => 2, "args" => %w[a b], "doc" => "Adds a and b." }] },
                   JSON.parse(j))
      assert_equal JSON.parse(j), YAML.safe_load(y)
      _, _, code = cli("object", "info", "calcnode/calc/nothing")
      assert_equal 1, code

      out, = cli("object", "find", "add")
      assert_equal "calcnode/calc/calc\ncalcnode/calc/other\n", out
      out, = cli("object", "find", "who*", "-o", "json")
      assert_equal [{ "path" => "calcnode/calc/calc", "methods" => [{ "name" => "whoami", "arity" => 0 }] }],
                   JSON.parse(out)
      out, = cli("object", "find", "nothing")
      assert_equal "", out

      out, err, code = cli("status", "get", "calcnode/calc")
      assert_equal [0, "tables=1 st=wait\n"], [code, out], err
      j, = cli("status", "get", "calcnode/calc", "-o", "json")
      y, = cli("status", "get", "calcnode/calc", "-o", "yaml")
      assert_equal({ "tables" => 1, "st" => "wait" }, JSON.parse(j))
      assert_equal "---\ntables: 1\nst: wait\n", y
      _, err, code = cli("status", "get", "calcnode/none")
      assert_equal 1, code
      assert_match(/no status from calcnode\/none/, err)

      out, err, code = cli("status", "echo", "calcnode/calc", "--once")
      assert_equal 0, code, err
      assert_match(/\A\d\d:\d\d:\d\d\.\d{3} calcnode\/calc \(now\)\n {13}tables=1 st=wait\n\z/, out)
      out, = cli("status", "echo", "calcnode/calc", "--once", "-o", "json")
      ev = JSON.parse(out)
      assert_equal ["calcnode/calc", { "tables" => 1, "st" => "wait" }, true], ev.values_at("path", "status", "now")
      _, _, code = cli("status", "echo", "calcnode/none", "--once")
      assert_equal 1, code

      # status echo: the status, then what changes; status hz: how often.
      echo = [PLAIN, RbConfig.ruby, *LIB, EXE, "status", "echo", "calcnode/calc", "--duration", "5", *@where,
              "--settle", "1.0"]
      hz = [PLAIN, RbConfig.ruby, *LIB, EXE, "status", "hz", "calcnode/calc", "--period", "0.3", "--duration", "5",
            "-o", "json", *@where, "--settle", "1.0"]
      Open3.popen3(*echo) do |_i, o, _e, eth|
        Open3.popen3(*hz) do |_i2, o2, _e2, hth|
          lines = Timeout.timeout(10) { [o.gets, o.gets] }
          assert_match(/ calcnode\/calc \(now\)\n\z/, lines[0])
          sleep 0.5
          [2, 3, 4].each do |n|
            node.puts n.to_s
            node.flush
            sleep 0.4
          end
          3.times { lines << Timeout.timeout(6) { o.gets } }
          assert_match(/\A\d\d:\d\d:\d\d\.\d{3} tables 1\u21922\n\z/, lines[2])
          assert_match(/ tables 3\u21924\n\z/, lines[4])
          reports = Timeout.timeout(10) { o2.read }.lines.map { JSON.parse(_1) }
          last = reports.last
          assert last, "hz reported"
          assert_equal 3, last["count"]
          assert_equal 2, last["window"]
          assert_includes 1.0..5.0, last["rate_hz"]
          assert_operator last["min_s"], :<=, last["max_s"]
          hth.value
        end
        eth.value
      end

      # __complete: the names a part at a time, an object's methods.
      Dir.mktmpdir do |cache|
        env = PLAIN.merge("XDG_CACHE_HOME" => cache)
        comp = ->(*w) { Open3.capture3(env, RbConfig.ruby, *LIB, EXE, "__complete", "--", *w)[0].split("\n") }
        assert_equal %w[calcnode/], comp.("status", "echo", *@where, "calc")
        assert_equal %w[calcnode/calc], comp.("status", "get", *@where, "calcnode/")
        assert_equal %w[calcnode/calc/calc calcnode/calc/other], comp.("call", *@where, "calcnode/calc/")
        assert_equal %w[add any boom kw whoami], comp.("call", *@where, "calcnode/calc/calc", "")
        assert_equal %w[calcnode], comp.("node", "info", *@where, "")
        assert_equal 1, Dir.glob(File.join(cache, "asterism", "*.json")).size
        line = "asterism status get #{@where.join(' ')} calc"
        out, = Open3.capture3(env, RbConfig.ruby, *LIB, EXE, "__complete", "--bash", line)
        assert_equal "calcnode/\n", out
      end
    end
  end

  # The bash script: its function, called as bash calls it on a Tab.
  def test_bash_script
    skip "no bash" unless system("bash", "-c", "true", out: File::NULL, err: File::NULL)
    lib = LIB.each_slice(2).map { |_, d| "-I#{d}" }.join(" ")
    script = <<~BASH
      asterism() { #{RbConfig.ruby} #{lib} #{EXE} "$@"; }
      source <(asterism completion bash)
      t() {
        COMP_LINE=$1; COMP_POINT=${#1}; read -ra COMP_WORDS <<< "$1"
        [[ $1 == *" " ]] && COMP_WORDS+=("")
        COMP_CWORD=$((${#COMP_WORDS[@]} - 1)); COMPREPLY=(); _asterism; echo "${COMPREPLY[*]}"
      }
      t "asterism status e"; t "asterism object "; t "asterism tree -o "; t "asterism node list --cre"
    BASH
    out, err, st = Open3.capture3(PLAIN.merge("ASTERISM_ROUTER" => nil, "ASTERISM_CREDENTIALS" => nil),
                                  "bash", "--norc", "-c", script)
    assert st.success?, err
    assert_equal ["echo", "find info list", "json yaml", "--credentials"], out.lines.map(&:chomp)
  end

  # __complete without a network that answers: nothing, soon.
  def test_complete_without_network
    Dir.mktmpdir do |cache|
      env = PLAIN.merge("XDG_CACHE_HOME" => cache, "ASTERISM_ROUTER" => nil, "ASTERISM_CREDENTIALS" => nil)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, _, st = Open3.capture3(env, RbConfig.ruby, *LIB, EXE, "__complete", "--", "node", "info", "--router",
                                  "tcp/127.0.0.1:#{TestHelper.free_port}", "")
      dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      assert_equal ["", 0], [out, st.exitstatus]
      assert_operator dt, :<, 4.0, "the time the network may take, and the process's start"
      out, = Open3.capture3(env, RbConfig.ruby, *LIB, EXE, "__complete", "--", "node", "info", "")
      assert_equal "", out, "no network named: no names, nothing asked"
      assert_empty Dir.glob(File.join(cache, "asterism", "*")), "what did not answer is not remembered"
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
                                        "--allow", "calc/calc.any", "--allow", "calc/calc.boom",
                                        "--allow", "calc/other.add"],
                                 read_timeout: 30)
      c = MCP::Client.new(transport: t)
      c.connect
      tools = c.tools.to_h { [_1.name, _1] }
      assert_equal %w[asterism_nodes asterism_objects asterism_status calcnode.calc.calc.add calcnode.calc.calc.any
                      calcnode.calc.calc.boom calcnode.calc.other.add].sort, tools.keys.sort,
                   "only the allowed methods are tools"
      named = tools["calcnode.calc.other.add"]
      assert_equal %w[a b], named.input_schema["required"], "the names the meta tells are the inputs"
      assert_match(/\AAdds a and b\. \(calcnode\/calc\/other: The other calculator\.\)\n/, named.description)
      assert_equal %w[arg1 arg2], tools["calcnode.calc.calc.add"].input_schema["required"]
      text = ->(r) { JSON.parse(r["result"]["content"][0]["text"]) }
      r = c.call_tool(tool: tools["calcnode.calc.calc.add"], arguments: { arg1: 20, arg2: 22 })
      assert_equal({ "value" => 42 }, text.(r))
      r = c.call_tool(tool: named, arguments: { a: 1, b: 2 })
      assert_equal({ "value" => 3 }, text.(r))
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
