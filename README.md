# Asterism for CRuby

Asterism joins Ruby on PCs, boards (mruby / PicoRuby, Family mruby) and ROS 2
into one Zenoh network. This repository holds the CRuby side, as two gems:

| Directory | Gem / require | What |
|---|---|---|
| `asterism-zenoh/` | `asterism-zenoh` / `require "asterism/zenoh"` | `Asterism::Zenoh`: a C extension over the prebuilt zenoh-c 1.10.1, with the Ruby API of the boards' zenoh-pico binding ([README](asterism-zenoh/README.md)) |
| `asterism/` | `asterism` / `require "asterism"` | The pure Ruby layers: remote objects (`Asterism.connect` / `expose` / `[]` / `poll`), `Asterism::CDR`, `Asterism::ROS` (rmw_zenoh topics and services), the bundled ROS 2 message types, and the type generator |

Neither is published yet (local builds only).

## Build and test

Needs CRuby 3.2+, a C compiler, `curl`, `unzip`, and the msgpack gem
(`gem install msgpack`). No Rust: zenoh-c is the official prebuilt release.

```
rake                  # zenoh_c:fetch, compile, test
rake zenoh_c:fetch    # download the release pinned in ZENOH_C_PIN to vendor/zenoh-c (sha256 checked)
rake compile          # build asterism-zenoh/lib/asterism/asterism_zenoh.so (+ libzenohc.so)
rake test             # two CRuby sessions over a local peer link; no router needed
ASTERISM_TEST_ROUTER=tcp/127.0.0.1:7447 rake test   # the same through a zenohd router
rake sync             # copy the pure Ruby layers from fmruby-core (FMRUBY_CORE)
rake sync:check       # the copies must match fmruby-core byte for byte
```

Without installing the gems, put both `lib` directories on the load path:
`ruby -I asterism-zenoh/lib -I asterism/lib your_script.rb` (the examples
do it themselves).

## The shared Ruby layers

For now the pure Ruby code lives in fmruby-core
(`lib/add/picoruby-asterism/mrblib/`, the types in
`flash/usr/share/asterism/msgs/`, the generator in
`lib/add/picoruby-asterism/tools/asterism_msggen.rb`). `rake sync` copies them
to `asterism/lib/asterism/shared/`, `asterism/data/msgs/` and
`asterism/tools/`, and records the fmruby-core commit in
`asterism/SYNCED_FROM`. The copies are never edited here; what CRuby needs
on top is in `asterism/lib/asterism/cruby.rb`:

- `Asterism::ROS::TYPE_PATH` is the gem's `data/msgs`.
- MessagePack packs every String as str (compatibility mode): the boards'
  MessagePack does not read the bin type that CRuby's msgpack uses for
  binary Strings.

## Examples

```
# objects: join the app "demo" of fmruby-core's asterism_demo, call a board,
# and answer its calls (its keys s / a call screen.say / apu.play here)
ruby examples/node.rb --router tcp/192.168.10.2:7447 [--peer fmruby-04a774]

# ROS 2: geometry_msgs/Twist on /cmd_vel, then AddTwoInts calls
ruby examples/ros2_talker.rb --router tcp/192.168.10.2:7447 [--service NAME]
```

The router is the zenohd 1.10.1 of the family-mruby parent repository
(`docker-compose.yml`, with `docker-compose.zenoh-lan.yml` for boards on
WiFi and `docker-compose.ros2.yml` for ROS 2 Jazzy with rmw_zenoh).
