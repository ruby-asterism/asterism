# The CRuby side of rake test:cross: topics and subscriptions with an mruby
# node (host_test/data_node.rb, node "mdata"), both through Asterism, over
# a peer link. Checks both directions: the mruby node's declarations
# (pubs_of, types_of, the @pubs puts), its values in a CRuby subscription
# (seq, time, encoding, lost), and this node's values in the mruby
# subscription (reported back by its probe).
#
#   ASTERISM_CROSS_PORT=PORT ruby -I lib -I ../asterism-zenoh/lib test/cross_mruby.rb
require_relative "helper"
require "asterism"

class TestCrossMruby < Minitest::Test
  include TestHelper

  JPEG = "\xff\xd8\xff\xe0mruby\xff\xd9".b

  def test_topics_with_an_mruby_node
    Asterism.connect("tcp/127.0.0.1:#{ENV.fetch("ASTERISM_CROSS_PORT")}", node: "cruby", app: "t", mode: :peer)
    assert wait_for(5) { Asterism.poll; Asterism.each("mdata/t/probe").size == 1 }
    probe = Asterism["mdata/t/probe", timeout: 3.0]

    pubs = { "imu" => { "t" => 2, "u" => "m/s2", "d" => "acceleration", "ts" => true },
             "cam/front" => { "t" => 4, "e" => 17 } }
    assert_equal pubs, Asterism.pubs_of("mdata", "t")
    assert_equal({ "mdata/sample" => { "f" => [["id", "int"], ["tags", "str[]"], ["at", 3]], "d" => "a sample" } },
                 Asterism.types_of("mdata", "t"))
    assert_nil Asterism.status_of("mdata", "t")

    # mruby -> CRuby
    got = []
    Asterism.subscribe("mdata/t/**") { |v, info| got << [v, info] }
    pubs_puts = []
    Asterism.subscribe("mdata/t/@pubs") { |v, info| pubs_puts << [v, info] }
    sleep 0.3
    assert_equal 3, probe.put_imu(3)
    assert_equal 1, probe.put_cam
    assert wait_for { Asterism.poll; got.size >= 4 }
    assert_equal [[0.5, -1, 1], [0.5, -1, 2], [0.5, -1, 3]], got[0, 3].map(&:first)
    assert_equal [0, 1, 2], got[0, 3].map { _2.seq }
    assert_equal ["msgpack"] * 3, got[0, 3].map { _2.encoding }
    assert got[0, 3].all? { (_2.time - Time.now.to_f * 1000).abs < 5000 }, "the sender's time"
    v, info = got[3]
    assert_equal [JPEG, "image/jpeg", "cam/front", 0, nil], [v, info.encoding, info.name, info.seq, info.time]
    assert_equal ["imu"], probe.unpublish_cam
    assert wait_for { Asterism.poll; pubs_puts.any? }
    v, info = pubs_puts.last
    assert_equal({ "imu" => pubs["imu"] }, v, "@pubs is MessagePack too")
    assert_nil info.seq, "@pubs has no sequence number"
    assert_equal({ "imu" => pubs["imu"] }, Asterism.pubs_of("mdata", "t"))

    # CRuby -> mruby
    a = Asterism.publish("a", type: :number, ts: true)
    img = Asterism.publish("img", type: :image, encoding: "image/png")
    n = Asterism.publish("n")
    sleep 0.3
    a.put(1.25)
    img.put("\x89PNG\r\n".b)
    n.put({ "k" => [1, "two"] })
    a.instance_variable_set(:@seq, 4)
    a.put(2)
    assert wait_for { Asterism.poll; probe.got.size >= 4 }
    rows = probe.got
    assert_equal ["cruby/t/a", 1.25, 0, "msgpack", 0, false], rows[0].values_at(0, 1, 2, 4, 5, 6)
    assert_kind_of Integer, rows[0][3]
    assert_equal ["cruby/t/img", "\x89PNG\r\n".b, 0, nil, "image/png", 0, false], rows[1]
    assert_equal ["cruby/t/n", { "k" => [1, "two"] }, 0, nil, "msgpack", 0, false], rows[2]
    assert_equal ["cruby/t/a", 2, 4, "msgpack", 3, false], rows[3].values_at(0, 1, 2, 4, 5, 6)
    assert_equal [{ "k" => [1, "two"] }], probe.plain, "a block with |v| on mruby"
    probe.stop
  ensure
    Asterism.close
  end
end
