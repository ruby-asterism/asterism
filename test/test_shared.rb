# The shared places (docs/protocol.md 17): the declaration entries and
# the reading of senders (no network), and between connections of this
# process through one router: a node's place and the network's, several
# senders on one key (the numbers counted per sender, info.from), the
# declarations in each sender's @pubs, publishers_of, and each value's type
# read from its own sender (two senders giving one type name different
# definitions).
require_relative "helper"
require "asterism"

class TestShared < Minitest::Test
  include TestHelper

  FakeSample = Struct.new(:key, :payload, :attachment, :kind, :encoding, :timestamp)

  # ------------------------------------------------------------ no network

  def test_entries
    pl = ->(e) { Asterism::Pubs.place(e) }
    assert_equal [nil, nil, "imu"], pl.("imu")
    assert_equal [nil, nil, "board1/strokes"], pl.("board1/strokes")
    assert_equal [:global, nil, "lobby"], pl.("@shared/lobby")
    assert_equal [:global, nil, "a/b"], pl.("@shared/a/b")
    assert_equal [:node, "host", "spectate/t1/state"], pl.("host/@shared/spectate/t1/state")
    ["@shared", "@shared/", "host/@shared", "@other/x", "a/@pubs/b", "a//b", "/a", "a/", "a/*", "", "*/@shared/x",
     "a/b/@shared/c", "@shared/@shared/x", 5, nil].each do |bad|
      assert_nil pl.(bad), bad.inspect
    end
    assert_equal "imu", Asterism::Pubs.entry(nil, "n", "imu")
    assert_equal "n/@shared/x/y", Asterism::Pubs.entry(:node, "n", "x/y")
    assert_equal "@shared/x", Asterism::Pubs.entry(:global, "n", "x")
    assert_equal "n/a/imu", Asterism::Pubs.path("n", "a", "imu")
    assert_equal "n/@shared/x", Asterism::Pubs.path("n", "a", "n/@shared/x")
    assert_equal "@shared/x", Asterism::Pubs.path("n", "a", "@shared/x")
    assert_nil Asterism::Pubs.path("n", "a", "@x")

    d = { "t" => 1 }
    h = { "imu" => d, "@shared/g" => d, "n/@shared/s" => d, "m/@shared/s" => d, "@x/y" => d, "a/*" => d }
    assert_equal %w[imu @shared/g n/@shared/s m/@shared/s], Asterism::Pubs.check(h).keys
    assert_equal %w[imu @shared/g n/@shared/s], Asterism::Pubs.check(h, "n").keys, "another node's place is left out"
    put = MessagePack.pack({ "imu" => d, "m/@shared/s" => d, "n/@shared/s" => d })
    assert_equal ["n", "a", { "imu" => d, "n/@shared/s" => d }], Asterism::Pubs.parse("asterism/n/a/@pubs", put)

    assert_nil Asterism.shared_place!(nil)
    assert_equal :node, Asterism.shared_place!(:node)
    assert_equal :global, Asterism.shared_place!("global")
    assert_raises(ArgumentError) { Asterism.shared_place!(:app) }
  end

  def test_reading_senders
    sub = Asterism::Subscription.new(nil, "**", nil, nil)
    att = ->(*a) { MessagePack.pack(a) }
    s = ->(key, a) do
      _, info = sub.unwrap(FakeSample.new(key, MessagePack.pack(1), a, :put, "zenoh/bytes", nil))
      info
    end
    k = "asterism/host/@shared/spectate/t1"
    i = s.(k, att.(0, nil, "host/a"))
    assert_equal [:node, "host/@shared/spectate/t1", "spectate/t1", "host/a", "host", "a", 0, nil, 0],
                 [i.shared, i.path, i.name, i.from, i.node, i.app, i.seq, i.time, i.lost]
    i = s.(k, att.(5, nil, "host/b"))
    assert_equal ["host/b", 5, 0, false], [i.from, i.seq, i.lost, i.restarted?], "another sender: its first value"
    i = s.(k, att.(3, 1_700_000_000_000, "host/a"))
    assert_equal ["host/a", 3, 2, 1_700_000_000_000], [i.from, i.seq, i.lost, i.time], "per sender: 1 and 2 missed"
    i = s.(k, att.(6, nil, "host/b"))
    assert_equal ["host/b", 0, false], [i.from, i.lost, i.restarted?]
    i = s.(k, att.(1, nil, "host/a"))
    assert_equal [true, 1], [i.restarted?, i.lost], "a's numbers went back"

    g = s.("asterism/@shared/lobby", att.(7, nil, "pc/chat"))
    assert_equal [:global, "@shared/lobby", "lobby", "pc/chat", "pc", "chat", 7],
                 [g.shared, g.path, g.name, g.from, g.node, g.app, g.seq]
    n = s.(k, att.(9))
    assert_equal [nil, "host", nil, 9, 0], [n.from, n.node, n.app, n.seq, n.lost], "no sender: the key's node"
    n = s.(k, att.(4, nil, "not a sender"))
    assert_equal [nil, true], [n.from, n.restarted?], "a sender that is not node/app: none (the key's own lane)"
    n = s.("asterism/@shared/lobby", att.(8, nil, 3))
    assert_equal [nil, nil, nil], [n.from, n.node, n.app]
    own = s.("asterism/n/a/x", att.(0, nil, "o/p"))
    assert_equal [nil, "n/a", "n", "a"], [own.shared, own.from, own.node, own.app],
                 "an application's own key: the sender is the key's, the third element is not read"
  end

  # ------------------------------------------------------------ network

  def setup
    return unless name.start_with?("test_shared_places")
    if (r = TestHelper.router)
      @loc = r
    else
      @loc = "tcp/127.0.0.1:#{TestHelper.free_port}"
      @router = Z::Session.open(nil, config: { "mode" => "router", "listen/endpoints" => [@loc],
                                               "scouting/multicast/enabled" => false })
    end
  end

  def teardown
    Asterism.connections.each(&:close)
    @router&.close
  end

  def connect(node, app) = Asterism.connect(@loc, node: node, app: app, check_timeout: 0.5)

  def poll_until(limit = 5)
    wait_for(limit) { Asterism.poll_all; yield }
  end

  def test_shared_places_between_connections
    games = connect("host", "games")
    room = connect("host", "room01")
    pc = connect("pc", "chat")
    viewer = connect("viewer", "v")
    assert poll_until { viewer.apps.size == 4 }

    # Two senders of one node's place, each with its own type of one name.
    games.define_type("g/table", [["seats", "int"]], desc: "the host's")
    room.define_type("g/table", [["seats", "str[]"], ["turn", "int"]], desc: "the room's")
    a = games.publish("spectate/t1/state", shared: :node, type: "g/table")
    b = room.publish("spectate/t1/state", shared: :node, type: "g/table", ts: true)
    own = room.publish("score", type: :number)
    lobby = pc.publish("lobby", shared: :global, type: :text, desc: "who is here")
    assert_equal ["host/@shared/spectate/t1/state", "asterism/host/@shared/spectate/t1/state", :node,
                  "spectate/t1/state"], [a.entry, a.key, a.shared, a.name]
    assert_equal ["@shared/lobby", "asterism/@shared/lobby", :global], [lobby.entry, lobby.key, lobby.shared]
    assert_equal ["host/@shared/spectate/t1/state", "score"], room.published
    assert_equal({ "host/@shared/spectate/t1/state" => { "t" => "g/table", "ts" => true }, "score" => { "t" => 1 } },
                 viewer.pubs_of("host", "room01"))
    assert_equal({ "@shared/lobby" => { "t" => 7, "d" => "who is here" } }, viewer.pubs_of("pc", "chat"))

    got = []
    viewer.subscribe("*/@shared/spectate/**") { |v, info| got << [v, info] }
    glob = []
    viewer.subscribe("@shared/**") { |v, info| glob << [v, info] }
    apps = []
    viewer.subscribe("**") { |v, info| apps << info.path }
    sleep 0.3
    a.put({ "seats" => 2 })
    b.put({ "seats" => %w[x y], "turn" => 0 })
    a.instance_variable_set(:@seq, 3) # a's 1 and 2 go missing
    a.put({ "seats" => 3 })
    b.put({ "seats" => %w[x], "turn" => 1 })
    lobby.put("hello")
    own.put(10)
    assert poll_until { got.size >= 4 && glob.size >= 1 && apps.size >= 1 }
    rows = got.map { |v, i| [i.from, i.seq, i.lost, i.restarted?, i.path, i.shared] }
    by = rows.group_by(&:first)
    assert_equal [[0, 0], [3, 2]], by["host/games"].map { |r| r.values_at(1, 2) }, "games: 2 missed"
    assert_equal [[0, 0], [1, 0]], by["host/room01"].map { |r| r.values_at(1, 2) }, "room01 counted on its own"
    assert rows.all? { _5 == "host/@shared/spectate/t1/state" && _6 == :node }
    assert got.select { _2.from == "host/room01" }.all? { _2.time.is_a?(Integer) }, "ts: the time"
    assert got.select { _2.from == "host/games" }.all? { _2.time.nil? }, "no ts: nil"
    v, i = glob.first
    assert_equal ["hello", "pc/chat", :global, "@shared/lobby", "lobby"], [v, i.from, i.shared, i.path, i.name]
    assert_equal ["host/room01/score"], apps.uniq, "** reaches no shared place"

    # Each value's type, from its own sender.
    ia = got.find { _2.from == "host/games" }[1]
    ib = got.find { _2.from == "host/room01" }[1]
    assert_equal ["g/table", { "f" => [["seats", "int"]], "d" => "the host's" }], viewer.type_of(ia)
    assert_equal ["g/table", { "f" => [["seats", "str[]"], ["turn", "int"]], "d" => "the room's" }], viewer.type_of(ib)
    assert_equal({ "t" => "g/table", "ts" => true }, viewer.declaration_of(ib))
    assert_equal 7, viewer.type_of(glob.first[1])

    # Who declares a shared key.
    pubs = viewer.publishers_of("host/@shared/spectate/t1/state", timeout: 1.0)
    assert_equal({ "host/games" => { "t" => "g/table" }, "host/room01" => { "t" => "g/table", "ts" => true } }, pubs)
    assert_equal pubs, viewer.publishers_of("*/@shared/spectate/t1/state", timeout: 1.0)
    assert_equal({ "pc/chat" => { "t" => 7, "d" => "who is here" } }, games.publishers_of("@shared/lobby", timeout: 1.0))
    assert_equal({}, viewer.publishers_of("@shared/nothing", timeout: 0.5))
    assert_equal pubs.keys.sort, room.publishers_of("host/@shared/spectate/t1/state", timeout: 1.0).keys.sort,
                 "this application's own among them"
    assert_raises(ArgumentError) { viewer.publishers_of("host/room01/score") }

    # Withdrawing one sender's declaration.
    assert room.unpublish("spectate/t1/state", shared: :node)
    assert_equal ["score"], room.published
    assert_equal({ "host/games" => { "t" => "g/table" } },
                 viewer.publishers_of("host/@shared/spectate/t1/state", timeout: 1.0))
    assert games.unpublish(a)
    assert_raises(Asterism::Disconnected) { a.put(1) }
    assert_raises(ArgumentError) { games.publish("x", shared: :app) }
  end
end
