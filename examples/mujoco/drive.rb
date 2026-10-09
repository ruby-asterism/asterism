# Drive the MuJoCo rover (examples/mujoco/rover.rb) from CRuby by calling
# its Asterism objects: mujoco/rover/drive and mujoco/rover/state.
#
#   ruby examples/mujoco/drive.rb --router tcp/127.0.0.1:7447          # the test drive
#   ruby examples/mujoco/drive.rb --router tcp/127.0.0.1:7447 --keys   # the keyboard
#
# The test drive: world.reset, forward 1 m, then 90 degrees to the left on
# the spot, each stopped by the wheel odometry (state.odom); then the
# distance and the turn by the odometry and by the simulator's true pose
# (state.pose), side by side.
#
# Keys: w / x faster forward / backward, a / d turn left / right, s (or
# space) stop, r world.reset, q quit. While the command is not zero it is
# sent 10 times a second (the rover stops 0.5 s after the last one); a stop
# is sent once, so another driver can take over while this one is idle.
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__),
                   File.join(ENV["ASTERISM_ZENOH_DIR"] || File.expand_path("../../../asterism-zenoh", __dir__), "lib"))
require "asterism"
require "optparse"
require "io/console"

opt = { router: "tcp/127.0.0.1:7447", rover: "mujoco", keys: false, distance: 1.0, turn: 90.0, speed: 0.2,
        turn_speed: 0.6, name: "cruby_driver", no_reset: false }
OptionParser.new do |o|
  o.on("--router LOC") { |v| opt[:router] = v }
  o.on("--rover NODE", "the rover's node ID (default mujoco)") { |v| opt[:rover] = v }
  o.on("--keys", "drive with the keyboard") { opt[:keys] = true }
  o.on("--distance M", Float, "test drive: metres forward (default 1.0)") { |v| opt[:distance] = v }
  o.on("--turn DEG", Float, "test drive: degrees to the left (default 90)") { |v| opt[:turn] = v }
  o.on("--speed MPS", Float, "test drive: forward speed (default 0.2)") { |v| opt[:speed] = v }
  o.on("--name NODE", "this node's ID, also sent as by: (default cruby_driver)") { |v| opt[:name] = v }
  o.on("--no-reset", "test drive: start from where the rover is") { opt[:no_reset] = true }
end.parse!

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
def deg(rad) = rad * 180.0 / Math::PI

def angle_diff(a, b)
  d = a - b
  d -= 2 * Math::PI while d > Math::PI
  d += 2 * Math::PI while d < -Math::PI
  d
end

def line(s)
  p = s["pose"]
  o = s["odom"]
  format("pose x %6.3f y %6.3f %7.2f deg | odom x %6.3f y %6.3f %7.2f deg | v %5.2f w %5.2f",
         p["x"], p["y"], p["yaw_deg"], o["x"], o["y"], o["yaw_deg"], s["speed"]["v"], s["speed"]["w"])
end

Asterism.connect(opt[:router], node: opt[:name], app: "driver")
base = "#{opt[:rover]}/rover"
drive = Asterism["#{base}/drive"]
state = Asterism["#{base}/state"]
world = Asterism["#{base}/world"]
by = opt[:name]
begin
  info = world.info
rescue Asterism::Error => e
  abort "no rover at #{base} on #{opt[:router]} (#{e.class}: #{e.message})"
end
puts "rover #{base}: MuJoCo #{info['mujoco']}, timestep #{info['timestep']} s"

if opt[:keys]
  v = 0.0
  w = 0.0
  sent_stop = true
  puts "w/x forward/backward, a/d left/right, s stop, r reset, q quit"
  $stdin.raw do |io|
    loop do
      if io.wait_readable(0.1)
        case io.getc
        when "w" then v = [v + 0.05, 0.5].min.round(2)
        when "x" then v = [v - 0.05, -0.5].max.round(2)
        when "a" then w = [w + 0.2, 2.0].min.round(1)
        when "d" then w = [w - 0.2, -2.0].max.round(1)
        when "s", " " then v = w = 0.0
        when "r" then world.reset
        when "q", "\u0003" then break
        end
      end
      if v.zero? && w.zero?
        drive.stop(by: by) unless sent_stop
        sent_stop = true
      else
        drive.cmd(v, w, by: by)
        sent_stop = false
      end
      Asterism.poll
      print "\r#{format('cmd v %5.2f w %5.2f  ', v, w)}#{line(state.all)}\e[K"
    end
  end
  drive.stop(by: by)
  puts
else
  world.reset unless opt[:no_reset]
  sleep 0.5
  s0 = state.all
  puts "start:   #{line(s0)}"
  o0 = s0["odom"]
  p0 = s0["pose"]

  # Forward: slows down near the end, stops on the odometry.
  t = mono
  loop do
    o = state.odom
    left = opt[:distance] - Math.hypot(o["x"] - o0["x"], o["y"] - o0["y"])
    break if left <= 0.002

    drive.cmd([[opt[:speed], 1.0 * left].min, 0.03].max, 0.0, by: by)
    sleep 0.05
  end
  drive.stop(by: by)
  forward_s = mono - t
  sleep 1.0
  s1 = state.all
  puts "forward: #{line(s1)} (#{forward_s.round(2)} s)"

  # Turn left on the spot.
  target = opt[:turn] * Math::PI / 180.0
  o1 = s1["odom"]
  t = mono
  loop do
    o = state.odom
    left = target - angle_diff(o["yaw"], o1["yaw"]).abs
    break if left <= 0.002

    drive.cmd(0.0, [[opt[:turn_speed], 1.5 * left].min, 0.08].max, by: by)
    sleep 0.05
  end
  drive.stop(by: by)
  turn_s = mono - t
  sleep 1.0
  s2 = state.all
  puts "turn:    #{line(s2)} (#{turn_s.round(2)} s)"

  d_odom = Math.hypot(s1["odom"]["x"] - o0["x"], s1["odom"]["y"] - o0["y"])
  d_true = Math.hypot(s1["pose"]["x"] - p0["x"], s1["pose"]["y"] - p0["y"])
  a_odom = deg(angle_diff(s2["odom"]["yaw"], s1["odom"]["yaw"]))
  a_true = deg(angle_diff(s2["pose"]["yaw"], s1["pose"]["yaw"]))
  puts format("forward: odom %.4f m, true %.4f m (odom %+.2f %%)", d_odom, d_true, (d_odom - d_true) / d_true * 100)
  puts format("turn:    odom %.2f deg, true %.2f deg (odom %+.2f deg)", a_odom, a_true, a_odom - a_true)
end
Asterism.close
