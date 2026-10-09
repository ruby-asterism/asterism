# The MuJoCo rover as Asterism objects: CRuby runs the physics (MuJoCo's C
# library through Fiddle, lib/mujoco.rb) in real time and exposes the robot
# on the network as node "mujoco", app "rover". Boards, CRuby and
# asterism-console drive it by calling these objects; ROS 2 is not used.
#
#   ruby examples/mujoco/fetch.rb                                  # once
#   ruby examples/mujoco/rover.rb --router tcp/127.0.0.1:7447 [--node mujoco]
#   ruby examples/mujoco/rover.rb --bench 5                        # mj_step as fast as it goes
#
# Objects (mujoco/rover/<object>):
#   drive.cmd(v, w, by: nil)  forward speed v (m/s) and turn rate w (rad/s,
#                             left positive); turned into the two wheel
#                             speeds. The robot stops 0.5 s after the last
#                             command. The last command wins, whoever sent
#                             it; by: names the sender (shown in state).
#                             Returns {"v", "w"} as accepted (clamped)
#   drive.stop                at once (with the acceleration limit)
#   state.pose                the simulator's true pose {"x", "y", "z", "yaw", "yaw_deg"}
#   state.odom                the pose from the wheel angles, as a robot would know it
#   state.imu                 {"quat" [w,x,y,z], "gyro" [x,y,z] rad/s, "accel" [x,y,z] m/s^2}
#   state.speed               {"v", "w" measured, "cmd_v", "cmd_w" asked, "out_v", "out_w" after
#                             the acceleration limit, "wheels" [l, r] rad/s, "driver", "age" s}
#   state.all                 all of the above and "t" (simulated seconds), the
#                             Hash that is also put on the state key
#   world.reset               back to the start (the robot at the origin facing +x)
#   world.objects             the pillars and boxes: [{"name", "type", "pos", "size", "yaw_deg"}]
#   world.info                MuJoCo's version, the timestep, steps per second, CPU
#
# The state Hash is also put 10 times a second on asterism/<node>/rover/state
# (MessagePack) for plots and recordings (asterism-console).
#
# Like the S1 rover over ROS 2, the wheel speeds are limited in acceleration
# (0.5 m/s^2, 2 rad/s^2): a step in the speed makes the velocity servos spin
# the wheels on the floor, and the odometry then runs ahead of the robot.
$LOAD_PATH.unshift(File.expand_path("lib", __dir__),
                   File.expand_path("../../lib", __dir__),
                   File.join(ENV["ASTERISM_ZENOH_DIR"] || File.expand_path("../../../asterism-zenoh", __dir__), "lib"))
require "mujoco"
require "optparse"

opt = { router: "tcp/127.0.0.1:7447", node: "mujoco", model: File.expand_path("model/scene.xml", __dir__),
        bench: nil, state_hz: 10.0, report: 10.0 }
OptionParser.new do |o|
  o.on("--router LOC") { |v| opt[:router] = v }
  o.on("--node ID", "Asterism node ID (default mujoco)") { |v| opt[:node] = v }
  o.on("--model XML", "the scene (default model/scene.xml)") { |v| opt[:model] = v }
  o.on("--bench SECONDS", Float, "only measure mj_step, no network") { |v| opt[:bench] = v }
  o.on("--state-hz HZ", Float, "how often the state key is put (default 10)") { |v| opt[:state_hz] = v }
  o.on("--report SECONDS", Float, "print the rates this often (default 10)") { |v| opt[:report] = v }
end.parse!

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
def cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)

def log(text)
  puts "#{Time.now.strftime('%H:%M:%S.%L')} #{text}"
  $stdout.flush
end

def yaw_of(w, x, y, z) = Math.atan2(2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z))

def wrap(a)
  a -= 2 * Math::PI while a > Math::PI
  a += 2 * Math::PI while a < -Math::PI
  a
end

def r6(x) = x.round(6)

