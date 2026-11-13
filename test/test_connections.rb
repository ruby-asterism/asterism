# Several connections in one program (docs/protocol.md 1.1): each is an
# application of its own. Two applications of the same node ("host/game"
# and "host/spectate") and a third node ("viewer/v"), all in this process,
# clients of one router (an in-process zenoh router, or the test router):
# they see each other as applications, call each other (also nested), keep
# their own status, topics and types, answer the node's one profile, are
# refused when the same <node>/<app> is there already (in this program or
# on the network), and one goes while the others stay.
require_relative "helper"
require "asterism"

class TestConnections < Minitest::Test
  include TestHelper

  class Echo
    def initialize(net) = @net = net
    def echo(v) = v
    def who = [@net.current_call.from, @net.current_call.object]
    # Calls another connection of this program while answering.
    def via(path, v) = @net[path].echo(v)
  end

  def setup
    if (r = TestHelper.router)
      @loc = r
    else
      @loc = "tcp/127.0.0.1:#{TestHelper.free_port}"
      @router = Z::Session.open(nil, config: { "mode" => "router", "listen/endpoints" => [@loc],
                                               "scouting/multicast/enabled" => false })
    end
    %i[@profile_defaults @node_profiles @profile_icons].each { Asterism.instance_variable_set(_1, nil) }
  end

  def teardown
    Asterism.connections.each(&:close)
    @raw&.close
    @router&.close
    %i[@profile_defaults @node_profiles @profile_icons].each { Asterism.instance_variable_set(_1, nil) }
  end

  def connect(node, app) = Asterism.connect(@loc, node: node, app: app, check_timeout: 0.5)

  def poll_until(limit = 5)
    wait_for(limit) { Asterism.poll_all; yield }
  end

  def test_two_applications_of_one_node_in_one_program
    game = connect("host", "game")
    spec = connect("host", "spectate")
    viewer = connect("viewer", "v")
    assert_equal [game, spec, viewer], Asterism.connections
    assert_equal "host/spectate", spec.path
    joined = []
    game.on_app_join { |n, a| joined << "#{n}/#{a}" }
    assert poll_until { game.apps.size == 3 && spec.apps.size == 3 && viewer.apps.size == 3 }
    assert_equal ["host/game", "host/spectate", "viewer/v"], game.apps.sort
    assert_equal ["host/spectate", "viewer/v"], joined.sort, "the other connection is another application"
    assert_equal %w[host viewer], game.nodes.sort

    # Calls between them, through the network (each answers on its own).
    game.expose("e", Echo.new(game), methods: { echo: 1, who: 0, via: 2 })
    spec.expose("e", Echo.new(spec), methods: { echo: 1, who: 0, via: 2 })
    assert poll_until { spec.each("host/game/e").size == 1 && game.each("host/spectate/e").size == 1 }
    assert_equal 42, spec["host/game/e"].echo(42)
    assert_equal 43, game["host/spectate/e"].echo(43)
    assert_equal %w[host e], game["host/spectate/e"].who, "the caller is the node"
    # Nested: viewer -> game, which calls spectate while answering.
    assert_equal "deep", viewer["host/game/e"].via("host/spectate/e", "deep")
    # A wait on one connection answers the calls of the others.
    assert_equal "back", game["host/spectate/e"].via("host/game/e", "back")
    assert_nil game.current_call
    assert_equal ["e"], game.exposed
    assert_equal ["e"], spec.exposed

    # Each its own status, topics and types.
    game.status(tables: 2)
    spec.status(watching: 1)
    spec.define_type("g/state", [["b", "int[]"]])
    st = spec.publish("t1/state", type: "g/state")
    gt = game.publish("t1/moves")
    assert_equal ["t1/state"], spec.published
    assert_equal ["t1/moves"], game.published
    assert poll_until { viewer.status_of("host", "spectate") == { "watching" => 1 } }
    assert_equal({ "tables" => 2 }, viewer.status_of("host", "game"))
    assert_equal({ "t1/state" => { "t" => "g/state" } }, viewer.pubs_of("host", "spectate"))
    assert_equal({ "t1/moves" => {} }, viewer.pubs_of("host", "game"))
    assert_equal({}, viewer.types_of("host", "game"))
    assert_equal({ "g/state" => { "f" => [["b", "int[]"]] } }, viewer.types_of("host", "spectate"))
    assert_equal({ "watching" => 1 }, game.status_of("host", "spectate"), "one connection asks the other")

    # Values from one connection reach a subscription of the other (it is
    # another application; a connection's own values do not come back).
    got = []
    mine = []
    game.subscribe("host/spectate/**") { |v, info| got << [v, info.name] }
    spec.subscribe("host/spectate/**") { |v, _| mine << v }
    sleep 0.3
    assert poll_until { st.put({ "b" => [1] }); got.any? }
    assert_equal [{ "b" => [1] }, "t1/state"], got[0]
    assert_empty mine
    gt.put(1)

    # The node's one profile: a change on either is both's.
    assert_equal "Host", game.profile(name: "Host")["name"]
    assert_equal game.profile, spec.profile
    assert poll_until { (viewer.profile_of("host", icon: false) || {})["name"] == "Host" }
    assert_equal "Board", spec.profile(name: "Board")["name"]
    assert_equal "Board", game.profile["name"]

    # The same <node>/<app> again: refused in this program, and on the
    # network (another program's token).
    e = assert_raises(Asterism::Error) { connect("host", "game") }
    assert_match(/already connected in this program/, e.message)
    @raw = Z::Session.open(@loc)
    tok = @raw.liveliness("asterism/host/taken")
    sleep 0.3
    e = assert_raises(Asterism::Error) { connect("host", "taken") }
    assert_match(/already on the network/, e.message)
    tok.close
    assert_equal 3, Asterism.connections.size

    # One goes, the others stay.
    left = []
    game.on_app_leave { |n, a| left << "#{n}/#{a}" }
    game.close
    refute game.connected?
    assert spec.connected?
    assert_equal [spec, viewer], Asterism.connections
    assert poll_until { viewer.apps.size == 2 }
    assert_empty left, "a closed connection tells nothing more"
    assert_equal 43, viewer["host/spectate/e"].echo(43)
    assert_equal "Board", viewer.profile_of("host", icon: false)["name"], "the node still answers its profile"
    assert_raises(Asterism::Disconnected) { game["host/spectate/e"].echo(1) }
    assert_raises(Asterism::Disconnected) { gt.put(2) }
    # The same name may come back as a new connection.
    again = connect("host", "game")
    assert_equal "Board", again.profile["name"], "the node's profile outlived its connections"
    assert_nil again.status, "the status was the old connection's"
    assert poll_until { viewer.apps.size == 3 }
    spec.close
    viewer.close
    again.close
    assert_empty Asterism.connections
    refute Asterism.poll_all
  end

  # The CRuby block API: each connection its own receiving thread, under the
  # one lock; calls between them while both run.
  # The look for another copy on the network (up to check_timeout:) runs
  # without Asterism::LOCK: the program's other connections go on meanwhile.
  module SeeLock
    def already_there?(*args)
      TestConnections.lock_seen << ::Asterism::LOCK.mon_owned?
      t = Thread.new { ::Asterism::LOCK.synchronize { :taken } }
      TestConnections.lock_seen << t.join(1)&.value
      super
    end
  end

  def self.lock_seen = (@lock_seen ||= [])

  def test_connect_looks_for_copies_without_the_lock
    Asterism::Connection.prepend(SeeLock) unless Asterism::Connection.ancestors.include?(SeeLock)
    TestConnections.lock_seen.clear
    game = connect("host", "game")
    assert_equal [false, :taken], TestConnections.lock_seen, "not held; another thread takes it meanwhile"
    assert game.connected?
    e = assert_raises(Asterism::Error) { connect("host", "game") }
    assert_match(/already connected in this program/, e.message)
  ensure
    TestConnections.lock_seen.clear
  end

  def test_receiving_threads_of_two_connections
    Asterism.connect(@loc, node: "host", app: "game", check_timeout: 0.5) do |game|
      Asterism.connect(@loc, node: "host", app: "spectate", check_timeout: 0.5) do |spec|
        game.expose("e", Echo.new(game), methods: { echo: 1, via: 2 })
        spec.expose("e", Echo.new(spec), methods: { echo: 1, via: 2 })
        game.start
        spec.start
        assert wait_for(5) { game.each("host/spectate/e").size == 1 && spec.each("host/game/e").size == 1 }
        assert_equal 7, game["host/spectate/e"].echo(7)
        assert_equal "x", spec["host/game/e"].via("host/spectate/e", "x")
        refute_same game.runner, spec.runner
        assert game.running? && spec.running?
      end
      assert game.running?, "the other connection's thread goes on"
      assert_equal [game], Asterism.connections
    end
    assert_empty Asterism.connections
  end
end
