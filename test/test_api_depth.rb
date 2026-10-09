# The queue depths of the CRuby API (lib/asterism/cruby/zenoh.rb): a burst
# of replies or live tokens larger than 16 is received whole with the
# defaults, depth: bounds it, dropped counts what did not fit, and a loss
# the application did not choose warns once.
require_relative "helper"
require "asterism"

class TestApiDepth < Minitest::Test
  include TestHelper

  BURST = 40

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

  # A queryable on prefix/** that answers each query with BURST replies.
  def burst_queryable(prefix)
    @a.queryable("#{prefix}/**") do |q|
      BURST.times { |i| q.reply("#{prefix}/k#{i}", i.to_s) }
    end
    @a.start
    settle
  end

  def test_get_burst_with_the_default_depth
    burst_queryable("dpa/g")
    got = []
    err = capture_io { assert_equal BURST, @b.get("dpa/g/**") { |r| got << r.payload } }[1]
    assert_equal (0...BURST).map(&:to_s), got
    assert_equal "", err, "nothing dropped, nothing said"
    e = @b.get("dpa/g/**")
    assert_kind_of Asterism::Zenoh::GetEnumerator, e
    assert_nil e.dropped
    assert_equal BURST, e.to_a.size
    assert_equal 0, e.dropped
    assert_equal BURST, e.received
    assert_equal 0, e.errors
  end

  # The replies are taken while they come in, so how many are dropped
  # depends on the timing; what came is either taken or counted. (The
  # binding's own tests check the exact numbers, taking after the burst.)
  def assert_bounded(taken, dropped, depth)
    assert_equal BURST, taken + dropped
    assert_operator dropped, :<=, BURST - depth
  end

  def test_get_depth_bounds_and_counts
    burst_queryable("dpa/h")
    e = @b.get("dpa/h/**", depth: 8)
    got = nil
    out, err = capture_io { got = e.map(&:payload) }
    assert_bounded(got.size, e.dropped, 8)
    assert_equal got.sort_by(&:to_i), got, "in order"
    assert_equal "", out + err, "depth: given: no warning"
    e4 = @b.get("dpa/h/**", depth: 4)
    assert_bounded(e4.count, e4.dropped, 4)
  end

  # A finished get that dropped some replies (the queue order of a real
  # one is timing-dependent here).
  FakeGet = Struct.new(:dropped) do
    def done? = true
    def pending = 0
    def each_result = []
    def received = 10
    def errors = 0
  end

  def test_a_get_that_dropped_with_the_default_depth_warns_once_per_get
    g1 = FakeGet.new(3)
    g2 = FakeGet.new(5)
    _, err = capture_io do
      2.times { @b.send(:get_each, -> { g1 }, false, "get dpa/w/**", true, nil) { nil } }
      @b.send(:get_each, -> { g2 }, false, "get dpa/w/**", true, nil) { nil }
      @b.send(:get_each, -> { FakeGet.new(7) }, false, "get dpa/w/**", false, nil) { nil }
    end
    lines = err.split("\n")
    assert_equal 2, lines.size, err
    assert_match(%r{get dpa/w/\*\*: 3 replies dropped}, lines[0])
    assert_match(/5 replies dropped/, lines[1])
  end

  def test_querier_get_depth
    burst_queryable("dpa/q")
    qr = @b.querier("dpa/q/**")
    settle
    e = qr.get(depth: 5)
    assert_bounded(e.to_a.size, e.dropped, 5)
    assert_equal BURST, qr.get { |_r| nil }
    qr.close
  end

  def test_liveliness_get_burst
    tokens = (0...BURST).map { |i| @a.liveliness("dpa/lv/t#{i}") }
    settle
    keys = @b.liveliness_get("dpa/lv/**")
    assert_kind_of Array, keys
    assert_equal BURST, keys.size
    assert_equal 0, keys.dropped
    assert_equal BURST, keys.received
    few = @b.liveliness_get("dpa/lv/**", depth: 3)
    assert_bounded(few.size, few.dropped, 3)
    tokens.each(&:close)
  end

  def test_liveliness_watch_burst_and_dropped
    tokens = (0...BURST).map { |i| @a.liveliness("dpa/lw/t#{i}") }
    settle
    w = @b.liveliness_watch("dpa/lw/**")
    small = @b.liveliness_watch("dpa/lw/**", depth: 4)
    assert wait_for { w.received == BURST && small.received == BURST }
    assert_equal BURST, w.pending
    assert_equal 0, w.dropped
    assert_equal BURST - 4, small.dropped
    assert_equal 4, small.each(timeout: 0.2).to_a.size
    w.close
    small.close
    tokens.each(&:close)
  end

  def test_a_watch_that_dropped_with_the_default_depth_warns_once
    tokens = (0...20).map { |i| @a.liveliness("dpa/ww/t#{i}") }
    settle
    # A watch whose depth was left at the default (here made small by
    # going through the session, then wrapped as the Connection does).
    raw = @b.session.liveliness_watch("dpa/ww/**", depth: 2)
    w = Asterism::Zenoh::Connection::Watch.new(@b, raw, "dpa/ww/**", warn: true)
    assert wait_for { raw.received == 20 }
    _, err = capture_io do
      w.each(timeout: 0.2).to_a
      w.each(timeout: 0.2).to_a
    end
    lines = err.split("\n")
    assert_equal 1, lines.size, err
    assert_match(/liveliness_watch dpa\/ww\/\*\*: 18 changes dropped/, lines[0])
    assert_equal 18, w.dropped
    w.close
    tokens.each(&:close)
  end

  def test_a_subscription_that_dropped_with_the_default_depth_warns_once
    sub = @a.subscribe("dpa/s")
    explicit = @a.subscribe("dpa/s", depth: 2)
    settle
    20.times { |i| @b.put("dpa/s", i.to_s) }
    assert wait_for { sub.received == 20 && explicit.received == 20 }
    _, err = capture_io do
      sub.each_sample
      explicit.each_sample
      @b.put("dpa/s", "more")
      sleep 0.2
      sub.each_sample
    end
    assert_equal 4, sub.dropped
    assert_equal 18, explicit.dropped
    lines = err.split("\n")
    assert_equal 1, lines.size, err
    assert_match(/subscribe dpa\/s: 4 samples dropped/, lines[0])
  end
end
