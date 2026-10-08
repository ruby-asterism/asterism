# CRuby as a ROS 2 node (rmw_zenoh) with the Ruby-like API: publishes
# std_msgs/String on /chatter and geometry_msgs/Twist on /cmd_vel from
# timers, prints what comes on /chatter_in, serves AddTwoInts, and calls an
# AddTwoInts service.
#
#   ruby examples/ros2_talker.rb --router tcp/192.0.2.2:7447 [--seconds 10]
#        [--service /fmruby_service_fmruby_aaaaaa/add_two_ints]
#
# From ROS 2:
#   ros2 topic echo /chatter std_msgs/msg/String
#   ros2 topic pub /chatter_in std_msgs/msg/String "{data: hi}"
#   ros2 service call /cruby/add_two_ints example_interfaces/srv/AddTwoInts "{a: 1, b: 2}"
# A board running fmruby-core's ros2_types shows the Twist in its window.
# Without --service the first AddTwoInts server in the ROS graph (from the
# liveliness tokens) other than this node's own is called.
# This repository's lib, and asterism-zenoh's next to it (ASTERISM_ZENOH_DIR
# overrides; an installed asterism-zenoh gem works too).
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__),
                   File.join(ENV["ASTERISM_ZENOH_DIR"] || File.expand_path("../../asterism-zenoh", __dir__), "lib"))
require "asterism"
require "optparse"

opt = { router: "tcp/127.0.0.1:7447", seconds: 10, service: nil, name: "cruby_talker", calls: 5 }
OptionParser.new do |o|
  o.on("--router LOC") { |v| opt[:router] = v }
  o.on("--seconds S", Float, "how long to spin (Ctrl-C ends earlier)") { |v| opt[:seconds] = v }
  o.on("--service NAME") { |v| opt[:service] = v }
  o.on("--calls N", Integer, "service calls") { |v| opt[:calls] = v }
  o.on("--name NODE") { |v| opt[:name] = v }
end.parse!

def log(text)
  puts "#{Time.now.strftime('%H:%M:%S.%L')} #{text}"
  $stdout.flush
end

ADD = "example_interfaces/srv/AddTwoInts"

Asterism::ROS.connect(opt[:router]) do |ros|
  node = ros.node(opt[:name])
  log("node /#{opt[:name]} on #{opt[:router]} (zid #{ros.session.zid})")
  ros.on_error { |e, where| log("#{where}: #{e.class}: #{e.message}") }

  chatter = node.publisher("/chatter", "std_msgs/msg/String")
  cmd_vel = node.publisher("/cmd_vel", "geometry_msgs/msg/Twist")

  node.subscribe("/chatter_in", "std_msgs/msg/String") do |msg, info|
    log("/chatter_in ##{info&.sequence}: #{msg.data}")
  end
  node.subscribe("/cmd_vel_in", "geometry_msgs/msg/Twist") do |msg|
    case msg
    in { linear: { x: 0.0 }, angular: { z: 0.0 } }
      log("/cmd_vel_in: stop")
    in { linear: { x: }, angular: { z: } }
      log("/cmd_vel_in: forward #{x}, turn #{z}")
    end
  end
  node.service("/cruby/add_two_ints", ADD) do |req|
    log("/cruby/add_two_ints #{req.a} + #{req.b}")
    { sum: req.a + req.b }
  end

  n = 0
  node.every(1.0) do
    n += 1
    chatter << { data: "hello #{n} from Ruby" }
    cmd_vel << { linear: { x: 0.5 * n, y: -0.25 }, angular: { z: 1.25 } }
    log("published /chatter and /cmd_vel ##{n}")
  end

  ros.start # spin on a thread of its own; this thread makes service calls

  service = opt[:service]
  if service.nil?
    sleep 0.5 # let the graph's tokens arrive
    add_type = Asterism::ROS.require_type(ADD)
    own = "/cruby/add_two_ints"
    service = ros.zenoh.liveliness_get("@ros2_lv/0/**").filter_map do |key|
      parts = key.split("/")
      parts[9].tr("%", "/") if parts[5] == "SS" && parts[10] == add_type::TYPE_NAME
    end.reject { _1 == own }.first
  end
  if service
    opt[:calls].times do |i|
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      res = node.call(service, ADD, a: i, b: 10 * i, timeout: 3)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
      log("#{service}: #{i} + #{10 * i} = #{res.sum} (#{ms} ms)")
    end
  else
    log("no AddTwoInts server in the graph (--service to name one)")
  end

  ros.stop
  log("spinning on the main thread for #{opt[:seconds]} s (Ctrl-C ends)")
  Thread.new do
    sleep opt[:seconds]
    ros.stop
  end
  ros.spin
  log("done")
end
