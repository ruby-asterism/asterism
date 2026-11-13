# Asterism

Asterism joins Ruby on PCs, boards (mruby / PicoRuby) and ROS 2 into one
Zenoh network: Ruby objects on other machines are called like local ones,
and a Ruby program can be a ROS 2 node (rmw_zenoh's wire format). This
repository holds the pure Ruby layers, written once for every Ruby:

| Path | What |
|---|---|
| `mrblib/` | The layers: remote objects (`Asterism::Connection`), `Asterism::CDR`, `Asterism::ROS`. The source of truth for both forms below |
| `mrbgem.rake` | The mrbgem `picoruby-asterism` (mruby / PicoRuby): compiles `mrblib/` |
| `asterism.gemspec`, `lib/` | The CRuby gem `asterism`: `lib/asterism.rb` loads `mrblib/` as it is, `lib/asterism/cruby.rb` adds what CRuby needs, `lib/asterism/cruby/` the CRuby API (CRuby only) |
| `data/icon.png` | CRuby's default profile icon (32x32 PNG; [Profiles](#profiles)) |
| `data/msgs/` | ROS 2 message types generated from ROS 2 Jazzy's definitions (Apache-2.0; tf2_msgs BSD-3-Clause; see NOTICE) |
| `tools/` | The type generator `asterism_msggen.rb`, the Jazzy definitions it reads, `ros2_types.rb` (refreshes them from a ROS 2 image) |
| `exe/asterism`, `lib/asterism/cli*` | The command line: look at a network, call an object, an MCP server ([The command line](#the-command-line); CRuby only) |
| `test/` | `test/msgs` (types, CDR; CRuby only), `test_asterism.rb` (objects and ROS between CRuby sessions), `test_profile.rb` (node profiles), `test_status.rb` (application statuses), `test_meta_apps.rb` (the meta's args / doc, on_app_join / on_app_leave), `test_cli.rb` (the command line), `test_session.rb` (`Connection#session`, `on_join` / `on_leave`), `test_connections.rb` (several connections in one program), `test_api_*.rb` (the CRuby API), `bench_poll.rb` (`rake bench:poll`) |
| `test/protocol/` | the conformance samples of the wire protocol (`samples.json`), the driver that checks an implementation against them, and the Ruby node it checks (`rake test:protocol`, `rake test:protocol_mruby`; [docs/protocol.md](docs/protocol.md)) |
| `host_test/` | `rake test:mruby`: the shared layer on mruby (profiles between two mruby processes; `Connection#session`, `on_join` / `on_leave` and the time of a poll against `peer.rb`); with `rake test:cross`, topics with a CRuby node and several connections in one mruby program |
| `examples/` | CRuby: `node.rb` (objects with a board), `node_polled.rb` (the same with the portable API of the boards), `ros2_talker.rb` (topics, a timer, services with ROS 2), `ros2_rover.rb` (drive a ROS 2 robot: `/cmd_vel`, `/odom`, `/imu`), `zenoh.rb` (plain Zenoh), `mujoco/` (MuJoCo run from CRuby through Fiddle, its robot exposed as Asterism objects; see its README) |

The Zenoh binding underneath is a separate gem with the same Ruby API on
each Ruby:

- CRuby: [asterism-zenoh](https://github.com/ruby-asterism/asterism-zenoh)
  (over zenoh-c)
- mruby / PicoRuby: [picoruby-asterism-zenoh](https://github.com/ruby-asterism/picoruby-asterism-zenoh)
  (over zenoh-pico)

Which zenoh-c features the CRuby binding exposes (configuration and TLS,
scouting, publishers, queriers, the advanced publisher / subscriber,
events, key expressions, timestamps) and which zenoh-pico could offer is
in asterism-zenoh's
[feature coverage](https://github.com/ruby-asterism/asterism-zenoh/blob/main/docs/feature_coverage.md).
The ones added in 0.3.0 are CRuby only: the shared layer (`mrblib/`) does
not use them.

Both gems are on rubygems.org (`gem install asterism` installs
asterism-zenoh too). What changed in each version is in
[CHANGELOG.md](CHANGELOG.md); 0.4.0 is the first step toward 1.0
([docs/api_review.md](docs/api_review.md)) and only adds and deprecates
(see [Deprecations and 1.0](#deprecations-and-10)); 0.5.0 adds node
profiles ([Profiles](#profiles): what a node runs on, where, a name and an
icon); 0.6.0 adds the object layer's session
([The connection's session](#the-connections-session-netsession): for plain
Zenoh and ROS 2 too) and makes polling cheap when nothing changed. **0.7.0 speaks wire protocol 1 only**
([docs/protocol.md](docs/protocol.md)): it does not talk to the object
layer of earlier versions, so every node of a network moves to 0.7.0
together. It adds who called (`current_call`, `expose(...,
caller: :from)`; [Who called](#who-called)), the kind of a remote error
(`RemoteError#remote_kind`) and `proxy.asterism_call`. Protocol 2 adds
topics, types and an application's own profile ([Topics](#topics)), and
the connection becomes an object: `Asterism.connect` returns an
`Asterism::Connection`, whose methods are the whole API, and a program may
hold several ([Several connections](#several-connections)).

A mechanism-by-mechanism comparison with dRuby and Rinda is in
[docs/comparison.md](docs/comparison.md).

## Which API?

Asterism has two APIs over the same layers. Both are in the CRuby gem;
the boards have the first one only.

| You write for | Use | Why |
|---|---|---|
| A board, or code that must run on both | the **portable API** ([below](#the-portable-api): `net.poll`, `node.poll`, `each_pending`) | the only one on the boards; nothing runs behind your back |
| CRuby only (tools, servers, scripts) | the **CRuby API** ([The CRuby API](#the-cruby-api): `Asterism.connect { }`, `Asterism::Zenoh.open { }`, `Asterism::ROS.connect { }`) | blocks, a receiving thread, Enumerators, `Data` values |
| CRuby, but you own the loop (a game loop, a test) | the portable API | same as the boards |

Entry points and what they give:

| Call | Gives | Underneath |
|---|---|---|
| `Asterism::Zenoh::Session.open` | a `Session` (portable) | zenoh-c / zenoh-pico |
| `Asterism::Zenoh.open` | a `Zenoh::Connection` (CRuby) | `c.session` is the `Session` |
| `Asterism.connect` | an `Asterism::Connection` (portable: one application; a program may open several), also to the block (CRuby) | a `Session` of its own |
| `net.session` | that `Session` (portable), for put, subscribe and a ROS 2 node on the same connection; `net.zenoh` is it as a `Zenoh::Connection` (CRuby) | the connection's (its `close` closes it) |
| `Asterism::ROS::Node.new(session, ...)` | a `Node` (portable) | the `Session` given |
| `Asterism::ROS.connect` | a `ROS::Connection` (CRuby) | `ros.zenoh` is the `Zenoh::Connection` |

Units: a time with no unit in its name is seconds (`timeout:`,
`connect_timeout:`, `check_timeout:`, `node.every(0.5)`, `DEFAULT_TIMEOUT`);
anything else says its unit (`timeout_ms:`, `every(ms: 500)`, `took_ms`,
`DEFAULT_TIMEOUT_MS`, `stamp_ns`). Both units are accepted everywhere a
time is taken, on both APIs and every Ruby; giving one twice raises
`ArgumentError`.

## Using it

CRuby (needs CRuby 3.4+ and a C compiler):

```
gem install asterism          # also installs asterism-zenoh (>= 0.4.1, < 1.0) and msgpack
ruby -e 'require "asterism"'
```

`asterism-zenoh` compiles its C extension when it is installed and
downloads the prebuilt zenoh-c for the machine (x86_64 / aarch64 Linux,
glibc or musl; x86_64 / arm64 macOS), checked against a pinned sha256; see
its README for machines without network access. Linux needs glibc 2.34 or
newer (Ubuntu 22.04, Debian 12 and later) or musl; macOS is supported by the
build but not yet tested. To install from the repositories instead:

```
(cd ../asterism-zenoh && rake gem) && rake gem
gem install --local ../asterism-zenoh/pkg/asterism-zenoh-0.4.1.gem pkg/asterism-0.10.0.gem
```

From the working trees, without installing:

```
ruby -I lib -I ../asterism-zenoh/lib your_script.rb    # after `rake compile` in ../asterism-zenoh
```

`Asterism::ROS::TYPE_PATH` is `data/msgs` there; add your own directories.
MessagePack sends a binary (ASCII-8BIT) String as bin and any other String
as str (the wire protocol; [Values](#values)).

mruby / PicoRuby: add this repository and picoruby-asterism-zenoh as gems
(`conf.gem "path/to/asterism"`; a `MessagePack` module with `pack` /
`unpack` is needed too: for the wire protocol it must write a binary String
(`String#b`) as bin and read a bin as one, and refuse ext types, integers
outside int64 and bytes after the value), and put `data/msgs` on the device's file system at
`/usr/share/asterism/msgs` (or add the place to
`Asterism::ROS::TYPE_PATH`). Family mruby does this from pinned commits of
these repositories.

## Tests

```
rake                  # every suite
rake test:msgs        # generator, type hashes, CDR, bundled types (CRuby only; no Zenoh, no docker)
rake test:transfer    # files in pieces (Asterism::Transfer) over a stand-in for the calls: lost, repeated, swapped pieces, a connection down, a receiver started again
rake test:objects     # objects, profiles, statuses, topics, several connections in one program and Asterism::ROS between CRuby sessions
rake test:api         # the CRuby API (blocks, receiving threads, Enumerators)
rake test:cli         # the command line (exe/asterism), its Tab completion and its MCP bridge (the mcp gem's client; skipped without it)
ASTERISM_TEST_ROUTER=tcp/127.0.0.1:7447 rake test:objects test:api   # the same through a zenohd router
rake test:mruby       # the shared layer on mruby (builds mruby; not part of `rake`)
rake test:cross       # topics between an mruby node and a CRuby one, and several connections in one mruby program through a router (builds mruby; not part of `rake`)
rake test:protocol    # the wire protocol's conformance samples and driver against CRuby (docs/protocol.md)
rake test:protocol_mruby   # the same driver against mruby (builds mruby; not part of `rake`)
rake bench:poll       # the time and allocations of one Connection#poll by nodes and objects (prints a table)
```

`test:mruby` builds mruby with picoruby-asterism-zenoh and this gem
(MRB_UTF8_STRING, as on Family mruby's boards) and runs `host_test/`: two
mruby processes over a local peer link. It takes the mruby and zenoh-pico
pinned by a picoruby-asterism-zenoh checkout next to this one (its
`rake mruby:fetch zenoh:fetch`), or `PICORUBY_ASTERISM_ZENOH_DIR` /
`MRUBY_DIR`. A small MessagePack for the test is in
`host_test/msgpack.rb` (the boards bring their own).

`test:objects` and `test:api` need asterism-zenoh: built next to this repository
(`../asterism-zenoh`, its `rake compile`), or `ASTERISM_ZENOH_DIR`, or the
installed gem. The tests run with deprecated calls raising
(`Asterism.deprecations = :raise`); the tests of the old forms switch it
back around themselves.

## Examples

```
# objects: join the app "demo" of Family mruby's asterism_demo, call a board,
# and answer its calls (its keys s / a call screen.say / apu.play here)
ruby examples/node.rb --router tcp/192.0.2.2:7447 [--peer fmruby-aaaaaa]
ruby examples/node_polled.rb --router tcp/192.0.2.2:7447    # the same, polled

# ROS 2: /chatter and /cmd_vel from a timer, /chatter_in printed,
# /cruby/add_two_ints served, AddTwoInts calls
ruby examples/ros2_talker.rb --router tcp/192.0.2.2:7447 [--service NAME]

# ROS 2: drive a robot (made for family-mruby's MuJoCo rover,
# docker/asterism/docker-compose.mujoco.yml): 1 m forward and 90 degrees left by /odom,
# compared with /ground_truth/odom; or the keyboard
ruby examples/ros2_rover.rb --router tcp/192.0.2.2:7447 [--keys]

# MuJoCo from CRuby (Fiddle), the robot as objects mujoco/rover/{drive,state,world};
# the MuJoCo release is fetched into examples/mujoco/vendor (examples/mujoco/README.md)
ruby examples/mujoco/fetch.rb
ruby examples/mujoco/rover.rb --router tcp/192.0.2.2:7447
ruby examples/mujoco/drive.rb --router tcp/192.0.2.2:7447 [--keys]

# plain Zenoh: run two with different --name
ruby examples/zenoh.rb --router tcp/192.0.2.2:7447 --name pc1
```

## The CRuby API

On CRuby, `require "asterism"` also brings a layer with blocks, a receiving
thread, Enumerators and pattern matching (`lib/asterism/cruby/`). It is
built on the portable API below, which stays as it is: code written for a
board still runs unchanged on CRuby, and code using this layer does not run
on a board.

### Zenoh

```ruby
Asterism::Zenoh.open("tcp/192.0.2.2:7447") do |s|   # closed when the block ends
  s.subscribe("home/**") { |sample| puts "#{sample.key} = #{sample.payload}" }
  s.queryable("home/pc/status") { |q| q.reply("ok") }
  s.put("home/pc/hello", "hi")
  s.get("home/**/status").each { |reply| p reply }   # until every answer came or the time ran out
  sub = s.subscribe("sensor/temp")                    # no block: take from it
  sub.each.lazy.map { _1.payload.to_f }.first(3)      # waits for the samples
  s.liveliness_watch("asterism/**") { |key, alive| puts "#{key} #{alive}" }
  s.run                                               # receive on this thread until Ctrl-C
end

# asterism-zenoh 0.3.0 and later (CRuby only)
Asterism::Zenoh.open("tls/192.0.2.2:7447",
                     config: { "transport/link/tls/root_ca_certificate" => "ca.pem" }) do |s|
  pub = s.publisher("home/pc/temp", encoding: "text/plain", priority: :data_high)
  pub.on_matching { |listening| puts "listened to: #{listening}" }
  pub.put(21.5)
  s.delete("home/pc/old")
  s.subscribe("home/**") { |sm| p [sm.kind, sm.encoding, sm.timestamp&.to_time] }
  q = s.querier("home/**/status", timeout: 1.0)
  q.get(errors: true).each { |r| puts r.error? ? "error: #{r.payload}" : r.payload }
  latched = s.advanced_publisher("home/pc/mode", cache: 1, sample_miss_detection: true)
  latched.put("eco")                                 # late subscribers with history: get it
  s.advanced_subscriber("home/**/mode", history: true) { |sm| puts sm.payload }
  s.on_transport { |ev| puts "#{ev.zid} #{ev.kind}" }
  s.run
end
```

| Call | Notes |
|---|---|
| `Asterism::Zenoh.open(locator = nil, mode:, listen:, scouting:, timestamping:, config:, config_file:, connect_timeout:, interval: 0.002)` | `Session.open` wrapped in a `Connection`. With a block: yields it, closes it after (also on an exception), returns the block's value |
| `Connection.new(session)` | wraps a session opened with the portable API |
| `s.put(key, payload, attachment: nil, **opts)` | a payload that is not a String is sent as `to_s`. opts: `encoding:`, `priority:`, `congestion_control:`, `express:`, `reliability:`, `timestamp:`, `allowed_destination:` (asterism-zenoh's `Session#put`) |
| `s.delete(key, **opts)` | subscribers get a `Sample` of kind `:delete` |
| `s.publisher(key, **opts)` | a `Publisher`: `put(payload, attachment:, encoding:, timestamp:)`, `delete`, `matching?`, `on_matching { \|listening\| }` (on the receiving thread), `close`. With a block: yields it and closes it after |
| `s.advanced_publisher(key, cache:, sample_miss_detection:, publisher_detection:, **opts)` | the same `Publisher`, keeping the last samples for late subscribers (ROS 2's transient local) |
| `s.advanced_subscriber(key, depth: 16, history:, recovery:, query_timeout:, **opts) { \|sample\| }` | a `Subscription` that also gets the publishers' history; `on_publisher { \|key, alive\| }`, `on_miss { \|miss\| }` |
| `s.querier(key, timeout: 2.0, **opts)` (or `timeout_ms:`) | a `Querier`: `get(params:, payload:, attachment:, encoding:, errors: false)` like `s.get`, `matching?`, `on_matching`, `close` |
| `s.on_transport(history: false) { \|ev\| }` / `s.on_link { \|ev\| }` | a `TransportEvent` / `LinkEvent` (`added?` / `removed?`, `zid`, ...) on the receiving thread; returns an `Events` (`close`) |
| `s.peer_zids`, `router_zids`, `transports`, `links`, `new_timestamp`, `declare_keyexpr(key)` | as in asterism-zenoh |
| `s.subscribe(key, depth: 16) { \|sample\| }` | the block gets each `Sample` on the receiving thread. Returns a `Subscription` (`close` ends it) |
| `s.subscribe(key, depth: 16)` | a `Subscription` to take from: `each(timeout: nil)` waits for samples (an Enumerator without a block; Enumerable), `each_sample` gives what is there now as Samples (`each_pending`, its old name here, is deprecated: in the portable API `each_pending` gives Arrays), `pending` / `received` / `dropped` / `closed?` / `close` |
| `s.queryable(key, depth: 16, complete: false) { \|q\| }` | each query on the receiving thread, finished when the block returns. `q.reply(payload)` answers on the queryable's key (when it has no wildcard), `q.reply(key, payload, attachment:)` as before. Without a block, `each(timeout:)` yields the queries |
| `s.get(key, timeout: 2.0, params:, payload:, attachment:, target:, consolidation:, errors: false, depth: 1024, **opts)` | a `GetEnumerator` of `Reply`; each iteration sends the get again, and `dropped` / `received` / `errors` are those of the last one. With a block: yields each, returns their number. `depth:` the replies kept until taken (see [Queues](#queues)). `errors: true` also yields the error replies (`reply.error?`; left out by default, as `each_reply` does: look there when "nobody answers"); `consolidation: :none` keeps every reply (zenoh's own default is `:auto`). opts: `encoding:`, `priority:`, `congestion_control:`, `express:`, `accept_replies:`, `timeout_ms:` |
| `s.liveliness(key)` | a token (`close`). With a block: withdrawn after the block |
| `s.liveliness_watch(key, depth: 1024) { \|key, alive\| }` | on the receiving thread; the tokens alive now come first, in one burst. Without a block, `each` yields `Liveliness` (`key`, `alive?`). `pending` / `received` / `dropped` / `closed?` / `close` |
| `s.liveliness_get(key, timeout: 2.0, depth: 1024)` | the keys alive now (a `KeyList`: an Array with `dropped` and `received`; waits) |
| `s.start` / `s.stop` / `s.running?` | receive on a thread of its own |
| `s.run` | receive on this thread until `stop`, the connection closing, or Ctrl-C (returns nil) |
| `s.on_error { \|error, where\| }` | what the blocks raise (`StandardError`); without a handler it is printed with `warn`. Receiving goes on. `on_error` replaces the handler; every other `on_*` adds one |
| `s.session`, `zid`, `connection_count`, `poll`, `closed?`, `close` | (`peers` is the deprecated name of `connection_count`) |

`Sample`, `Reply` (`key`, `payload`, `attachment`, and since 0.3.0 `kind`,
`encoding`, `timestamp` and the rest; `text` is the payload as UTF-8; both
are asterism-zenoh's) and `Liveliness` are `Data` values, so they work with pattern
matching: `case sample in {key: %r{/temp\z}, payload:}`.

### Objects

```ruby
Asterism.connect("tcp/192.0.2.2:7447", node: "mypc", app: "demo") do |net|   # closed after
  net.expose("screen", Screen.new, methods: [:say])
  net.on_join  { |node| puts "joined #{node}" }
  net.on_leave { |node| puts "left #{node}" }
  board = net["fmruby-aaaaaa/demo/screen"]
  board.say("hello")
  net.each("*/demo/info").map(&:status)               # Enumerable
  net.run                                             # answer calls until Ctrl-C
end
```

| Call | Notes |
|---|---|
The connection (`Asterism::Connection`) is the portable API's (the same
object and methods on a board); CRuby adds to it:

| Call | Notes |
|---|---|
| `Asterism.connect(...) { \|net\| }` | yields the `Asterism::Connection`, `net.close` when the block ends; returns the block's value. Without a block, returns the connection (as on a board) |
| `net.start` / `stop` / `run` / `running?` / `on_error` | the connection's receiving thread, as for Zenoh. The exposed objects' methods, the `on_join` / `on_leave` / `on_app_*` blocks and the `subscribe` blocks run there (or in `run`, or in whatever polls). A method of an exposed object that raises is answered to its caller as a `RemoteError`; `on_error` gets what the blocks raise |
| `net.zenoh` | `net.session` as a `Zenoh::Connection` (`subscribe { }`, `put`, `publisher`, ...) on this receiving thread: its blocks run there, between the calls answered. `shared?` is true; its `close` does nothing and `start` / `stop` / `run` are the connection's. A ROS 2 node on it: `Asterism::ROS::Connection.new(net.zenoh).node("name")`. See [The connection's session](#the-connections-session-netsession) |
| `net.on_status(pattern = "*/*") { \|node, app, status\| }` | the statuses put by the applications matching, on the receiving thread ([Status](#status)) |
| `net.each(pattern)` | as on the boards (an Array without a block); the connection is `Enumerable` over `each("**")` (`net.map(&:asterism_path)`, `net.count`) |
| Waiting calls (`net[path].method`, `status_of`, `profile_of`, ...) | from another thread while the receiving thread runs, they wait for its ticks; on that thread, or while nothing receives, they poll as on the boards |

### Over TLS (a router on the internet)

`config:` of `Asterism.connect` (and of `Asterism::Zenoh.open`,
`Asterism::ROS.connect`) goes to the zenoh session: a Hash of zenoh's
configuration keys, or a JSON5 String (`File.read("client.json5")`). For a
router that asks for a client certificate (mutual TLS):

```ruby
tls = {
  "transport/link/tls/root_ca_certificate" => "certs/ca.pem",     # the CA that signed the router
  "transport/link/tls/connect_certificate" => "certs/cruby.pem",  # this node's certificate
  "transport/link/tls/connect_private_key" => "certs/cruby.key",
  "transport/link/tls/enable_mtls" => true
}
Asterism.connect("tls/router.example.org:7448", node: "cruby", app: "demo", config: tls) do |net|
  net["fmruby-aaaaaa/demo/info"].status        # a board on the router's other side
end
```

With an Asterism console, the certificate page saves everything as one
file ("Save all (.tar)": the key, the certificate, the CA, an example
configuration and `asterism.json` with the name and the router). Connect
with that one file:

```ruby
Asterism.connect(credentials: "alice.tar", app: "game") do |net|
  net["fmruby-aaaaaa/game/board"].state
end
Asterism::Zenoh.open(credentials: "alice.tar") { |s| s.put("asterism/alice/game/hello", "hi") }
Asterism::ROS.connect(credentials: "alice.tar") { |ros| ros.node("ruby_talker") }
```

The gem reads the tar in memory (nothing is written; `Asterism::Credentials`)
and gives zenoh the CA, the certificate and the key as
`transport/link/tls/root_ca_certificate_base64`,
`connect_certificate_base64` and `connect_private_key_base64`, with
`enable_mtls`. The locator defaults to the router in `asterism.json` and
`node:` to the certificate's name; give either to use another. `config:`
(a Hash) is laid over these keys. A tar that the group or others may read
is warned about, as ssh does with a key: `chmod 600 alice.tar`.

The boards (mruby / PicoRuby over picoruby-asterism-zenoh) take the same
file with `Asterism.connect(credentials: "/home/asterism/alice.tar", app: "game")`
when their Zenoh binding has TLS (`Asterism::Zenoh::TLS`; ESP-IDF builds).
There `Asterism::Credentials` reads the tar in plain Ruby (no Regexp, no
`pack`), the boards have no file modes to warn about, and the key pair is
left for the router to check; `config:` takes the TLS keys only.

The router checks the certificate against its CA, and its ACL can tell the
nodes apart by the certificate's common name. The name in the locator must
be one the router's certificate is valid for (zenoh checks it; it is
`verify_name_on_connect`). `examples/node.rb --ca --cert --key` does the same.
The boards (zenoh-pico on ESP32) have no TLS: they stay on a router in their
own network, which connects to the outside one.

### ROS 2

```ruby
Asterism::ROS.connect("tcp/192.0.2.2:7447", domain: 0) do |ros|
  node = ros.node("ruby_talker")
  chatter = node.publisher("/chatter", "std_msgs/msg/String")
  chatter << { data: "hello from Ruby" }
  node.subscribe("/odom", "nav_msgs/msg/Odometry") { |odom| puts odom.pose.pose.position.x }
  node.every(0.1) { chatter << { data: Time.now.to_s } }
  node.service("/add_ruby", "example_interfaces/srv/AddTwoInts") { |req| { sum: req.a + req.b } }
  p node.call("/add_two_ints", "example_interfaces/srv/AddTwoInts", a: 1, b: 2).sum
  node.topic("/scan", "sensor_msgs/msg/LaserScan").each.lazy.first(1)
  ros.spin                                            # until Ctrl-C
end
```

| Call | Notes |
|---|---|
| `Asterism::ROS.connect(locator = nil, domain: 0, type_path: nil, mode:, listen:)` | opens a session; yields an `Asterism::ROS::Connection` and closes it after. `type_path:` adds directories to `TYPE_PATH` |
| `ros.node(name, namespace: "/", enclave: "/")` | an `Asterism::ROS::Node` (every method of the portable API) with the calls below |
| `node.subscribe(topic, type) { \|msg, info\| }` | the portable API's (run from `node.poll`), here on the receiving thread; `info` is the `Attachment` or nil. Without a block: a subscription whose `each(timeout: nil)` waits for `[msg, info]` (Enumerable) |
| `node.topic(topic, type).each` | subscribes for the iteration and withdraws after it (`first(n)`, `break`, the time running out) |
| `node.every(seconds) { }` / `node.every(ms: 500) { }` | the portable API's timer (run from `node.poll`), here on the receiving thread; returns a `Timer` (`cancel`, `fired`) |
| `node.service(name, type) { \|req\| response }` | answered while the connection spins (or from `node.poll`). What the block raises goes to `on_error`, and that request gets no answer |
| `node.call(name, type, request = nil, request:, timeout: 2.0, **fields)` | waits for the response. Here `timeout:` is always the time limit (see [Reserved keywords](#reserved-keywords)) |
| `ros.spin` (`run`) / `start` / `stop` / `running?` / `on_error` / `close` | |
| `ros.zenoh` | the `Asterism::Zenoh::Connection` underneath (same receiving thread) |
| `Asterism::ROS::Connection.new(net.zenoh, domain: 0)` | nodes on an Asterism connection's session (the same Zenoh ID as its objects), spun by that connection's receiving thread. Its `close` withdraws its nodes only |

`type` is a generated type or its name (`"geometry_msgs/msg/Twist"`).
Messages and `Attachment` take part in pattern matching (`deconstruct_keys`,
on the boards too): `case msg in {linear: {x:}, angular: {z:}}`. A type
that is not bundled: generate it with `tools/asterism_msggen.rb -o DIR`
(see [Message types](#message-types)) and give the directory, as
`Asterism::ROS.connect(..., type_path: "DIR")` or
`Asterism::ROS::TYPE_PATH << "DIR"`; then pass its name like any other.

### Threads

- Each connection has at most one receiving thread, and only when the
  application asks for it (`start`), or the application's own thread
  inside `run` / `spin`. The blocks (subscriptions, queryables, timers,
  services, exposed objects, `on_join`) run there, one after another. **A
  block that takes long delays everything else that connection receives**:
  hand long work to a thread or a Queue of your own.
- zenoh-c never calls Ruby: it fills the queues, and the receiving thread
  empties them every 2 ms (`interval:`) with the portable API.
- A tick of the receiving thread holds the connection's lock (a `Monitor`;
  for the object layer one for all its connections, `Asterism::LOCK`: a
  call waiting on one connection answers the calls of the others). The
  application's calls into the same layer take it too, so the layers
  written for one thread are never entered by two at once.
- A call that waits for an answer (`proxy.method`, `node.call`) from another
  thread while the receiving thread runs does not poll by itself: it waits
  until a tick brings the answer. On the receiving thread itself (a block
  that calls), or while nothing receives, it polls as on the boards.
- `stop`, `close` and the end of the block wait for the receiving thread to
  end; no thread is left behind. When the connection is lost the receiving
  thread ends by itself, and waiting calls raise as before.
- Enumerators (`each`, `get`, `topic`) wait on the thread that iterates
  them.
- **Do not wait in a block.** On CRuby a block that calls and waits (a
  proxy call, `node.call`) works, but delays every other block of that
  connection; on a board it can overflow the stack ([Stack](#stack)).

What may be shared between threads:

| Object | Use from several threads? |
|---|---|
| `Asterism::Zenoh::Session` and its subscribers, queryables, gets, publishers, queriers (CRuby) | yes; each queued entry goes to exactly one taker |
| `Zenoh::Connection` | yes; its blocks run one at a time on the receiving thread |
| An Enumerator (`Subscription#each`, `Watch#each`, `get`, `topic`) | one thread per iteration |
| The object layer (`Asterism::Connection`, proxies, `Future`) | yes; serialized by `Asterism::LOCK` (one for all the connections of the process) |
| `ROS::Connection` and the nodes it makes | yes (its runner's lock) |
| A `ROS::Node` made with `Node.new` (portable API) on CRuby | **no**: one thread, as on the boards |
| A session opened before `fork` | not in the child: its calls raise `Zenoh::ClosedError`; connect after fork |
| The boards | one thread (the application's update loop) |
| Ractors | not supported |

## The command line

The gem has a command, `asterism`, that looks at a network from a terminal
(CRuby). It is one more node: it connects, reads the liveliness tokens,
the meta, the profiles and the statuses, and calls a method only when told
to with `call`. Its commands are a noun and a verb, as ros2's are
(`asterism node` alone lists the node's verbs, `asterism --help` all of
them):

```
asterism node list   --router tcp/192.0.2.2:7447    # the nodes, a name a line
asterism node info   games                          # one node: profile, apps, statuses, objects
asterism app list                                   # node/app, a line each
asterism app info    games/games                    # its status, topics, types and objects
asterism object list 'games/games/*'                # node/app/object, a line each
asterism object info games/games/othello1           # its description and its methods
asterism object find join                           # the objects that have join (* as a wildcard)
asterism object get  games/games/othello1 state     # the next value the application puts there
asterism object echo games/games/othello1 state     # the values as they come (what changed)
asterism topic list  'games/*'                      # node/app/name of each topic, with its type
asterism topic info  games/games/board1/strokes     # its declaration, and its type's definition
asterism status get  games/games                    # the status now
asterism status echo games/games                    # the status, then each change (--once: now, once)
asterism status hz   games/games                    # how often it changes
asterism call        games/games/othello1 join '"Alice"'
asterism call        linux/demo/screen say hello --kwargs '{color: 3}'
asterism ping        games/games/othello1           # round trips (its meta; no method runs)
asterism ping        games/games/othello1 --call view '"<token>"'   # round trips of a call
asterism watch                                      # nodes, apps and objects coming and going, statuses
asterism tree        --credentials admin.tar        # nodes > apps > objects (--methods: the methods)
asterism completion  bash                           # Tab completion (below)
```

The older commands stay, with the same output: `nodes` (every node with
its applications and statuses, in one listing), `objects [PATTERN]` (each
object with its description and methods) and `echo` (`ping`).

```
$ export ASTERISM_ROUTER=tcp/192.0.2.2:7447
$ asterism node list
games
linux
$ asterism object list
games/games/mahjong1
games/games/othello1
linux/demo/screen
$ asterism app info games/games
games/games
  status:
    mahjong1: st=wait members=0 humans=0 cpus=0 ais=0 away=0
    othello1: st=wait members=0 humans=0 cpus=0 away=0
  objects:
    mahjong1  18 methods
      A riichi mahjong table (four seats). From a program: call describe first,
      then join, sit, and look / choose in a loop.
    othello1  11 methods
      An othello table (two seats). join, sit, then view / move in a loop.
$ asterism object info games/games/othello1
games/games/othello1
  An othello table (two seats). join, sit, then view / move in a loop.
  join(name)              Joins the table as name (or gets this node's
                          membership back). Returns {"token", ...}: every later
                          call brings the token. {"error" => why} when the table
                          is full.
  mine()                  This node's membership ({"token", ...}), or nil when
                          it has not joined.
  ...
$ asterism object find join
games/games/mahjong1
games/games/othello1
$ asterism status get games/games -o yaml
---
mahjong1:
  st: wait
  members: 0
  ...
$ asterism status echo games/games
12:00:01.204 games/games (now)
             mahjong1: st=wait members=0 humans=0 cpus=0 ais=0 away=0
             othello1: st=wait members=0 humans=0 cpus=0 away=0
12:00:05.120 mahjong1.members 0→1
12:00:05.133 mahjong1.humans 0→1
$ asterism status hz games/games
average rate: 0.409 Hz
  min: 0.013 s  max: 4.876 s  std dev: 2.432 s  window: 2
$ asterism tree
games  (cruby) "asterism-games"
  games
    status:
      mahjong1: st=wait members=0 humans=0 cpus=0 ais=0 away=0
      othello1: st=wait members=0 humans=0 cpus=0 away=0
    mahjong1  18 methods
    othello1  11 methods
linux  (family_mruby/sim)
  demo
    screen  3 methods
$ asterism watch
12:00:01.204 ~ status games/games (now)
               mahjong1: st=wait members=0 humans=0 cpus=0 ais=0 away=0
               othello1: st=wait members=0 humans=0 cpus=0 away=0
12:00:04.881 + node wasm-1a2b3c
12:00:04.881 + app wasm-1a2b3c/game
12:00:05.120 ~ status games/games mahjong1.members 0→1
12:00:05.133 ~ status games/games mahjong1.humans 0→1
```

- **Where the network is.** `--router tcp/HOST:7447` (a router without TLS),
  or `--credentials FILE.tar` (a console's `.tar`: mutual TLS, its router
  and its name; `--router` overrides the router). `--peer LOCATOR` links
  straight to a node listening there (no router). The node ID is the
  certificate's name, otherwise `cli-` and 6 hex digits (`--node`); the
  application `cli-` and 4 (`--app`). With none of `--router`,
  `--credentials`, `--peer` on the line, `ASTERISM_CREDENTIALS` and
  `ASTERISM_ROUTER` from the environment are used instead (all or nothing:
  a router on the line never meets a `.tar` from the environment), so
  `export ASTERISM_CREDENTIALS=~/me.tar` makes `asterism tree` enough, and
  an MCP client can pass it in the server's environment.
- **What it sees** is what the router lets it see. With a console's `.tar`
  that is the row's roles: a role for looking only is in the console's
  docs/g1_5.md ("Looking only: a viewer role"): it reads every node, object,
  profile and status, and the router refuses its calls, so `asterism call`
  says "nobody answers" and nothing runs. Something the router refuses is
  left out of a listing; it is not reported as gone.
- **Arguments** of `call` (and `ping --call`): each is JSON, else a Ruby
  literal (nil, true, false, numbers, strings, symbols, arrays, hashes; read
  with Ripper, nothing is evaluated), else the text as written. `--kwargs`
  is a JSON object or a Ruby Hash.
- **Lists** (`node list`, `app list`, `object list`, `object find`) print
  the names only, a name a line, sorted, so they go to `grep` and `xargs`
  as they are (on a terminal the parts are coloured; to a pipe they are
  plain).
- **Output**: text, or `-o json` / `-o yaml` on every command that reads
  (the YAML holds what the JSON does; `--json` is `-o json`, its output as
  it always was). The streams (`watch`, `status echo`, `status hz`) give a
  JSON object a line, or a YAML document each (`---`), with the time. The
  text is for people: on a terminal it has colours (nodes, applications,
  objects, the `+` `-` `~` of watch; `NO_COLOR=1` turns them off) and is
  wrapped to the terminal's width; written to a pipe or a file it is plain
  and 80 columns wide (or `COLUMNS`). A status is shown as `key=value`, a
  line for each level that holds Hashes (a long text or array is cut with
  `…`; `-o json` has it whole). `tree` tells how many methods an object
  has, `tree --methods` lists them; `object info` (and `objects`) lists
  each method with its description. `watch` and `status echo` show a
  status whole the first time (and when its application comes back), then
  only what changed: `a.b 0→1`, `+a.c=…` (a key came), `-a.d` (a key
  went). `--timeout` (2.0 s) is each get's and call's limit, `--settle`
  (1.5 s) how long it waits for the tokens after connecting.
- **topic list / info** read what the applications declare
  (`@profile?pubs;types`, docs/protocol.md 10, 11): each topic's type (a
  built-in one by its name, `vector3`, or an application's own), its
  encoding (none: MessagePack), unit and text, and the definition of an
  application's own type (`topic info`, and `app info`, which lists the
  types the application defines). `tree`, `nodes`, `node info` and
  `app info` list an application's topics under its status.
- **object get / echo PATH [KEY]** read what an application puts on its
  topics, `asterism/<node>/<app>/<name>` (docs/protocol.md 9; a game
  table puts its state on `<table>/state`). `PATH` is
  `node/app/object` (`*` for a part), `KEY` the rest (`*` and `**` as whole
  parts; `**` by default). A put is kept nowhere and a get has no answer
  for it, so both wait for puts: `object get` prints the next one and ends
  (`--timeout`, 5 s; an application puts when its value changes, so a quiet
  one gives nothing), `object echo` prints them as they come: a key's
  value whole the first time, then only what changed in it, as
  `status echo` does (`--raw`: each value whole; `--once`: the first put;
  `--duration`). The value is MessagePack (Asterism's own, no encoding) as
  it is; a value with an encoding as JSON or text for those encodings, as
  its encoding and size otherwise (`image/jpeg`); from a sender that does
  not follow the protocol, JSON or text as they are, bytes as their count.
  `-o json` gives each put as `{"key", "t", "bytes", "format", "value"}`
  (`format`: `msgpack` or the encoding) with `seq` and `sent` (the sender's
  time) from its attachment, and `lost` (values missed before it) or
  `restarted` (the sender's numbers started again); the text says those
  on a line of their own (`(2 lost)`). When nothing comes
  they say so: the router does not let this node read the key (a role
  needs `read` on it), or nothing changed.
- **status hz** counts the changes of the status (a put of the same status
  again is not one) and prints, every `--period` (1 s) in which a change
  came, the average rate and the intervals' min, max and standard
  deviation over the last `--window` (1000) intervals, as `ros2 topic hz`
  does. An application puts its status when it changes, so this is how
  often the application has something new to tell.
- **watch** shows the applications and objects themselves (their tokens),
  not only the nodes: a node with two applications stays while one closes,
  and `watch` shows that one leave.

### Tab completion

```
source <(asterism completion bash)     # or put this line in ~/.bashrc
source <(asterism completion zsh)      # zsh, after compinit (~/.zshrc)
```

The commands, the verbs and the options complete without the network. The
names on the network complete too: the nodes, `node/app`, `node/app/object`
a part at a time (`ga<Tab>` gives `games/`, `games/games/<Tab>` the
objects), and after `call PATH` (or `ping PATH --call`) the object's
methods. On each Tab the script runs `asterism __complete`, which asks the
network named on the line (`--router`, `--credentials`, `--peer`) or in
`ASTERISM_CREDENTIALS` / `ASTERISM_ROUTER`:

- briefly: what does not answer within 1.5 s gives no candidates, and the
  shell is not kept waiting;
- remembered for 20 s, a file per network in `$XDG_CACHE_HOME/asterism/`
  (`~/.cache/asterism/`; the directory 0700, the files 0600), named by a
  digest of where the network is. It holds the names only, never a key or
  a certificate. What did not answer is not remembered;
- as one more node for a moment (a `cli-` node, or the certificate's name),
  so `asterism watch` shows it come and go.

### Inside another program

A program that is connected already (a console's bridge, which shows the
commands on a page) runs the same commands on its own connection:

```ruby
require "asterism/cli"
cli = Asterism::CLI.new(out: io, err: io, env: {}, net: conn,
                        stop: -> { asked_to_stop }, permit: ->(plan) { nil })
cli.run(%w[node list])        # the exit code; the text went to io
```

- `net:` the `Asterism::Connection` to run on. It is neither started nor closed:
  what a command subscribes to or hooks onto it (watch, echo, hz, get) is
  released when the command ends. Its own application is left out of the
  listings, as the command line's own is.
- `stop:` asked while a command streams or waits; `true` ends it as
  Ctrl-C does.
- `permit:` asked once the words are read, with an `Asterism::CLI::Plan`:
  `key` ("node list", "call", ...), `kind` (`:read`; `:call` for `call`
  and `ping --call`, with `path` and `method`; `:local` for `mcp` and
  `completion`), `args`, `options`. It returns nil to go on, or the reason
  the command may not run (printed; `CLI#refused` keeps it).
- Such a command line takes no `--router`, `--credentials`, `--peer`,
  `--node` or `--app`, never runs `mcp` or `completion`, takes long
  options only as written in full (`--cal` is not `--call`), and prints
  `--help` to `out` (OptionParser's own `--help` / `--version` would print
  to `$stdout` and exit the process). `__complete` asks the connection on
  each Tab and keeps nothing.
- Colours and width: `out` that answers `tty?` true (and `winsize`) gets
  them, as a terminal does.
- `require "asterism/cli/commands"` loads the command table alone (the
  nouns, verbs, commands, `CLI.kind`, `CLI::Plan`), without the Zenoh
  binding, for a program that only checks a command line.

### MCP: Asterism as tools of an AI assistant

`asterism mcp` is an MCP server on stdio (it needs the `mcp` gem, which
the asterism gem does not depend on: `gem install mcp`). It reads by
default, and calls only the methods `--allow` names:

```
asterism mcp --router tcp/192.0.2.2:7447 --allow 'games/othello1.*'
claude mcp add asterism -- asterism mcp --credentials admin.tar --allow 'games/othello1.*'
```

| Tool | What |
|---|---|
| `asterism_nodes` | the nodes, their profiles, applications (with their statuses) and objects |
| `asterism_objects` | the objects and their methods (meta); `callable_as` names the tool for an allowed method |
| `asterism_status` | the applications' statuses (`node` / `app` narrow it) |
| `asterism_topics` | the topics the applications declare, with their types, encodings, units and texts, and the definitions of their own types (`node` / `app` narrow it) |
| `asterism_values` | the latest value of each topic the applications put on (`asterism/<node>/<app>/<name>`, e.g. a game table's state), as this server received them since it started, with its encoding and sequence numbers; `pattern` (`node/app/name`, `*` and `**`; default `**`), `wait` (seconds, at most 30) and `images` (true: pictures as MCP images, at most 4) |
| `<node>.<app>.<object>.<method>` | one per method an `--allow` pattern names, made from the meta: the arguments' names it tells are the inputs and its doc the description (with the object's doc after it); without names, arity n gives the inputs `arg1` .. `argN` (any JSON value), arity -1 an array `args`; `kwargs` is an object of keyword arguments. The answer is `{"value": ...}`, or an error with its kind |

- `--allow PATTERN` (repeatable): `[node/][app/]object.method`, `*` within
  a part as a wildcard. A pattern with fewer parts matches the last parts
  of the path (`games/othello1.*` is `*/games/othello1.*`); without
  `.method` every method of the object.
- The call tools follow the network: when an allowed object appears or
  goes, the list is made again and the client is told
  (`notifications/tools/list_changed`).
- The calls are made as this node (`--node`, or the certificate's name), so
  an object exposed with `caller: :from` sees who called; a game table
  gives the MCP client its own seat. `--app` names this application (a
  game host that follows its players by the application `game` sees an
  MCP client started with `--app game` come and go).
- **asterism_values**: from its start the server subscribes to
  `asterism/**` (the applications' own keys; `@profile` and `@status` are
  not under it) and keeps the last value of each key with the time it
  came. A put comes only when a value changes and is kept nowhere else, so
  a key that has not been put since the server started is not there:
  `wait` waits (at most 30 s) for the first put that matches when none has
  come yet. Each value has `key`, `value`, `t`, `age_s` (seconds since it
  came), `bytes`, `format` (`msgpack`, or the encoding it came with:
  `image/jpeg` shows as its size), `seq` and `sent` (the sender's time)
  from its attachment, `lost` (values of the key missed since the start)
  and `app`: `alive`, `gone` (the application is
  not on the network now; the value is its last one, not the present) or
  `restarted` (it left and came back after this value). A value whose JSON
  is longer than 8192 bytes is cut (`truncated: true`, the value the start
  of its JSON text); the server keeps at most 1000 keys and 16 MiB (the
  key received longest ago is forgotten first; `forgotten` counts them), a
  single put over 256 KiB as its size only, and an answer lists at most
  100 keys (`more`). Nothing that matches: `note` says so (not put since
  the start, or the router does not let the server read it). A console's
  viewer role (`read` / `watch` on `asterism/**`) is enough.

  Showing an othello table to an AI assistant (the game host puts the
  table on `games/games/othello1/state` after every move):

  ```
  claude mcp add asterism -- asterism mcp --credentials viewer.tar
  > Watch the othello game on games/games/othello1 and tell me who is winning.
    (the assistant calls asterism_values with pattern games/games/othello1/state, wait 30)
  {"since":"2026-10-20T02:16:50.191Z","values":[{"key":"games/games/othello1/state",
   "t":"2026-10-20T02:16:58.583Z","age_s":0.4,"app":"alive","bytes":181,"format":"msgpack",
   "value":{"v":15,"t":"othello1","st":"play","nm":["CPU","Alice"],"sk":[2,1],...,
            "bd":"..W.......W.......WBWWW...WBB....W.BBB..........................",
            "tn":0,"n":10,"last":"c1","lg":"b1b2e2f2g2b3h3b4a6","cnt":[6,8]}}]}
  ```

- An object that describes its methods at `expose` (`args:` and `doc:`,
  "Describing the methods" below) gives the AI assistant the names and the
  texts; without them it sees only the number of arguments.

## License

MIT (LICENSE) for Asterism's code. The ROS 2 definitions in
`tools/ros2_jazzy/` (with the package.xml of their packages), the types
generated from them in `data/msgs/` and the fixtures computed by ROS 2's
tools in `test/msgs/` are under the Apache License 2.0 (NOTICE,
`data/msgs/NOTICE`, `data/msgs/LICENSE-Apache-2.0.txt`), except those of
tf2_msgs, which are under the BSD 3-Clause License
(`data/msgs/LICENSE-BSD-3-Clause-tf2_msgs.txt`). Each generated type names
its package and license at its top. The gem `asterism` is therefore `MIT`,
`Apache-2.0` and `BSD-3-Clause`, each for its own files.

Not in this repository: the gems Asterism depends on are not bundled.
`msgpack` (CRuby) and `asterism-zenoh` (the CRuby Zenoh binding, which in
turn fetches zenoh-c at build time; see its README) are installed by
RubyGems, and on mruby / PicoRuby the Zenoh binding is the separate mrbgem
`picoruby-asterism-zenoh`. Their licenses are their own.

---

# The portable API

The same on every Ruby (CRuby adds the layer described in
[The CRuby API](#the-cruby-api)). The examples use PicoRuby's `sleep_ms`; on CRuby
write `sleep`. When PicoRuby's `Machine` is there it is used for the clock
and the short pauses while waiting; otherwise `Time` and `sleep`. Besides
`Asterism::Zenoh`, the layers need a `MessagePack` module with `pack` /
`unpack` (the API of the msgpack gem; whichever gem provides it).

```ruby
# on the machine that has the object
net = Asterism.connect("tcp/192.0.2.2:7447", node: "fmruby-bbbbbb", app: "demo")
net.expose("apu", apu, methods: [:play, :stop])
loop { net.poll; ... }                    # in the update loop

# on another machine
net = Asterism.connect("tcp/192.0.2.2:7447", node: "linux", app: "demo")
apu = net["fmruby-bbbbbb/demo/apu"]       # <node>/<app>/<object>
apu.play("t120 o4 cdefg")                 # runs there, returns its value
apu.respond_to?(:play)                    # => true (from the exposed list)
f = apu.async.play("cde")                 # does not wait
f.done?; f.value
net["fmruby-bbbbbb/demo/apu", timeout: 5.0].play("c")   # a longer time limit
net.each("*/*/apu") { |a| a.stop }        # every apu alive now
net.nodes                                 # => ["linux", "fmruby-bbbbbb"]
```

`Asterism.connect` returns the connection (an `Asterism::Connection`): one
application on the network, with everything of it (its session, its
token, its objects, its status, topics and types). Everything below is a
method of it (`net.` in the tables); the module keeps only
`Asterism.connect`, `Asterism.connections`, `Asterism.poll_all` and
`Asterism.profile_defaults`, and the stateless helpers (`Asterism::Codec`,
`Asterism::Profile`, `Asterism::Status`, `Asterism::Types`,
`Asterism::Pubs`).

## API

| Call | Returns | Raises / notes |
|---|---|---|
| `Asterism.connect(locator = nil, node: nil, app:, mode: nil, listen: nil, config: nil, connect_timeout: nil, check_timeout: 1.5, credentials: nil)` (`credentials:` see [Over TLS](#over-tls-a-router-on-the-internet)) | `Asterism::Connection` | `locator`, `mode:`, `listen:` (and `config:` / `connect_timeout:` when given: TLS and the rest of zenoh's configuration on CRuby; the boards take the TLS keys of `config:` only and raise `ArgumentError` for the rest) go to `Asterism::Zenoh::Session.open` (client of a router by default; `mode: :peer` with or without `listen:` without one). `node:` is this machine's ID, `app:` the application's name (one key chunk each: no `/ * $ ? #`, not starting with `@`; else `ArgumentError`). `Disconnected` when it cannot connect; `Error` when the same `<node>/<app>` is already there: open in this program, or its token or objects alive on the network (a second copy of the application). Waits up to `check_timeout:` seconds for that check (a router answers at once; give more over a slow relay). A program may connect several times, as several applications ([Several connections](#several-connections)). The default is plain text without authentication; see [Over TLS](#over-tls-a-router-on-the-internet). |
| `Asterism.connections` | `[Connection]` | The connections of this program that are open (or lost, until their `on_leave` blocks were told), in the order they were opened. |
| `Asterism.poll_all` | true / false | `poll` on each of them; true while one is connected. |
| `Asterism.profile_defaults(kind:, name:, host:, icon:)` / `Asterism.profile_defaults` | Hash | The profile every node of this program starts with (a board's firmware sets it before the application connects); see [Profiles](#profiles). |
| `net.expose(name, obj, methods:, caller: nil, doc: nil)` | `"<node>/<app>/<name>"` | `methods:` is an Array of names, or a Hash `name => number of arguments` (checked before the call; `-1` or the Array form: any) or `name => { args: [names], doc: "text" }` ([Describing the methods](#describing-the-methods)); `doc:` the object's own text. `ArgumentError` when `obj` has no such public method. Exposing a name again replaces it. `caller: :from` passes the calling node's ID to every method as the keyword `from:` and refuses a call that brings `from:` itself ([Who called](#who-called)). |
| `net.current_call` | `Asterism::CurrentCall` or nil | While an exposed method of this connection runs for a call: `from` (the calling node's ID), `verified` (`:claimed`, or `:local` for a call from this application), `object`, `method`. nil outside a call ([Who called](#who-called)). |
| `net.unexpose(name)` | true / false | |
| `net.poll` | true / false | Call from the update loop: polls Zenoh, answers the calls that came in, follows who is alive, calls the `on_join` / `on_leave` blocks and hands the values to the `subscribe` blocks. `false` once the connection is closed or lost. Cheap when nothing came (0.6.0): each queue is looked at by its count, and the list of nodes is made again only after a liveliness change. |
| `net.on_app_join { \|node, app\| }` / `net.on_app_leave { \|node, app\| }` | the connection | An application of another node appeared (its token `asterism/<node>/<app>`) / is gone. A node may run several (another connection of this program among them): each comes and goes on its own while the node stays. Told like `on_join` (from `poll`; at connect for those there; all leave when the connection is lost); `off_app_join(proc)` / `off_app_leave(proc)` |
| `net.on_join { \|node\| }` / `net.on_leave { \|node\| }` | the connection | Another node appeared (one of its applications or objects) / is gone (no application and no object left). The nodes there already join on the first polls after connecting; when the connection is lost, every node known until then leaves (on the next `poll`). The blocks run from `poll` only, never from the polling inside a waiting call; what they raise comes out of `poll`. Each call adds a block; `off_join(proc)` / `off_leave(proc)` remove one; `close` forgets them (a lost connection does not). |
| `net[path, timeout: 2.0]` | `Proxy` | `path` is `<node>/<app>/<object>` without wildcards (`ArgumentError`). `timeout:` (seconds) or `timeout_ms:` is the time limit of its calls, which go out on this connection. Nothing is sent until a method is called. |
| `proxy.<method>(*args, **kw)` | the remote return value | Waits for the answer (the proxy's time limit). `RemoteError` when it raised there or could not be called (`remote_kind` says which: `raised`, or not exposed `not_exposed` (`NoMethodError`), wrong number of arguments `arguments` (`ArgumentError`), no such object `no_object` (`NameError`); [Errors](#errors)), `TimeoutError` when no answer came in time (also at once when nobody answers that key), `Disconnected`, `EncodeError` (before anything is sent) for a value MessagePack cannot carry. A block cannot be sent (`ArgumentError`). |
| `proxy.asterism_call(name, *args, **kw)` | the remote return value | The same call by the method's name (a String or Symbol): for names a proxy cannot forward (those `Object` and `Kernel` have: `display`, `hash`, `class`, `fail`, ...) and names that are not Ruby identifiers. `proxy.async.asterism_call(...)` returns a `Future`. |
| `proxy.async.<method>(...)` | `Future` | Sends and returns at once. `EncodeError` / `Disconnected` are raised here. |
| `future.done?` | true / false | Never waits (`net.poll` moves it on). True once the answer came, the time ran out or the connection closed. |
| `future.value` | the return value | Waits (polling) if not done; raises like a waiting call. `future.took` (seconds) / `took_ms`: time to the answer. |
| `proxy.respond_to?(name)` / `proxy.remote_methods` | true / false, `[Symbol]` | From the object's meta (fetched once, `proxy.asterism_refresh` forgets it). `respond_to?` is false when the object does not answer; `remote_methods` raises then. (`proxy.methods` returns the same with a deprecation warning; from 1.0 it is `Object#methods`.) |
| `proxy.asterism_meta` / `proxy.asterism_path` / `proxy.asterism_connection` | Hash, String, `Connection` | `{"methods" => [{"name" => name, "arity" => n}, ...]}` |
| `net.each(pattern = "**") { \|proxy\| }` | count (Array without a block) | The exposed objects alive now (this application's own included) whose `<node>/<app>/<object>` matches; `*` is one chunk, `**` any number. 1.0 returns the connection from the block form instead of the number (Ruby's `each` returns its receiver); write `net.each(pattern).size` for the count. |
| `net.nodes` | `[String]` | Node IDs alive now, this one first. |
| `net.apps(pattern = "*/*")` | `[String]` | The applications alive now, `"<node>/<app>"` (from their liveliness tokens; this one first). |
| `net.node_id` / `app` / `path` / `connected?` / `exposed` / `lost_reason` | | `path` is `"<node>/<app>"` |
| `net.reconnecting?` | true / false | True while the router is away and the binding opens the connection again ([When the connection is lost](#when-the-connection-is-lost)). |
| `net.session` | `Asterism::Zenoh::Session` | The connection's own session, for put / subscribe / a ROS 2 node on the same connection ([The connection's session](#the-connections-session-netsession)). The same object until the connection closes. `Disconnected` when not connected. Its `close` does nothing (warns once); `net.close` closes it. |
| `net.close` | nil | Withdraws every exposed object, topic and subscription, and closes the session. Idempotent. A closed connection is not opened again: `Asterism.connect` makes a new one. |
| `net.profile(kind:, name:, host:, icon:)` / `net.profile` | Hash | This node's profile (the node of this connection): sets the fields given and returns it; without arguments, returns it. See [Profiles](#profiles). |
| `net.profile_of(node, icon: true, timeout: 2.0)` | Hash or nil | Another node's profile, nil when it does not answer (an older version, a ROS 2 node). |
| `net.status(hash = nil, **fields)` / `net.status` | Hash or nil | This application's status: a Hash is the whole status, keywords change those fields (nil removes one); put on the network when it changes. Without arguments, returns it. See [Status](#status). |
| `net.status_of(node, app, timeout: 2.0)` | Hash or nil | Another application's status, nil when it has none or does not answer. |
| `net.publish(name, type:, unit:, desc:, ts:, encoding:, shared: nil)` | `Asterism::Topic` | Declares a topic of this application; `topic.put(value)` sends. `shared: :node` / `:global` puts it on a shared place instead. See [Topics](#topics) and [Shared places](#shared-places). |
| `net.subscribe(path, depth: nil) { \|v, info\| }` | `Asterism::Subscription` | The values on `<node>/<app>/<topic>` (wildcards allowed), or a shared place's `<node>/@shared/<name>` / `@shared/<name>`, from `net.poll`; `close` ends it. |
| `net.pubs_of(node, app)` / `net.types_of(node, app)` | Hash or nil | Another application's topics (shared ones under their entries) / types, `{}` when it has none, nil when it does not answer. |
| `net.publishers_of(path, timeout: 2.0)` | Hash | The applications that declare a shared key (`@shared/<name>`, `<node>/@shared/<name>`, `*` for the node): `{"<node>/<app>" => declaration}`. |
| `net.declaration_of(info)` / `net.type_of(info)` | Hash / Integer or `[name, definition]`, or nil | A received value's declaration / type, from its sender (`info.from`). |
| `net.define_type(name, fields, desc: nil)` | Hash | An application type, told by `@profile?types`. |
| `net.published` / `net.unpublish(topic or name)` / `net.unsubscribe(sub)` | | |

## Describing the methods

The meta (what `proxy.respond_to?` reads) can carry the arguments' names
and what each method does, for the people and the tools that show them
(`asterism mcp` turns them into an AI assistant's tool inputs and
descriptions; `asterism objects` prints them). Give them at `expose`, next
to the numbers:

```ruby
net.expose("othello1", table, caller: :from, doc: "An othello table. Call view for the board.",
           methods: { join: 1,                                   # a number, as before
                      "move" => { args: %w[token n square],
                                  doc: "Plays square (\"d3\") on the board version n of view." },
                      view: { args: [:token], doc: "The board as this member sees it." } })
```

- The names give the number of arguments checked (`args: %w[a b]` is 2);
  `arity: -1` keeps it unchecked (the names are then the leading ones).
- The texts are at most 2048 bytes, the names at most 16 of 64 bytes; the
  first line of a doc is its summary. They travel in every meta reply, so
  keep them short on a board.
- Old readers ignore them and old nodes do not send them
  (docs/protocol.md 5); a proxy works the same either way.

## Profiles

A node tells what it is (0.5.0): what Ruby runs it, where, a display name
and an icon. A console draws it with that; anyone can ask.

```ruby
net.profile(name: "Rover", icon: File.binread("rover.png"))   # this node's (any time)
net.profile
# => {"protocol" => 2, "kind" => "cruby", "name" => "Rover", "icon" => "\x89PNG...", "icon_hash" => "2a8c0626"}
net.profile_of("fmruby-aaaaaa")
# => {"protocol" => 2, "kind" => "family_mruby", "host" => "atoms3r", "icon" => "\x89PNG...", "icon_hash" => "..."}
net.profile_of("fmruby-aaaaaa", icon: false)   # the same without the icon bytes
net.profile_of("an-older-node")                # => nil
Asterism.profile_defaults(kind: :family_mruby, host: "atoms3r")   # what every node of the program starts with
```

| Field | Value | Default |
|---|---|---|
| `protocol` | set by Asterism, never given: the wire protocol the node speaks (`Asterism::PROTOCOL`, 2). A node whose profile has none speaks protocol 0 (asterism before 0.7.0), which this version does not talk to | |
| `kind` | what Ruby runs the node: `family_mruby`, `picoruby`, `cruby`, `console` (a lower-case word: `a-z`, `0-9`, `_`, up to 32 bytes; other words are allowed) | `cruby` on CRuby, `picoruby` on mruby / PicoRuby; Family mruby's firmware sets `family_mruby` |
| `host` | where it runs, e.g. `atoms3r`, `tab5`, `p4nano`, `browser`, `sim` (up to 32 bytes) | none; Family mruby's firmware sets it from the board |
| `name` | a display name (up to 64 bytes) | none |
| `icon` | the bytes of a PNG (a binary String; sent as a MessagePack bin): at most 8 KB and 256x256 (32x32 is the size meant). PNG only: an SVG can carry scripts | the file at `Asterism.default_icon_path` when it is there: on CRuby the gem's `data/icon.png` (a ruby), on the boards `/usr/share/asterism/icon.png` |
| `icon_hash` | set by Asterism, never given: the icon's summary (8 hex digits: the Adler-32 of the PNG's chunk CRCs, so a board computes it from a few bytes) | |

- **Setting.** `net.profile(**fields)` changes the fields given and keeps
  the others; `nil` leaves `name` / `host` out, goes back to the default
  `kind`, and means no icon for `icon:`. It raises `ArgumentError` for a
  field it does not accept (an unknown name, a `kind` that is not a word, an
  icon that is not a PNG, larger than 8 KB or 256x256). The profile is the
  node's, not the connection's: every connection of this program made as
  that node has the same one (a change on one is the others' too), and it
  outlives them (a connection made again as that node finds it).
- **The program's defaults.** `Asterism.profile_defaults(**fields)` takes the
  same fields, before connecting or at any time: what every node of this
  program has where its own connections set nothing (a firmware sets them
  before the application runs: Family mruby sets `kind`, `host` and,
  through `/usr/share/asterism/icon.png`, the icon). A node's own field
  wins, also a `nil` (`net.profile(host: nil)` leaves the host out over a
  default).
- **Reading.** `net.profile_of(node)` asks `asterism/<node>/@profile`
  and waits like a call (`timeout:` / `timeout_ms:`); this node's own comes
  without the network. The answer is cleaned (`Asterism::Profile.check`):
  only the fields above, each checked; an icon that is not an acceptable
  PNG is dropped with its hash, an answer without a valid `kind` is `nil`.
  `icon: false` asks without the icon (the parameter `icon=0`): a reader
  that already has the icon of that `icon_hash` asks this way.
- **Following.** At each connect and at each change while connected, the
  node also puts its profile without the icon on `asterism/<node>/@profile`;
  subscribe to `asterism/*/@profile` to follow the changes (and fetch the
  icon again only when `icon_hash` changed). Older nodes neither answer nor
  put.
- **Several applications of one node.** Each connection answers for the
  node, and `profile_of` takes the first answer. In one program they answer
  the same (above). Applications of one node in different programs (a board
  running two, each in a VM of its own) each answer their own: give them
  the same defaults (Family mruby's firmware sets the same in each), or set
  it in one and read the notices, where the last change wins.
- `Asterism::Profile.png_info(bytes)` gives `[width, height, icon_hash]` of
  an acceptable PNG (nil otherwise), for a tool that wants to check an icon
  first.

## Status

An application tells what changes while it runs: how many tables a game
host has open and who sits at them, a battery level, a mode. The profile
says once what a node is; the status is the application's and changes.

```ruby
net.status(tables: 3, humans: 2)           # sets those fields, keeps the others
net.status(humans: nil)                    # nil removes a field
net.status({ "mahjong1" => { "st" => "play", "humans" => 1 } })   # a Hash: the whole status
net.status                                 # => {"mahjong1" => {...}} (nil when none was set)
net.status_of("games", "games")            # another application's, or nil
```

- **On the network.** The application's own profile,
  `asterism/<node>/<app>/@profile` ([docs/protocol.md](docs/protocol.md)
  8), answers the status (`?status`; with no parameters the status and
  the topics), and the status is put on `asterism/<node>/<app>/@status`
  when it changes (setting the same status again puts nothing) and after
  a lost connection comes back. An application that has neither
  a status nor a topic nor a type answers nothing.
- **The value.** A Hash with String (or Symbol) keys; the values are
  anything a call can carry, nested at most 4 levels below the Hash, and
  the whole packs into 1024 bytes at most. `ArgumentError` otherwise.
  Whoever may read `asterism/*/*/@profile` or `asterism/*/*/@status` reads
  it: counts and states, not secrets.
- **Following.** Subscribe to `asterism/*/*/@status` and read each put with
  `Asterism::Status.parse(key, payload)` (`[node, app, status]` or nil); on
  CRuby, `net.on_status("*/*") { |node, app, status| }`. Only changes are
  put: ask `status_of` once for an application that appeared.
- **Behind access control.** `@profile`, `@status` and `@pubs` are
  verbatim chunks: `asterism/**` does not match them. A router's rules
  need `asterism/*/*/@profile` (query) and `asterism/*/*/@status`,
  `asterism/*/*/@pubs` (subscription) for a reader, and the same under
  `asterism/<node>/*/` for the application (queryable and reply, put).
- The status is the connection's (each connection is one application). It
  stays readable after `close` but goes nowhere; a new connection starts
  without one.

## Topics

An application streams values on topics it declares: the type, unit and
description are said once, and each value goes with only a sequence number
(and the sender's time, when asked for).

```ruby
imu = net.publish("imu", type: :vector3, unit: "m/s2", desc: "acceleration", ts: true)
imu.put([0.1, 0.0, 9.8])                       # MessagePack, no encoding
cam = net.publish("camera", type: :image, encoding: "image/jpeg")
cam.put(File.binread("frame.jpg"))             # the bytes as they are
net.define_type("mygame/board.strokes", [["pts", "int[]"], ["color", "str"]], desc: "one stroke")
net.publish("board1/strokes", type: "mygame/board.strokes")

net.subscribe("*/demo/imu") do |v, info|       # from net.poll
  puts "#{info.node} #{v.inspect} seq=#{info.seq} lost=#{info.lost} at #{info.time}"
end
net.pubs_of("linux", "demo")                   # => {"imu" => {"t" => 2, "u" => "m/s2", ...}}
```

- **Keys.** `asterism/<node>/<app>/<topic>` (a topic name may have several
  chunks). The declarations are answered at `@profile?pubs` and put on
  `asterism/<node>/<app>/@pubs` when they change; types at `@profile?types`
  ([docs/protocol.md](docs/protocol.md) 9-12).
- **define_type** fields: a built-in type by number or name (`2`,
  `"vector3"`, an array `"vector3[]"`), a basic one (`"int"`, `"str[]"`,
  `"any"` for a value of any shape) or another application type's name;
  `[]` repeats for arrays of arrays (`"int[][]"`).
- **type:** a built-in type (`:number`, `:vector3`, `:pose`, `:image`,
  `:state`, `:log`, `:text`, or its number `Asterism::Types::VECTOR3`) or an
  application type's name (a String). **encoding:** one of Zenoh's
  encodings with a number (`image/jpeg`, `image/png`, `text/plain`, ...):
  the values are then Strings, sent as they are.
- **info** (`Asterism::SampleInfo`): `key`, `node`, `app`, `name`, `seq`,
  `time` (the sender's, ms since 1970, with `ts: true`), `encoding`
  (`"msgpack"` for a MessagePack value), `timestamp` (the router's, when it
  stamped the value), `lost` (values of this key missed since the last
  one) and `restarted?` (the sender started the topic over), `path` (the
  key below `asterism/`), `from` (the sender, `"<node>/<app>"`) and
  `shared` (nil, or `:node` / `:global` on a shared place). A block that
  takes only `|v|` gets the value.
- Topics and subscriptions end with the connection; the types and the
  status are the connection's too. After a new `connect`, declare them on
  the new connection.
- A topic that belongs to another application is declared by a
  connection that is that application
  ([Several connections](#several-connections)).

### Shared places

Data with no single owner goes on a shared place: a node's
`asterism/<node>/@shared/<name>` (what the node emits: its tables'
spectators' view, fed by whichever of its programs runs a table) or the
network's `asterism/@shared/<name>` (a meeting place for the network's
trusted members). Each sender declares the key in its own `@pubs`, with its
own types; several applications may put on one key, and each value says
its sender.

```ruby
t = net.publish("spectate/t1/state", shared: :node, type: "mygame/table")
t.put(state)                                   # asterism/<node>/@shared/spectate/t1/state
g = net.publish("lobby", shared: :global, type: :text)

net.subscribe("*/@shared/spectate/**") do |v, info|
  info.from     # => "linux/room01" (the sender)
  info.lost     # counted per sender
  net.type_of(info)                            # the sender's type: 7, or ["mygame/table", definition]
end
net.publishers_of("linux/@shared/spectate/t1/state")  # => {"linux/games" => {"t" => "mygame/table"}, ...}
net.pubs_of("linux", "games")                  # => {"linux/@shared/spectate/t1/state" => {...}}
```

- **Entries.** A shared topic is declared under the key below `asterism/`:
  `<node>/@shared/<name>` or `@shared/<name>` (an application's own topic
  under its name). `net.published` lists entries; `net.unpublish(topic)` or
  `net.unpublish(name, shared: :node)`.
- **Attachment.** `[seq, ms or nil, "<node>/<app>"]`; the numbers are each
  sender's, and the reader counts `lost` per key and sender.
- **Types.** Two senders may define one type name differently: read a
  value's type from its sender (`net.type_of(info)`,
  `net.declaration_of(info)`), not from another sender of the key.
- **Wildcards.** `@shared` is a verbatim chunk: `net.subscribe("**")` and
  `"<node>/**"` do not reach it; subscribe to `"*/@shared/**"` and
  `"@shared/**"`.
- **Who may put there** is the router's: a node's place by its own node
  (`asterism/${node}/@shared/**`), the network's by the roles an
  administrator grants it to ([docs/protocol.md](docs/protocol.md) 17).

## The connection's session: `net.session`

An application that also puts, subscribes or runs a ROS 2 node uses its
connection's own session for it (0.6.0) instead of opening another:

```ruby
net = Asterism.connect("tcp/192.0.2.2:7447", node: "fmruby-aaaaaa", app: "game")
net.expose("othello", game, methods: [:move, :state])
s = net.session                                         # an Asterism::Zenoh::Session
s.put("asterism/fmruby-aaaaaa/game/othello/log", MessagePack.pack(line))
moves = s.subscribe("asterism/*/game/othello/log")      # moves.each_pending in the update loop
node = Asterism::ROS::Node.new(s, "brain")               # a ROS 2 node with the same Zenoh ID
cmd = node.publisher("/cmd_vel", "geometry_msgs/msg/Twist")
# update loop: net.poll; node.poll
```

CRuby API:

```ruby
Asterism.connect(router, node: "mypc", app: "demo") do |net|
  net.zenoh.subscribe("asterism/*/game/**") { |sample| p sample.key }   # on the receiving thread
  ros = Asterism::ROS::Connection.new(net.zenoh)
  ros.node("brain").subscribe("/odom", "nav_msgs/msg/Odometry") { |odom| puts odom.pose.pose.position.x }
  net.run
end
```

- **Why the same.** A ROS 2 node on the application's session has the
  application's Zenoh ID, so a console draws it inside the node; every
  session costs a TLS link and a router seat on a board; and a router that
  lets each pass in once (a one-time password at a `wss://` door) lets only
  the first session in.
- **Who closes it.** The session is the connection's. `net.session.close`
  (and `net.zenoh.close`) does nothing but warn once, so a library handed
  the session cannot break the connection. `net.close`, the end of the
  connect block and a lost connection close it, and with it everything
  declared on it: the application's subscribers, publishers, ROS 2 nodes.
  Close those yourself when you are done with them earlier (`sub.close`,
  `node.close`; on CRuby `ros.close` withdraws its nodes and leaves the
  rest).
- **After a lost connection** (`net.poll` returned false), connect
  again, take the new connection's session and declare again what you had
  on the old one.
- **Polling.** `net.poll` polls the session; `node.poll` polls it too
  and only then serves the node. Each subscriber, queryable and node keeps
  what came for it, so the order does not matter and nothing is taken from
  another. Your own `put` does not come back to your own subscriber on the
  same session.
- **Keys.** Keep your keys out of the object layer's: `asterism/<node>/<app>/**`
  is answered by its queryable (`get` there is a call), `asterism/<node>/<app>` and
  `asterism/<node>/<app>/<object>` are its liveliness tokens. Values of your
  own under `asterism/<node>/<app>/...` are best declared as topics
  ([Topics](#topics)); a plain put there is fine too: puts and
  subscriptions do not meet queryables or liveliness.

## Several connections

A connection is one application: its liveliness token, its objects, its
status, topics and types, its own profile (`asterism/<node>/<app>/@profile`).
A program that is several applications opens a connection for each,
as the same node or another:

```ruby
game = Asterism.connect(router, node: "host", app: "games")
game.expose("lobby", lobby, methods: { tables: 0 })
room = Asterism.connect(router, node: "host", app: "room01")    # a room as its own application
room.expose("table1", table, methods: { move: 2, view: 1 })
room.publish("table1/state", type: "mygame/table.state").put(state)
room.publish("spectate/table1/state", shared: :node,            # what the spectators see,
             type: "mygame/table.state")                        # on the node's shared place
loop do
  Asterism.poll_all                                             # or game.poll; room.poll
  ...
end
room.close                                                      # game goes on
```

- **Each its own.** Objects, `status`, `publish`, `subscribe`,
  `define_type`, `on_join` and the rest are the connection's. The others
  see each connection as an application (`apps`, `on_app_join`), call its
  objects through the network (with the router's access control, as any
  other application) and get its values (a connection's own values do not
  come back to it, another connection's do).
- **The node's one profile.** Every connection answers
  `asterism/<node>/@profile` for its node, all with the same profile
  ([Profiles](#profiles)).
- **Waiting.** A call waiting on one connection keeps answering the calls
  of the program's other connections (one of them may be the one called),
  and the waits of all of them nest at most `MAX_NESTING` deep in all.
  Their `on_join` / `subscribe` blocks still run only from their own
  `poll`. On CRuby, one lock (`Asterism::LOCK`) serializes them, and each
  may have its own receiving thread.
- **The same `<node>/<app>` twice** is refused: `Asterism.connect` raises
  `Error` when it is open in this program or alive on the network
  (docs/protocol.md 6.3).
- **What each costs.** Every connection is a Zenoh session of its own: on
  a board a TCP or TLS link (the TLS one with its buffers), a seat at the
  router, the queryables of the object layer (calls, the node's profile,
  and the application's profile once it has a status, topic or type) and
  a liveliness watch. One connection is the usual on a board; open a
  second only for a second application. zenoh-pico sessions of one
  program reach each other through a router only (a session's opening
  waits for the other's poll, so they cannot be peers of each other).

## Errors

Every error Asterism raises is an `Asterism::Error` (a `StandardError`):

```
Asterism::Error                       (the Zenoh bindings define it)
├── Asterism::Zenoh::Error            (binding failures; #code is zenoh's result code)
│   └── Asterism::Zenoh::ClosedError  (the session is closed or its connection was lost)
├── Asterism::Disconnected            (object layer: the connection is closed or lost)
├── Asterism::TimeoutError            (no answer in time; old name Asterism::Timeout)
│   └── Asterism::ROS::TimeoutError   (old name Asterism::ROS::Timeout)
├── Asterism::EncodeError
├── Asterism::RemoteError             (remote_kind, remote_class, remote_message)
├── Asterism::ROS::UnknownType
├── Asterism::CDR::DecodeError
└── Asterism::DeprecationError        (only with Asterism.deprecations = :raise)
```

`RemoteError#remote_kind` says what happened on the other side, as a word
of the protocol (docs/protocol.md 4.4): `raised` (the method raised;
`remote_class` is its class there), `not_exposed`, `no_object`,
`arguments`, `malformed`, `unsendable`, `nesting`, `protocol` (the other
side speaks a different protocol); nil when the answer did not say.

The old names `Asterism::Timeout` and `Asterism::ROS::Timeout` still work
(they warn once). Inside `module Asterism`, `Timeout` is Ruby's `Timeout`
module again. The ROS layer raises `Zenoh::ClosedError` when its session
is closed (1.0: `Disconnected`, as the object layer).

## Defaults

| What | Default | Changed by |
|---|---|---|
| A proxy call | 2 s | `net[path, timeout:]` / `timeout_ms:`; `DEFAULT_TIMEOUT` (s), `DEFAULT_TIMEOUT_MS` |
| A service call | 2 s | `client.call(..., timeout:)` / `timeout_ms:`; `Client::DEFAULT_TIMEOUT` |
| `get`, `liveliness_get`, a querier | 2 s | `timeout:` / `timeout_ms:` |
| Connecting | 3 s | `connect_timeout:` (CRuby); `Zenoh::CONNECT_TIMEOUT_MS` (fixed at build time on the boards) |
| A send that cannot go out | 3 s | `Zenoh::SEND_TIMEOUT_MS` |
| The duplicate check of `Asterism.connect` | 1.5 s | `check_timeout:`; `CHECK_TIMEOUT` |
| Queue depth (subscriptions, queryables) | 16 (services 8; the object layer's queryable 32) | `depth:` |
| Queue depth of gets, liveliness gets and liveliness watches | CRuby 1024, the boards 16 (the object layer's watch: 1024 on CRuby, 64 on the boards) | `depth:`; `Zenoh::DEFAULT_GET_DEPTH`, `Zenoh::DEFAULT_WATCH_DEPTH` |
| A full queue | drops the oldest (counted in `dropped`); the CRuby API warns once | `depth:` |
| Pause between polls of a waiting call | 2 ms | `WAIT_STEP_MS`, `Client::WAIT_STEP_MS` |
| Receiving interval of the CRuby API | 2 ms | `interval:` |
| Calls waiting inside each other | 4 (all the connections of a program together) | `MAX_NESTING` |
| Encoding depth of a value | 16 | `Codec::MAX_DEPTH` |
| A profile icon | 8 KB, 256x256, PNG only | `Asterism::Profile::ICON_MAX`, `ICON_SIDE_MAX` |
| `get` consolidation | `:none` (every reply; zenoh's own default is `:auto`, but services and the object layer want every reply) | `consolidation:` |

### Queues

Everything received waits in a bounded queue until taken; when it is full
the oldest entry goes and is counted in `dropped`. A router answers a
wildcard get or liveliness get, and a new liveliness watch, with
everything at once, so on CRuby those three queues hold 1024 by default
(they grow as entries come; nothing is allocated up front). On the boards
they stay at 16: a get's queue is allocated in full when it is sent (in
PSRAM on ESP-IDF) and a watch's comes from the VM's pool; pass `depth:`
when a wildcard can match more.

On CRuby, a get (`get`, `Querier#get`, `liveliness_get`), a liveliness
watch or a subscription of the CRuby API whose depth was left at the
default warns once (`asterism: get demo/**: 3 replies dropped, ...`) when
something was dropped; with `depth:` given it stays quiet, and `dropped`
tells. The object layer warns once when its own watch dropped changes
(then `net.each` and `net.nodes` may miss objects).
`Asterism.warn_once(obj, message)` is the helper.

Every `each_*` of the portable API (`each_pending`, `each_reply`,
`each_result`) takes what is there now, without waiting, and returns an
Array without a block (it drains the queue; an Enumerator would take only
when iterated).

## Deprecations and 1.0

0.4.0 adds and deprecates; nothing that worked in 0.3.0 stops working. A
deprecated call warns once per name (`warn` on CRuby, so it goes to
`$stderr`; on the boards `warn` or `puts`, once per VM).
`Asterism.deprecations = :raise` (or the environment variable
`ASTERISM_DEPRECATIONS=raise`) raises `Asterism::DeprecationError` instead,
for CI; `:silent` turns them off.

| Deprecated (0.4.0) | Use | In 1.0 |
|---|---|---|
| `net[path, 2000]` (the time as a positional argument) | `net[path, timeout: 2.0]` or `timeout_ms: 2000` | removed |
| A Float there (`net[path, 2.0]` waits 2 ms) | `timeout: 2.0` | removed (warns with its own message now) |
| `session.get(key, ms, params, payload)`, `session.liveliness_get(key, ms)` | `timeout:` / `timeout_ms:`, `params:`, `payload:` | removed (a positional depth stays) |
| `session.peers`, `connection.peers` | `connection_count` | removed |
| `Asterism::Timeout`, `Asterism::ROS::Timeout` | `TimeoutError` | kept as aliases through 1.x |
| `proxy.methods` (the remote list) | `proxy.remote_methods` | `Object#methods` again |
| `Connection::Subscription#each_pending` (CRuby API; it gave Samples) | `each_sample` | removed |
| `q.reply(payload)` where the query's key differs from the queryable's own plain key | `q.reply(key, payload)` | answers on the queryable's key (as the CRuby API does) |
| `client.call(field: ...)` with a field named `timeout` / `timeout_ms` | `request: { ... }` (or a Hash) | the keyword is the time limit (`ArgumentError` when ambiguous) |

Also changing in 1.0, without a warning now: `net.each { }` returns the
connection instead of a count; the ROS
layer raises `Disconnected` when its session is closed; the internal
methods (marked `@api private` in the source) are hidden.

### Reserved keywords

`client.call` and `node.call` take the request's fields as keywords, next
to `request:`, `timeout:` and `timeout_ms:`. A request type with a field
of one of those names cannot be given that field as a keyword without
ambiguity: give the request as `request: { timeout: 5 }` (or a Hash /
message as the first argument) and the time limit as `timeout:`. In 0.4.0
the ambiguous keyword warns; on the portable API a `timeout:` field stays
a field, as before.

### When the connection is lost

A client of a router keeps its connection when the router goes away for a
while (it restarts, the line drops): the Zenoh binding opens the connection
again by itself (zenoh-c on CRuby; zenoh-pico built with reconnection on
the boards) and declares again everything that was declared, so the
application token, the exposed objects, the liveliness watch, the topics
and what the application declared on `net.session` are all back without
the application doing anything. Meanwhile `net.reconnecting?` is true,
`connected?` stays true, the other nodes leave (`on_leave`) and join again
after it (`on_join`), calls raise `Asterism::Disconnected` or time out, and
puts reach nobody. The profile, the status and the topics are told again
once it is back. Measured
with zenohd 1.10.1 restarted by `docker restart` (`rake test:reconnect`,
CRuby and mruby): back about 1 s after the router.

A peer connection (or a build without reconnection) is closed when the
peer (or the router) goes away, and is not reopened by itself. From then on
`net.poll` returns `false`, `connected?` is false, `lost_reason` says
why, and calls raise `Asterism::Disconnected`. **`Asterism::Zenoh::Error`
never comes out of Asterism; it is always wrapped in `Disconnected`** (the
message is kept). Everything of the connection is gone with it (objects,
status, topics, types, subscriptions): to go on, the application calls
`Asterism.connect` again (a new connection) and sets them again on it, with
what it had on the old `net.session` (subscribers, ROS 2 nodes; the old
session is closed, its entities raise `Zenoh::ClosedError`). The node's
profile stays (it is the node's).

## Values

Only what MessagePack carries: `nil`, `true`, `false`, `Integer` (signed
64 bit), `Float`, `String`, `Array`, `Hash`. A `Symbol` is sent as a
`String` and arrives as one (also as a Hash key; keyword names become
Symbols again). A binary String (`String#b`: ASCII-8BIT on CRuby, the
binary flag on mruby) goes as a MessagePack bin and arrives as a binary
String; any other String goes as text (str). Anything else in the
arguments, or an Integer outside the signed 64-bit range, raises
`EncodeError` before sending; in a return value the caller gets
`RemoteError` (`unsendable`). Nesting is limited to 16 levels.

- Hash keys: use String (or Symbol) and Integer keys for anything another
  language reads (Python and JavaScript refuse others by default).
- Times: send an Integer of nanoseconds since the epoch (or name the unit:
  `timeout_ms`); there is no time type.
- A keyword given as `nil` and one left out differ: the callee's default
  applies only to the one left out.
- A JavaScript caller's `1.0` arrives as the Integer `1`.

## Who called

The caller's node ID travels in the call's key (`.../call/<caller>`). An
exposed method can read it:

```ruby
class Rover
  def initialize(net) = @net = net

  def stop
    c = @net.current_call            # nil outside a call
    log("stop from #{c.from}")       # c.verified: :claimed (:local from this app)
  end

  def drive(v, w, from:)             # caller: :from fills from: in
    log("drive from #{from}")
  end
end
net.expose("rover", Rover.new(net), methods: { stop: 0 })
net.expose("wheels", Rover.new(net), methods: { drive: 2 }, caller: :from)
```

- `net.current_call` is set only while a method of that connection runs
  for a call (per thread on CRuby). Calls answered while that method waits for its own
  call come on top of it and go when they end.
- With `caller: :from`, a call that passes `from:` itself is refused
  (`RemoteError`, `remote_kind` `arguments`): `from` is always the one
  Asterism took from the call.
- **It is a claim.** Any client can call with any name. A router's access
  control makes it binding: with mutual TLS, zenohd's ACL can let each
  certificate query only keys ending in its own name
  (`asterism/*/*/*/call/<name>`; docs/protocol.md 4.7). Without such a
  router, use `from` to avoid mistakes, not to decide who may do what.

## Keys and encoding

Wire protocol 2. The full description, for implementations in other
languages, is [docs/protocol.md](docs/protocol.md) (with the conformance
tests); why it has this shape (the review of protocol 0's Ruby-shaped
parts, and what was decided) is
[docs/protocol_review.md](docs/protocol_review.md).

| Key | Zenoh | Payload |
|---|---|---|
| `asterism/<node>/<app>/<object>/call/<caller>` | get / queryable | query: `{"method" => name, "args" => [...], "kwargs" => {...}}` (args and kwargs left out when empty); reply: `{"value" => value}` or `{"error" => {"kind" => ..., "class" => ..., "message" => ...}}`. `<caller>` is the calling node's ID |
| `asterism/<node>/<app>/<object>/meta` | get / queryable | reply: `{"methods" => [{"name" => name, "arity" => n}, ...]}` (arity `-1` when not declared). The object may be `*` in the query: one reply per object |
| `asterism/<node>/<app>` | liveliness | the application is connected (a node is there while any of its applications or objects is) |
| `asterism/<node>/<app>/<object>` | liveliness | the object is exposed |
| `asterism/<node>/@profile` | get / queryable, and put | query (parameter `icon=0` for no icon): reply the node's profile, a Hash (`kind`, `host`, `name`, `icon`, `icon_hash`; [Profiles](#profiles)). The node also puts the profile without the icon at connect and on each change. `@profile` is a verbatim chunk, so `asterism/**` does not match it: the object layer's wildcards never see it. Every connection of the node answers it |
| `asterism/<node>/<app>/@profile`, `@status`, `@pubs`, `<topic>` | get / queryable, put | the application's own profile (its status, topics and types), the puts of its status and topics, the values of its topics ([Status](#status), [Topics](#topics)) |

One queryable per application (`asterism/<node>/<app>/**`), one for the
node's profile (`asterism/<node>/@profile`), and one for the application's
own profile once it has a status, topic or type. A call whose
node or app is a wildcard reaches every application that exposes that
object, each answering with its own key; Asterism itself only sends calls
to one object.

## How waiting works

Everything is polled; nothing runs behind the application. A call that
waits keeps polling (pausing 2 ms between polls) and answers the calls that
come in meanwhile, so two machines calling each other at the same time do
not lock up. An answered call may itself call and wait; such waits nest at
most `Asterism::MAX_NESTING` (4) deep, beyond that the call raises `Error`
(the caller of the outer call gets it as `RemoteError`). While a call
waits, the rest of that application (drawing, input) waits too; other
applications do not. A program's other connections keep answering their
calls meanwhile (their `poll` blocks wait), and the nesting counts the
waits of all of them.

Calls to an object of the same application (`<node>/<app>` is this one) do
not go out (a Zenoh session does not see its own queryable): they are run
in place, with the same encoding and checks.

## Stack

A waiting call polls Zenoh on the caller's C stack. Measured on the P4
(Family mruby, 16 KB application stack): the application idles at 8.1 KB
used; a waiting call made from the update loop takes it to 10.7 KB, also
with calls answered while waiting (two machines relaying calls to each
other). The same call made from an input handler that C calls into (one more
interpreter entry) reached 12.4 KB; an earlier version of this gem, which
took zenoh replies through blocks and fetched the meta from inside
`respond_to_missing?`, overflowed the stack there. Make waiting calls from
the update loop, or use `async`.

The blocks the layers call (`net.on_join` / `on_leave`, `net.subscribe`,
the ROS `node.subscribe` and `node.every` blocks) run from `net.poll` /
`node.poll`, that is on the update loop's stack, one Ruby block call deeper.
The layers walk their lists with `while` loops so that nothing else stands
between the update loop and the block. **Do not wait inside these blocks**
(no proxy call, no `node.call` / `client.call`): note what came, and make
the call from the update loop, or start a `call_async` / `async` call and
look at it later.

Measured on the P4 (Family mruby, 16 KB): an application with
`on_join` / `on_leave` blocks, relaying calls with another machine in both
directions at once, keeps 5.8 KB free (as before the blocks); a ROS node
publishing from `node.every` and receiving through a `node.subscribe` block
keeps 6.9 KB free, the same as polling `each_pending` by hand. Loading a
nested type (`geometry_msgs/msg/Twist`) at start-up took 0.6 KB more.

## Files in pieces: `Asterism::Transfer`

A file carried from one machine to another over calls, that comes through
lost, repeated and reordered pieces, a connection that drops for a while
and a receiver started again, and arrives whole (its SHA-256 checked) or
not at all. The receiver's position is the truth: every answer says how
many bytes it holds, and the sender goes on from there. Plain Ruby that is
not compiled into the mrbgem (an mruby VM that carries no files pays
nothing for it): `data/transfer/transfer.rb`, which the boards load at run
time (`require "/usr/share/asterism/transfer/transfer"` on Family mruby)
and CRuby with `require "asterism/transfer"`. Its head describes the calls
(`begin` / `chunk` / `commit` / `cancel`).

```ruby
# the receiver: what it takes and where a whole file goes
class Inbox < Asterism::Transfer::Inbox
  def refused(kind, from, meta) = (kind == "file" ? nil : "takes no #{kind}")
  def received(t) = (File.rename(t["part"], "inbox/#{t['name']}"); { "status" => "placed" })
end
inbox = Inbox.new("tmp/")          # the piece files and their notes go here
inbox.resume_held                  # a file held when it last ended goes on
net.expose("inbox", inbox, methods: Asterism::Transfer::Inbox::METHODS, caller: :from)
# ... inbox.tick in the update loop

# the sender: stepped from the update loop, never waiting in one go
s = Asterism::Transfer::Sender.new("node-b/app/inbox", "file", "photo.png", net: net, name: "photo")
until s.done?
  net.poll
  s.step
end
s.ok? ? s.answer : s.reason
```

On CRuby, `Asterism::Transfer::FileInbox` is the receiver of the kind
`file` (the rules of a Family mruby machine: the senders allowed, names
that stay in its directory, `foo(1).txt` beside a name already there unless
the sender asks to overwrite, a limit for the directory), and
a second connection (`Asterism.connect(router, node: "mypc", app: "transfer")`)
can expose it at `<node>/transfer/inbox`, where the machines send, beside
the program's own application. `Asterism::Transfer::Endpoint` does the
same on a plain Zenoh connection:

```ruby
conn = Asterism::Zenoh.open("tcp/127.0.0.1:7447")
inbox = Asterism::Transfer::FileInbox.new("inbox/", work: "work/", from: ["fmruby-*"],
                                          max_bytes: 1 << 30, label: "mypc").start
ep = Asterism::Transfer::Endpoint.new(conn, inbox, node: "mypc").start
conn.start
loop { ep.tick; sleep 0.5 }   # a file that stopped coming is deleted after a minute
```

A piece is 3,072 bytes by default: one call carries about 4 KB in all on
zenoh-pico (`Z_FRAG_MAX_SIZE` 4096; a String argument of 4,044 bytes still
went through between two Family mruby programs, 4,048 did not and was not
answered at all). SHA-256 is CRuby's Digest, mbedTLS (`MbedTLS::Digest`)
where the build has it, else plain Ruby (`data/transfer/sha256.rb`, slow).

## Limits

- Objects cannot be passed by reference (a return value is a copy), blocks
  cannot be sent, there are no events (later stages).
- The wire protocol is protocol 2 only: every node of a network moves to
  it together (nodes of asterism before 0.7.0, protocol 0, do not see its
  objects, and a protocol 0 call is refused with `remote_kind`
  `protocol`).
- No authentication by default (plain TCP): a trusted LAN is assumed, or
  TLS through a router (CRuby; [Over TLS](#over-tls-a-router-on-the-internet)).
- One object-layer connection per process (per VM on the boards).
- Pattern matching on the boards: `case/in` with `deconstruct_keys`, nested
  hash patterns, classes and ranges as values, array and find patterns,
  guards, alternatives, pins of a local of the same scope and binding from
  inside a block work with the compiler of mruby-compiler2 `a2c72afb` or
  later (PicoRuby master), and in Family mruby, which carries the two fixes
  on its older PicoRuby. An older PicoRuby compares a hash pattern's value
  the wrong way round (a class or a range never matches, a literal matches
  any value) and does not bind an outer variable from inside a block;
  there, match on the key alone and test the value in Ruby. Still
  different on Family mruby's PicoRuby: `^x` of an outer local inside a
  block, `^(expr)`, `Const[...]` and `**rest` next to another key. The full
  list of what the boards' Ruby can and cannot do is in
  [docs/ruby_features.md](docs/ruby_features.md) (the Ruby feature table).

## ROS 2 (rmw_zenoh): `Asterism::ROS` and `Asterism::CDR`

A minimal ROS 2 node that talks to ROS 2 systems using rmw_zenoh (checked
with ROS 2 Jazzy, rmw_zenoh_cpp 0.2.11, Zenoh 1.8.0), directly on an
`Asterism::Zenoh::Session`. Pure Ruby, independent of the object layer above
(no `Asterism.connect`, no MessagePack; only its clock and pause helpers).
Topics and services. The message and service types are generated from
`.msg` / `.srv` files (see [Message types](#message-types)) and loaded when
the application asks for them.

```ruby
s = Asterism::Zenoh::Session.open("tcp/192.0.2.2:7447")
node = Asterism::ROS::Node.new(s, "fmruby_talker")       # namespace: "/", domain: 0
str = Asterism::ROS.require_type("std_msgs/msg/String")
pub = node.publisher("/chatter", str)
sub = node.subscription("/chatter_back", "std_msgs/msg/String")  # by name works too
loop do
  s.poll
  pub << { data: "hello" }                               # or pub.publish(str.new(data: "hello"))
  sub.each_pending { |msg, info| puts "#{info && info.sequence}: #{msg.data}" }
end

# or with blocks, run from node.poll (in the update loop):
node.every(1) { pub << { data: "tick" } }               # or every(ms: 1000)
node.subscribe("/cmd_vel", "geometry_msgs/msg/Twist") { |msg, _info| drive(msg) }
loop { node.poll }

def drive(msg)
  case msg                                               # deconstruct_keys
  in { linear: { x: }, angular: { z: } } then move(x, z)
  end
end
node.close                                               # or let the session close
```

Services:

```ruby
add = Asterism::ROS.require_type("example_interfaces/srv/AddTwoInts")
node.service("/fmruby/add_two_ints", add) { |req| { sum: req.a + req.b } }
cli = node.client("/add_two_ints", add)
loop do
  node.poll                       # session.poll, then answers the requests
  res = cli.call(a: 2, b: 3)      # waits (polling), raises Asterism::ROS::TimeoutError
  puts res.sum
  c = cli.call_async(a: 2, b: 3)  # returns at once
  # ... later updates:
  puts c.value.sum if c.done?
end
```

| Call | Returns | Notes |
|---|---|---|
| `Asterism::ROS::Node.new(session, name, namespace: "/", domain: 0, enclave: "/")` | `Node` | Declares the node's liveliness token (`ros2 node list`). `name` has no `/`. |
| `node.publisher(topic, type, qos: DEFAULT_QOS)` | `Publisher` | `topic` absolute, or relative to the namespace. `type` is a generated type or its ROS name (`"geometry_msgs/msg/Twist"`, loaded with `require_type`); the same for subscriptions, services and clients. Declares the publisher token (`ros2 topic list`). |
| `pub.publish(msg)` / `pub << msg` | nil / `pub` | `msg` is a message of the type or a Hash of its fields. Puts the CDR payload with rmw_zenoh's attachment (sequence number, time, GID). |
| `node.subscription(topic, type, qos: DEFAULT_QOS, depth: 16)` | `Subscription` | Subscribes and declares the subscription token. |
| `sub.each_pending { \|msg, info\| }` | count | `info` is an `Attachment` (`sequence`, `stamp_ns`, `gid`) or nil. Samples that are not valid CDR are skipped and counted in `sub.errors`. `sub.pending` / `received` / `dropped` count as the Zenoh subscriber's do. |
| `node.service(name, type, qos: DEFAULT_QOS, depth: 8) { \|req\| response }` | `Service` | Serves `name` (`ros2 service list`). The block gets a `type::Request` and returns a `type::Response` or a Hash of its fields. It runs from `node.poll` (or `service.handle_pending`), never behind the application. A request without rmw_zenoh's attachment, or that does not decode, is counted in `service.errors` and gets no answer. An exception from the block ends that request without an answer and is raised from `node.poll`. `service.handled`: answered so far. |
| `node.poll(steps = 8)` | true / false | `session.poll(steps)`, then answers the requests waiting for this node's services, then gives what came to the `subscribe` blocks and fires the `every` timers that are due. Returns what `session.poll` returns. A waiting `client.call` polls only the session and the services (`node.pump`), not the blocks. |
| `node.subscribe(topic, type, qos: DEFAULT_QOS, depth: 16) { \|msg, info\| }` | `Subscription` | `node.subscription` whose messages (decoded, with their `Attachment` or nil) go to the block, from `node.poll`. `sub.close` ends it. Do not wait in the block (see [Stack](#stack)). Without a block it is `node.subscription`. |
| `node.every(seconds) { }` / `node.every(ms: 500) { }` | `Timer` | Calls the block every `seconds` (a Float works) or `ms:` milliseconds, the first time one period from now, from `node.poll` (so no more often than the update loop polls). It keeps the period; after a long stall it starts again from now instead of firing the missed times at once. `timer.cancel`, `timer.fired` (count), `timer.period` (s), `timer.period_ms`. Do not wait in the block. |
| `node.client(name, type, qos: DEFAULT_QOS)` | `Client` | Declares the client token. |
| `client.call(request = nil, request: nil, timeout: 2.0, **fields)` | `type::Response` | Sends the request (a `type::Request` or a Hash, positional or `request:`, or the fields as keywords) and waits, polling the node (its services keep answering). The time limit: `timeout:` (seconds) or `timeout_ms:`. `Asterism::ROS::TimeoutError` when no response came in time, at once when nobody serves the name; `Asterism::Zenoh::ClosedError` when the session closed. See [Reserved keywords](#reserved-keywords). |
| `client.call_async(...)` | `Call` | The same arguments; sends and returns at once. `call.done?` never waits (`node.poll` moves it on); `call.value` waits and returns the response or raises like `call`; `call.response` (nil until it came), `call.took` (s) / `took_ms`, `call.sequence`. |
| `node.call(name, type, request = nil, request:, timeout:, **fields)` | `type::Response` | `client.call` through a client made on first use and kept per name. |
| `node.close` / `pub.close` / `sub.close` / `service.close` / `client.close` | nil | Withdraws the tokens (they also go when the session closes). `node.close` closes everything the node made. |
| `Asterism::ROS.require_type(name)` | the type | Loads `<pkg>/<msg\|srv>/<Name>.rb` from `Asterism::ROS::TYPE_PATH` (`["/usr/share/asterism/msgs"]`; add directories to it) and returns `Asterism::ROS::<Pkg>::<Name>`. A type already loaded (or defined in Ruby) is returned at once. `UnknownType` when there is no file. |
| `Asterism::CDR::Writer` / `Reader` | | Plain CDR with the 4-byte header, aligned from the end of the header: `bool int8 uint8 int16 uint16 int32 uint32 int64 uint64 float32 float64 string`, `array(kind, v, fixed, max)`, `bytes`, `structs(type, ...)`. Writes little endian; reads either order. |

What goes on the wire (rmw_zenoh_cpp 0.2.x):

| Item | Form |
|---|---|
| Data key | `<domain>/<topic without the outer "/">/<DDS type>/<type hash>`, e.g. `0/chatter/std_msgs::msg::dds_::String_/RIHS01_df668c74...` |
| Payload | CDR: `00 01 00 00`, uint32 length with the NUL, bytes, NUL |
| Attachment | int64 sequence, int64 time (ns since the epoch), both little endian, one byte GID length (16), 16 bytes GID: 33 bytes. **Required**: rmw_zenoh drops a sample without it |
| Node token | `@ros2_lv/<domain>/<zid>/<nid>/<nid>/NN/<enclave>/<namespace>/<node>` |
| Topic token | `@ros2_lv/<domain>/<zid>/<nid>/<id>/MP` (or `MS`) `/<enclave>/<namespace>/<node>/<topic>/<DDS type>/<type hash>/<qos>` |
| Service key | `<domain>/<service without the outer "/">/<DDS service type>/<service type hash>`, e.g. `0/add_two_ints/example_interfaces::srv::dds_::AddTwoInts_/RIHS01_e118de6b...`. The type and hash are those of the service, not of its Request / Response |
| Service request | a get on the service key, target ALL_COMPLETE, no consolidation, payload the request's CDR, attachment as above (the client's sequence number from 1, time, the client's GID) |
| Service reply | from a **complete** queryable (a non-complete one never sees ALL_COMPLETE queries), on the service key, payload the response's CDR, attachment: the request's sequence number and GID with the server's time. The client pairs reply and request by the sequence number |
| Service tokens | like topic tokens, with `SS` (server) and `SC` (client) |

In tokens, `/` inside a name is written `%` (`/chatter` is `%chatter`, the
root namespace `%`). `<zid>` is the Zenoh session ID (`session.zid`).
`DEFAULT_QOS` (`::,10:,:,:,,`) is rmw_zenoh's form of the default profile:
reliable, volatile, keep last 10.

Not here (later stages): actions, QoS other than the default (transient
local needs Zenoh's advanced publisher), name remapping, receiving a type
the application has not loaded.

## Message types

### Values

A generated message is a plain Ruby class (`Asterism::ROS::Message` is its
base; the app VM has neither `Data` nor `Struct`). The same code runs on
CRuby.

```ruby
Twist = Asterism::ROS.require_type("geometry_msgs/msg/Twist")
t = Twist.new(linear: { x: 0.1 })     # missing fields take their defaults
t = Twist.from({ "linear" => { "x" => 0.1 } })   # Hash, String keys too
t.linear.x                            # => 0.1
t.angular                             # => #<geometry_msgs/msg/Vector3 {x: 0.0, ...}>
t.to_h                                # => {linear: {x: 0.1, y: 0.0, z: 0.0}, angular: {...}}
bytes = Twist.encode(t)               # or Twist.encode(linear: { x: 0.1 })
Twist.decode(bytes) == t              # => true
Twist::TYPE_NAME                      # "geometry_msgs::msg::dds_::Twist_"
Twist::TYPE_HASH                      # "RIHS01_9c45bf16..."
Asterism::ROS::SensorMsgs::BatteryState::POWER_SUPPLY_STATUS_FULL   # constants
```

| Field in the .msg | Ruby value | Default |
|---|---|---|
| `bool` | true / false | false |
| integers, `byte`, `char` | Integer (a `uint64` at or above 2**63 reads back negative) | 0 |
| `float32` / `float64` | Float | 0.0 |
| `string`, `string<=N` | String (UTF-8 bytes; longer than N raises `ArgumentError` on encode) | "" |
| a message | that type (a Hash is turned into it) | its defaults |
| `T[N]`, `T[]`, `T[<=N]` | Array (a wrong length or over the bound raises `ArgumentError` on encode) | N defaults, or [] |
| `byte[]`, `uint8[]`, `char[]` (any size) | a binary String (an Array of Integers is taken too) | "\0" * N, or "" |
| `wstring` | not supported: encode / decode raise `NotImplementedError` | |

Defaults written in the .msg (`float64 w 1`) are used. Unknown field names
raise `ArgumentError`; integers are not range-checked (they wrap).

### The bundled types

Made from ROS 2 Jazzy's definitions, in `data/msgs` (on a board:
`/usr/share/asterism/msgs`), one file per type:
std_msgs (Bool, Byte, Char, String, Empty, the integer and float types,
Header, ColorRGBA, MultiArrayDimension / Layout and every *MultiArray),
builtin_interfaces (Time, Duration), geometry_msgs (Vector3, Point, Point32,
Quaternion, Pose, Pose2D, Twist, Accel, Transform, Wrench and their
*Stamped, PoseWithCovariance, TwistWithCovariance), sensor_msgs (Imu,
BatteryState, Temperature, Range, MagneticField, Illuminance,
FluidPressure, RelativeHumidity, JointState, NavSatStatus, NavSatFix,
LaserScan, PointField, PointCloud2, CompressedImage), nav_msgs (Odometry,
Path, MapMetaData, OccupancyGrid), diagnostic_msgs (DiagnosticArray,
DiagnosticStatus, KeyValue), tf2_msgs/TFMessage, visualization_msgs
(Marker, MarkerArray, MeshFile, UVCoordinate), rcl_interfaces (Log for
`/rosout`, ParameterEvent, Parameter, ParameterValue),
example_interfaces/srv/AddTwoInts. The list is `tools/bundled_types.txt`
(84 files, 0.23 MB). Nothing of them is compiled into the mrbgem: an
application loads what it uses, and each file loads the types it is made
of.

### Field types

Each generated message has `FIELD_TYPES` next to `FIELDS`: what each field
is, as plain Arrays, Strings, Integers and nil (the same on the boards),
one `[name, base, kind, nested, capacity, string_capacity]` per field:

| Element | Value |
|---|---|
| `name` | the field name (a String) |
| `base` | the .msg type: `"float64"`, `"string"`, `"uint8"`, ..., or the full name of a message (`"std_msgs/msg/Header"`) |
| `kind` | `"scalar"`, `"array"` (`T[N]`), `"bounded_sequence"` (`T[<=N]`) or `"sequence"` (`T[]`) |
| `nested` | the full name of the message type, or nil |
| `capacity` | N of an array or a bounded sequence, else nil |
| `string_capacity` | N of `string<=N`, else nil |

```ruby
Asterism::ROS::SensorMsgs::JointState::FIELD_TYPES
# => [["header", "std_msgs/msg/Header", "scalar", "std_msgs/msg/Header", nil, nil],
#     ["name", "string", "sequence", nil, nil, nil],
#     ["position", "float64", "sequence", nil, nil, nil], ...]
Asterism::ROS.field_types("sensor_msgs/msg/Imu")
# => {"sensor_msgs/msg/Imu" => [...], "std_msgs/msg/Header" => [...],
#     "geometry_msgs/msg/Quaternion" => [...], "geometry_msgs/msg/Vector3" => [...],
#     "builtin_interfaces/msg/Time" => [...]}
```

`Asterism::ROS.field_types(type)` takes a type or its name, loads the
types it is made of and gives the `FIELD_TYPES` of each, the type first
(for a service, its Request and Response). A byte array or sequence
(`uint8`, `byte`, `char`) is a binary String in Ruby (see the table
above). Types generated before 0.4.1 have no `FIELD_TYPES`; regenerate
them (`field_types` raises `Asterism::ROS::UnknownType` for them).

### Making types: `tools/asterism_msggen.rb`

CRuby, standard library only, no ROS 2 installation needed (only the
`.msg` / `.srv` files of the packages involved):

```
# a type of an installed ROS 2 (and the types it uses)
ruby tools/asterism_msggen.rb -I /opt/ros/jazzy/share -o out geometry_msgs/msg/Twist
# your own package (my_pkg/msg/Foo.msg; -I for the packages it refers to)
ruby tools/asterism_msggen.rb -I /opt/ros/jazzy/share -o out path/to/my_pkg/msg/Foo.msg
# print the type hashes
ruby tools/asterism_msggen.rb -I share --hash example_interfaces/srv/AddTwoInts
# compare the hashes with the type description JSON ROS 2 installs
ruby tools/asterism_msggen.rb -I /opt/ros/jazzy/share --check-json /opt/ros/jazzy/share sensor_msgs/msg/Imu
```

`-I` directories are laid out like a ROS 2 `share`: `<pkg>/msg/*.msg`,
`<pkg>/srv/*.srv`. The output is `<out>/<pkg>/<msg|srv>/<Name>.rb`; copy it
to the device (`/usr/share/asterism/msgs` or a directory added to
`Asterism::ROS::TYPE_PATH`), or put the output directory in `TYPE_PATH` on
CRuby. A service's type hash needs `service_msgs/msg/ServiceEventInfo` and
`builtin_interfaces/msg/Time` under `-I` (every ROS 2 `share` has them).

The type hash (RIHS01) is computed the way ROS 2 Jazzy does
(`rosidl_generator_type_description`): the type and every type it refers
to, each as `{type_name, fields: [{name, type: {type_id, capacity,
string_capacity, nested_type_name}}]}` without default values, the referred
ones sorted by name, written as Python's `json.dumps(..., separators=(", ",
": "))`, then SHA-256. A service's description is `request_message`,
`response_message` and `event_message` (`<Name>_Event`: `info`, and
`request` / `response` as sequences of at most one). Other ROS 2 versions
may change the rules; regenerate and check with `--check-json` against that
version.

`tools/ros2_jazzy/` holds the Jazzy definitions of the bundled types and
the hashes from Jazzy's JSON (`type_hashes.txt`) that the tests
(`rake test:msgs`) compare with. `tools/ros2_types.rb` refreshes both, and
`data/msgs`, from a ROS 2 Jazzy docker image (`rake types:refresh` with
`ASTERISM_ROS2_IMAGE`; `rake types:check` only compares). The definitions
are from ros2/common_interfaces, ros2/rcl_interfaces,
ros2/example_interfaces (Apache License 2.0) and ros2/geometry2 (tf2_msgs,
BSD 3-Clause License); see NOTICE.

### Loading

On mruby, `require_type` reads the file and evaluates it in the
application's VM (`Kernel#eval`); PicoRuby's `require` would run each file
in a Sandbox task that stays for the life of the VM. On CRuby it uses
`require`. Measured on the P4 (Family mruby, a 1 MB VM pool):
geometry_msgs/Twist with Vector3 15.3 KB, sensor_msgs/Imu with Header,
Time and Quaternion 32.8 KB more, std_msgs/Float32MultiArray with its
layout types 20.0 KB more (68 KB for nine files, 340 ms). Evaluating a file
compiles it on the caller's stack (about 2.5 KB deeper than the update
loop); load the types in `on_create`, not in a deep call chain.

A type name may come from the network, so `require_type` checks it before
it builds a path: `pkg/msg/Name` or `pkg/srv/Name`, the package
`[a-z][a-z0-9_]*`, the name `[A-Z][A-Za-z0-9]*` (ROS 2's rules for
interface names). Anything else (`../msg/Foo`, an empty part, an upper-case
package, more slashes, NUL) raises `ArgumentError`.
