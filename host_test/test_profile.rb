# The mruby test of node profiles (rake test:mruby): the checks on mruby
# (MRB_UTF8_STRING, as on the boards), the defaults with a default icon
# file, and asterism/<node>/@profile against node.rb in another process.
#
#   mruby -r msgpack.rb test_profile.rb PORT ICON_FILE
#
# Prints one line per failed check and a summary; exits with 1 on failure.
port = ARGV[0]
icon_file = ARGV[1]
Asterism.deprecations = :raise
$checks = 0
$fails = 0

def check(cond, what)
  $checks += 1
  return if cond
  $fails += 1
  puts "FAIL: #{what}"
end

def raises(klass, what)
  yield
  check(false, "#{what}: nothing raised")
rescue klass
  check(true, what)
rescue => e
  check(false, "#{what}: #{e.class}: #{e.message} instead of #{klass}")
end

ICON = File.open(icon_file, "r") { |f| f.read }
P = Asterism::Profile

# --- the checks
info = P.png_info(ICON)
check(info && info[0] == 32 && info[1] == 32, "png_info sides: #{info.inspect}")
check(info && info[2].length == 8, "icon_hash is 8 hex digits")
# A multi-byte character in front of the bytes must not move them (UTF-8 strings).
check(P.png_info("\xC3\xA9" + ICON).nil?, "not at the signature")
check(P.png_info(ICON + "x").nil?, "bytes after IEND")
check(P.png_info(ICON[0, 40]).nil?, "cut short")
check(P.check({ "kind" => "cruby", "icon" => "<svg/>" }) == { "kind" => "cruby" }, "svg dropped")
check(P.check({ "kind" => "Bad" }).nil?, "a kind that is not a word")
full = P.check({ "kind" => "family_mruby", "host" => "sim", "name" => "R", "icon" => ICON })
check(full && full["icon_hash"] == info[2], "check keeps a good icon")

# --- the defaults: kind picoruby, the icon from default_icon_path
module Asterism
  def self.default_icon_path
    ARGV[1]
  end
end
pr = Asterism.profile
check(pr["kind"] == "picoruby", "default kind on mruby: #{pr['kind']}")
check(pr["icon_hash"] == info[2], "default icon read from the file")
pr = Asterism.profile(kind: :family_mruby, host: "sim")
check(pr["kind"] == "family_mruby" && pr["host"] == "sim", "kind and host set")
pr = Asterism.profile(name: "app")
check(pr["host"] == "sim" && pr["name"] == "app", "fields merge")
raises(ArgumentError, "an icon that is not a PNG") { Asterism.profile(icon: "nope") }
raises(ArgumentError, "an unknown field") { Asterism.profile(colour: 1) }
check(Asterism.profile(icon: nil)["icon_hash"].nil?, "icon: nil is no icon")

# --- over the network, from node.rb
Asterism.connect("tcp/127.0.0.1:#{port}", node: "mtest", app: "t", mode: :peer)
t = Time.now
until Asterism.nodes.include?("mnode") || Time.now - t > 5
  Asterism.poll
  usleep 2000
end
check(Asterism.nodes.include?("mnode"), "mnode seen")
other = Asterism.profile_of("mnode")
check(other && other["kind"] == "picoruby" && other["host"] == "host_test" && other["name"] == "mruby node",
      "profile_of: #{other.inspect[0, 120]}")
check(other && other["icon"] == ICON && other["icon_hash"] == info[2], "the icon came whole")
check(other && other["protocol"] == 2, "the other node speaks protocol 2")
check(other && other["icon"].encoding == "ASCII-8BIT", "the icon came as a bin (a binary String)")
check(MessagePack.pack(Asterism::Profile.binary("\x89PNG")).getbyte(0) == 0xc4,
      "an icon's bytes are a binary String (sent as a bin)")
small = Asterism.profile_of("mnode", icon: false, timeout: 1.5)
check(small && small["icon"].nil? && small["icon_hash"] == info[2], "icon: false leaves the bytes out")
s = Asterism.session
s.put("test/name", "renamed")
t = Time.now
renamed = nil
while Time.now - t < 3
  Asterism.poll
  renamed = Asterism.profile_of("mnode", icon: false)
  break if renamed && renamed["name"] == "renamed"
  usleep 20000
end
check(renamed && renamed["name"] == "renamed", "a change shows")
check(Asterism.profile_of("nobody", timeout: 1.0).nil?, "nil when nobody answers")
own = Asterism.profile_of("mtest")
check(own && own["kind"] == "family_mruby" && own["name"] == "app", "own profile without the network")

