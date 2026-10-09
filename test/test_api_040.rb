# What 0.4.0 adds to the CRuby API (docs/api_review.md): seconds and
# keywords, connection_count, each_sample, the block forms of liveliness
# and publisher, request: on node.call, and the deprecation warnings of the
# old forms. The shared layer's additions are tested in test_asterism.rb.
require_relative "helper"
require "asterism"

class TestApi040 < Minitest::Test
  include TestHelper

  def setup
    a, b = open_pair
    @a = Asterism::Zenoh::Connection.new(a)
    @b = Asterism::Zenoh::Connection.new(b)
  end

  def teardown
    @b&.close
    @a&.close
  end

  def settle = sleep(0.3)

  def test_error_tree
    [Asterism::Zenoh::Error, Asterism::Zenoh::ClosedError, Asterism::EncodeError, Asterism::TimeoutError,
     Asterism::Disconnected, Asterism::RemoteError, Asterism::ROS::TimeoutError, Asterism::ROS::UnknownType,
     Asterism::CDR::DecodeError, Asterism::DeprecationError].each do |k|
      assert_operator k, :<, Asterism::Error, k.to_s
    end
    assert_operator Asterism::ROS::TimeoutError, :<, Asterism::TimeoutError
    # Inside module Asterism, Timeout is Ruby's again (not an exception class).
    require "timeout"
    assert_equal ::Timeout, Asterism.module_eval("Timeout")
  end

  def test_connection_count_and_peers
    assert wait_for { @b.connection_count == 1 }
    warned = with_deprecations { assert_equal 1, @b.peers }
    assert_equal 1, warned.size
    assert_match(/Connection#peers/, warned[0])
  end

  def test_each_sample_and_old_each_pending
    sub = @a.subscribe("c8/s")
    settle
    @b.put("c8/s", "one")
    @b.put("c8/s", "two")
    assert wait_for { sub.pending == 2 }
    assert_equal ["one"], sub.each_sample.first(1).map(&:payload)
    @b.put("c8/s", "three")
    assert wait_for { sub.pending == 1 }
    warned = with_deprecations { assert_equal ["three"], sub.each_pending.map(&:payload) }
    assert_equal 1, warned.size
    assert_match(/Subscription#each_pending.*each_sample/, warned[0])
  end

  def test_get_and_liveliness_in_seconds_or_ms
    @a.queryable("c8/q") { |q| q.reply("ok") }
    @a.start
    settle
    assert_equal ["ok"], @b.get("c8/q", timeout: 1.0).map(&:text)
    assert_equal ["ok"], @b.get("c8/q", timeout_ms: 1000).map(&:text)
    assert_raises(ArgumentError) { @b.get("c8/q", timeout: 1, timeout_ms: 1000) { nil } }
    tok = @a.liveliness("c8/alive/a")
    settle
    assert_equal ["c8/alive/a"], @b.liveliness_get("c8/alive/**", timeout_ms: 1000)
    tok.close
  end

  def test_block_forms_of_liveliness_and_publisher
    keys = nil
    v = @a.liveliness("c8/scoped") do |tok|
      settle
      keys = @b.liveliness_get("c8/scoped", timeout: 1.0)
      refute tok.closed?
      :inside
    end
    assert_equal :inside, v
    assert_equal ["c8/scoped"], keys
    settle
    assert_equal [], @b.liveliness_get("c8/scoped", timeout: 0.5)

    sub = @b.subscribe("c8/pub")
    settle
    kept = nil
    @a.publisher("c8/pub") do |pub|
      kept = pub
      pub.put("x")
    end
    assert kept.closed?
    assert wait_for { sub.pending == 1 }
  end

  def test_querier_and_advanced_subscriber_in_seconds
    qr = @b.querier("c8/none", timeout: 0.2)
    t = Time.now
    assert_equal 0, qr.get { nil }
    assert_operator Time.now - t, :<, 2.0
    qr.close
    adv = @b.advanced_subscriber("c8/adv", history: true, query_timeout: 0.5)
    adv.close
  end
end

class TestApi040ROS < Minitest::Test
  include TestHelper

  def setup
    loc = TestHelper.router
    if loc
      @ra = Asterism::ROS.connect(loc)
      @rb = Asterism::ROS.connect(loc)
    else
      loc = "tcp/127.0.0.1:#{TestHelper.free_port}"
      @ra = Asterism::ROS.connect(nil, mode: :peer, listen: loc)
      @rb = Asterism::ROS.connect(loc, mode: :peer)
    end
  end

  def teardown
    @rb&.close
    @ra&.close
  end

  def test_call_with_request_keyword_and_every_ms
    na = @ra.node("c8_server")
    nb = @rb.node("c8_client")
    add = "example_interfaces/srv/AddTwoInts"
    na.service("/c8/add", add) { |req| { sum: req.a + req.b } }
    ticks = 0
    t = na.every(ms: 20) { ticks += 1 }
    assert_equal 20, t.period_ms
    @ra.start
    @rb.start
    sleep 0.3
    assert_equal 5, nb.call("/c8/add", add, request: { a: 2, b: 3 }, timeout: 2.0).sum
    assert_equal 5, nb.call("/c8/add", add, { a: 2, b: 3 }, timeout_ms: 2000).sum
    assert_raises(ArgumentError) { nb.call("/c8/add", add, a: 1, b: 1, timeout: 1, timeout_ms: 1000) }
    assert_operator ticks, :>, 3
  end
end
