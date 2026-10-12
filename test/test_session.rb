# Asterism.session (0.6.0): the object layer's Zenoh session used for put,
# subscribe and a ROS 2 node, with its ownership rules; and the on_join /
# on_leave / nodes behaviour that the lighter Asterism.poll must keep. The
# other nodes are a second Zenoh session of this process that declares the
# tokens and answers (the portable API, as on the boards).
require_relative "helper"
require "asterism"

class TestAsterismSession < Minitest::Test
  include TestHelper

  # [Asterism's locator, the other session]: Asterism connects to a
  # listening peer (so that closing the other loses the connection), or
  # both are clients of the test router.
  def connect_pair(node: "me", app: "t")
    if (r = TestHelper.router)
      other = Z::Session.open(r)
      Asterism.connect(r, node: node, app: app)
    else
      loc = "tcp/127.0.0.1:#{TestHelper.free_port}"
      other = Z::Session.open(nil, mode: :peer, listen: loc)
      Asterism.connect(loc, node: node, app: app, mode: :peer)
    end
    other
  end

  def teardown
    Asterism.close
    @other&.close
  end

  class Echo
    def echo(v) = v
  end

  def test_one_session_for_objects_put_subscribe_and_ros
    @other = connect_pair
    s = Asterism.session
    assert_kind_of Z::Session, s
    assert_same s, Asterism.session

    # put from Asterism's session, subscribe on it.
    seen = @other.subscribe("g1b/**")
    mine = s.subscribe("back/**")
    sleep 0.2
    s.put("g1b/state", "hello")
    assert wait_for { seen.pending > 0 }
    key, payload = seen.each_pending[0]
    assert_equal ["g1b/state", "hello"], [key, payload]
    @other.put("back/x", "there")
    assert wait_for { Asterism.poll; mine.pending > 0 }
    assert_equal "there", mine.each_pending[0][1]

    # A ROS 2 node on the same session: the same Zenoh ID as the objects.
    node = Asterism::ROS::Node.new(s, "brain")
    assert_equal s.zid, node.zid
    peer_node = Asterism::ROS::Node.new(@other, "rover")
    got = []
    node.subscribe("/g1b/odom", "std_msgs/msg/String") { |msg, _| got << msg.data }
    pub = peer_node.publisher("/g1b/odom", "std_msgs/msg/String")
    cmd = peer_node.subscription("/g1b/cmd", "std_msgs/msg/String")
    out = node.publisher("/g1b/cmd", "std_msgs/msg/String")
    sleep 0.3
    pub << { data: "p1" }
    out << { data: "go" }
    assert wait_for { node.poll; Asterism.poll; got == ["p1"] }
    assert wait_for { cmd.pending > 0 }
    assert_equal "go", cmd.each_pending[0][0].data
    tokens = @other.liveliness_get("@ros2_lv/**", timeout: 1.0)
    keys = []
    wait_for { @other.poll; done = tokens.done?; keys.concat(tokens.each_reply); done }
    keys = keys.map { |k| k.is_a?(Array) ? k[0] : k }
    assert(keys.any? { |k| k.include?("/#{s.zid}/") && k.end_with?("/brain") }, "the node's token has Asterism's zid")

    # Calls are still answered by Asterism.poll on the shared session.
    Asterism.expose("echo", Echo.new, methods: [:echo])
    g = @other.get("asterism/me/t/echo/call", timeout: 2.0, payload: MessagePack.pack(["echo", [5], {}]))
    replies = []
    wait_for { Asterism.poll; node.poll; d = g.done?; replies.concat(g.each_reply); d }
    assert_equal ["ok", 5], MessagePack.unpack(replies[0][1])

    # The application's close does not close it (warns once).
    _, err = capture_io { assert_nil s.close; s.close }
    assert_equal 1, err.scan("belongs to Asterism").size
    refute s.closed?
    assert Asterism.poll
    assert Asterism.connected?

    # Asterism.close closes it, with the ROS node and the subscribers on it.
    Asterism.close
    assert s.closed?
    assert_raises(Asterism::Disconnected) { Asterism.session }
    assert_raises(Asterism::Zenoh::Error) { s.put("g1b/state", "late") }

    # A new connection, a new session.
    @other.close
    @other = connect_pair
    refute_same s, Asterism.session
    refute Asterism.session.closed?
  end

  def test_lost_connection_closes_the_session
    skip "a router keeps the client's session" if TestHelper.router
    @other = connect_pair
    s = Asterism.session
    @other.close
    @other = nil
    assert wait_for(5) { !Asterism.poll }
    assert s.closed?
    e = assert_raises(Asterism::Disconnected) { Asterism.session }
    assert_equal Asterism.lost_reason, e.message
  end

  # The order and number of on_join / on_leave calls and the list of
  # nodes, through joins and leaves of node tokens and objects. The same
  # sequence was checked against 0.5.0's Asterism.poll (which made the list
  # again on every poll).
  def test_join_and_leave_as_before
    @other = connect_pair
    events = []
    Asterism.on_join { |n| events << [:join, n] }
    Asterism.on_leave { |n| events << [:leave, n] }
    poll_some = lambda do |n = 30|
      n.times do
        Asterism.poll
        sleep 0.003
      end
    end
    poll_some.call

    t1 = @other.liveliness("asterism/n1")
    assert wait_for { Asterism.poll; events.size == 1 }
    assert_equal [[:join, "n1"]], events
    assert_equal %w[me n1], Asterism.nodes

    # A node seen only by its object; then a second object of n1 (no join).
    o2 = @other.liveliness("asterism/n2/app/o")
    o1 = @other.liveliness("asterism/n1/app/o2")
    assert wait_for { Asterism.poll; Asterism.each("*/app/*").size == 2 }
    poll_some.call
    assert_equal [[:join, "n1"], [:join, "n2"]], events
    assert_equal %w[me n1 n2], Asterism.nodes

    # Nothing changes: nothing is told, the list stays.
    list = Asterism.nodes
    poll_some.call(100)
    assert_equal 2, events.size
    assert_equal list, Asterism.nodes
    Asterism.nodes << "scribble"
    assert_equal list, Asterism.nodes, "nodes returns a copy"

    # n1's token goes but its object stays: n1 stays. Then the object goes.
    t1.close
    poll_some.call
    assert_equal 2, events.size
    assert_equal %w[me n2 n1], Asterism.nodes # tokens first, then the objects' nodes
    o1.close
    assert wait_for { Asterism.poll; events.size == 3 }
    assert_equal [:leave, "n1"], events[2]
    assert_equal %w[me n2], Asterism.nodes

    # A token and an object of one node in one burst: one join.
    t3 = @other.liveliness("asterism/n3")
    o3 = @other.liveliness("asterism/n3/app/x")
    assert wait_for { Asterism.poll; events.size == 4 }
    poll_some.call
    assert_equal [[:join, "n3"]], events[3..]
    assert_equal %w[me n3 n2], Asterism.nodes

    # A block added later is told only of what comes after.
    late = []
    Asterism.on_join { |n| late << n }
    t4 = @other.liveliness("asterism/n4")
    assert wait_for { Asterism.poll; late == ["n4"] }
    t4.close
    assert wait_for { Asterism.poll; events.last == [:leave, "n4"] }

    if TestHelper.router
      [t3, o3, o2].each(&:close)
      assert wait_for { Asterism.poll; events.count { |e| e[0] == :leave } == 4 }
      assert_equal [[:leave, "n3"], [:leave, "n2"]].sort, events.last(2).sort
    else
      # The connection is lost: every node known leaves, once, in order.
      @other.close
      @other = nil
      assert wait_for(5) { !Asterism.poll }
      poll_some.call
      assert_equal [[:leave, "n3"], [:leave, "n2"]], events.last(2)
      assert_equal 8, events.size
    end
    assert_equal [], Asterism.nodes if Asterism.lost_reason
  end
end
