# The CRuby side of rake test:cross: topics and subscriptions with an mruby
# node (host_test/data_node.rb, node "mdata"), both through Asterism, over
# a peer link. Checks both directions: the mruby node's declarations
# (pubs_of, types_of, the @pubs puts), its values in a CRuby subscription
# (seq, time, encoding, lost), and this node's values in the mruby
# subscription (reported back by its probe). Shared places: the mruby
# node's place read here (its sender, numbers, type and publishers), and
# the network's place written here, read by the mruby subscription with
# the sender and the numbers.
#
#   ASTERISM_CROSS_PORT=PORT ruby -I lib -I ../asterism-zenoh/lib test/cross_mruby.rb
require_relative "helper"
require "asterism"

class TestCrossMruby < Minitest::Test
  include TestHelper

  JPEG = "\xff\xd8\xff\xe0mruby\xff\xd9".b

  def test_topics_with_an_mruby_node
    @net = Asterism.connect("tcp/127.0.0.1:#{ENV.fetch("ASTERISM_CROSS_PORT")}", node: "cruby", app: "t", mode: :peer)
    assert wait_for(5) { @net.poll; @net.each("mdata/t/probe").size == 1 }
    probe = @net["mdata/t/probe", timeout: 3.0]

    pubs = { "imu" => { "t" => 2, "u" => "m/s2", "d" => "acceleration", "ts" => true },
             "cam/front" => { "t" => 4, "e" => 17 }, "mdata/@shared/cross/m" => { "t" => "mdata/sample" } }
    assert_equal pubs, @net.pubs_of("mdata", "t")
    assert_equal({ "mdata/sample" => { "f" => [["id", "int"], ["tags", "str[]"], ["at", "pose"], ["trail", "vector3[]"],
                                                     ["kind", 5]], "d" => "a sample" } },
                 @net.types_of("mdata", "t"))
    assert_nil @net.status_of("mdata", "t")

    # mruby -> CRuby
    got = []
    @net.subscribe("mdata/t/**") { |v, info| got << [v, info] }
    pubs_puts = []
    @net.subscribe("mdata/t/@pubs") { |v, info| pubs_puts << [v, info] }
    sleep 0.3
    assert_equal 3, probe.put_imu(3)
    assert_equal 1, probe.put_cam
    assert wait_for { @net.poll; got.size >= 4 }
    assert_equal [[0.5, -1, 1], [0.5, -1, 2], [0.5, -1, 3]], got[0, 3].map(&:first)
    assert_equal [0, 1, 2], got[0, 3].map { _2.seq }
    assert_equal ["msgpack"] * 3, got[0, 3].map { _2.encoding }
    assert got[0, 3].all? { (_2.time - Time.now.to_f * 1000).abs < 5000 }, "the sender's time"
    v, info = got[3]
    assert_equal [JPEG, "image/jpeg", "cam/front", 0, nil], [v, info.encoding, info.name, info.seq, info.time]
    assert_equal ["imu", "mdata/@shared/cross/m"], probe.unpublish_cam
    assert wait_for { @net.poll; pubs_puts.any? }
    v, info = pubs_puts.last
    left = pubs.reject { |k, _| k == "cam/front" }
    assert_equal(left, v, "@pubs is MessagePack too")
    assert_nil info.seq, "@pubs has no sequence number"
    assert_equal(left, @net.pubs_of("mdata", "t"))

    # CRuby -> mruby
    a = @net.publish("a", type: :number, ts: true)
    img = @net.publish("img", type: :image, encoding: "image/png")
    n = @net.publish("n")
    sleep 0.3
    a.put(1.25)
    img.put("\x89PNG\r\n".b)
    n.put({ "k" => [1, "two"] })
    a.instance_variable_set(:@seq, 4)
    a.put(2)
    assert wait_for { @net.poll; probe.got.size >= 4 }
    rows = probe.got
    assert_equal ["cruby/t/a", 1.25, 0, "msgpack", 0, false], rows[0].values_at(0, 1, 2, 4, 5, 6)
    assert_kind_of Integer, rows[0][3]
    assert_equal ["cruby/t/img", "\x89PNG\r\n".b, 0, nil, "image/png", 0, false], rows[1]
    assert_equal ["cruby/t/n", { "k" => [1, "two"] }, 0, nil, "msgpack", 0, false], rows[2]
    assert_equal ["cruby/t/a", 2, 4, "msgpack", 3, false], rows[3].values_at(0, 1, 2, 4, 5, 6)
    assert_equal [{ "k" => [1, "two"] }], probe.plain, "a block with |v| on mruby"

    # Shared places. mruby -> CRuby: its node's place, its sender, its type.
    sh = []
    @net.subscribe("*/@shared/cross/**") { |v, info| sh << [v, info] }
    sleep 0.3
    assert_equal 3, probe.put_shared(3)
    assert wait_for { @net.poll; sh.size >= 3 }
    assert_equal [[0, 0], [1, 0], [2, 0]], sh.map { |_, i| [i.seq, i.lost] }
    i = sh[0][1]
    assert_equal ["mdata/@shared/cross/m", "mdata/t", :node, "cross/m", nil], [i.path, i.from, i.shared, i.name, i.time]
    assert_equal ["mdata/sample", @net.types_of("mdata", "t")["mdata/sample"]], @net.type_of(i)
    assert_equal({ "mdata/t" => { "t" => "mdata/sample" } }, @net.publishers_of("mdata/@shared/cross/m", timeout: 1.0))

    # CRuby -> mruby: the network's place, with the sender and a gap.
    # (Two senders on one key are in host_test/test_connections.rb and
    # test/test_shared.rb: a second CRuby peer of the listening mruby node
    # is dropped by zenoh-pico.)
    ka = @net.publish("cross/k", shared: :global, type: :number, ts: true)
    sleep 0.3
    ka.put(1)
    ka.instance_variable_set(:@seq, 3) # 1 and 2 go missing
    ka.put(2)
    assert wait_for { @net.poll; probe.shared.size >= 2 }
    rows = probe.shared
    assert_equal [["@shared/cross/k", 1, 0, "cruby/t", 0, false, "global"],
                  ["@shared/cross/k", 2, 3, "cruby/t", 2, false, "global"]], rows
    probe.stop
  ensure
    @net&.close
  end
end
