# The Ruby-like Zenoh API (lib/asterism/cruby/zenoh.rb) between two
# sessions of this process: blocks on the receiving thread, Enumerators,
# start / stop / run, errors in blocks, and the thread being gone after.
require_relative "helper"
require "asterism"

class TestApiZenoh < Minitest::Test
  include TestHelper

  def setup
    a, b = open_pair
    @a = Asterism::Zenoh::Connection.new(a)
    @b = Asterism::Zenoh::Connection.new(b)
    @threads_before = Thread.list.size
  end

  def teardown
    @b&.close
    @a&.close
  end

  def settle = sleep(0.3)

  def test_subscribe_block_on_the_receiving_thread
    got = Queue.new
    threads = Queue.new
    sub = @a.subscribe("c5/z/**") do |s|
      threads << Thread.current
      got << s
    end
    @a.start
    assert @a.running?
    settle
    @b.put("c5/z/x", "hello", attachment: "\x01".b)
    @b.put("c5/z/y", 42)
    s1 = got.pop(timeout: 3)
    s2 = got.pop(timeout: 3)
    assert_equal ["c5/z/x", "hello", "\x01".b], [s1.key, s1.payload, s1.attachment]
    assert_equal "42", s2.payload
    assert_equal Encoding::UTF_8, s1.text.encoding
    refute_equal Thread.current, threads.pop
    case s1
    in { key: /x\z/, payload: String => text }
      assert_equal "hello", text
    end
    sub.close
    @b.put("c5/z/x", "after close")
    sleep 0.2
    assert_equal 0, got.size
  end

  def test_each_waits_and_works_with_lazy
    sub = @a.subscribe("c5/z/temp")
    settle
    feeder = Thread.new do
      5.times do |i|
        @b.put("c5/z/temp", (20.5 + i).to_s)
        sleep 0.05
      end
    end
    values = sub.each.lazy.map { _1.payload.to_f }.first(3)
    assert_equal [20.5, 21.5, 22.5], values
    feeder.join
    # each ends after its timeout when nothing more comes.
    t = Time.now
    rest = sub.each(timeout: 0.3).to_a
    assert_operator Time.now - t, :<, 1.0
    assert_equal ["23.5", "24.5"], rest.map(&:payload)
    # A subscription with a block does not also hand out its samples.
    blk = @a.subscribe("c5/z/blk") { |_| }
    assert_raises(Asterism::Error) { blk.each.first }
  end

  def test_queryable_block_and_get_enumerator
    @b.queryable("c5/z/status") { |q| q.reply("ok #{q.params}") }
    @b.queryable("c5/z/other") { |q| q.reply("c5/z/other", "other") }
    @b.start
    settle
    replies = @a.get("c5/z/**", params: "p=1").to_a
    assert_equal ["c5/z/other", "c5/z/status"], replies.map(&:key).sort
    assert_includes replies.map(&:payload), "ok p=1"
    n = @a.get("c5/z/status") { |r| assert_instance_of Asterism::Zenoh::Reply, r }
    assert_equal 1, n
    # Nobody answers: the Enumerator is empty and ends at once.
    t = Time.now
    assert_equal [], @a.get("c5/nobody/**", timeout: 2).to_a
    assert_operator Time.now - t, :<, 1.5
  end

  def test_queryable_each_without_block
    qa2 = @b.queryable("c5/z/q2")
    settle
    replier = Thread.new do
      qa2.each(timeout: 2) do |q|
        q.reply("pong")
        break
      end
    end
    sleep 0.05
    assert_equal ["pong"], @a.get("c5/z/q2").map(&:payload)
    replier.join
  end

  def test_liveliness_watch_and_get
    events = Queue.new
    @a.liveliness_watch("c5/live/**") { |key, alive| events << [key, alive] }
    @a.start
    tok = @b.liveliness("c5/live/one")
    assert_equal ["c5/live/one", true], events.pop(timeout: 3)
    assert_equal ["c5/live/one"], @a.liveliness_get("c5/live/**")
    tok.close
    assert_equal ["c5/live/one", false], events.pop(timeout: 3)
    # Without a block: an Enumerator of Liveliness values.
    tok2 = @b.liveliness("c5/live/two")
    w = @a.liveliness_watch("c5/live/two")
    first = w.each(timeout: 3).first
    assert_equal "c5/live/two", first.key
    assert first.alive?
    tok2.close
  end

  def test_run_on_this_thread_and_stop_from_a_block
    seen = []
    @a.subscribe("c5/z/run") do |s|
      seen << s.payload
      @a.stop if seen.size == 3
    end
    settle
    feeder = Thread.new { 5.times { |i| @b.put("c5/z/run", i.to_s); sleep 0.02 } }
    t = Thread.new { @a.run }
    assert t.join(5), "run returns after stop"
    feeder.join
    assert_equal %w[0 1 2], seen
    refute @a.running?
  end

  def test_errors_in_blocks_do_not_stop_receiving
    errors = Queue.new
    got = Queue.new
    @a.on_error { |e, where| errors << [e.message, where] }
    @a.subscribe("c5/z/err") do |s|
      raise "bad #{s.payload}" if s.payload == "1"
      got << s.payload
    end
    @a.start
    settle
    %w[0 1 2].each { |v| @b.put("c5/z/err", v) }
    assert_equal "0", got.pop(timeout: 3)
    assert_equal "2", got.pop(timeout: 3)
    assert_equal ["bad 1", "subscribe c5/z/err"], errors.pop(timeout: 1)
    assert @a.running?
  end

  def test_errors_without_handler_are_warned
    @a.subscribe("c5/z/warn") { |_s| raise ArgumentError, "noisy" }
    @a.start
    settle
    _out, err = capture_io do
      @b.put("c5/z/warn", "x")
      sleep 0.3
    end
    assert_match(/subscribe c5\/z\/warn: ArgumentError: noisy/, err)
  end

  def test_open_with_block_closes_and_leaves_no_thread
    loc = TestHelper.router || "tcp/127.0.0.1:#{TestHelper.free_port}"
    opts = TestHelper.router ? {} : { mode: :peer, listen: loc }
    before = Thread.list.size
    conn = nil
    value = Asterism::Zenoh.open(TestHelper.router ? loc : nil, **opts) do |s|
      conn = s
      s.subscribe("c5/z/none") { |_| }
      s.start
      assert s.running?
      :done
    end
    assert_equal :done, value
    assert conn.closed?
    refute conn.running?
    assert_equal before, Thread.list.size
    # Also when the block raises.
    assert_raises(RuntimeError) do
      Asterism::Zenoh.open(TestHelper.router ? loc : nil, **opts) do |s|
        conn = s
        s.start
        raise "inside"
      end
    end
    assert conn.closed?
    assert_equal before, Thread.list.size
  end

  def test_receiving_ends_when_the_connection_is_lost
    skip "a router keeps both clients open" if TestHelper.router
    @a.start
    @b.start
    assert @b.running?
    @a.close
    assert wait_for(5) { !@b.running? }, "the receiving thread of the connecting peer ends"
    assert @b.closed?
    assert wait_for(2) { Thread.list.size <= @threads_before }
  end
end
