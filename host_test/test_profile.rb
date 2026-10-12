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
s.put("test/stop", "")
Asterism.poll
Asterism.close

puts "#{$checks} checks, #{$fails} failed"
exit($fails == 0 ? 0 : 1)
