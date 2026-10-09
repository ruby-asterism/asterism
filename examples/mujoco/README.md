# MuJoCo from CRuby: a rover as Asterism objects

CRuby runs the physics simulator [MuJoCo](https://mujoco.org) through its C
API, with Ruby's standard Fiddle (no C extension, no Python), and exposes a
small two-wheeled robot on the Asterism network. Boards (Family mruby),
other Ruby processes and asterism-console drive it by calling its objects;
ROS 2 is not involved.

This directory is an example, not part of the gem. `lib/mujoco.rb` is
written so that it could become a gem of its own later.

| File | |
|---|---|
| `MUJOCO_PIN` | the MuJoCo release used: version, archive, sha256 |
| `fetch.rb` | downloads that release into `vendor/` (gitignored) and checks its sha256 |
| `layout_gen.rb` | makes `lib/mujoco/layout_<version>.rb` from the release's headers (needs `cc`, once per MuJoCo version) |
| `lib/mujoco.rb` | the Fiddle wrapper: `MuJoCo::Lib`, `Model`, `Data` |
| `lib/mujoco/layout_3_15_0.rb` | generated: the struct offsets for MuJoCo 3.15.0 |
| `model/rover.xml`, `model/scene.xml` | the robot and its world (copies of family-mruby's `docker/mujoco/model`, MIT) |
| `rover.rb` | runs the simulation in real time and exposes the robot (node `mujoco`, app `rover`) |
| `drive.rb` | CRuby driver: a test drive (1 m, 90 degrees, odometry against the true pose) or the keyboard |

## Getting MuJoCo

MuJoCo's official prebuilt release for Linux x86_64 is downloaded on the
machine that runs `rover.rb`, pinned by version and sha256 (the same idea as
asterism-zenoh's zenoh-c), into `examples/mujoco/vendor/`:

```
ruby examples/mujoco/fetch.rb      # vendor/mujoco-3.15.0/lib/libmujoco.so.3.15.0
```

Nothing is installed system-wide and nothing is built. `MUJOCO_LIB=/path/to/libmujoco.so.3.15.0`
uses a library from elsewhere (it must be the same version). Checked with glibc 2.35
(Ubuntu 22.04 on WSL2); macOS and aarch64 are not pinned.
No GPU and no display are needed: nothing is rendered.

## Running it

From the root of this repository, with a zenohd router (family-mruby's
`docker compose up -d zenohd`, or any Zenoh 1.x router) and asterism-zenoh
built next to this repository (`../asterism-zenoh`, `rake compile`; or
`ASTERISM_ZENOH_DIR`):

```
ruby examples/mujoco/rover.rb --router tcp/127.0.0.1:7447     # the simulation, Ctrl-C stops it
ruby examples/mujoco/drive.rb --router tcp/127.0.0.1:7447     # test drive
ruby examples/mujoco/drive.rb --router tcp/127.0.0.1:7447 --keys
ruby examples/mujoco/rover.rb --bench 5                       # mj_step alone, as fast as it goes
```

`rover.rb` prints every 10 s the physics steps per second, how close the
simulated clock is to the wall clock, and its CPU use.

## The objects

Node `mujoco` (`--node`), app `rover`:

| Call | Returns |
|---|---|
| `drive.cmd(v, w, by: nil)` | forward speed `v` (m/s, at most 1.0) and turn rate `w` (rad/s, left positive, at most 3.0), turned into the two wheel speeds. Returns `{"v", "w"}` as taken. `by:` names the sender (shown in `state.speed`) |
| `drive.stop(by: nil)` | stops (with the acceleration limit) |
| `state.pose` | the true pose from the simulator: `{"x", "y", "z", "yaw", "yaw_deg"}` (m, rad, degrees) |
| `state.odom` | the pose from the wheel angles, as a real robot would know it: `{"x", "y", "yaw", "yaw_deg"}` |
| `state.imu` | `{"quat" [w, x, y, z], "gyro" [x, y, z] rad/s, "accel" [x, y, z] m/s^2}` |
| `state.speed` | `{"v", "w"}` from the odometry, `"cmd_v", "cmd_w"` asked, `"out_v", "out_w"` after the acceleration limit, `"wheels" [l, r]` rad/s, `"driver"`, `"age"` (s since the last command) |
| `state.all` | `{"t", "pose", "odom", "speed", "imu"}` in one call |
| `world.reset` | back to the start (origin, facing +x); the odometry starts again from 0 |
| `world.objects` | the pillars and boxes: `[{"name", "type", "pos", "size", "yaw_deg"}]` |
| `world.info` | the MuJoCo version, the timestep, steps per second, CPU (from the last report) |

The `state.all` Hash is also put 10 times a second on the key
`asterism/mujoco/rover/state` (MessagePack), for asterism-console's plots
and recordings (paths such as `pose.x`, `odom.yaw_deg`, `speed.wheels[0]`).

### Driving rules

- **The robot stops 0.5 s after the last command.** A driver sends
  `drive.cmd` again and again (the examples: 5 to 20 times a second) while
  it wants the robot to move.
- **The last command wins**, whoever sent it. A driver that has nothing to
  do sends nothing: `drive.stop` once when it comes to a stop, then quiet,
  so another driver can take over. Two drivers moving the robot at the same
  time alternate and the robot jerks (and its odometry slips); `rover.rb`
  logs each change of driver.
- Speeds change at most 0.5 m/s^2 and 2 rad/s^2, as the S1 robot's
  diff_drive_controller did: a step in the wheel speed makes the velocity
  servos spin the wheels on the floor, and the odometry then runs ahead of
  the robot.

## How the wrapper works

- `Fiddle.dlopen` on `libmujoco.so` and one `Fiddle::Function` per C
  function used: `mj_version`, `mj_versionString`, `mj_loadXML`,
  `mj_makeData`, `mj_step`, `mj_forward`, `mj_resetData`, `mj_name2id`,
  `mj_deleteData`, `mj_deleteModel`.
- `mjModel` and `mjData` are not described to Fiddle field by field. The
  wrapper reads, at byte offsets, the size fields (`nq`, `nv`, `nu`,
  `nbody`, `njnt`, `ngeom`, `nsite`, `nsensor`, `nsensordata`), the timestep
  and the array pointers it needs (`jnt_type`, `jnt_qposadr`, `jnt_dofadr`,
  `geom_type`, `geom_size`, `sensor_dim`, `sensor_adr` of the model;
  `time`, `qpos`, `qvel`, `ctrl`, `sensordata`, `xpos`, `xquat`,
  `geom_xpos`, `geom_xmat` of the data), then the values in the arrays.
- **The offsets come from the release's own headers.** `layout_gen.rb`
  compiles a small C program against `vendor/mujoco-<tag>/include` that
  prints `offsetof()` of each field (and has the compiler check each
  field's C type: `mjtSize`, `mjtNum`, `mjtNum*`, `int*`), and writes the
  table to `lib/mujoco/layout_<version>.rb`. Nothing is counted by hand.
- **Checks**: `MuJoCo::Lib.open` refuses a library whose `mj_version()` and
  `mj_versionString()` are not those the layout was made for
  (`MuJoCo::VersionMismatch`). The layout does move between minor
  versions: from 3.14.0 to 3.15.0 `mjModel` shrank from 5696 to 5656 bytes
  (`sensor_adr` moved from 5120 to 5080). After loading, the sizes must be
  small and positive and the timestep sensible, and after `mj_forward` the
  clock must read 0 and the world body the origin with the identity
  orientation; otherwise `MuJoCo::Error`.
- One thread per `Model` / `Data`. `rover.rb` runs everything (physics,
  Asterism polling, the state key) on its main thread with the portable
  API (`Asterism.poll`), so the objects are called between physics steps.

### Updating MuJoCo

1. In `MUJOCO_PIN`, set the tag, the asset, its sha256 (from the release
   page) and `header_version` (`mjVERSION_HEADER` of the new `mujoco.h`).
2. `ruby examples/mujoco/fetch.rb && ruby examples/mujoco/layout_gen.rb`
   (writes `lib/mujoco/layout_<new>.rb`; a field whose type changed stops
   the compile).
3. Point the `require_relative` in `lib/mujoco.rb` at the new layout,
   delete the old one, and run `rover.rb --bench 2` and `drive.rb`.

## License

The files here are Asterism's (MIT). MuJoCo is Copyright DeepMind
Technologies Limited, under the Apache License 2.0; it is not in this
repository: `fetch.rb` downloads the official release, which carries its
`LICENSE` and `THIRD_PARTY_NOTICES` (in `vendor/mujoco-<tag>/`). The offsets
in `lib/mujoco/layout_*.rb` are numbers computed from MuJoCo's headers, not
copies of them.
