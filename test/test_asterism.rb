# The shared pure Ruby layers on CRuby: the object layer between two CRuby
# processes (Asterism is one connection per process), and Asterism::ROS
# between two sessions of this process.
require_relative "helper"
require "asterism"
require "rbconfig"

class TestAsterismObjects < Minitest::Test
  include TestHelper

  # The other process: listens (peer mode, or a client of the test router),
  # exposes "calc" and "back", and answers until its stdin closes.
  CHILD = <<~'RUBY'
    require "asterism"
    loc = ARGV[0]
    if ARGV[1] == "router"
      Asterism.connect(loc, node: "child", app: "t")
    else
      Asterism.connect(nil, node: "child", app: "t", mode: :peer, listen: loc)
    end
    class Calc
      def add(a, b) = a + b
      def kw(x, scale: 1) = x * scale
      def boom = raise(ArgumentError, "boom in child")
      def bin = "\xff\x00\x01".b
      def echo(v) = v
      def secret = "no"
      # Calls the caller back while answering (nested waits on both sides).
      def relay(node) = Asterism["#{node}/t/back"].name + "!"
    end
    Asterism.expose("calc", Calc.new, methods: { add: 2, kw: 1, boom: 0, bin: 0, echo: 1, relay: 1 })
    STDOUT.puts "ready"
    STDOUT.flush
    loop do
      Asterism.poll
      r, = IO.select([STDIN], nil, nil, 0.002)
      break if r && STDIN.read_nonblock(1, exception: false).nil?
    end
    Asterism.close
  RUBY

  class Back
    def name = "parent"
  end

  def test_calls_between_two_processes
    if (router = TestHelper.router)
      loc = router
      mode = "router"
    else
      loc = "tcp/127.0.0.1:#{TestHelper.free_port}"
      mode = "peer"
    end
    # The child loads the same asterism and asterism-zenoh as this process.
    lib = [File.expand_path("../lib", __dir__), TestHelper.zenoh_lib].compact
    child = IO.popen([RbConfig.ruby, *lib.flat_map { |l| ["-I", l] }, "-e", CHILD, loc, mode], "r+")
    assert_equal "ready", child.gets&.strip
    if router
      Asterism.connect(loc, node: "parent", app: "t")
    else
      Asterism.connect(loc, node: "parent", app: "t", mode: :peer)
    end
    Asterism.expose("back", Back.new, methods: [:name])
    joined = []
    left = []
    Asterism.on_join { |n| joined << n }
    Asterism.on_leave { |n| left << n }
    assert wait_for { Asterism.poll; Asterism.nodes.include?("child") }
    # Told from Asterism.poll (the shared layer; no receiving thread here).
    assert_equal ["child"], joined
    assert_equal [], left

    calc = Asterism["child/t/calc"]
    assert_equal 5, calc.add(2, 3)
    assert_equal 12, calc.kw(4, scale: 3)
    assert_equal "\xff\x00\x01".b, calc.bin.b
    v = { "a" => [1, 2.5, nil, true, "x"], "n" => -(2**40) }
    assert_equal v, calc.echo(v)
    assert_equal "sym", calc.echo(:sym)
    assert_equal "parent!", calc.relay("parent")

    e = assert_raises(Asterism::RemoteError) { calc.boom }
    assert_equal "ArgumentError", e.remote_class
    assert_equal "boom in child", e.remote_message
    e = assert_raises(Asterism::RemoteError) { calc.secret }
    assert_equal "NoMethodError", e.remote_class
    e = assert_raises(Asterism::RemoteError) { calc.add(1) }
    assert_equal "ArgumentError", e.remote_class
    assert_raises(Asterism::EncodeError) { calc.echo(Object.new) }

    assert calc.respond_to?(:add)
    refute calc.respond_to?(:secret)
    assert_equal %i[add kw boom bin echo relay].sort, calc.remote_methods.sort
    warned = with_deprecations { assert_equal calc.remote_methods.sort, calc.methods.sort; calc.methods }
    assert_equal 1, warned.size
    assert_match(/Proxy#methods is deprecated.*remote_methods/, warned[0])

    f = calc.async.add(10, 20)
    assert wait_for { Asterism.poll; f.done? }
    assert_equal 30, f.value
    assert f.took_ms
    assert_in_delta f.took_ms / 1000.0, f.took

    # The time limit in seconds; the old positional milliseconds warn.
    assert_equal 9, Asterism["child/t/calc", timeout: 1.5].add(4, 5)
    assert_equal 9, Asterism["child/t/calc", timeout_ms: 1500].add(4, 5)
    assert_raises(ArgumentError) { Asterism["child/t/calc", timeout: 1, timeout_ms: 1000] }
    warned = with_deprecations do
      assert_equal 3, Asterism["child/t/calc", 2000].add(1, 2)
      Asterism["child/t/calc", 2.0]
    end
    assert_equal 2, warned.size
    assert_match(/Asterism\[\] with the time limit as a positional argument/, warned[0])
    assert_match(/Float.*2\.0 waits 2 ms/, warned[1])

    assert_equal ["child/t/calc"], Asterism.each("child/*/*").map(&:asterism_path)
    assert_equal ["parent", "child"], Asterism.nodes
    assert_equal "parent", Asterism["parent/t/back"].name, "own objects are called in place"

    t = Time.now
    e = assert_raises(Asterism::TimeoutError) { Asterism["child/other/x"].anything }
    assert_match(/nobody answers/, e.message)
    assert Time.now - t < 1.5
    # The old name still rescues, and warns once.
    warned = with_deprecations do
      assert_raises(Asterism::Timeout) { Asterism["child/other/x"].anything }
      assert_equal Asterism::TimeoutError, Asterism::Timeout
    end
    assert_equal 1, warned.size
    assert_match(/Asterism::Timeout is deprecated.*TimeoutError/, warned[0])
    # off_join removes a block given to on_join.
    h = proc { |n| joined << "again #{n}" }
    Asterism.on_join(&h)
    Asterism.off_join(h)

    child.close_write
    child.read
    child.close
    if router
      assert wait_for(3) { Asterism.poll; !Asterism.nodes.include?("child") }
      assert_raises(Asterism::TimeoutError) { calc.add(1, 2) }
    else
      # The only peer is gone: the session closes (no reconnection).
      assert wait_for(5) { !Asterism.poll }
      refute Asterism.connected?
      assert Asterism.lost_reason
      assert_raises(Asterism::Disconnected) { calc.add(1, 2) }
    end
    # Gone (or the connection lost): told once.
    assert_equal ["child"], left
    Asterism.poll
    assert_equal ["child"], left
    assert_equal ["child"], joined
  ensure
    Asterism.close
    if child && !child.closed?
      child.close_write rescue nil
      child.close rescue nil
    end
  end

  def test_codec_sends_strings_as_str
    bin = Asterism::Codec.pack(["\xff".b, "abc"])
    # fixarray(2), fixstr(1) 0xff, fixstr(3) "abc": no bin type (0xc4..0xc6),
    # which the boards' MessagePack does not read.
    assert_equal "\x92\xa1\xff\xa3abc".b, bin
  end
end

class TestAsterismROS < Minitest::Test
  include TestHelper

  def setup
    @a, @b = open_pair
  end

  def teardown
    @na&.close
    @nb&.close
    @b&.close
    @a&.close
  end

  def test_types_come_from_the_gem
    assert_equal [Asterism::MSGS_DIR], Asterism::ROS::TYPE_PATH
    t = Asterism::ROS.require_type("geometry_msgs/msg/Twist")
    assert_equal "geometry_msgs::msg::dds_::Twist_", t::TYPE_NAME
    assert_match(/\ARIHS01_\h{64}\z/, t::TYPE_HASH)
  end

  def test_topic_and_service
    @na = Asterism::ROS::Node.new(@a, "c1_a")
    @nb = Asterism::ROS::Node.new(@b, "c1_b")
    twist = Asterism::ROS.require_type("geometry_msgs/msg/Twist")
    add = Asterism::ROS.require_type("example_interfaces/srv/AddTwoInts")
    sub = @na.subscription("/c1/cmd_vel", twist)
    @na.service("/c1/add", add) { |req| { sum: req.a + req.b } }
    pub = @nb.publisher("/c1/cmd_vel", "geometry_msgs/msg/Twist")
    cli = @nb.client("/c1/add", add)
    sleep 0.3

    pub << { linear: { x: 0.5, y: -0.25 }, angular: { z: 1.25 } }
    got = nil
    assert wait_for { @na.poll; (got = sub.each_pending).any? }
    msg, info = got[0]
    assert_in_delta 0.5, msg.linear.x
    assert_in_delta(-0.25, msg.linear.y)
    assert_in_delta 1.25, msg.angular.z
    assert_equal 1, info.sequence
    assert_equal 16, info.gid.bytesize

    # The service answers from @na.poll; the client waits polling @nb, so a
    # thread keeps polling @na meanwhile (both nodes are in this process).
    stop = false
    th = Thread.new { until stop; @na.poll; sleep 0.002; end }
    begin
      assert_equal 5, cli.call(a: 2, b: 3).sum
      assert_equal 3_999_999_993, cli.call(a: -7, b: 4_000_000_000).sum
      c = cli.call_async(a: 1, b: 1)
      assert wait_for { @nb.poll; c.done? }
      assert_equal 2, c.value.sum
      assert_equal 7, @nb.call("/c1/add", add, a: 3, b: 4).sum
      # The request as request: (or a Hash), the time limit in seconds.
      assert_equal 9, cli.call(request: { a: 4, b: 5 }, timeout: 1.0).sum
      assert_equal 9, cli.call({ a: 4, b: 5 }, timeout_ms: 1000).sum
      assert_equal 9, @nb.call("/c1/add", add, request: add::Request.new(a: 4, b: 5), timeout: 1.0).sum
      assert_raises(ArgumentError) { cli.call({ a: 1, b: 1 }, request: { a: 1, b: 1 }) }
      assert_raises(ArgumentError) { cli.call(a: 1, b: 1, timeout: 1, timeout_ms: 1000) }
      c = cli.call_async(a: 1, b: 2)
      c.value
      assert_in_delta c.took_ms / 1000.0, c.took
    ensure
      stop = true
      th.join
    end
    e = assert_raises(Asterism::ROS::TimeoutError) { @nb.call("/c1/nobody", add, a: 1, b: 1) }
    assert_match(/nobody serves it/, e.message)
    assert_kind_of Asterism::TimeoutError, e
    assert_kind_of Asterism::Error, e
    warned = with_deprecations do
      assert_raises(Asterism::ROS::Timeout) { @nb.call("/c1/nobody", add, request: { a: 1, b: 1 }, timeout: 0.5) }
    end
    assert_equal 1, warned.size
    assert_match(/Asterism::ROS::Timeout is deprecated/, warned[0])
  end

  # node.subscribe with a block and node.every, polled as on the boards:
  # they run from node.poll, never from the polling of a waiting call.
  def test_subscribe_block_and_every_from_poll
    @na = Asterism::ROS::Node.new(@a, "c6_a")
    @nb = Asterism::ROS::Node.new(@b, "c6_b")
    add = "example_interfaces/srv/AddTwoInts"
    got = []
    ticks = 0
    sub = @na.subscribe("/c6/chatter", "std_msgs/msg/String") { |msg, info| got << [msg.data, info.sequence] }
    timer = @na.every(0.05) { ticks += 1 }
    assert_equal 0.05, timer.period
    assert_equal 50, timer.period_ms
    t2 = @na.every(ms: 500) { nil }
    assert_equal 0.5, t2.period
    assert_equal 500, t2.period_ms
    t2.cancel
    assert_raises(ArgumentError) { @na.every(1, ms: 1000) { nil } }
    assert_raises(ArgumentError) { @na.every { nil } }
    @nb.service("/c6/add", add) { |req| { sum: req.a + req.b } }
    pub = @nb.publisher("/c6/chatter", "std_msgs/msg/String")
    sleep 0.3
    pub << { data: "one" }
    pub << { data: "two" }
    assert wait_for { @na.poll; got.size == 2 }
    assert_equal [["one", 1], ["two", 2]], got

    # While @na waits for a service call, what comes in waits for node.poll.
    stop = false
    th = Thread.new { until stop; @nb.poll; sleep 0.002; end }
    begin
      pub << { data: "three" }
      sleep 0.1
      before = ticks
      assert_equal 3, @na.call("/c6/add", add, a: 1, b: 2).sum
      sleep 0.12
      assert_equal 7, @na.call("/c6/add", add, a: 3, b: 4).sum
      assert_equal 2, got.size, "no subscribe block inside a waiting call"
      assert_equal before, ticks, "no timer inside a waiting call"
    ensure
      stop = true
      th.join
    end
    @na.poll
    assert_equal ["three", 3], got[2]
    assert_operator ticks, :>, before

    timer.cancel
    n = ticks
    sleep 0.12
    @na.poll
    assert_equal n, ticks, "no more after cancel"
    sub.close
    pub << { data: "four" }
    sleep 0.1
    @na.poll
    assert_equal 3, got.size, "no more after close"
    # Without a block, subscribe is subscription (as on CRuby's block API).
    plain = @na.subscribe("/c6/chatter", "std_msgs/msg/String")
    assert_kind_of Asterism::ROS::Subscription, plain
    sleep 0.3
    pub << { data: "five" }
    assert wait_for { @na.poll; plain.pending == 1 }
    assert_equal 1, plain.received
    assert_equal "five", plain.each_pending[0][0].data
    plain.close
    assert_raises(ArgumentError) { @na.every(0) { nil } }
  end

  # deconstruct_keys is in the shared layer (the boards' VM runs case/in).
  def test_pattern_matching_on_messages
    twist = Asterism::ROS.require_type("geometry_msgs/msg/Twist")
    msg = twist.from(linear: { x: 0.5 }, angular: { z: -1.0 })
    case msg
    in { linear: { x: }, angular: { z: } }
      assert_in_delta 0.5, x
      assert_in_delta(-1.0, z)
    end
    assert_equal({ linear: msg.linear }, msg.deconstruct_keys([:linear]))
    att = Asterism::ROS::Attachment.new(7, 9, "g" * 16)
    case att
    in { sequence: 7, stamp_ns: }
      assert_equal 9, stamp_ns
    end
  end
end
