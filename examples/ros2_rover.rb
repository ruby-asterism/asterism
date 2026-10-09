# CRuby driving a ROS 2 robot: sends geometry_msgs/Twist on /cmd_vel and
# shows nav_msgs/Odometry (/odom) and sensor_msgs/Imu (/imu). Made for the
# MuJoCo rover of family-mruby (docker-compose.mujoco.yml), which also
# publishes the simulator's true pose on /ground_truth/odom; any robot with
# a diff_drive_controller-like /cmd_vel and /odom works (without the ground
# truth the comparison is left out).
#
#   ruby examples/ros2_rover.rb --router tcp/127.0.0.1:7447            # the test drive
#   ruby examples/ros2_rover.rb --router tcp/127.0.0.1:7447 --keys     # drive with the keyboard
#
# The test drive: forward 1 m, then turn 90 degrees to the left on the
# spot, each stopped by the wheel odometry; then the distance and the turn
# by /odom and by the ground truth, side by side.
#
# Keys: w / x faster forward / backward, a / d turn left / right, s (or
# space) stop, q quit. The command is sent 10 times a second (the
# controller stops the robot after 0.5 s without one).
#
# This repository's lib, and asterism-zenoh's next to it (ASTERISM_ZENOH_DIR
# overrides; an installed asterism-zenoh gem works too).
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__),
                   File.join(ENV["ASTERISM_ZENOH_DIR"] || File.expand_path("../../asterism-zenoh", __dir__), "lib"))
require "asterism"
require "optparse"
require "io/console"

opt = { router: "tcp/127.0.0.1:7447", keys: false, distance: 1.0, turn: 90.0, name: "cruby_rover",
        speed: 0.2, turn_speed: 0.6 }
OptionParser.new do |o|
  o.on("--router LOC") { |v| opt[:router] = v }
  o.on("--keys", "drive with the keyboard") { opt[:keys] = true }
  o.on("--distance M", Float, "test drive: metres forward (default 1.0)") { |v| opt[:distance] = v }
  o.on("--turn DEG", Float, "test drive: degrees to the left (default 90)") { |v| opt[:turn] = v }
  o.on("--speed MPS", Float, "test drive: forward speed (default 0.2)") { |v| opt[:speed] = v }
  o.on("--name NODE") { |v| opt[:name] = v }
end.parse!

# A planar pose from an Odometry: [x, y, yaw]
def pose_of(odom)
  p = odom.pose.pose.position
  q = odom.pose.pose.orientation
  yaw = Math.atan2(2.0 * (q.w * q.z + q.x * q.y), 1.0 - 2.0 * (q.y * q.y + q.z * q.z))
  [p.x, p.y, yaw]
end

def angle_diff(a, b)
  d = a - b
  d -= 2 * Math::PI while d > Math::PI
  d += 2 * Math::PI while d < -Math::PI
  d
end

def deg(rad) = rad * 180.0 / Math::PI

state = { odom: nil, truth: nil, imu: nil, odom_n: 0, imu_n: 0 }
lock = Mutex.new

