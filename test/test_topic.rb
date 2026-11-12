# Topics (docs/protocol.md 9-11): the checks and the reading of sequence
# numbers (no network), and between two CRuby processes: Asterism.publish
# and Topic#put (MessagePack without an encoding, the bytes of an image with
# image/jpeg, the attachment [seq] or [seq, time]), Asterism.subscribe
# (|v, info| and |v|, lost values, wrapping, a restart, close), the puts on
# @pubs, the application's profile (?status, ?pubs, ?types), pubs_of and
# types_of, and the CRuby API (net.subscribe on the receiving thread).
require_relative "helper"
require "asterism"
require "rbconfig"
require "timeout"

class TestTopic < Minitest::Test
  include TestHelper

  FakeSample = Struct.new(:key, :payload, :attachment, :kind, :encoding, :timestamp)

  # ------------------------------------------------------------ no network

  def test_types
    assert_equal 2, Asterism::Types.number(:vector3)
    assert_equal 7, Asterism::Types.number("text")
    assert_nil Asterism::Types.number(:nope)
    assert_equal 2, Asterism::Types.topic_type!(:vector3)
    assert_equal 4, Asterism::Types.topic_type!(4)
    assert_equal "mygame/board.strokes", Asterism::Types.topic_type!("mygame/board.strokes")
    assert_nil Asterism::Types.topic_type!(nil)
    assert_raises(ArgumentError) { Asterism::Types.topic_type!(:nope) }
    assert_raises(ArgumentError) { Asterism::Types.topic_type!(0) }
    assert_raises(ArgumentError) { Asterism::Types.topic_type!(8) }
    assert_raises(ArgumentError) { Asterism::Types.topic_type!("") }
    assert_raises(ArgumentError) { Asterism::Types.topic_type!(1.5) }
    d = Asterism::Types.definition!([["pts", "int[]"], [:pos, :vector3], ["kids", "mygame/node[]"], ["n", 1]], "a board")
    assert_equal({ "f" => [["pts", "int[]"], ["pos", 2], ["kids", "mygame/node[]"], ["n", 1]], "d" => "a board" }, d)
    assert_equal({ "f" => [] }, Asterism::Types.definition!([], nil))
    assert_raises(ArgumentError) { Asterism::Types.definition!([["a"]], nil) }
    assert_raises(ArgumentError) { Asterism::Types.definition!([["a", "[]"]], nil) }
    assert_raises(ArgumentError) { Asterism::Types.definition!([["a", "vector3[]"]], nil) }
    assert_raises(ArgumentError) { Asterism::Types.definition!([["a", 9]], nil) }
    assert_raises(ArgumentError) { Asterism::Types.definition!({ "a" => "int" }, nil) }
    assert_raises(ArgumentError) { Asterism::Types.definition!([], 5) }
    got = Asterism::Types.check({ "ok" => { "f" => [["a", 1], ["b", "str"]], "d" => "x", "z" => 1 },
                                  "bad f" => { "f" => [["a"]] }, "no f" => {}, 5 => { "f" => [] },
                                  "bad d" => { "f" => [], "d" => 5 } })
    assert_equal({ "ok" => { "f" => [["a", 1], ["b", "str"]], "d" => "x" }, "bad d" => { "f" => [] } }, got)
    assert_nil Asterism::Types.check([1])
  end

  def test_pubs
    assert_equal 17, Asterism::Pubs.encoding_id("image/jpeg")
    assert_equal 16, Asterism::Pubs.encoding_id("image/png")
    assert_equal 4, Asterism::Pubs.encoding_id("text/plain;charset=utf-8")
    assert_equal 7, Asterism::Pubs.encoding_id("application/cdr")
    assert_equal 0, Asterism::Pubs.encoding_id("zenoh/bytes")
    assert_equal 52, Asterism::Pubs.encoding_id("video/vp9")
    assert_nil Asterism::Pubs.encoding_id("application/msgpack")
    assert_equal "image/jpeg", Asterism::Pubs.encoding_name(17)
    assert_nil Asterism::Pubs.encoding_name(53)
    got = Asterism::Pubs.check({ "imu" => { "t" => 2, "u" => "m/s2", "d" => "accel", "ts" => true, "x" => 1 },
                                 "cam" => { "t" => 4, "e" => 17 }, "odd" => { "t" => 0, "e" => "x", "ts" => 1 },
                                 5 => {}, "nomap" => 1 })
    assert_equal({ "imu" => { "t" => 2, "u" => "m/s2", "d" => "accel", "ts" => true },
                   "cam" => { "t" => 4, "e" => 17 }, "odd" => {} }, got)
    pl = MessagePack.pack({ "a" => {} })
    assert_equal ["n", "a", { "a" => {} }], Asterism::Pubs.parse("asterism/n/a/@pubs", pl)
    assert_nil Asterism::Pubs.parse("asterism/n/a/@status", pl)
  end

  def test_topic_names
    assert_equal "imu", Asterism.check_topic_name(:imu)
    assert_equal "board1/strokes", Asterism.check_topic_name("board1/strokes")
    ["", "/a", "a/", "a//b", "a/*", "a/@x", "a/$b", "a?", "#", 5].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { Asterism.check_topic_name(bad) }
    end
  end

  def test_profile_parts
    assert_equal %w[status pubs], Asterism.app_profile_parts(nil)
    assert_equal %w[status pubs], Asterism.app_profile_parts("")
    assert_equal %w[status pubs], Asterism.app_profile_parts("x=1")
    assert_equal %w[types], Asterism.app_profile_parts("types")
    assert_equal %w[pubs types], Asterism.app_profile_parts("pubs;x;types;pubs")
    assert_equal %w[status], Asterism.app_profile_parts("status=1")
  end

  # Sequence numbers as a subscription reads them (docs/protocol.md 9.4).
  def test_reading_sequence_numbers
    sub = Asterism::Subscription.new("n/a/x", nil, nil)
    att = ->(*a) { MessagePack.pack(a) }
    s = ->(seq, key: "asterism/n/a/x", time: nil) do
      a = time ? att.(seq, time) : att.(seq)
      v, info = sub.unwrap(FakeSample.new(key, MessagePack.pack(seq), a, :put, "zenoh/bytes", nil))
      [v, info.seq, info.lost, info.restarted?]
    end
    assert_equal [5, 5, 0, false], s.(5), "the first: nothing lost (it may not start at 0)"
    assert_equal [6, 6, 0, false], s.(6)
    assert_equal [9, 9, 2, false], s.(9), "7 and 8 missed"
    assert_equal [2, 2, 2, true], s.(2), "back to 2: a restart, 0 and 1 of the new run missed"
    assert_equal [0, 0, 0, false], s.(0, key: "asterism/n/a/y"), "per key"
    max = Asterism::Topic::SEQ_MAX
    assert_equal [max - 1, max - 1, 0, false], s.(max - 1, key: "asterism/n/a/w")
    assert_equal [1, 1, 2, false], s.(1, key: "asterism/n/a/w"), "wrapped: max and 0 missed"
    sub2 = Asterism::Subscription.new("n/a/x", nil, nil)
    sub2.unwrap(FakeSample.new("asterism/n/a/x", MessagePack.pack(1), att.(max), :put, "zenoh/bytes", nil))
    _, info = sub2.unwrap(FakeSample.new("asterism/n/a/x", MessagePack.pack(1), att.(0), :put, "zenoh/bytes", nil))
    assert_equal [0, false], [info.lost, info.restarted?], "max then 0: the wrap, nothing lost"
    _, info = sub2.unwrap(FakeSample.new("asterism/n/a/x", MessagePack.pack(1), att.(0), :put, "zenoh/bytes", nil))
    assert_equal [0, true], [info.lost, info.restarted?], "the same number again: a restart"

    # The rest of the info, and what is not a value.
    v, info = sub.unwrap(FakeSample.new("asterism/n/a/b/c", "\xff\xd8".b, att.(3, 1_700_000_000_123), :put,
                                        "image/jpeg", nil))
    assert_equal "\xff\xd8".b, v
    assert_equal ["n", "a", "b/c", "n/a/b/c", 3, 1_700_000_000_123, "image/jpeg"],
                 [info.node, info.app, info.name, info.path, info.seq, info.time, info.encoding]
    v, info = sub.unwrap(FakeSample.new("asterism/n/a/z", MessagePack.pack(nil), nil, :put, "zenoh/bytes", nil))
    assert_equal [nil, nil, nil, 0, "msgpack"], [v, info.seq, info.time, info.lost, info.encoding]
    assert_nil sub.unwrap(FakeSample.new("asterism/n/a/z", "\xc1".b, nil, :put, "zenoh/bytes", nil))
    assert_nil sub.unwrap(FakeSample.new("asterism/n/a/z", "", nil, :delete, "zenoh/bytes", nil))
    assert_equal 1, sub.malformed
    _, info = sub.unwrap(FakeSample.new("asterism/n/a/z", MessagePack.pack(1), att.("x"), :put, nil, nil))
    assert_nil info.seq, "an attachment that is not [seq, ...]"
  end

  def test_publish_needs_a_connection
    assert_raises(Asterism::Disconnected) { Asterism.publish("x") }
    assert_raises(Asterism::Disconnected) { Asterism.subscribe("a/b/c") { nil } }
  end

  # ------------------------------------------------------------ two processes

  # The other process: node "child", app "t" with three topics and a type
  # defined before connecting. Lines on stdin: "imu", "cam", "strokes"
  # put one value; "skip N" makes the imu topic skip N numbers; "wrap"
  # puts it near the end of the numbers; "drop" withdraws the camera;
  # "again" publishes imu again (its numbers start over).
  CHILD = <<~'RUBY'
    require "asterism"
    loc = ARGV[0]
    Asterism.define_type("t/stroke", [["pts", "int[]"], ["color", "str"]], desc: "one stroke")
    if ARGV[1] == "router"
      Asterism.connect(loc, node: "child", app: "t")
    else
      Asterism.connect(nil, node: "child", app: "t", mode: :peer, listen: loc)
    end
    imu = Asterism.publish("imu", type: :vector3, unit: "m/s2", desc: "accel", ts: true)
    strokes = Asterism.publish("board1/strokes", type: "t/stroke")
    cam = Asterism.publish("camera", type: :image, encoding: "image/jpeg")
    STDOUT.puts "ready"
    STDOUT.flush
    loop do
      Asterism.poll
      r, = IO.select([STDIN], nil, nil, 0.002)
      next unless r
      line = STDIN.gets
      break if line.nil?
      cmd, arg = line.strip.split(" ", 2)
      case cmd
      when "imu" then imu.put([1.5, -2, 9.8])
      when "cam" then cam.put("\xff\xd8\xff\xe0JFIF\xff\xd9".b)
      when "strokes" then strokes.put({ "pts" => [1, 2, 3], "color" => "red" })
      when "skip" then arg.to_i.times { imu.advance }
      when "wrap" then imu.instance_variable_set(:@seq, Asterism::Topic::SEQ_MAX)
      when "drop" then cam.close
      when "again" then imu = Asterism.publish("imu", type: :vector3, unit: "m/s2", desc: "accel", ts: true)
      end
      STDOUT.puts "done #{cmd}"
      STDOUT.flush
    end
    Asterism.close
  RUBY

  def test_topics_between_two_processes
    if (router = TestHelper.router)
      loc = router
      mode = "router"
    else
      loc = "tcp/127.0.0.1:#{TestHelper.free_port}"
      mode = "peer"
    end
    lib = [File.expand_path("../lib", __dir__), TestHelper.zenoh_lib].compact
    child = IO.popen([RbConfig.ruby, *lib.flat_map { |l| ["-I", l] }, "-e", CHILD, loc, mode], "r+")
    assert_equal "ready", child.gets&.strip
    if router
      Asterism.connect(loc, node: "parent", app: "t")
    else
      Asterism.connect(loc, node: "parent", app: "t", mode: :peer)
    end
    assert wait_for { Asterism.poll; Asterism.apps.include?("child/t") }
    cmd = ->(c) { child.puts c; assert_equal "done #{c.split.first}", child.gets&.strip }

    # The declarations, by the application's profile.
    pubs = { "imu" => { "t" => 2, "u" => "m/s2", "d" => "accel", "ts" => true },
             "board1/strokes" => { "t" => "t/stroke" }, "camera" => { "t" => 4, "e" => 17 } }
    assert_equal pubs, Asterism.pubs_of("child", "t")
    types = { "t/stroke" => { "f" => [["pts", "int[]"], ["color", "str"]], "d" => "one stroke" } }
    assert_equal types, Asterism.types_of("child", "t")
    assert_nil Asterism.status_of("child", "t"), "no status set"
    s = Asterism.session
    ask = lambda do |params|
      replies = []
      g = s.get("asterism/child/t/@profile", timeout_ms: 800, params: params)
      wait_for(2) { Asterism.poll; replies.concat(g.each_reply); g.done? }
      replies.map { |k, pl| [k, MessagePack.unpack(pl)] }
    end
    assert_equal [["asterism/child/t/@profile", { "pubs" => pubs }]], ask.(nil), "no status: left out"
    assert_equal [["asterism/child/t/@profile", { "types" => types }]], ask.("types")
    assert_equal [["asterism/child/t/@profile", { "pubs" => pubs, "types" => types }]], ask.("pubs;types")
    assert_equal [["asterism/child/t/@profile", {}]], ask.("status")
    assert_nil Asterism.pubs_of("child", "nothing", timeout: 0.5)
    # This application's own, without the network: nothing yet.
    assert_equal({}, Asterism.pubs_of("parent", "t"))
    assert_equal({}, Asterism.types_of("parent", "t"))

    got = []
    plain = []
    sub = Asterism.subscribe("child/t/**") { |v, info| got << [v, info] }
    Asterism.subscribe("child/t/imu") { |v| plain << v }
    pubs_puts = s.subscribe("asterism/*/*/@pubs")
    raw = s.subscribe("asterism/child/t/**")
    sleep 0.3 # the subscriptions reach the other side
    cmd.("imu")
    cmd.("cam")
    cmd.("strokes")
    cmd.("imu")
    assert wait_for { Asterism.poll; got.size >= 4 }
    v, info = got[0]
    assert_equal [1.5, -2, 9.8], v
    assert_equal ["child", "t", "imu", 0, "msgpack", 0, false], [info.node, info.app, info.name, info.seq,
                                                                  info.encoding, info.lost, info.restarted?]
    assert_kind_of Integer, info.time
    assert_in_delta Time.now.to_f * 1000, info.time, 5000, "the sender's time, ms since 1970"
    v, info = got[1]
    assert_equal "\xff\xd8\xff\xe0JFIF\xff\xd9".b, v, "the bytes as they are, no MessagePack"
    assert_equal ["camera", 0, "image/jpeg", nil], [info.name, info.seq, info.encoding, info.time]
    v, info = got[2]
    assert_equal({ "pts" => [1, 2, 3], "color" => "red" }, v)
    assert_equal ["board1/strokes", "asterism/child/t/board1/strokes", 0, nil], [info.name, info.key, info.seq, info.time]
    assert_equal [1, 0], [got[3][1].seq, got[3][1].lost]
    assert_equal [[1.5, -2, 9.8], [1.5, -2, 9.8]], plain, "a block with |v| gets the value"

    # On the wire: no encoding for MessagePack, the attachment [seq] / [seq, ms].
    samples = raw.each_sample
    assert_equal 4, samples.size
    assert_equal ["zenoh/bytes", "image/jpeg", "zenoh/bytes", "zenoh/bytes"], samples.map(&:encoding)
    assert_equal [0, 0, 0, 1], samples.map { MessagePack.unpack(_1.attachment)[0] }
    assert_equal [2, 1, 1, 2], samples.map { MessagePack.unpack(_1.attachment).size }
    assert_equal MessagePack.pack([1.5, -2, 9.8]), samples[0].payload

    # Lost values, the wrap and a restart.
    cmd.("skip 3")
    cmd.("imu")
    assert wait_for { Asterism.poll; got.size >= 5 }
    assert_equal [5, 3, false], [got[4][1].seq, got[4][1].lost, got[4][1].restarted?]
    cmd.("wrap")
    cmd.("imu")
    cmd.("imu")
    assert wait_for { Asterism.poll; got.size >= 7 }
    # A jump of more than half the numbers reads as a restart.
    assert_equal [Asterism::Topic::SEQ_MAX, Asterism::Topic::SEQ_MAX, true],
                 [got[5][1].seq, got[5][1].lost, got[5][1].restarted?]
    assert_equal [0, 0, false], [got[6][1].seq, got[6][1].lost, got[6][1].restarted?], "the wrap"
    cmd.("again")
    cmd.("imu")
    assert wait_for { Asterism.poll; got.size >= 8 }
    assert_equal [0, 0, true], [got[7][1].seq, got[7][1].lost, got[7][1].restarted?], "published again: a restart"

    # @pubs: put again when publish replaces imu (the same declarations:
    # nothing), and when the camera goes.
    cmd.("drop")
    seen = []
    assert wait_for { Asterism.poll; seen.concat(pubs_puts.each_pending); seen.any? }
    parsed = seen.map { |k, pl| Asterism::Pubs.parse(k, pl) }
    assert_equal [["child", "t", pubs.reject { |k, _| k == "camera" }]], parsed
    assert_equal pubs.reject { |k, _| k == "camera" }, Asterism.pubs_of("child", "t")

    # close: nothing more comes.
    sub.close
    assert sub.closed?
    n = got.size
    np = plain.size
    cmd.("imu")
    assert wait_for { Asterism.poll; plain.size > np }, "the other subscription still gets them"
    assert_equal n, got.size

    # This application's own topics and the CRuby API.
    t = Asterism.publish("echo/x", desc: "mine")
    assert_equal({ "echo/x" => { "d" => "mine" } }, Asterism.pubs_of("parent", "t"))
    assert_equal ["echo/x"], Asterism.published
    assert_raises(ArgumentError) { Asterism.publish("x", encoding: "zenoh/bytes") }
    assert_raises(ArgumentError) { Asterism.publish("x", encoding: "application/msgpack") }
    assert_raises(ArgumentError) { Asterism.publish("x", ts: 1) }
    assert_raises(Asterism::EncodeError) { t.put(Object.new) }
    raw_cam = Asterism.publish("raw", encoding: "image/png")
    assert_raises(ArgumentError) { raw_cam.put([1]) }
    assert Asterism.unpublish("raw")
    assert raw_cam.closed?
    assert_raises(Asterism::Disconnected) { raw_cam.put("x") }
    net = Asterism.net
    q = Queue.new
    net.subscribe("child/t/imu") { |v, info| q << [v, info.seq] }
    errors = Queue.new
    net.on_error { |e, where| errors << [e.message, where] }
    net.subscribe("child/t/imu") { |_v| raise "boom" }
    net.start
    sleep 0.3
    cmd.("imu")
    assert_equal [[1.5, -2, 9.8], 2], Timeout.timeout(3) { q.pop }
    assert_equal ["boom", "subscribe"], Timeout.timeout(3) { errors.pop }
    net.stop
    Asterism.close
    assert t.closed?, "the topics end with the connection"
    assert_raises(Asterism::Disconnected) { t.put(1) }
  ensure
    Asterism.close
    if child && !child.closed?
      child.close_write rescue nil
      child.read rescue nil
      child.close rescue nil
    end
  end
end
