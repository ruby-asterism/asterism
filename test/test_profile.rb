# Node profiles (0.5.0): the checks (no network), and asterism/<node>/@profile
# between two CRuby processes: the defaults, a change, icon: false, the
# notice put on the key, a node that does not answer (an older version), and
# answers whose icon is not acceptable.
require_relative "helper"
require "asterism"
require "rbconfig"
require "zlib"

class TestProfile < Minitest::Test
  include TestHelper

  ICON = File.binread(File.expand_path("../data/icon.png", __dir__))

  # A PNG with the given sides and an IDAT of filler bytes (the checks do
  # not inflate it).
  def self.png(w, h, idat = "x")
    chunk = ->(type, body) { [body.bytesize].pack("N") + type + body + [Zlib.crc32(type + body)].pack("N") }
    "\x89PNG\r\n\x1a\n".b + chunk.("IHDR", [w, h, 8, 6, 0, 0, 0].pack("NNC5")) + chunk.("IDAT", idat.b) +
      chunk.("IEND", "".b)
  end

  def crcs_adler(png)
    crcs = +"".b
    pos = 8
    while pos < png.bytesize
      len = png[pos, 4].unpack1("N")
      crcs << png[pos + 8 + len, 4]
      pos += 12 + len
    end
    format("%08x", Zlib.adler32(crcs))
  end

  # ------------------------------------------------------------ no network

  def test_png_info_and_hash
    w, h, hash = Asterism::Profile.png_info(ICON)
    assert_equal [32, 32], [w, h]
    assert_equal crcs_adler(ICON), hash
    assert_equal [256, 1, crcs_adler(self.class.png(256, 1))], Asterism::Profile.png_info(self.class.png(256, 1))
    other = self.class.png(32, 32, "y")
    refute_equal Asterism::Profile.png_info(self.class.png(32, 32))[2], Asterism::Profile.png_info(other)[2]
  end

  def test_png_info_refuses
    pi = ->(b) { Asterism::Profile.png_info(b) }
    assert_nil pi.("GIF89a" + ICON[6..])                        # not the signature
    assert_nil pi.(ICON[0..-2])                                  # cut short
    assert_nil pi.(ICON + "x")                                   # bytes after IEND
    assert_nil pi.(self.class.png(257, 1))                       # wider than 256
    assert_nil pi.(self.class.png(0, 1))
    assert_nil pi.(self.class.png(32, 32, "z" * 8200))           # more than 8 KB
    assert pi.(self.class.png(32, 32, "z" * (8192 - 57)))        # 8 KB exactly
    assert_nil pi.(self.class.png(32, 32, "z" * (8192 - 56)))
    assert_nil pi.(nil)
    assert_nil pi.(42)
  end

  def test_check_cleans_a_received_profile
    c = ->(h) { Asterism::Profile.check(h) }
    assert_nil c.(nil)
    assert_nil c.("cruby")
    assert_nil c.({ "name" => "no kind" })
    assert_nil c.({ "kind" => "Not a word" })
    assert_equal({ "kind" => "jruby" }, c.({ "kind" => "jruby", "extra" => 1 }))
    full = c.({ "kind" => "family_mruby", "host" => "sim", "name" => "Rover", "icon" => ICON.dup.force_encoding("UTF-8"),
                "icon_hash" => "00000000" })
    assert_equal %w[kind host name icon icon_hash], full.keys
    assert_equal Encoding::BINARY, full["icon"].encoding
    assert_equal Asterism::Profile.png_info(ICON)[2], full["icon_hash"], "the hash is the receiver's own"
    # An icon that is not a PNG, or too large, goes with its hash.
    assert_equal({ "kind" => "cruby" }, c.({ "kind" => "cruby", "icon" => "<svg/>", "icon_hash" => "12345678" }))
    big = self.class.png(32, 32, "z" * 9000)
    assert_equal({ "kind" => "cruby" }, c.({ "kind" => "cruby", "icon" => big }))
    # Without the icon (asked with icon=0), the hash stays when it is one.
    assert_equal({ "kind" => "cruby", "icon_hash" => "0a1b2c3d" }, c.({ "kind" => "cruby", "icon_hash" => "0a1b2c3d" }))
    assert_equal({ "kind" => "cruby" }, c.({ "kind" => "cruby", "icon_hash" => "XYZ" }))
    assert_equal({ "kind" => "cruby" }, c.({ "kind" => "cruby", "name" => "n" * 65, "host" => 3 }))
  end

  def test_profile_fields_and_defaults
    Asterism.instance_variable_set(:@profile_set, nil)
    Asterism.instance_variable_set(:@profile_icon, nil)
    p0 = Asterism.profile
    assert_equal "cruby", p0["kind"]
    assert_equal ICON, p0["icon"], "CRuby's default icon is the gem's data/icon.png"
    assert_equal Asterism::Profile.png_info(ICON)[2], p0["icon_hash"]
    refute p0.key?("host")
    p1 = Asterism.profile(name: "Lab PC", host: :lab, kind: :console)
    assert_equal({ "protocol" => 1, "kind" => "console", "host" => "lab", "name" => "Lab PC" }, p1.except("icon", "icon_hash"))
    assert_equal "Lab PC", Asterism.profile(kind: nil)["name"], "fields not given stay"
    assert_equal "cruby", Asterism.profile["kind"], "kind: nil goes back to the default"
    refute Asterism.profile(icon: nil).key?("icon_hash"), "icon: nil is no icon"
    other = self.class.png(16, 16)
    assert_equal Asterism::Profile.png_info(other)[2], Asterism.profile(icon: other)["icon_hash"]
    assert_raises(ArgumentError) { Asterism.profile(icon: "not a png") }
    assert_raises(ArgumentError) { Asterism.profile(icon: self.class.png(32, 32, "z" * 9000)) }
    assert_raises(ArgumentError) { Asterism.profile(icon: self.class.png(300, 300)) }
    assert_raises(ArgumentError) { Asterism.profile(kind: "CRuby") }
    assert_raises(ArgumentError) { Asterism.profile(name: "") }
    assert_raises(ArgumentError) { Asterism.profile(name: "n" * 65) }
    assert_raises(ArgumentError) { Asterism.profile(colour: "red") }
    assert_equal Asterism::Profile.png_info(other)[2], Asterism.profile["icon_hash"], "a refused change changes nothing"
    assert Asterism::Profile.wants_icon?(nil)
    assert Asterism::Profile.wants_icon?("x=1")
    refute Asterism::Profile.wants_icon?("icon=0")
    refute Asterism::Profile.wants_icon?("x=1;icon=no")
  ensure
    Asterism.instance_variable_set(:@profile_set, nil)
    Asterism.instance_variable_set(:@profile_icon, nil)
  end

  # ------------------------------------------------------------ two processes

  # The other process: node "child" with a profile of its own; a raw
  # queryable on the same session plays nodes whose answers are not
  # acceptable. Lines on stdin: "name <text>" changes the name, "icon"
  # changes the icon.
  CHILD = <<~'RUBY'
    require "asterism"
    require "zlib"
    loc = ARGV[0]
    Asterism.profile(name: "Child", host: "test")
    if ARGV[1] == "router"
      Asterism.connect(loc, node: "child", app: "t")
    else
      Asterism.connect(nil, node: "child", app: "t", mode: :peer, listen: loc)
    end
    s = Asterism.instance_variable_get(:@session)
    bad = s.queryable("asterism/*/@profile")
    png = lambda do |w, h, idat|
      chunk = ->(type, body) { [body.bytesize].pack("N") + type + body + [Zlib.crc32(type + body)].pack("N") }
      "\x89PNG\r\n\x1a\n".b + chunk.("IHDR", [w, h, 8, 6, 0, 0, 0].pack("NNC5")) + chunk.("IDAT", idat.b) +
        chunk.("IEND", "".b)
    end
    answers = {
      "svg" => { "kind" => "cruby", "icon" => "<svg onload='x'/>" },
      "big" => { "kind" => "cruby", "icon" => png.(32, 32, "z" * 9000) },
      "huge" => { "kind" => "cruby", "icon" => png.(1024, 1024, "z") },
      "junk" => "not a profile",
    }
    STDOUT.puts "ready"
    STDOUT.flush
    loop do
      Asterism.poll
      bad.each_pending do |q|
        name = q.key.split("/")[1]
        q.reply(q.key, MessagePack.pack(answers[name])) if answers.key?(name)
        q.finish
      end
      r, = IO.select([STDIN], nil, nil, 0.002)
      next unless r
      line = STDIN.gets
      break if line.nil?
      cmd, arg = line.strip.split(" ", 2)
      Asterism.profile(name: arg) if cmd == "name"
      Asterism.profile(icon: png.(8, 8, "i")) if cmd == "icon"
      STDOUT.puts "done #{cmd}"
      STDOUT.flush
    end
    Asterism.close
  RUBY

  def test_profiles_between_two_processes
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
    assert wait_for { Asterism.poll; Asterism.nodes.include?("child") }
    # The notices on the profile key (the console follows them).
    s = Asterism.instance_variable_get(:@session)
    notices = s.subscribe("asterism/*/@profile")

    pr = Asterism.profile_of("child")
    assert_equal({ "protocol" => 1, "kind" => "cruby", "host" => "test", "name" => "Child" }, pr.except("icon", "icon_hash"))
    assert_equal ICON, pr["icon"]
    assert_equal Asterism::Profile.png_info(ICON)[2], pr["icon_hash"]
    # On the wire the icon is a bin (msgpack-ruby reads a bin as ASCII-8BIT,
    # a str as UTF-8) and the protocol is told.
    wire = Asterism.profile_async("child", true, nil, nil).raw_value
    assert_equal Encoding::BINARY, wire["icon"].encoding
    assert_equal Encoding::UTF_8, wire["kind"].encoding
    assert_equal 1, wire["protocol"]
    without = Asterism.profile_of("child", icon: false, timeout: 1.5)
    assert_equal pr.except("icon"), without

    # Changes while connected are put on the key, without the icon.
    child.puts "name Renamed"
    assert_equal "done name", child.gets&.strip
    got = nil
    assert wait_for { Asterism.poll; got ||= notices.each_pending.find { |k, _| k == "asterism/child/@profile" } }
    told = Asterism::Profile.check(MessagePack.unpack(got[1]))
    assert_equal "Renamed", told["name"]
    refute told.key?("icon")
    assert_equal pr["icon_hash"], told["icon_hash"]
    child.puts "icon"
    assert_equal "done icon", child.gets&.strip
    again = Asterism.profile_of("child")
    refute_equal pr["icon_hash"], again["icon_hash"], "a new icon, a new hash"
    assert_equal [8, 8], Asterism::Profile.png_info(again["icon"])[0, 2]

    # This node's own profile, without the network.
    assert_equal Asterism.profile, Asterism.profile_of("parent")

    # Not answered (an older version, a ROS 2 node): nil, at once when
    # nobody answers that key.
    t = Time.now
    assert_nil Asterism.profile_of("old", timeout: 1.0)
    assert Time.now - t < 1.5
    # Answers that are not acceptable: the icon is dropped, or the whole.
    assert_equal({ "kind" => "cruby" }, Asterism.profile_of("svg"))
    assert_equal({ "kind" => "cruby" }, Asterism.profile_of("big"))
    assert_equal({ "kind" => "cruby" }, Asterism.profile_of("huge"))
    assert_nil Asterism.profile_of("junk")
    assert_raises(ArgumentError) { Asterism.profile_of("a/b") }

    # The CRuby API: net.profile_of waits for the receiving thread's ticks.
    net = Asterism.net
    net.start
    assert_equal "Renamed", net.profile_of("child", icon: false)["name"]
    assert_equal "Lab", net.profile(name: "Lab")["name"]
    net.stop
  ensure
    Asterism.close
    Asterism.instance_variable_set(:@profile_set, nil)
    Asterism.instance_variable_set(:@profile_icon, nil)
    if child && !child.closed?
      child.close_write rescue nil
      child.read rescue nil
      child.close rescue nil
    end
  end
end
