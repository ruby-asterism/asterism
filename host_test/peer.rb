# The other side of host_test/test_session.rb (rake test:mruby runs it as
# its own process): a plain Zenoh session that listens and does what the
# test asks on keys under ctl/:
#
#   ctl/token/<key...>   payload "1": declare a liveliness token on <key>,
#                        "0": withdraw it
#   ctl/odom             publish the payload on the ROS 2 topic /g1b/odom
#   ctl/stop             end (the test's connection is lost)
#
# Whatever comes on g1b/** is put back on seen/<the rest>.
#
#   mruby -r msgpack.rb peer.rb PORT MSGS_DIR
port = ARGV[0]
Asterism::ROS::TYPE_PATH.replace([ARGV[1]])
s = Asterism::Zenoh::Session.open(nil, mode: :peer, listen: "tcp/127.0.0.1:#{port}")
ctl = s.subscribe("ctl/**", depth: 64)
g1b = s.subscribe("g1b/**")
node = Asterism::ROS::Node.new(s, "rover")
odom = node.publisher("/g1b/odom", "std_msgs/msg/String")
tokens = {}
puts "ready"
stop = false
deadline = Time.now + 120
until stop || Time.now > deadline
  s.poll
  ctl.each_pending.each do |key, payload|
    if key == "ctl/stop"
      stop = true
    elsif key == "ctl/odom"
      odom.publish({ data: payload })
    elsif key.start_with?("ctl/token/")
      k = key[10, key.length]
      if payload == "1"
        tokens[k] ||= s.liveliness(k)
      else
        t = tokens.delete(k)
        t.close if t
      end
    end
  end
  g1b.each_pending.each { |key, payload| s.put("seen/#{key[4, key.length]}", payload) }
  usleep 1000
end
s.close
puts "peer done"
