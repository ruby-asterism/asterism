# The Ruby-like ROS 2 API (lib/asterism/cruby/ros.rb) between two
# connections of this process: subscription blocks, timers, services
# answered while spinning, service calls waiting on another thread,
# Enumerators, pattern matching, errors, and the thread being gone after.
require_relative "helper"
require "asterism"

class TestApiROS < Minitest::Test
  include TestHelper

  def setup
    a, b = open_pair
    @ra = Asterism::ROS::Connection.new(Asterism::Zenoh::Connection.new(a))
    @rb = Asterism::ROS::Connection.new(Asterism::Zenoh::Connection.new(b))
  end

  def teardown
    @rb&.close
    @ra&.close
  end

  def settle = sleep(0.3)

  def test_publish_subscribe_timer_and_pattern_matching
    na = @ra.node("c5_listener")
    nb = @rb.node("c5_talker")
    got = Queue.new
    na.subscribe("/c5/cmd_vel", "geometry_msgs/msg/Twist") { |msg, info| got << [msg, info, Thread.current] }
    pub = nb.publisher("/c5/cmd_vel", "geometry_msgs/msg/Twist")
    @ra.start
    settle
    pub << { linear: { x: 0.5 }, angular: { z: 1.25 } }
    msg, info, th = got.pop(timeout: 3)
    refute_equal Thread.current, th
    case msg
    in { linear: { x: Float => x }, angular: { z: } }
      assert_in_delta 0.5, x
      assert_in_delta 1.25, z
    end
    case info
    in { sequence: 1, gid: String => gid }
      assert_equal 16, gid.bytesize
    end

    # A timer on b's receiving thread publishes; a's block receives.
    n = 0
    timer = nb.every(0.05) { pub << { linear: { x: n += 1 } } }
    @rb.start
    xs = 3.times.map { got.pop(timeout: 3)[0].linear.x }
    timer.cancel
    assert_equal [1.0, 2.0, 3.0], xs
    assert_operator timer.fired, :>=, 3
    sleep 0.15
    got.clear
    sleep 0.15
    assert_equal 0, got.size, "no more after cancel"
  end

  def test_services_while_spinning
    na = @ra.node("c5_server")
    nb = @rb.node("c5_client")
    na.service("/c5/add", "example_interfaces/srv/AddTwoInts") { |req| { sum: req.a + req.b } }
    @ra.start
    @rb.start
    settle
    # b spins on its thread; this thread's call waits for b's ticks.
    assert_equal 3, nb.call("/c5/add", "example_interfaces/srv/AddTwoInts", a: 1, b: 2).sum
    # Calls from several threads at once.
    sums = 4.times.map { |i| Thread.new { nb.call("/c5/add", "example_interfaces/srv/AddTwoInts", a: i, b: 10).sum } }
    assert_equal [10, 11, 12, 13], sums.map(&:value)
    # A service block that calls another service (on the receiving thread).
    na.service("/c5/twice", "example_interfaces/srv/AddTwoInts") do |req|
      { sum: 2 * na.call("/c5/back", "example_interfaces/srv/AddTwoInts", a: req.a, b: req.b).sum }
    end
    nb.service("/c5/back", "example_interfaces/srv/AddTwoInts") { |req| { sum: req.a + req.b } }
    settle
    assert_equal 14, nb.call("/c5/twice", "example_interfaces/srv/AddTwoInts", a: 3, b: 4, timeout: 3).sum
    e = assert_raises(Asterism::ROS::TimeoutError) { nb.call("/c5/nobody", "example_interfaces/srv/AddTwoInts", a: 1, b: 1) }
    assert_match(/nobody serves it/, e.message)
  end

  def test_service_errors_go_to_on_error
    errors = Queue.new
    @ra.on_error { |e, where| errors << [e.message, where] }
    na = @ra.node("c5_bad")
    nb = @rb.node("c5_caller")
    na.service("/c5/div", "example_interfaces/srv/AddTwoInts") { |req| { sum: req.a / req.b } }
    @ra.start
    @rb.start
    settle
    assert_raises(Asterism::ROS::TimeoutError) { nb.call("/c5/div", "example_interfaces/srv/AddTwoInts", a: 1, b: 0, timeout: 0.5) }
    assert_equal ["divided by 0", "service /c5/div"], errors.pop(timeout: 1)
    assert @ra.running?
    assert_equal 3, nb.call("/c5/div", "example_interfaces/srv/AddTwoInts", a: 6, b: 2).sum
  end

  def test_enumerators
    na = @ra.node("c5_reader")
    nb = @rb.node("c5_writer")
    str = "std_msgs/msg/String"
    pub = nb.publisher("/c5/chatter", str)
    sub = na.subscribe("/c5/chatter", str)
    settle
    feeder = Thread.new { 5.times { |i| pub << { data: "m#{i}" }; sleep 0.03 } }
    assert_equal %w[m0 m1 m2], sub.each.lazy.map { |m, _info| m.data }.first(3)
    feeder.join
    assert_equal %w[m3 m4], sub.each(timeout: 0.3).map { |m, _| m.data }
    sub.close

    # topic: subscribes only while iterated.
    topic = na.topic("/c5/chatter", str)
    feeder = Thread.new do
      sleep 0.4
      3.times { |i| pub << { data: "t#{i}" }; sleep 0.03 }
    end
    assert_equal ["t0"], topic.each.lazy.map { |m, _| m.data }.first(1)
    feeder.join
    assert_equal [], topic.each(timeout: 0.2).to_a, "nothing kept between iterations"
  end

  def test_run_and_block_form
    loc = TestHelper.router || "tcp/127.0.0.1:#{TestHelper.free_port}"
    opts = TestHelper.router ? {} : { mode: :peer, listen: loc }
    before = Thread.list.size
    conn = nil
    seen = []
    Asterism::ROS.connect(TestHelper.router ? loc : nil, domain: 3, **opts) do |ros|
      conn = ros
      node = ros.node("c5_spin")
      assert_equal 3, node.domain
      node.every(0.02) { seen << :tick; ros.stop if seen.size == 3 }
      t = Thread.new { ros.spin }
      assert t.join(3)
    end
    assert_equal 3, seen.size
    assert conn.zenoh.closed?
    assert_equal before, Thread.list.size
  end

  def test_type_path_option
    dir = File.expand_path("msgs/out_c5", __dir__)
    Asterism::ROS.connect(nil, type_path: dir, mode: :peer, listen: "tcp/127.0.0.1:#{TestHelper.free_port}") { |_| }
    assert_includes Asterism::ROS::TYPE_PATH, dir
  ensure
    Asterism::ROS::TYPE_PATH.delete(dir)
  end
end
