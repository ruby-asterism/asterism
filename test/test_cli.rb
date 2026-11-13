# The command line (exe/asterism, lib/asterism/cli.rb): the arguments
# (JSON or Ruby literals), the --allow patterns, and the commands against a
# node in another process over a peer link (or ASTERISM_TEST_ROUTER):
# nodes, objects, tree, ping, call, watch, the noun-verb commands (node,
# app, object, status; -o json / yaml; object get / echo of the values a
# node puts), the Tab completion (__complete),
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
    out, = capture_io { assert_equal 2, Asterism::CLI.start(%w[object]) }
    assert_match(/^  object get PATH \[KEY\] +the next value/, out)
    assert_match(/^  object echo PATH \[KEY\] +the values it puts/, out)
    _, err = capture_io { assert_equal 2, Asterism::CLI.start(%w[object get a/b --router tcp/192.0.2.2:7447]) }
    assert_match(/PATH is node\/app\/object/, err)
    _, err = capture_io { assert_equal 2, Asterism::CLI.start(%w[object echo a/b/c x* --router tcp/192.0.2.2:7447]) }
    assert_match(/names, \* \(one part\) or \*\*/, err)
    _, err = capture_io do
      assert_equal 2, Asterism::CLI.start(%w[object get a/b/c --timeout 0 --router tcp/192.0.2.2:7447])
    end
    assert_match(/--timeout: more than 0/, err)
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

  # ------------------------------------------------------------ values (object get / echo, asterism_values)

  V = Asterism::CLI::Values

  def test_values_decode
    assert_equal [{ "bd" => "...", "n" => [1, 2] }, "msgpack"], V.decode(MessagePack.pack({ "bd" => "...", "n" => [1, 2] }))
    assert_equal [{ "1" => 2 }, "msgpack"], V.decode(MessagePack.pack({ 1 => 2 })), "keys as JSON has them"
    assert_equal [nil, "msgpack"], V.decode(MessagePack.pack(nil))
    assert_equal [nil, "empty"], V.decode("")
    assert_equal [{ "x" => [1, "b"] }, "json"], V.decode('{"x": [1, "b"]}')
    assert_equal ["hello world", "text"], V.decode("hello world")
    assert_equal ["(3 bytes)", "bytes"], V.decode("\xff\xfe\xc1".b)
    assert_equal [{ "b" => "(2 bytes)", "f" => "NaN" }, "msgpack"],
                 V.decode(MessagePack.pack({ "b" => "\xff\xfe".b, "f" => Float::NAN }))
    e = V.entry("asterism/a/b/c/state", MessagePack.pack({ "n" => 1 }), Time.at(0))
    assert_equal({ "key" => "a/b/c/state", "t" => "1970-01-01T00:00:00.000Z", "bytes" => 4, "format" => "msgpack",
                   "value" => { "n" => 1 } }, e)
    assert_equal "a/b/c/**", V.check_pattern!("a/b/c/**")
    assert_equal "**", V.check_pattern!("**")
    assert_equal "*/*/*/state", V.check_pattern!("*/*/*/state")
    ["a/b*/c", "a//b", "", "a/@status", "a/b/c/$x"].each do |bad|
      assert_raises(ArgumentError, bad) { V.check_pattern!(bad) }
    end
  end

  def test_values_store
    clock = 100.0
    alive = { "g/g" => true, "h/h" => true }
    st = V::Store.new(max_keys: 3, max_total: 1000, max_bytes: 300, alive: ->(a) { alive[a] }, clock: -> { clock },
                      now: -> { Time.at(clock) })
    pk = ->(v) { MessagePack.pack(v) }
    st.put("asterism/g/g/t1/state", pk.({ "n" => 1 }))
    clock += 2
    st.put("g/g/t2/state", pk.({ "n" => 2 }))
    st.put("h/h/x/log", "plain text")
    a = st.answer("g/g/**")
    assert_equal %w[g/g/t1/state g/g/t2/state], a["values"].map { _1["key"] }, "sorted, only those that match"
    assert_equal "1970-01-01T00:01:40.000Z", a["since"]
    t1 = a["values"][0]
    assert_equal({ "key" => "g/g/t1/state", "t" => "1970-01-01T00:01:40.000Z", "age_s" => 2.0, "app" => "alive",
                   "bytes" => 4, "format" => "msgpack", "value" => { "n" => 1 } }, t1)
    assert_equal ["plain text"], st.answer("*/*/*/log")["values"].map { _1["value"] }
    assert_equal 3, st.answer["values"].size, "** is every key"
    refute st.answer.key?("note")
    # A newer put replaces the value and becomes the newest.
    st.put("g/g/t1/state", pk.({ "n" => 3 }))
    st.put("g/g/t3/state", pk.({ "n" => 4 }))
    assert_equal %w[g/g/t1/state g/g/t3/state h/h/x/log], st.keys.sort, "over 3 keys: the oldest (t2) forgotten"
    assert_equal 1, st.answer["forgotten"]
    assert_equal({ "n" => 3 }, st.answer("g/g/t1/*")["values"][0]["value"])
    # The total: a value that fills it pushes the old ones out.
    st.put("g/g/big/state", "x" * 290)
    assert_equal %w[g/g/big/state g/g/t1/state g/g/t3/state], st.keys.sort, "4 keys: the oldest (h/h/x/log) forgotten"
    st.put("g/g/big2/state", "y" * 290)
    st.put("g/g/big3/state", "z" * 290)
    st.put("g/g/big4/state", "w" * 290)
    assert_equal %w[g/g/big2/state g/g/big3/state g/g/big4/state], st.keys.sort, "at most 1000 bytes kept"
    # Too large to keep: its size only.
    st.put("g/g/huge/state", "q" * 301)
    huge = st.answer("g/g/huge/state")["values"][0]
    assert_equal [301, "dropped", true], huge.values_at("bytes", "format", "truncated")
    assert_match(/301 bytes: too large to keep/, huge["value"])

    # The application's mark: gone, restarted.
    st = V::Store.new(alive: ->(a) { alive[a] }, clock: -> { clock })
    st.put("g/g/t/state", pk.({ "n" => 1 }))
    st.put("h/h/t/state", pk.({ "n" => 1 }))
    st.left("g/g")
    alive.delete("g/g")
    assert_equal({ "g/g/t/state" => "gone", "h/h/t/state" => "alive" },
                 st.answer["values"].to_h { [_1["key"], _1["app"]] })
    alive["g/g"] = true
    assert_equal "restarted", st.answer("g/**")["values"][0]["app"], "left and back after this value"
    st.put("g/g/t/state", pk.({ "n" => 2 }))
    assert_equal "alive", st.answer("g/**")["values"][0]["app"], "a value from its new life"

    # Cut: a value whose JSON is longer than VALUE_CUT.
    long = { "s" => "a" * (V::Store::VALUE_CUT + 10) }
    st.put("g/g/long/state", pk.(long))
    got = st.answer("g/g/long/state")["values"][0]
    assert_equal true, got["truncated"]
    assert_kind_of String, got["value"]
    assert got["value"].start_with?('{"s":"aaa')
    assert got["value"].end_with?("…")
    assert_operator got["value"].bytesize, :<=, V::Store::VALUE_CUT + 3
    refute st.answer("g/g/t/state")["values"][0].key?("truncated")
    # More keys than an answer lists.
    st2 = V::Store.new
    (V::Store::MAX_ANSWER + 5).times { |i| st2.put(format("a/b/c/k%03d", i), pk.(i)) }
    many = st2.answer
    assert_equal [V::Store::MAX_ANSWER, 5], [many["values"].size, many["more"]]
    assert_raises(ArgumentError) { st2.answer("a/b*") }
  end

  # Protocol 2's values: the encoding, the attachment's numbers, the
  # values lost between two of a key, the pictures kept for the MCP bridge.
  def test_values_encodings
    jpeg = "\xFF\xD8\xFF\xE0\x00\x10".b
    assert_equal ["(6 bytes)", "image/jpeg"], V.decode(jpeg, "image/jpeg")
    assert_equal [{ "a" => 1 }, "msgpack"], V.decode(MessagePack.pack({ "a" => 1 }), "zenoh/bytes"), "the default"
    assert_equal [{ "a" => 1 }, "application/json"], V.decode('{"a": 1}', "application/json")
    assert_equal ["{not json", "application/json"], V.decode("{not json", "application/json")
    assert_equal ["x,y\n1,2", "text/csv"], V.decode("x,y\n1,2", "text/csv;charset=utf-8"), "the schema left out"
    assert_equal ["(2 bytes)", "text/plain"], V.decode("\xff\xfe".b, "text/plain"), "not UTF-8"
    assert_equal ["(3 bytes)", "application/cdr"], V.decode("abc", "application/cdr")
    assert_equal [7, nil], V.attachment(MessagePack.pack([7]))
    assert_equal [7, 1_700_000_000_123], V.attachment(MessagePack.pack([7, 1_700_000_000_123]))
    assert_equal [nil, nil], V.attachment(nil)
    assert_equal [nil, nil], V.attachment(MessagePack.pack(["x"]))
    assert_equal [nil, nil], V.attachment("\xc1".b)
    assert_equal [5, nil], V.attachment(MessagePack.pack([5, "not ms"]))
    e = V.entry("asterism/a/b/cam", jpeg, Time.at(0), encoding: "image/jpeg",
                attachment: MessagePack.pack([3, 1_700_000_000_123]))
    assert_equal({ "key" => "a/b/cam", "t" => "1970-01-01T00:00:00.000Z", "bytes" => 6, "format" => "image/jpeg",
                   "value" => "(6 bytes)", "seq" => 3, "sent" => "2023-11-14T22:13:20.123Z" }, e)

    sq = V::Seq.new
    assert_equal [0, false], sq.see("k", 5), "the first: nothing lost"
    assert_equal [0, false], sq.see("k", 6)
    assert_equal [2, false], sq.see("k", 9)
    assert_equal [0, false], sq.see("other", 100), "each key its own"
    assert_equal [1, true], sq.see("k", 1), "back: started again"
    sq.see("w", Asterism::Topic::SEQ_MAX)
    assert_equal [0, false], sq.see("w", 0), "the wrap is a step"
    pk = ->(n) { MessagePack.pack([n]) }
    e = V.entry("a/b/c", MessagePack.pack(1), Time.at(0), attachment: pk.(10), seq: sq)
    refute e.key?("lost")
    e = V.entry("a/b/c", MessagePack.pack(1), Time.at(0), attachment: pk.(13), seq: sq)
    assert_equal [13, 2], e.values_at("seq", "lost")
    e = V.entry("a/b/c", MessagePack.pack(1), Time.at(0), attachment: pk.(0), seq: sq)
    assert_equal [true, nil], e.values_at("restarted", "lost")

    st = V::Store.new(now: -> { Time.at(0) })
    st.put("g/g/cam", jpeg, encoding: "image/jpeg", attachment: pk.(1))
    st.put("g/g/cam", jpeg, encoding: "image/jpeg", attachment: pk.(4))
    st.put("g/g/imu", MessagePack.pack([1, 2, 3]), attachment: MessagePack.pack([0, 1000]))
    a = st.answer("g/g/*")
    cam, imu = a["values"]
    assert_equal ["image/jpeg", "(6 bytes)", 4, 2], cam.values_at("format", "value", "seq", "lost")
    refute cam.key?("image"), "no images unless asked"
    assert_equal [[1, 2, 3], 0, "1970-01-01T00:00:01.000Z"], imu.values_at("value", "seq", "sent")
    refute imu.key?("lost")
    out, pics = st.answer_images("g/g/*")
    assert_equal 0, out["values"][0]["image"]
    refute out["values"][1].key?("image")
    assert_equal [["image/jpeg", jpeg]], pics
    st.put("g/g/cam", "x", encoding: "image/jpeg", attachment: pk.(5))
    assert_equal 2, st.answer("g/g/cam")["values"][0]["lost"], "lost counts all the key's since the start"
    _, pics = st.answer_images("g/g/*", images: 0)
    assert_empty pics
  end

  def test_values_wait
    st = V::Store.new
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    a = st.answer("g/g/t/state", wait: 0.3)
    dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    assert_equal [], a["values"]
    assert_includes 0.25..2.0, dt, "waited, then gave up"
    assert_match(/nothing came for g\/g\/t\/state in 0.3 s: .*since this server started.*does not let/, a["note"])
    assert_match(/nothing came for x\/\*\*: /, st.answer("x/**")["note"], "no wait: at once")
    th = Thread.new { sleep 0.2; st.put("g/g/other/state", "1"); sleep 0.2; st.put("g/g/t/state", MessagePack.pack(7)) }
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    a = st.answer("g/g/t/*", wait: 5)
    dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    th.join
    assert_equal [7], a["values"].map { _1["value"] }, "the first put that matches ends the wait"
    assert_includes 0.3..2.0, dt
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal 1, st.answer("g/g/t/*", wait: 5)["values"].size
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :<, 0.2, "one is there: no wait"
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Thread.new { sleep 0.2; st.put("q/q/q/q", "1") }
    st.answer("q/**", wait: -3)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :<, 0.15, "a wait below 0 is 0"
  end

  def test_put_lines
    cli = Asterism::CLI.new(out: StringIO.new, env: {})
    t = Time.at(0)
    ts = t.strftime("%H:%M:%S.%L")
    pad = " " * 13
    e = ->(v) { V.entry("asterism/g/g/t/state", MessagePack.pack(v), t) }
    assert_equal ["#{ts} g/g/t/state", "#{pad}st=play n=1 cnt=[2, 2]"],
                 cli.put_lines(t, e.({ "st" => "play", "n" => 1, "cnt" => [2, 2] }), nil)
    assert_equal ["#{ts} g/g/t/state n 1\u21922", "#{ts} g/g/t/state cnt [2, 2]\u2192[1, 4]"],
                 cli.put_lines(t, e.({ "st" => "play", "n" => 2, "cnt" => [1, 4] }),
                               { "st" => "play", "n" => 1, "cnt" => [2, 2] }, again: true)
    assert_nil cli.put_lines(t, e.({ "n" => 1 }), { "n" => 1 }, again: true), "no change, no line"
    assert_equal ["#{ts} g/g/t/state 5"], cli.put_lines(t, e.(5), 4, again: true)
    assert_nil cli.put_lines(t, e.(5), 5, again: true)
    assert_equal ["#{ts} g/g/t/state \"a b\""], cli.put_lines(t, e.("a b"), nil)
    jpeg = V.entry("g/g/cam", "\xFF\xD8\xFF".b, t, encoding: "image/jpeg")
    assert_equal ["#{ts} g/g/cam (image/jpeg, 3 bytes)"], cli.put_lines(t, jpeg, nil)
    assert_equal ["#{ts} g/g/cam (image/jpeg, 3 bytes)"], cli.put_lines(t, jpeg, "(3 bytes)", again: true),
                 "a picture each time, even of the same size"
    sq = V::Seq.new
    n = ->(v, i) { V.entry("g/g/t/state", MessagePack.pack(v), t, attachment: MessagePack.pack([i]), seq: sq) }
    n.({ "n" => 1 }, 0)
    assert_equal ["#{ts} g/g/t/state (2 lost)", "#{ts} g/g/t/state n 1\u21922"],
                 cli.put_lines(t, n.({ "n" => 2 }, 3), { "n" => 1 }, again: true)
    assert_equal ["#{ts} g/g/t/state (started again at 0)"], cli.put_lines(t, n.({ "n" => 2 }, 0), { "n" => 2 }, again: true)
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
    assert_equal %w[app call completion echo help mcp node nodes object objects ping status topic tree version watch],
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
    assert_equal %w[--once], complete("object echo --on", src)
    assert_equal %w[--raw], complete("object echo --ra", src)
    refute_includes complete("object get --", src), "--once"
    assert_includes complete("object get --", src), "--timeout"
    assert_equal %w[echo find get info list], complete("object ", src)
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
    assert_equal %w[games/games/mahjong1 games/games/othello1], complete("object get games/games/")
    assert_equal %w[games/games/othello1], complete("object echo games/games/o")
    assert_empty complete("object get games/games/othello1 "), "a key is not asked for"
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
    require "json"
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
    topics = {}
    loop do
      Asterism.poll
      r, = IO.select([STDIN], nil, nil, 0.002)
      next unless r
      line = STDIN.gets
      break if line.nil?
      if line.start_with?("put ")
        # put NAME JSON: a value on this application's topic NAME (declared
        # the first time, without a type).
        _, key, json = line.chomp.split(" ", 3)
        (topics[key] ||= Asterism.publish(key)).put(JSON.parse(json))
      elsif line.start_with?("jpeg ")
        # jpeg NAME SIZE: SIZE bytes of a JPEG on the topic NAME (image/jpeg).
        _, key, size = line.split
        t = (topics[key] ||= Asterism.publish(key, type: :image, encoding: "image/jpeg"))
        t.put("\xFF\xD8\xFF\xE0".b + ("\x00".b * (size.to_i - 4)))
      elsif line.start_with?("skip ")
        # skip NAME: the next number of the topic NAME is not sent (one lost).
        topics[line.split[1]].advance
      elsif line.start_with?("declare")
        # declare: a typed topic and a type of this application's own.
        Asterism.define_type("calc/result", [["sum", "int"], ["at", :vector3], ["parts", "float[]"]],
                             desc: "What a sum gave.")
        topics["imu"] = Asterism.publish("imu", type: :vector3, unit: "m/s2", ts: true, desc: "Acceleration.")
        topics["calc/result"] = Asterism.publish("calc/result", type: "calc/result")
      else
        Asterism.status(tables: line.to_i)
      end
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
      assert_equal "calcnode\n  profile: kind=cruby protocol=2 name=\"Calc node\" icon_hash=HASH\n  calc\n" \
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

  # On a connection given (CLI.new(net:)), as a console's bridge runs it:
  # this process is one more node ("host"/"console"), the commands run on
  # its connection, permit: is asked, stop: ends the streams, and what a
  # command subscribed to is released while the connection stays.
  def test_on_a_given_connection
    with_node do |node|
      if (r = TestHelper.router)
        Asterism.connect(r, node: "host", app: "console")
      else
        Asterism.connect(@where[1], node: "host", app: "console", mode: :peer)
      end
      net = Asterism.net
      net.start
      assert wait_for(5) { Asterism.each("calcnode/**").size == 2 }
      plans = []
      run = lambda do |*words, permit: ->(pl) { plans << pl; nil }, stop: nil, cols: 80|
        out = FakeTTY.new(cols)
        cli = Asterism::CLI.new(out: out, err: out, env: { "NO_COLOR" => "1" }, net: net, stop: stop, permit: permit)
        code = cli.run(words)
        [out.string, code, cli]
      end

      out, code = run.("node", "list")
      assert_equal [0, "calcnode\n"], [code, out], "this connection's own node is left out"
      assert_equal ["node list", :read], plans.last.to_h.values_at(:key, :kind)
      out, code = run.("tree")
      assert_equal 0, code, out
      assert_includes out, "    calc  5 methods\n"
      out, code = run.("call", "calcnode/calc/calc", "add", "2", "3")
      assert_equal [0, "5\n"], [code, out]
      assert_equal ["call", :call, "calcnode/calc/calc", "add", %w[calcnode/calc/calc add 2 3]],
                   plans.last.to_h.values_at(:key, :kind, :path, :method, :args)
      out, code = run.("call", "calcnode/calc/calc", "whoami")
      assert_equal [0, "\"host\"\n"], [code, out], "the caller is the connection's node"
      run.("ping", "calcnode/calc/calc", "--call", "add", "1", "2", "--count", "1")
      assert_equal [:call, "calcnode/calc/calc", "add"], plans.last.to_h.values_at(:kind, :path, :method)
      run.("ping", "calcnode/calc/calc", "--count", "1")
      assert_equal :read, plans.last.kind

      # Refused by permit: its reason, nothing called.
      out, code, cli = run.("call", "calcnode/calc/calc", "add", "2", "3", permit: ->(pl) { "#{pl.method}: no" })
      assert_equal [2, "asterism: add: no\n", "add: no"], [code, out, cli.refused]
      # Long options in full only: --cal is not --call (a call that would pass as a read).
      n = plans.size
      out, code = run.("ping", "calcnode/calc/calc", "--cal", "add")
      assert_equal 2, code
      assert_match(/invalid option: --cal/, out)
      assert_equal n, plans.size, "refused before permit: is asked"
      out, code = run.("node", "list", "--router", "tcp/192.0.2.2:7447")
      assert_equal [2, "asterism: --router: this command line runs on the connection it was given\n"], [code, out]
      out, code = run.("call", "a/b/c", "m", "--node=other")
      assert_match(/--node: this command line runs on the connection/, out)
      assert_equal 2, code
      out, code = run.("mcp")
      assert_equal [2, "asterism: mcp runs only as a program of its own (asterism mcp)\n"], [code, out]
      assert_equal :local, plans.last.kind
      out, code = run.("completion", "bash")
      assert_equal 2, code
      out, code = run.("node", "list", "--help")
      assert_equal 0, code
      assert_match(/\AUsage: asterism node list \[options\]/, out)
      refute_match(/--router/, out)
      out, code = run.("version", "--version")
      assert_equal [0, "asterism #{Asterism::VERSION}\n"], [code, out]
      out, code = run.("__complete", "--", "call", "calc")
      assert_equal [0, "calcnode/\n"], [code, out]
      out, = run.("__complete", "--", "call", "calcnode/calc/calc", "a")
      assert_equal "add\nany\n", out

      # A stream ends when stop: says so; what it subscribed to goes, the
      # connection stays.
      stop = false
      q = Queue.new
      th = Thread.new { q << run.("status", "echo", "calcnode/calc", stop: -> { stop }) }
      sleep 1.0
      node.puts "9"
      node.flush
      sleep 0.8
      stop = true
      out, code, cli = Timeout.timeout(3) { q.pop }
      th.join
      assert_equal 0, code
      assert_match(/calcnode\/calc \(now\)\n\s+tables=1 st=wait\n.*tables 1→9/m, out)
      assert_empty cli.instance_variable_get(:@held)
      stop = false
      th = Thread.new { q << run.("watch", stop: -> { stop }) }
      sleep 0.8
      stop = true
      _, code, cli = Timeout.timeout(3) { q.pop }
      th.join
      assert_equal 0, code
      assert_empty cli.instance_variable_get(:@held)
      assert_empty Asterism.instance_variable_get(:@on_join).to_a, "watch's on_join is taken off"
      assert net.connected?
      out, code = run.("object", "get", "calcnode/calc/calc", "--timeout", "30", stop: -> { true })
      assert_equal 1, code, out
    ensure
      Asterism.close
    end
  end

  # object get / echo: the values the node puts on its own keys.
  def test_object_values
    with_node do |node|
      say = lambda do |line, after = 0|
        sleep after
        node.puts line
        node.flush
      end
      # get: waits for the next put.
      cmd = [PLAIN, RbConfig.ruby, *LIB, EXE, "object", "get", "calcnode/calc/calc", "state", "-o", "json",
             "--timeout", "8", *@where, "--settle", "1.0"]
      Open3.popen3(*cmd) do |_i, o, e, th|
        sleep 2.5
        say.('put calc/other {"n":1}')
        say.('put calc/state {"st":"play","n":1}', 0.3)
        out = Timeout.timeout(10) { o.read }
        assert_equal 0, th.value.exitstatus, e.read
        got = JSON.parse(out)
        assert_equal ["calcnode/calc/calc/state", { "st" => "play", "n" => 1 }, "msgpack"],
                     got.values_at("key", "value", "format")
        assert_match(/\A\d{4}-\d\d-\d\dT/, got["t"])
      end
      out, err, code = cli("object", "get", "calcnode/calc/calc", "--timeout", "0.5")
      assert_equal [1, ""], [code, out]
      assert_match(/nothing came on calcnode\/calc\/calc\/\*\* in 0.5 s \(the router does not let this node read it, or it has not changed\)/, err)
      _, err, code = cli("object", "get", "calcnode/calc", "--timeout", "0.5")
      assert_equal 2, code
      assert_match(/PATH is node\/app\/object/, err)
      _, err, code = cli("object", "get", "calcnode/c*/calc", "--timeout", "0.5")
      assert_equal 2, code

      # echo: whole the first time, then what changed; -o json each put whole.
      echo = [PLAIN, RbConfig.ruby, *LIB, EXE, "object", "echo", "calcnode/*/calc", "--duration", "6", *@where,
              "--settle", "1.0"]
      json = [PLAIN, RbConfig.ruby, *LIB, EXE, "object", "echo", "calcnode/calc/calc", "state", "--once", "-o", "json",
              *@where, "--settle", "1.0"]
      raw = [PLAIN, RbConfig.ruby, *LIB, EXE, "object", "echo", "calcnode/calc/calc", "--raw", "--duration", "6",
             *@where, "--settle", "1.0"]
      Open3.popen3(*echo) do |_i, o, _e, eth|
        Open3.popen3(*json) do |_i2, o2, _e2, jth|
          Open3.popen3(*raw) do |_i3, o3, _e3, rth|
            sleep 2.5
            say.('put calc/state {"st":"play","n":1,"cnt":[2,2]}')
            say.('put calc/state {"st":"play","n":2,"cnt":[4,1]}', 0.4)
            say.('put calc/state {"st":"play","n":2,"cnt":[4,1]}', 0.4)
            say.('put calc/log "hello"', 0.4)
            text = Timeout.timeout(10) { o.read }.lines.map(&:chomp)
            assert_equal 0, eth.value.exitstatus
            ts = /\A\d\d:\d\d:\d\d\.\d{3} /
            assert_match(/#{ts}calcnode\/calc\/calc\/state\z/, text[0])
            assert_equal "#{' ' * 13}st=play n=1 cnt=[2, 2]", text[1]
            assert_match(/#{ts}calcnode\/calc\/calc\/state n 1\u21922\z/, text[2])
            assert_match(/#{ts}calcnode\/calc\/calc\/state cnt \[2, 2\]\u2192\[4, 1\]\z/, text[3])
            assert_match(/#{ts}calcnode\/calc\/calc\/log hello\z/, text[4], "the same value again: no line")
            assert_equal 5, text.size, text.inspect
            once = Timeout.timeout(10) { o2.read }.lines
            assert_equal 0, jth.value.exitstatus
            assert_equal 1, once.size, "--once: the first put"
            assert_equal({ "st" => "play", "n" => 1, "cnt" => [2, 2] }, JSON.parse(once[0])["value"])
            r = Timeout.timeout(10) { o3.read }.lines.map(&:chomp)
            rth.value
            assert_equal 7, r.size, "--raw: each put whole (#{r.inspect})"
            assert_equal "#{' ' * 13}st=play n=2 cnt=[4, 1]", r[5]
          end
        end
      end
      _, err, code = cli("object", "echo", "calcnode/calc/calc", "--once", "--duration", "0.5")
      assert_equal 1, code
      assert_match(/nothing came on calcnode\/calc\/calc\/\*\* in 0.5 s/, err)
    end
  end

  # Protocol 2's topics: what an application declares (topic list / info,
  # app info, tree) and its values with their encodings and numbers.
  def test_topics
    with_node do |node|
      say = lambda do |line, after = 0|
        sleep after
        node.puts line
        node.flush
      end
      say.("declare")
      sleep 0.3
      out, err, code = cli("topic", "list", "calcnode/*")
      assert_equal 0, code, err
      assert_equal "calcnode/calc/calc/result  calc/result\ncalcnode/calc/imu  vector3 (m/s2, ts)\n", out
      j, = cli("topic", "list", "-o", "json")
      assert_equal [{ "path" => "calcnode/calc/calc/result", "type" => "calc/result" },
                    { "path" => "calcnode/calc/imu", "type" => "vector3", "unit" => "m/s2", "desc" => "Acceleration.",
                      "ts" => true }], JSON.parse(j).select { _1["path"].start_with?("calcnode/") }
      _, err, code = cli("topic", "list", "calcnode")
      assert_equal 2, code
      assert_match(/NODE\/APP/, err)

      out, err, code = cli("topic", "info", "calcnode/calc/calc/result")
      assert_equal 0, code, err
      assert_equal "calcnode/calc/calc/result\n  type: calc/result\n  encoding: msgpack\n  definition:\n" \
                   "    calc/result\n      What a sum gave.\n      sum int  at vector3  parts float[]\n", out
      j, = cli("topic", "info", "calcnode/calc/calc/result", "-o", "json")
      assert_equal({ "path" => "calcnode/calc/calc/result", "type" => "calc/result",
                     "definition" => { "f" => [%w[sum int], %w[at vector3], %w[parts float[]]],
                                       "d" => "What a sum gave." } }, JSON.parse(j))
      out, = cli("topic", "info", "calcnode/calc/imu")
      assert_equal "calcnode/calc/imu\n  type: vector3\n  encoding: msgpack\n  unit: m/s2\n" \
                   "  time: the sender's, with each value\n  Acceleration.\n", out
      _, err, code = cli("topic", "info", "calcnode/calc/nothing")
      assert_equal 1, code
      assert_match(/no topic calcnode\/calc\/nothing is declared/, err)
      _, _, code = cli("topic", "info", "calcnode/calc")
      assert_equal 2, code

      out, err, code = cli("app", "info", "calcnode/calc")
      assert_equal 0, code, err
      assert_includes out, "  status:\n    tables=1 st=wait\n  topics:\n    calc/result  calc/result\n" \
                           "    imu  vector3 (m/s2, ts)\n      Acceleration.\n  types:\n    calc/result\n" \
                           "      What a sum gave.\n      sum int  at vector3  parts float[]\n  objects:\n"
      j, = cli("app", "info", "calcnode/calc", "-o", "json")
      assert_equal %w[node app status topics types objects], JSON.parse(j).keys
      out, = cli("tree")
      assert_includes out, "      tables=1 st=wait\n    topics:\n      calc/result  calc/result\n" \
                           "      imu  vector3 (m/s2, ts)\n        Acceleration.\n    calc  5 methods\n"
      j, = cli("nodes", "--json")
      calc = JSON.parse(j).find { _1["node"] == "calcnode" }
      assert_equal %w[calc/result imu], calc["apps"][0]["topics"].map { _1["name"] }

      # The values: a picture, the numbers, what was lost.
      cmd = [PLAIN, RbConfig.ruby, *LIB, EXE, "object", "echo", "calcnode/calc/*", "-o", "json", "--duration", "5",
             *@where, "--settle", "1.0"]
      text = [PLAIN, RbConfig.ruby, *LIB, EXE, "object", "echo", "calcnode/calc/*", "--duration", "5",
              *@where, "--settle", "1.0"]
      Open3.popen3(*cmd) do |_i, o, _e, th|
        Open3.popen3(*text) do |_i2, o2, _e2, th2|
          sleep 2.5
          say.("jpeg cam 100")
          say.("put calc/state 1", 0.3)
          say.("skip calc/state", 0.3)
          say.("put calc/state 2", 0.1)
          got = Timeout.timeout(10) { o.read }.lines.map { JSON.parse(_1) }
          th.value
          cam = got.find { _1["key"] == "calcnode/calc/cam" }
          assert_equal ["image/jpeg", 100, "(100 bytes)", 0], cam.values_at("format", "bytes", "value", "seq"), got.inspect
          st = got.select { _1["key"] == "calcnode/calc/calc/state" }
          assert_equal [[1, 0, nil], [2, 2, 1]], st.map { _1.values_at("value", "seq", "lost") }
          lines = Timeout.timeout(10) { o2.read }.lines.map(&:chomp)
          th2.value
          ts = /\A\d\d:\d\d:\d\d\.\d{3} /
          assert_match(/#{ts}calcnode\/calc\/cam \(image\/jpeg, 100 bytes\)\z/, lines[0])
          assert_match(/#{ts}calcnode\/calc\/calc\/state 1\z/, lines[1])
          assert_match(/#{ts}calcnode\/calc\/calc\/state \(1 lost\)\z/, lines[2])
          assert_match(/#{ts}calcnode\/calc\/calc\/state 2\z/, lines[3])
        end
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
    assert_equal ["echo", "echo find get info list", "json yaml", "--credentials"], out.lines.map(&:chomp)
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
    with_node do |node|
      t = MCP::Client::Stdio.new(command: RbConfig.ruby,
                                 args: [*LIB, EXE, "mcp", *@where, "--settle", "1.0", "--allow", "calc/calc.add",
                                        "--allow", "calc/calc.any", "--allow", "calc/calc.boom",
                                        "--allow", "calc/other.add"],
                                 read_timeout: 30)
      c = MCP::Client.new(transport: t)
      c.connect
      tools = c.tools.to_h { [_1.name, _1] }
      assert_equal %w[asterism_nodes asterism_objects asterism_status asterism_topics asterism_values calcnode.calc.calc.add
                      calcnode.calc.calc.any calcnode.calc.calc.boom calcnode.calc.other.add].sort, tools.keys.sort,
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

      # asterism_values: nothing yet; wait for the first put; what came since.
      vt = tools["asterism_values"]
      assert_match(/only when the value changes/, vt.description)
      assert_match(/wait/, vt.description)
      assert_match(/since it started/, vt.description)
      r = c.call_tool(tool: vt, arguments: {})
      v = text.(r)
      assert_equal [], v["values"]
      assert_match(/nothing came for \*\*/, v["note"])
      Thread.new do
        sleep 0.5
        node.puts 'put calc/state {"st":"play","bd":"..BW.."}'
        node.flush
      end
      r = c.call_tool(tool: vt, arguments: { pattern: "calcnode/calc/*/state", wait: 10 })
      v = text.(r)
      assert_equal 1, v["values"].size, v.inspect
      got = v["values"][0]
      assert_equal ["calcnode/calc/calc/state", { "st" => "play", "bd" => "..BW.." }, "alive", "msgpack"],
                   got.values_at("key", "value", "app", "format")
      assert_kind_of Numeric, got["age_s"]
      node.puts 'put calc/log "two"'
      node.flush
      sleep 0.5
      v = text.(c.call_tool(tool: vt, arguments: { pattern: "calcnode/**" }))
      assert_equal %w[calcnode/calc/calc/log calcnode/calc/calc/state], v["values"].map { _1["key"] }
      r = c.call_tool(tool: vt, arguments: { pattern: "calcnode/c*" })
      assert r["result"]["isError"]

      # asterism_topics: the declarations and the types; asterism_values: a
      # picture as an image when asked.
      node.puts "declare"
      node.puts "jpeg cam 20"
      node.flush
      sleep 0.5
      r = c.call_tool(tool: tools["asterism_topics"], arguments: { node: "calcnode" })
      tp = text.(r)
      assert_equal ["calcnode/calc"], tp.keys
      assert_equal [{ "name" => "calc/log" }, { "name" => "calc/result", "type" => "calc/result" },
                    { "name" => "calc/state" }, { "name" => "cam", "type" => "image", "encoding" => "image/jpeg" },
                    { "name" => "imu", "type" => "vector3", "unit" => "m/s2", "desc" => "Acceleration.", "ts" => true }],
                   tp["calcnode/calc"]["topics"]
      assert_equal({ "calc/result" => { "f" => [%w[sum int], %w[at vector3], %w[parts float[]]],
                                        "d" => "What a sum gave." } }, tp["calcnode/calc"]["types"])
      assert_equal({}, text.(c.call_tool(tool: tools["asterism_topics"], arguments: { node: "nobody" })))
      r = c.call_tool(tool: vt, arguments: { pattern: "calcnode/calc/cam", wait: 5 })
      assert_equal 1, r["result"]["content"].size, "no image unless asked"
      cam = text.(r)["values"][0]
      assert_equal ["image/jpeg", "(20 bytes)", 0], cam.values_at("format", "value", "seq")
      r = c.call_tool(tool: vt, arguments: { pattern: "calcnode/calc/cam", images: true })
      content = r["result"]["content"]
      assert_equal 0, JSON.parse(content[0]["text"])["values"][0]["image"]
      assert_equal ["image", "image/jpeg"], content[1].values_at("type", "mimeType")
      assert_equal "\xFF\xD8\xFF\xE0".b + ("\x00".b * 16), content[1]["data"].unpack1("m0")
    ensure
      t&.close
    end
  end
end
