# Application statuses: the checks (no network), and
# asterism/<node>/<app>/@status between two CRuby processes: status_of, the
# puts on a change (and none for the same status again), the CRuby API's
# on_status, an application without a status, answers that are not
# acceptable, and Asterism.apps.
require_relative "helper"
require "asterism"
require "rbconfig"
require "timeout"

class TestStatus < Minitest::Test
  include TestHelper

  # ------------------------------------------------------------ no network

  def test_check_cleans_a_received_status
    c = ->(h) { Asterism::Status.check(h) }
    assert_nil c.(nil)
    assert_nil c.([1, 2])
    assert_nil c.("x")
    assert_equal({}, c.({}))
    assert_equal({ "a" => 1, "b" => [1, { "c" => nil }] }, c.({ "a" => 1, 5 => 2, "" => 3, "b" => [1, { "c" => nil }] }))
    assert_nil c.({ "big" => "x" * 1100 }), "more than MAX_BYTES packed"
    assert c.({ "big" => "x" * 1000 })
  end

  def test_parse_a_notice
    pl = MessagePack.pack({ "n" => 1 })
    assert_equal ["games", "games", { "n" => 1 }], Asterism::Status.parse("asterism/games/games/@status", pl)
    assert_nil Asterism::Status.parse("asterism/games/@status", pl)
    assert_nil Asterism::Status.parse("asterism/games/games/@profile", pl)
    assert_nil Asterism::Status.parse("asterism/games/games/@status", MessagePack.pack([1]))
  end

  def test_status_fields
    Asterism.instance_variable_set(:@status, nil)
    assert_nil Asterism.status
    assert_equal({ "tables" => 3, "humans" => 2 }, Asterism.status(tables: 3, humans: 2))
    assert_equal({ "tables" => 4, "humans" => 2 }, Asterism.status(tables: 4), "keywords keep the other fields")
    assert_equal({ "humans" => 2 }, Asterism.status(tables: nil), "nil removes a field")
    assert_equal({ "a" => { "b" => :c.to_s } }, Asterism.status({ a: { "b" => :c } }), "a Hash is the whole status")
    assert_equal({ "a" => 1, "z" => 2 }, Asterism.status({ "a" => 1 }, z: 2))
    assert_equal({}, Asterism.status({}))
    st = Asterism.status
    st["x"] = 1
    refute Asterism.status.key?("x"), "a copy"
    assert_raises(ArgumentError) { Asterism.status([1]) }
    assert_raises(ArgumentError) { Asterism.status({ 1 => 2 }) }
    assert_raises(ArgumentError) { Asterism.status({ "" => 2 }) }
    assert_raises(ArgumentError) { Asterism.status(t: Time.now) }
    assert_raises(ArgumentError) { Asterism.status(big: "x" * 1100) }
    assert_raises(ArgumentError) { Asterism.status(deep: [[[[[1]]]]]) }
    assert Asterism.status(deep: [[[[1]]]]), "four levels below the map"
    assert_equal({ "deep" => [[[[1]]]] }, Asterism.status, "a refused change changes nothing")
  ensure
    Asterism.instance_variable_set(:@status, nil)
  end

  # ------------------------------------------------------------ two processes

  # The other process: node "child", app "t", a status set before
  # connecting; app "quiet" of node "child2" (another process would be
  # needed for a second app, so a raw queryable plays the bad answers).
  # Lines on stdin: "set <n>" sets tables: n, "same" sets the same again.
  CHILD = <<~'RUBY'
    require "asterism"
    loc = ARGV[0]
    Asterism.status(tables: 1, st: "wait")
    if ARGV[1] == "router"
      Asterism.connect(loc, node: "child", app: "t")
    else
      Asterism.connect(nil, node: "child", app: "t", mode: :peer, listen: loc)
    end
    s = Asterism.session
    bad = s.queryable("asterism/bad/*/@status")
    answers = { "list" => [1, 2], "junk" => "x", "intkeys" => { 1 => 2, "ok" => true } }
    STDOUT.puts "ready"
    STDOUT.flush
    loop do
      Asterism.poll
      bad.each_pending do |q|
        app = q.key.split("/")[2]
        q.reply(q.key, MessagePack.pack(answers[app])) if answers.key?(app)
        q.finish
      end
      r, = IO.select([STDIN], nil, nil, 0.002)
      next unless r
      line = STDIN.gets
      break if line.nil?
      cmd, arg = line.strip.split(" ", 2)
      Asterism.status(tables: arg.to_i) if cmd == "set"
      Asterism.status(tables: Asterism.status["tables"]) if cmd == "same"
      STDOUT.puts "done #{cmd}"
      STDOUT.flush
    end
    Asterism.close
  RUBY

  def test_status_between_two_processes
    if (router = TestHelper.router)
      loc = router
      mode = "router"
    else
      loc = "tcp/127.0.0.1:#{TestHelper.free_port}"
      mode = "peer"
    end
    lib = [File.expand_path("../lib", __dir__), TestHelper.zenoh_lib].compact
    child = IO.popen([RbConfig.ruby, *lib.flat_map { |l| ["-I", l] }, "-e", CHILD, loc, mode], "r+")
    assert_equal "ready", child.gets&.strip
    if router
      Asterism.connect(loc, node: "parent", app: "t")
    else
      Asterism.connect(loc, node: "parent", app: "t", mode: :peer)
    end
    assert wait_for { Asterism.poll; Asterism.apps.include?("child/t") }
    assert_equal ["parent/t", "child/t"], Asterism.apps
    assert_equal ["child/t"], Asterism.apps("child/*")
    assert_equal({ "tables" => 1, "st" => "wait" }, Asterism.status_of("child", "t"))

    s = Asterism.session
    notices = s.subscribe("asterism/*/*/@status")
    sleep 0.3 # the subscription reaches the other side
    child.puts "set 2"
    assert_equal "done set", child.gets&.strip
    got = nil
    assert wait_for { Asterism.poll; got ||= notices.each_pending.find { |k, _| k == "asterism/child/t/@status" } }
    assert_equal ["child", "t", { "tables" => 2, "st" => "wait" }], Asterism::Status.parse(got[0], got[1])
    child.puts "same"
    assert_equal "done same", child.gets&.strip
    sleep 0.3
    Asterism.poll
    assert_empty notices.each_pending, "the same status again puts nothing"
    assert_equal 2, Asterism.status_of("child", "t")["tables"]

    # @status is a verbatim chunk: asterism/child/t/** does not reach it.
    replies = []
    g = s.get("asterism/child/t/**", timeout_ms: 800)
    assert wait_for(2) { Asterism.poll; replies.concat(g.each_reply); g.done? }
    assert_empty replies

    # No status set (this node's own, and nobody there): nil.
    assert_nil Asterism.status_of("parent", "t")
    t = Time.now
    assert_nil Asterism.status_of("child", "nothing", timeout: 1.0)
    assert Time.now - t < 1.5
    # Answers that are not acceptable.
    assert_nil Asterism.status_of("bad", "list")
    assert_nil Asterism.status_of("bad", "junk")
    assert_equal({ "ok" => true }, Asterism.status_of("bad", "intkeys"))
    assert_raises(ArgumentError) { Asterism.status_of("a/b", "t") }
    # This application's own, without the network.
    Asterism.status(n: 1)
    assert_equal({ "n" => 1 }, Asterism.status_of("parent", "t"))

    # The CRuby API: net.on_status and net.status_of on the receiving thread.
    net = Asterism.net
    seen = Queue.new
    net.on_status("child/*") { |n, a, st| seen << [n, a, st] }
    net.start
    sleep 0.3
    child.puts "set 5"
    assert_equal "done set", child.gets&.strip
    assert_equal ["child", "t", { "tables" => 5, "st" => "wait" }], Timeout.timeout(3) { seen.pop }
    assert_equal 5, net.status_of("child", "t")["tables"]
    assert_equal({ "n" => 2 }, net.status(n: 2))
    net.stop
  ensure
    Asterism.close
    Asterism.instance_variable_set(:@status, nil)
    if child && !child.closed?
      child.close_write rescue nil
      child.read rescue nil
      child.close rescue nil
    end
  end
end