# --- statuses (status.rb), on mruby and from node.rb
S = Asterism::Status
check(S.check({ "a" => 1, 5 => 2 }) == { "a" => 1 }, "status check drops a non-str key")
check(S.check([1]).nil?, "status check: not a map")
check(S.check({ "big" => "x" * 1100 }).nil?, "status check: too large")
check(Asterism.status(tables: 3) == { "tables" => 3 }, "status set: #{Asterism.status.inspect}")
check(Asterism.status(humans: 1) == { "tables" => 3, "humans" => 1 }, "status fields merge")
check(Asterism.status({ "x" => [1, { "y" => nil }] }) == { "x" => [1, { "y" => nil }] }, "a Hash is the whole status")
raises(ArgumentError, "status: too deep") { Asterism.status(d: [[[[[1]]]]]) }
raises(ArgumentError, "status: too large") { Asterism.status(big: "x" * 1100) }
raises(ArgumentError, "status: not a Hash") { Asterism.status([1]) }
check(Asterism.status_of("mtest", "t") == { "x" => [1, { "y" => nil }] }, "own status without the network")
check(Asterism.apps.include?("mnode/t") && Asterism.apps("mtest/*") == ["mtest/t"], "apps: #{Asterism.apps.inspect}")
st = Asterism.status_of("mnode", "t")
check(st == { "n" => 1, "st" => "wait" }, "status_of: #{st.inspect}")
notices = s.subscribe("asterism/*/*/@status")
t = Time.now
Asterism.poll while Time.now - t < 0.3
s.put("test/status", "2")
got = nil
t = Time.now
while got.nil? && Time.now - t < 3
  Asterism.poll
  notices.each_pending { |k, pl| got = S.parse(k, pl) if k == "asterism/mnode/t/@status" }
  usleep 2000
end
check(got == ["mnode", "t", { "n" => 2, "st" => "wait" }], "a status change is put: #{got.inspect}")
s.put("test/status", "2")
t = Time.now
again = 0
while Time.now - t < 0.5
  Asterism.poll
  notices.each_pending { |k, _| again += 1 if k == "asterism/mnode/t/@status" }
  usleep 2000
end
check(again == 0, "the same status again puts nothing (#{again})")
check(Asterism.status_of("mnode", "nothing", timeout: 1.0).nil?, "no status: nil")

# --- topics (topic.rb), on mruby and from node.rb
check(Asterism::Types.number(:vector3) == 2, "a built-in type's number")
check(Asterism::Types.definition!([["pts", "int[]"], ["at", :vector3]], "d") ==
      { "f" => [["pts", "int[]"], ["at", 2]], "d" => "d" }, "a definition")
raises(ArgumentError, "an array of a built-in type") { Asterism::Types.definition!([["a", "vector3[]"]], nil) }
check(Asterism::Pubs.encoding_id("image/jpeg") == 17 && Asterism::Pubs.encoding_id("video/vp9") == 52,
      "encoding numbers")
check(Asterism::Pubs.check({ "a" => { "t" => 2, "x" => 1 }, 5 => {} }) == { "a" => { "t" => 2 } }, "pubs check")
raises(ArgumentError, "a topic name with a wildcard") { Asterism.publish("a/*") }
raises(ArgumentError, "encoding zenoh/bytes") { Asterism.publish("a", encoding: "zenoh/bytes") }
# Sequence numbers as a subscription reads them (a stand-in for a sample).
class FakeSample
  attr_reader :key, :payload, :attachment, :kind, :encoding, :timestamp
  def initialize(key, seq)
    @key = key
    @payload = MessagePack.pack(seq)
    @attachment = MessagePack.pack([seq])
    @kind = :put
    @encoding = "zenoh/bytes"
    @timestamp = nil
  end
end
fs = Asterism::Subscription.new("x", nil, nil)
lost = [5, 6, 9, 2].map { |n| i = fs.unwrap(FakeSample.new("asterism/n/a/x", n))[1]; [i.lost, i.restarted?] }
check(lost == [[0, false], [0, false], [2, false], [2, true]], "lost and restarted: #{lost.inspect}")
fs.unwrap(FakeSample.new("asterism/n/a/w", Asterism::Topic::SEQ_MAX))
w = fs.unwrap(FakeSample.new("asterism/n/a/w", 0))[1]
check(w.lost == 0 && !w.restarted?, "the wrap")
pubs = Asterism.pubs_of("mnode", "t")
check(pubs == { "imu" => { "t" => 2, "u" => "m/s2", "ts" => true } }, "pubs_of: #{pubs.inspect}")
got = []
plain = []
Asterism.subscribe("mnode/t/imu") { |v, info| got << [v, info.seq, info.encoding, info.time.is_a?(Integer)] }
Asterism.subscribe("mnode/*/**") { |v| plain << v }
t = Time.now
Asterism.poll while Time.now - t < 0.3
s.put("test/imu", "7")
s.put("test/imu", "8")
t = Time.now
while got.size < 2 && Time.now - t < 3
  Asterism.poll
  usleep 2000
end
check(got == [[[1, 2, 7], 0, "msgpack", true], [[1, 2, 8], 1, "msgpack", true]], "values with |v, info|: #{got.inspect}")
check(plain == [[1, 2, 7], [1, 2, 8]], "values with |v|: #{plain.inspect}")
s.put("test/stop", "")
Asterism.poll
Asterism.close

puts "#{$checks} checks, #{$fails} failed"
exit($fails == 0 ? 0 : 1)
