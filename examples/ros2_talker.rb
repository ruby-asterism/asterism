# CRuby as a ROS 2 node (rmw_zenoh): publishes geometry_msgs/Twist on
# /cmd_vel and calls an example_interfaces/AddTwoInts service.
#
#   ruby examples/ros2_talker.rb --router tcp/192.168.10.2:7447
#        [--count 5] [--service /fmruby_service_fmruby_04a774/add_two_ints]
#
# ROS 2 sees the node as /cruby_talker: `ros2 topic echo /cmd_vel`, and a
# board running fmruby-core's ros2_types shows the Twist in its window. The
# service call is what `ros2 service call <service> AddTwoInts "{a: .., b: ..}"`
# does; without --service the first AddTwoInts server in the ROS graph
# (from the liveliness tokens) is used.
$LOAD_PATH.unshift(File.expand_path("../asterism-zenoh/lib", __dir__), File.expand_path("../asterism/lib", __dir__))
require "asterism"
require "optparse"

opt = { router: "tcp/127.0.0.1:7447", count: 5, service: nil, name: "cruby_talker", calls: 10 }
OptionParser.new do |o|
  o.on("--router LOC") { |v| opt[:router] = v }
  o.on("--count N", Integer, "Twist messages (one a second)") { |v| opt[:count] = v }
  o.on("--service NAME") { |v| opt[:service] = v }
  o.on("--calls N", Integer, "service calls") { |v| opt[:calls] = v }
  o.on("--name NODE") { |v| opt[:name] = v }
end.parse!

def log(text)
  puts "#{Time.now.strftime('%H:%M:%S.%L')} #{text}"
  $stdout.flush
end

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

session = Asterism::Zenoh::Session.open(opt[:router])
node = Asterism::ROS::Node.new(session, opt[:name])
twist = Asterism::ROS.require_type("geometry_msgs/msg/Twist")
add = Asterism::ROS.require_type("example_interfaces/srv/AddTwoInts")
pub = node.publisher("/cmd_vel", twist)
log("node /#{opt[:name]} on #{opt[:router]} (zid #{session.zid})")

# Wait a little so that subscribers (ros2 topic echo, boards) see the
# publisher before the first message.
t = now
node.poll while now - t < 1.0

opt[:count].times do |i|
  msg = { linear: { x: 0.5 + i, y: -0.25 }, angular: { z: 1.25 } }
  pub << msg
  log("published /cmd_vel #{msg.inspect}")
  t = now
  while now - t < 1.0
    node.poll
    sleep 0.01
  end
end

service = opt[:service]
if service.nil?
  # The first AddTwoInts server (SS token) in the graph.
  g = session.liveliness_get("@ros2_lv/0/**")
  t = now
  until g.done? || now - t > 2
    sleep 0.01
  end
  g.each_reply.each do |key, _payload, _att|
    parts = key.split("/")
    next unless parts[5] == "SS" && parts[10] == add::TYPE_NAME
    service ||= parts[9].tr("%", "/")
  end
end
if service
  cli = node.client(service, add)
  times = []
  opt[:calls].times do |i|
    t = now
    res = cli.call(a: i, b: 10 * i, timeout_ms: 3000)
    took = ((now - t) * 1000).round(1)
    times << took
    log("#{service}: #{i} + #{10 * i} = #{res.sum} (#{took} ms)")
  end
  s = times.sort
  log("#{times.size} calls: min #{s.first} ms, median #{s[s.size / 2]} ms, max #{s.last} ms") unless s.empty?
else
  log("no AddTwoInts server in the graph (--service to name one)")
end
node.close
session.close