# The robot in the simulator: wheels, odometry, sensors. Not thread safe;
# everything runs on the main loop (the objects are called from
# Asterism.poll there).
class Rover
  WHEEL_RADIUS = 0.05
  WHEEL_SEPARATION = 0.24
  ACCEL_V = 0.5          # m/s^2
  ACCEL_W = 2.0          # rad/s^2
  MAX_V = 1.0            # m/s
  MAX_W = 3.0            # rad/s
  CMD_TIMEOUT = 0.5      # s
  CONTROL_STEPS = 5      # physics steps per control update (2 ms x 5 = 100 Hz)

  attr_reader :model, :data, :steps, :driver

  def initialize(lib, path)
    @model = MuJoCo::Model.load_xml(lib, path)
    @data = MuJoCo::Data.new(@model)
    m = @model
    @act_l = m.id(:actuator, "left_wheel_joint")
    @act_r = m.id(:actuator, "right_wheel_joint")
    @q_l = m.read(:jnt_qposadr, m.id(:joint, "left_wheel_joint"))[0]
    @q_r = m.read(:jnt_qposadr, m.id(:joint, "right_wheel_joint"))[0]
    @v_l = m.read(:jnt_dofadr, m.id(:joint, "left_wheel_joint"))[0]
    @v_r = m.read(:jnt_dofadr, m.id(:joint, "right_wheel_joint"))[0]
    free = m.id(:joint, "floating_base_joint")
    raise MuJoCo::Error, "floating_base_joint is not a free joint" unless m.read(:jnt_type, free)[0] == MuJoCo::Layout::JNT[:free]

    @q_base = m.read(:jnt_qposadr, free)[0]
    @s_quat, @s_gyro, @s_accel = %w[imu_sensor_quat imu_sensor_gyro imu_sensor_accel].map do |n|
      m.read(:sensor_adr, m.id(:sensor, n))[0]
    end
    @steps = 0
    reset
  end

  def reset
    @data.reset
    @cmd = [0.0, 0.0]          # asked (v, w)
    @out = [0.0, 0.0]          # after the acceleration limit
    @cmd_at = nil              # monotonic time of the last command
    @driver = nil
    @odom = [0.0, 0.0, 0.0]
    @wheel_prev = wheel_angles
    @meas = [0.0, 0.0]
    apply
    true
  end

  # drive.cmd: the last command wins.
  def command(v, w, by)
    v = v.to_f.clamp(-MAX_V, MAX_V)
    w = w.to_f.clamp(-MAX_W, MAX_W)
    who = by.nil? ? "?" : by.to_s
    log("driver: #{who} (was #{@driver || '-'})") if who != @driver
    @driver = who
    @cmd = [v, w]
    @cmd_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    { "v" => v, "w" => w }
  end

  def stop(by = nil)
    @cmd = [0.0, 0.0]
    @cmd_at = nil
    @driver = by.to_s if by
    true
  end

  def time = @data.time

  # Simulated seconds since start, through resets (paces the main loop).
  def clock = @steps * @model.timestep

  # One control period: the acceleration limit, the wheel speeds, the
  # physics, the odometry.
  def control(now)
    @cmd = [0.0, 0.0] if @cmd_at && now - @cmd_at > CMD_TIMEOUT
    dt = CONTROL_STEPS * @model.timestep
    @out[0] = ramp(@out[0], @cmd[0], ACCEL_V * dt)
    @out[1] = ramp(@out[1], @cmd[1], ACCEL_W * dt)
    apply
    @data.step(CONTROL_STEPS)
    @steps += CONTROL_STEPS
    odometry(dt)
  end

  def pose
    x, y, z, qw, qx, qy, qz = @data.read(:qpos, @q_base, 7)
    yaw = yaw_of(qw, qx, qy, qz)
    { "x" => r6(x), "y" => r6(y), "z" => r6(z), "yaw" => r6(yaw), "yaw_deg" => (yaw * 180 / Math::PI).round(3) }
  end

  def odom
    x, y, yaw = @odom
    { "x" => r6(x), "y" => r6(y), "yaw" => r6(yaw), "yaw_deg" => (yaw * 180 / Math::PI).round(3) }
  end

  def imu
    s = @data.read(:sensordata, 0, @model.nsensordata)
    { "quat" => s[@s_quat, 4].map { r6(_1) }, "gyro" => s[@s_gyro, 3].map { r6(_1) },
      "accel" => s[@s_accel, 3].map { r6(_1) } }
  end

  def speed(now)
    wl = @data.read(:qvel, @v_l)[0]
    wr = @data.read(:qvel, @v_r)[0]
    { "v" => r6(@meas[0]), "w" => r6(@meas[1]), "cmd_v" => @cmd[0], "cmd_w" => @cmd[1],
      "out_v" => r6(@out[0]), "out_w" => r6(@out[1]), "wheels" => [r6(wl), r6(wr)],
      "driver" => @driver, "age" => @cmd_at ? (now - @cmd_at).round(3) : nil }
  end

  def all(now)
    { "t" => time.round(4), "pose" => pose, "odom" => odom, "speed" => speed(now), "imu" => imu }
  end

  # The named geoms of the world body other than the floor.
  def objects
    m = @model
    (0...m.ngeom).filter_map do |g|
      name = geom_name(g)
      next if name.nil? || name == "floor"

      type = MuJoCo::Layout::GEOM.key(m.read(:geom_type, g)[0]).to_s
      xm = @data.read(:geom_xmat, 9 * g, 9)
      { "name" => name, "type" => type, "pos" => @data.read(:geom_xpos, 3 * g, 3).map { r6(_1) },
        "size" => m.read(:geom_size, 3 * g, 3).map { r6(_1) },
        "yaw_deg" => (Math.atan2(xm[3], xm[0]) * 180 / Math::PI).round(2) }
    end
  end

  def close
    @data.close
    @model.close
  end

  private

  WORLD_GEOMS = %w[floor pillar_red pillar_green pillar_blue pillar_yellow box_purple box_cyan].freeze

  # mj_name2id the other way round would need mj_id2name; the scene's
  # world geoms are known by name, so look them up once.
  def geom_name(g)
    @geom_names ||= WORLD_GEOMS.to_h do |n|
      [@model.id(:geom, n), n]
    rescue MuJoCo::Error
      [nil, n]
    end
    @geom_names[g]
  end

  def ramp(cur, target, step)
    return target if (target - cur).abs <= step

    cur + (target > cur ? step : -step)
  end

  def apply
    v, w = @out
    half = w * WHEEL_SEPARATION / 2.0
    @data.write(:ctrl, @act_l, (v - half) / WHEEL_RADIUS)
    @data.write(:ctrl, @act_r, (v + half) / WHEEL_RADIUS)
  end

  def wheel_angles = [@data.read(:qpos, @q_l)[0], @data.read(:qpos, @q_r)[0]]

  # Dead reckoning from the wheel angles, as diff_drive_controller does.
  def odometry(dt)
    l, r = wheel_angles
    dl = (l - @wheel_prev[0]) * WHEEL_RADIUS
    dr = (r - @wheel_prev[1]) * WHEEL_RADIUS
    @wheel_prev = [l, r]
    ds = (dl + dr) / 2.0
    dyaw = (dr - dl) / WHEEL_SEPARATION
    x, y, yaw = @odom
    mid = yaw + dyaw / 2.0
    @odom = [x + ds * Math.cos(mid), y + ds * Math.sin(mid), wrap(yaw + dyaw)]
    @meas = [ds / dt, dyaw / dt]
  end
