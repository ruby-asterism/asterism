# net.session (0.6.0, lib/asterism/cruby/objects.rb): Asterism's session as
# a Zenoh::Connection on the object layer's receiving thread, a ROS 2 node
# on it (ROS::Connection.new(net.session)), and what close does to each.
# The other side is a second session of this process.
require_relative "helper"
require "asterism"

class TestApiSession < Minitest::Test
  include TestHelper

  class Echo
    def echo(v) = v
  end

  def setup
    if (r = TestHelper.router)
      @other = Z::Session.open(r)
      @loc = [r, {}]
    else
      loc = "tcp/127.0.0.1:#{TestHelper.free_port}"
      @other = Z::Session.open(nil, mode: :peer, listen: loc)
      @loc = [loc, { mode: :peer }]
    end
  end

  def teardown
    Asterism.close
    @other&.close
  end

  def test_net_session_shares_the_receiving_thread
    got = Queue.new
    odom = Queue.new
    session = nil
    Asterism.connect(@loc[0], node: "me", app: "t", **@loc[1]) do |net|
      conn = net.session
      session = conn.session
      assert_instance_of Asterism::Zenoh::Connection, conn
      assert conn.shared?
      assert_same conn, net.session
      assert_same Asterism.session, conn.session
      assert_same net.runner, conn.runner
      net.expose("echo", Echo.new, methods: [:echo])

      # A subscription block runs on the object layer's receiving thread.
      conn.subscribe("g1b/**") { |s| got << [s.payload, Thread.current.name] }
      # A ROS 2 node on the same session (the same Zenoh ID).
      ros = Asterism::ROS::Connection.new(conn)
      node = ros.node("brain")
      assert_equal conn.zid, node.zid
      node.subscribe("/g1b/odom", "std_msgs/msg/String") { |m| odom << m.data }
      peer = Asterism::ROS::Node.new(@other, "rover")
      pub = peer.publisher("/g1b/odom", "std_msgs/msg/String")
      net.start
      sleep 0.3
      @other.put("g1b/x", "hi")
      pub << { data: "o1" }
      assert_equal ["hi", "asterism receiver"], got.pop(timeout: 3)
      assert_equal "o1", odom.pop(timeout: 3)

      # Calls are answered meanwhile.
      g = @other.get("asterism/me/t/echo/call", timeout: 2.0, payload: MessagePack.pack(["echo", [7], {}]))
      replies = []
      wait_for { d = g.done?; replies.concat(g.each_reply); d }
      assert_equal ["ok", 7], MessagePack.unpack(replies[0][1])

      # Closing the ROS connection withdraws its nodes, nothing else.
      ros.close
      assert node.closed?
      assert net.running?
      refute session.closed?
      # net.session's close does nothing (warns once).
      _, err = capture_io { assert_nil conn.close; conn.close }
      assert_equal 1, err.scan("belongs to Asterism").size
      refute conn.closed?
      assert net.running?
      @other.put("g1b/y", "still")
      assert_equal "still", got.pop(timeout: 3)[0]
    end
    # The end of the block closes the session.
    assert session.closed?
    assert_raises(Asterism::Disconnected) { Asterism.session }
  end
end
