# The meta's argument names and descriptions (docs/protocol.md 5) and the
# applications coming and going (on_app_join / on_app_leave), between this
# process and two children on the same node ID with different applications.
require_relative "helper"
require "asterism"
require "rbconfig"

class TestMetaApps < Minitest::Test
  include TestHelper

  CHILD = <<~'RUBY'
    require "asterism"
    loc, app = ARGV
    Asterism.connect(loc, node: "child", app: app, mode: (ENV["T_ROUTER"] ? nil : :peer))
    class Table
      def move(token, n, square) = [token, n, square].join(" ")
      def view(token) = { "t" => token }
      def any(*a) = a.size
    end
    if app == "t"
      Asterism.expose("table", Table.new, doc: "A small table.",
                      methods: { "move" => { args: %w[token n square], doc: "Plays a move.\nSecond line." },
                                 view: { args: [:token] }, any: -1 })
    end
    STDOUT.puts "ready"
    STDOUT.flush
    loop do
      Asterism.poll
      r, = IO.select([STDIN], nil, nil, 0.002)
      break if r && STDIN.read_nonblock(1, exception: false).nil?
    end
    Asterism.close
  RUBY

  def spawn_child(loc, app)
    lib = [File.expand_path("../lib", __dir__), TestHelper.zenoh_lib].compact
    env = TestHelper.router ? { "T_ROUTER" => "1" } : {}
    c = IO.popen(env, [RbConfig.ruby, *lib.flat_map { |l| ["-I", l] }, "-e", CHILD, loc, app], "r+")
    assert_equal "ready", c.gets&.strip
    c
  end

  def stop_child(c)
    return unless c && !c.closed?
    c.close_write rescue nil
    c.read rescue nil
    c.close rescue nil
  end

  def test_meta_docs_and_applications
    loc = TestHelper.router || "tcp/127.0.0.1:#{TestHelper.free_port}"
    if TestHelper.router
      Asterism.connect(loc, node: "parent", app: "t")
    else
      Asterism.connect(nil, node: "parent", app: "t", mode: :peer, listen: loc)
    end
    events = []
    Asterism.on_join { |n| events << "+#{n}" }
    Asterism.on_leave { |n| events << "-#{n}" }
    Asterism.on_app_join { |n, a| events << "+#{n}/#{a}" }
    Asterism.on_app_leave { |n, a| events << "-#{n}/#{a}" }
    a = spawn_child(loc, "t")
    b = spawn_child(loc, "other")
    assert wait_for(5) { Asterism.poll; events.count { _1.start_with?("+child/") } == 2 }
    assert_equal ["+child", "+child/other", "+child/t"], events.sort

    # The meta: names and docs where given, the arity from the names.
    meta = Asterism.meta("child/t/table")
    assert_equal "A small table.", meta["doc"]
    by = meta["methods"].to_h { [_1["name"], _1] }
    assert_equal({ "name" => "move", "arity" => 3, "args" => %w[token n square],
                   "doc" => "Plays a move.\nSecond line." }, by["move"])
    assert_equal({ "name" => "view", "arity" => 1, "args" => ["token"] }, by["view"])
    assert_equal({ "name" => "any", "arity" => -1 }, by["any"])
    table = Asterism["child/t/table"]
    assert_equal "x 1 d3", table.move("x", 1, "d3")
    e = assert_raises(Asterism::RemoteError) { table.move("x", 1) }
    assert_equal "arguments", e.remote_kind

    # Another application of the same node closes: it leaves, the node stays.
    events.clear
    stop_child(b)
    assert wait_for(5) { Asterism.poll; events.include?("-child/other") }
    Asterism.poll
    assert_equal ["-child/other"], events
    assert_includes Asterism.nodes, "child"
    stop_child(a)
    assert wait_for(5) { Asterism.poll; events.include?("-child") } unless !TestHelper.router && !Asterism.connected?
  ensure
    Asterism.close
    stop_child(a)
    stop_child(b)
  end

  # What expose refuses (no network needed for the checks before it).
  def test_method_doc_checks
    assert_equal [2, { "args" => %w[a b] }], Asterism.method_doc("m", { args: %w[a b] })
    assert_equal [-1, { "doc" => "x" }], Asterism.method_doc("m", { doc: "x" })
    assert_equal [-1, { "args" => ["a"] }], Asterism.method_doc("m", { args: ["a"], arity: -1 })
    assert_raises(ArgumentError) { Asterism.method_doc("m", { args: %w[a b], arity: 1 }) }
    assert_raises(ArgumentError) { Asterism.method_doc("m", { args: "a" }) }
    assert_raises(ArgumentError) { Asterism.method_doc("m", { args: [""] }) }
    assert_raises(ArgumentError) { Asterism.method_doc("m", { doc: 1 }) }
    assert_raises(ArgumentError) { Asterism.method_doc("m", { doc: "x" * (Asterism::DOC_MAX + 1) }) }
    assert_raises(ArgumentError) { Asterism.method_doc("m", { name: "x" }) }
  end
end