end

lib = MuJoCo::Lib.open
log("MuJoCo #{lib.version} (#{lib.path})")
rover = Rover.new(lib, opt[:model])
m = rover.model
log("model #{opt[:model]}: nq #{m.nq} nv #{m.nv} nu #{m.nu} nbody #{m.nbody} ngeom #{m.ngeom} " \
    "nsensordata #{m.nsensordata}, timestep #{m.timestep} s")

if opt[:bench]
  t0 = mono
  c0 = cpu
  n = 0
  while mono - t0 < opt[:bench]
    rover.data.step(100)
    n += 100
  end
  dt = mono - t0
  log(format("bench: %d mj_step in %.2f s = %.0f steps/s (%.0fx real time at %.3f s a step), CPU %.0f %%",
             n, dt, n / dt, n / dt * m.timestep, m.timestep, (cpu - c0) / dt * 100))
  rover.close
  exit
end

require "asterism"

# The objects: thin, each method a call into the rover.
class Drive
  def initialize(rover) = @rover = rover
  def cmd(v, w, by: nil) = @rover.command(v, w, by)
  def stop(by: nil) = @rover.stop(by)
end

class State
  def initialize(rover) = @rover = rover
  def pose = @rover.pose
  def odom = @rover.odom
  def imu = @rover.imu
  def speed = @rover.speed(mono)
  def all = @rover.all(mono)
