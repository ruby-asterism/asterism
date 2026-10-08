# Checks the installed asterism and asterism-zenoh gems (run by CI after
# `gem install --local` of both, from outside the repository and without
# -I): that `require "asterism"` loads the installed gems, that the bundled
# message types are found, and that the Ruby-like API gets a put through
# between two sessions over a local peer link. Not one of the `rake test`
# files (those run against the repository's lib/).
#
#   ruby test/installed_check.rb
require "socket"
require "asterism"

def check(cond, what)
  abort "installed_check: FAILED: #{what}" unless cond
  puts "ok: #{what}"
end

%w[asterism asterism-zenoh].each do |name|
  spec = Gem.loaded_specs[name]
  check(spec, "#{name} #{spec&.version} loaded as a gem")
end
here = File.expand_path("..", __dir__)
check(!$LOADED_FEATURES.grep(%r{/asterism\.rb\z}).first.to_s.start_with?(here),
      "asterism.rb from the installed gem, not from this checkout")
check(Asterism::Zenoh::C_VERSION == "1.10.1", "zenoh-c #{Asterism::Zenoh::C_VERSION}")

twist = Asterism::ROS.require_type("geometry_msgs/msg/Twist")
check(twist, "bundled type geometry_msgs/msg/Twist")

srv = TCPServer.new("127.0.0.1", 0)
port = srv.addr[1]
srv.close
loc = "tcp/127.0.0.1:#{port}"
a = Asterism::Zenoh::Connection.new(Asterism::Zenoh::Session.open(nil, mode: :peer, listen: loc))
b = Asterism::Zenoh::Connection.new(Asterism::Zenoh::Session.open(loc, mode: :peer))
begin
  got = Queue.new
  a.subscribe("installed/check/**") { |s| got << s }
  a.start
  sample = nil
  20.times do
    b.put("installed/check/x", "hello")
    break if (sample = got.pop(timeout: 0.5))
  end
  check(sample && sample.key == "installed/check/x" && sample.text == "hello",
        "put / subscribe with a block: #{sample&.key} #{sample&.text.inspect}")
ensure
  b.close
  a.close
end
puts "installed_check: all ok (#{RUBY_DESCRIPTION})"
