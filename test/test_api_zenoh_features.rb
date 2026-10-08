# The Ruby-like API over the calls added in asterism-zenoh 0.3.0: Samples
# with their fields, delete, publishers with on_matching, queriers, error
# replies, the advanced publisher / subscriber with on_publisher, and
# on_transport. Blocks run on the receiving thread.
require_relative "helper"
require "asterism"

class TestApiZenohFeatures < Minitest::Test
  include TestHelper

  def setup
    a, b = open_pair
    @a = Asterism::Zenoh::Connection.new(a)
    @b = Asterism::Zenoh::Connection.new(b)
    @a.start
    @b.start
  end

  def teardown
    @b&.close
    @a&.close
  end

  def settle = sleep(0.3)

  def test_samples_carry_kind_encoding_and_timestamp
    got = Queue.new
    @a.subscribe("c7/api/**") { |s| got << [s, Thread.current] }
    settle
    @b.put("c7/api/x", { "a" => 1 }.to_s, encoding: "text/plain", timestamp: true, priority: :data_high)
    @b.delete("c7/api/x")
    s1, th = got.pop(timeout: 3)
    s2, = got.pop(timeout: 3)
    refute_equal Thread.current, th
    assert_equal [:put, "text/plain", :data_high], [s1.kind, s1.encoding, s1.priority]
    assert_kind_of Asterism::Zenoh::Timestamp, s1.timestamp
    assert s2.delete?
    case s2
    in { kind: :delete, key: }
      assert_equal "c7/api/x", key
    end
  end

  def test_publisher_on_matching
    seen = Queue.new
    pub = @b.publisher("c7/api/pub", encoding: "application/json")
    pub.on_matching { |m| seen << m }
    refute pub.matching?
    sub = @a.subscribe("c7/api/pub")
    assert_equal true, seen.pop(timeout: 3)
    pub.put([1, 2])
    assert_equal ["[1, 2]", "application/json"], sub.each(timeout: 3).first.then { |s| [s.payload, s.encoding] }
    sub.close
    assert_equal false, seen.pop(timeout: 3)
    pub.close
    assert pub.closed?
  end

  def test_querier_and_error_replies
    @a.queryable("c7/api/q/**") do |q|
      case q.params
      when "bad" then q.reply_err("nope")
      when "gone" then q.reply_del
      else q.reply("c7/api/q/one", 1)
      end
    end
    q = @b.querier("c7/api/q/**", timeout: 1.5)
    assert wait_for { q.matching? }
    assert_equal ["1"], q.get.map(&:payload)
    assert_equal [], q.get(params: "bad").to_a
    errs = q.get(params: "bad", errors: true).to_a
    assert_equal 1, errs.size
    assert errs[0].error?
    assert_equal "nope", errs[0].payload
    assert_equal [], @b.get("c7/api/q/x", params: "bad").to_a
    assert_equal ["nope"], @b.get("c7/api/q/x", params: "bad", errors: true).map(&:payload)
    q.close
  end

  def test_reply_del_on_the_queryables_own_key
    @a.queryable("c7/api/own") { |q| q.reply_del }
    settle
    r = @b.get("c7/api/own").to_a
    assert_equal [["c7/api/own", :delete]], r.map { [_1.key, _1.kind] }
  end

  def test_advanced_history_and_on_publisher
    pub = @b.advanced_publisher("c7/api/adv", cache: 2, publisher_detection: true, sample_miss_detection: true)
    %w[a b c].each { |v| pub.put(v) }
    settle
    got = Queue.new
    pubs = Queue.new
    sub = @a.advanced_subscriber("c7/api/adv", history: true) { |s| got << s.payload }
    sub.on_publisher { |key, alive| pubs << [key, alive] }
    assert_equal %w[b c], [got.pop(timeout: 3), got.pop(timeout: 3)]
    key, alive = pubs.pop(timeout: 3)
    assert alive
    assert_includes key, "c7/api/adv"
    pub.close
    assert_equal false, pubs.pop(timeout: 3)[1]
    sub.close
  end

  def test_on_transport
    skip "peer link only" if TestHelper.router
    loc = "tcp/127.0.0.1:#{TestHelper.free_port}"
    l = Asterism::Zenoh.open(nil, mode: :peer, listen: loc)
    events = Queue.new
    l.on_transport { |ev| events << ev }
    l.start
    c = Asterism::Zenoh.open(loc, mode: :peer)
    ev = events.pop(timeout: 3)
    assert ev.added?
    assert_equal c.zid, ev.zid
    assert_equal [c.zid], l.peer_zids
    c.close
    assert events.pop(timeout: 5).removed?
  ensure
    c&.close
    l&.close
  end
end