Asterism::ROS.connect(opt[:router]) do |ros|
  node = ros.node(opt[:name])
  ros.on_error { |e, where| warn "#{where}: #{e.class}: #{e.message}" }
  cmd = node.publisher("/cmd_vel", "geometry_msgs/msg/Twist")
  node.subscribe("/odom", "nav_msgs/msg/Odometry") do |m|
    lock.synchronize { state[:odom] = m; state[:odom_n] += 1 }
  end
  node.subscribe("/ground_truth/odom", "nav_msgs/msg/Odometry") do |m|
    lock.synchronize { state[:truth] = m }
  end
  node.subscribe("/imu", "sensor_msgs/msg/Imu") do |m|
    lock.synchronize { state[:imu] = m; state[:imu_n] += 1 }
  end
  ros.start # spin on a thread of its own

  send = ->(v, w) { cmd << { linear: { x: v }, angular: { z: w } } }
  now = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  snap = -> { lock.synchronize { state.dup } }

  status = lambda do |s|
    o = s[:odom] ? pose_of(s[:odom]) : nil
    i = s[:imu]
    line = o ? format("odom x %6.3f y %6.3f yaw %7.2f deg", o[0], o[1], deg(o[2])) : "odom -"
    if i
      line += format("  imu gyro.z %6.3f acc %6.2f %6.2f %6.2f", i.angular_velocity.z,
                     i.linear_acceleration.x, i.linear_acceleration.y, i.linear_acceleration.z)
    end
    line
  end

  t0 = now.call
  sleep 0.1 until snap.call[:odom] || now.call - t0 > 5
  abort "no /odom within 5 s (is the robot up on #{opt[:router]}?)" unless snap.call[:odom]
  puts "node /#{opt[:name]} on #{opt[:router]}"

  if opt[:keys]
    v = 0.0
    w = 0.0
    puts "w/x forward/backward, a/d left/right, s stop, q quit"
    $stdin.raw do |io|
      loop do
        if io.wait_readable(0.1)
          case io.getc
          when "w" then v = [v + 0.05, 0.5].min
          when "x" then v = [v - 0.05, -0.5].max
          when "a" then w = [w + 0.2, 2.0].min
          when "d" then w = [w - 0.2, -2.0].max
          when "s", " " then v = w = 0.0
          when "q", "\u0003" then break
          end
        end
        send.call(v, w)
        print "\r#{format('cmd v %5.2f w %5.2f  ', v, w)}#{status.call(snap.call)}\e[K"
      end
    end
    send.call(0.0, 0.0)
    puts
  else
    start = snap.call
    o0 = pose_of(start[:odom])
    g0 = start[:truth] && pose_of(start[:truth])
    puts "start: #{status.call(start)}"

    # Forward: slows down near the end, stops on the wheel odometry.
    t = now.call
    loop do
      o = pose_of(snap.call[:odom])
      left = opt[:distance] - Math.hypot(o[0] - o0[0], o[1] - o0[1])
      break if left <= 0.002
      send.call([[opt[:speed], 1.0 * left].min, 0.03].max, 0.0)
      sleep 0.05
    end
    send.call(0.0, 0.0)
    forward_s = now.call - t
    sleep 1.0
    mid = snap.call
    o1 = pose_of(mid[:odom])
    g1 = mid[:truth] && pose_of(mid[:truth])
    puts "after forward (#{forward_s.round(2)} s): #{status.call(mid)}"

    # Turn left on the spot.
    target = opt[:turn] * Math::PI / 180.0
    t = now.call
    loop do
      o = pose_of(snap.call[:odom])
      left = target - angle_diff(o[2], o1[2]).abs
      break if left <= 0.002
      send.call(0.0, [[opt[:turn_speed], 1.5 * left].min, 0.08].max)
      sleep 0.05
    end
    send.call(0.0, 0.0)
    turn_s = now.call - t
    sleep 1.0
    fin = snap.call
    o2 = pose_of(fin[:odom])
    g2 = fin[:truth] && pose_of(fin[:truth])
    puts "after turn (#{turn_s.round(2)} s): #{status.call(fin)}"

    d_odom = Math.hypot(o1[0] - o0[0], o1[1] - o0[1])
    a_odom = deg(angle_diff(o2[2], o1[2]))
    puts format("odom:         forward %.4f m, turn %.2f deg", d_odom, a_odom)
    if g0 && g1 && g2
      d_true = Math.hypot(g1[0] - g0[0], g1[1] - g0[1])
      a_true = deg(angle_diff(g2[2], g1[2]))
      drift = Math.hypot(g2[0] - g1[0], g2[1] - g1[1])
      puts format("ground truth: forward %.4f m, turn %.2f deg (moved %.4f m while turning)", d_true, a_true, drift)
      puts format("odom - truth: forward %+.4f m (%+.2f %%), turn %+.2f deg", d_odom - d_true,
                  100.0 * (d_odom - d_true) / d_true, a_odom - a_true)
    else
      puts "(no /ground_truth/odom: no comparison)"
    end
    s = snap.call
    puts "messages: /odom #{s[:odom_n]}, /imu #{s[:imu_n]}"
  end
  ros.stop
end