end

class World
  def initialize(rover, stats)
    @rover = rover
    @stats = stats
  end

  def reset
    log("world.reset")
    @rover.reset
  end

  def objects = @rover.objects
  def info = @stats.merge("mujoco" => MuJoCo::Layout::VERSION, "timestep" => @rover.model.timestep)
end

stats = { "steps_per_s" => nil, "cpu_percent" => nil, "realtime" => nil }
Asterism.connect(opt[:router], node: opt[:node], app: "rover")
Asterism.expose("drive", Drive.new(rover), methods: { cmd: 2, stop: 0 })
Asterism.expose("state", State.new(rover), methods: { pose: 0, odom: 0, imu: 0, speed: 0, all: 0 })
Asterism.expose("world", World.new(rover, stats), methods: { reset: 0, objects: 0, info: 0 })
# The state key goes out through a session of its own (the object layer's
# session is internal to Asterism).
pub_session = Asterism::Zenoh::Session.open(opt[:router])
state_key = "asterism/#{opt[:node]}/rover/state"
log("#{opt[:node]}/rover on #{opt[:router]}: drive, state, world; state on #{state_key} at #{opt[:state_hz]} Hz")

running = true
trap("INT") { running = false }
trap("TERM") { running = false }

POLL_STEP = 0.002
t0 = mono
sim0 = rover.clock
next_state = t0
win = { t: t0, cpu: cpu, steps: rover.steps, sim: rover.clock, late: 0, polls: 0, poll_s: 0.0 }
begin
  while running
    now = mono
    # Keep the simulated clock on the wall clock: catch up by at most 0.1 s
    # (after a stall the simulation slows instead of racing).
    target = now - t0
    behind = target - (rover.clock - sim0)
    if behind > 0.1
      win[:late] += 1
      sim0 = rover.clock - target + 0.1
    end
    rover.control(now) while rover.clock - sim0 < target

    p0 = mono
    break unless Asterism.poll

    win[:poll_s] += mono - p0
    win[:polls] += 1
    if now >= next_state
      pub_session.put(state_key, MessagePack.pack(rover.all(now)))
      next_state += 1.0 / opt[:state_hz]
      next_state = now if next_state < now
    end

    if now - win[:t] >= opt[:report]
      dt = now - win[:t]
      stats["steps_per_s"] = ((rover.steps - win[:steps]) / dt).round(1)
      stats["cpu_percent"] = ((cpu - win[:cpu]) / dt * 100).round(1)
      stats["realtime"] = ((rover.clock - win[:sim]) / dt).round(4)
      log(format("%.1f steps/s (sim %.4fx real time), CPU %.1f %%, %d polls (%.2f ms avg), %d catch-ups, driver %s",
                 stats["steps_per_s"], stats["realtime"], stats["cpu_percent"], win[:polls],
                 win[:polls].zero? ? 0 : win[:poll_s] / win[:polls] * 1000, win[:late], rover.driver || "-"))
      win = { t: now, cpu: cpu, steps: rover.steps, sim: rover.clock, late: 0, polls: 0, poll_s: 0.0 }
    end
    # Wait while the simulation is ahead of the wall clock (less than one
    # control period), answering calls every POLL_STEP meanwhile: a call
    # then waits about 2 ms here instead of up to a control period.
    loop do
      nap = (rover.clock - sim0) - (mono - t0)
      break unless nap.positive?

      sleep([nap, POLL_STEP].min)
      p0 = mono
      running &&= Asterism.poll
      win[:poll_s] += mono - p0
      win[:polls] += 1
    end
  end
ensure
  log("closing")
  Asterism.close
  pub_session&.close
  rover.close
end
