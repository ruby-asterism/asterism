# The Ruby-like object API (lib/asterism/cruby/objects.rb) between two
# CRuby processes (Asterism is one connection per process): connect with a
# block, a receiving thread answering while the main thread waits for its
# own calls, run / start / stop, on_join / on_leave, errors, and the thread
# being gone after.
require_relative "helper"
require "asterism"
require "rbconfig"

class TestApiObjects < Minitest::Test
  include TestHelper

  # The other process answers from net.run on its main thread; a watcher
  # thread stops it when stdin closes.
  CHILD = <<~'RUBY'
    require "asterism"
    loc, mode = ARGV
    opts = mode == "router" ? [loc, {}] : [nil, { mode: :peer, listen: loc }]
    class Calc
      def add(a, b) = a + b
      def slow(x) = (sleep 0.2; x * 2)
      def who = Thread.current.name.to_s
      # Calls the caller back while answering, from the child's run loop.
      def relay(node) = Asterism["#{node}/t/back"].name + "!"
    end
    Asterism.connect(opts[0], node: "child", app: "t", **opts[1]) do |net|
      net.expose("calc", Calc.new, methods: { add: 2, slow: 1, who: 0, relay: 1 })
      Thread.new do
        STDIN.read
        net.stop
      end
      STDOUT.puts "ready"
      STDOUT.flush
      net.run
    end
  RUBY

  class Back
    def name = "parent on #{Thread.current.name || 'main'}"
  end

  def spawn_child
    if (router = TestHelper.router)
      @loc = router
      mode = "router"
    else
      @loc = "tcp/127.0.0.1:#{TestHelper.free_port}"
      mode = "peer"
    end
    lib = [File.expand_path("../lib", __dir__), TestHelper.zenoh_lib].compact
    @child = IO.popen([RbConfig.ruby, *lib.flat_map { |l| ["-I", l] }, "-e", CHILD, @loc, mode], "r+")
    assert_equal "ready", @child.gets&.strip
  end

  def connect_opts
    TestHelper.router ? [@loc, {}] : [@loc, { mode: :peer }]
  end

  def end_child
    return unless @child && !@child.closed?
    @child.close_write rescue nil
    @child.read rescue nil
    @child.close rescue nil
  end

  def teardown
    Asterism.close
    end_child
  end

  def test_block_api_with_a_receiving_thread
    spawn_child
    before = Thread.list.size
    joined = Queue.new
    left = Queue.new
    errors = Queue.new
    loc, opts = connect_opts
    value = Asterism.connect(loc, node: "parent", app: "t", **opts) do |net|
      assert_instance_of Asterism::Net, net
      net.expose("back", Back.new, methods: [:name])
      net.on_join { |n| joined << n }
      net.on_join { |n| raise "join handler failed for #{n}" }
      net.on_leave { |n| left << n }
      net.on_error { |e, where| errors << [e.message, where] }
      net.start
      assert net.running?
      assert_equal "child", joined.pop(timeout: 5)
      assert_equal ["join handler failed for child", "on_join"], errors.pop(timeout: 1)

      calc = net["child/t/calc"]
      assert_equal 5, calc.add(2, 3)            # waits for the receiving thread's ticks
      assert_equal "", calc.who                 # answered on the child's main thread (run)
      # The child calls back while answering; this process's receiving
      # thread answers that while the main thread waits.
      assert_equal "parent on asterism receiver!", calc.relay("parent")
      # Calls from several threads at once.
      results = 4.times.map { |i| Thread.new { calc.slow(i) } }.map(&:value)
      assert_equal [0, 2, 4, 6], results
      f = calc.async.add(1, 1)
      assert_equal 2, f.value

      assert_equal ["child/t/calc"], net.each("child/*/*").map(&:asterism_path)
      assert_equal [5], net.each("*/t/calc").map { _1.add(2, 3) }
      assert_equal %w[parent child], net.nodes
      e = assert_raises(Asterism::TimeoutError) { net["child/other/x", timeout: 0.5].anything }
      assert_match(/nobody answers/, e.message)

      end_child
      assert_equal "child", left.pop(timeout: 10)
      :ok
    end
    assert_equal :ok, value
    refute Asterism.connected?
    assert wait_for(2) { Thread.list.size <= before }, "no thread left"
  end

  def test_connect_without_block_then_start_from_net
    spawn_child
    loc, opts = connect_opts
    assert_equal Asterism, Asterism.connect(loc, node: "parent", app: "t", **opts)
    Asterism.expose("back", Back.new, methods: [:name])
    net = Asterism.net
    assert_same net, Asterism.net
    assert wait_for { Asterism.poll; Asterism.nodes.include?("child") }
    # Not started: the waiting call polls by itself, as on the boards.
    assert_equal "parent on main!", Asterism["child/t/calc"].relay("parent")
    net.start
    assert_equal "parent on asterism receiver!", Asterism["child/t/calc"].relay("parent")
    # Asterism.poll from the main thread while the thread runs: serialized.
    10.times { assert Asterism.poll }
    net.stop
    refute net.running?
    assert_equal 7, Asterism["child/t/calc"].add(3, 4)
    net.start
    Asterism.close
    refute net.running?
    assert_nil Asterism.net
  end

  # config: goes to Session.open (TLS certificates in real use): a Hash
  # whose value shows in the session, and a configuration zenoh refuses.
  def test_connect_passes_config_to_the_session
    spawn_child
    loc, opts = connect_opts
    Asterism.connect(loc, node: "parent", app: "t", config: { "metadata" => { "name" => "cfg-test" } }, **opts) do |net|
      assert_equal 7, net["child/t/calc"].add(3, 4)
    end
    # As Session.open: a configuration zenoh refuses is an ArgumentError.
    assert_raises(ArgumentError) do
      Asterism.connect(loc, node: "parent", app: "t", config: "{ mode: 'nonsense' }", **opts)
    end
    refute Asterism.connected?
  end

  def test_waiting_call_ends_when_the_connection_is_lost
    skip "a router keeps the client open" if TestHelper.router
    spawn_child
    loc, opts = connect_opts
    Asterism.connect(loc, node: "parent", app: "t", **opts) do |net|
      net.start
      calc = net["child/t/calc", timeout: 5]
      th = Thread.new do
        calc.slow(1) # the child is killed while this waits
      rescue Asterism::Error => e
        e
      end
      sleep 0.05
      Process.kill(:KILL, @child.pid)
      r = th.value
      assert_kind_of Asterism::Error, r
      assert wait_for(5) { !net.running? }
      refute net.connected?
    end
  end
end
