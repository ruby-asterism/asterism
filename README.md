# Asterism

Asterism joins Ruby on PCs, boards (mruby / PicoRuby) and ROS 2 into one
Zenoh network: Ruby objects on other machines are called like local ones,
and a Ruby program can be a ROS 2 node (rmw_zenoh's wire format). This
repository holds the pure Ruby layers, written once for every Ruby:

| Path | What |
|---|---|
| `mrblib/` | The layers: remote objects (`Asterism`), `Asterism::CDR`, `Asterism::ROS`. The source of truth for both forms below |
| `mrbgem.rake` | The mrbgem `picoruby-asterism` (mruby / PicoRuby): compiles `mrblib/` |
| `asterism.gemspec`, `lib/` | The CRuby gem `asterism`: `lib/asterism.rb` loads `mrblib/` as it is, `lib/asterism/cruby.rb` adds what CRuby needs, `lib/asterism/cruby/` the Ruby-like API (CRuby only) |
| `data/msgs/` | ROS 2 message types generated from ROS 2 Jazzy's definitions (Apache-2.0, see NOTICE) |
| `tools/` | The type generator `asterism_msggen.rb`, the Jazzy definitions it reads, `ros2_types.rb` (refreshes them from a ROS 2 image) |
| `test/` | `test/msgs` (types, CDR; CRuby only), `test_asterism.rb` (objects and ROS between CRuby sessions), `test_api_*.rb` (the Ruby-like API) |
| `examples/` | CRuby: `node.rb` (objects with a board), `node_polled.rb` (the same with the polled API of the boards), `ros2_talker.rb` (topics, a timer, services with ROS 2), `zenoh.rb` (plain Zenoh) |

The Zenoh binding underneath is a separate gem with the same Ruby API on
each Ruby:

- CRuby: [asterism-zenoh](https://github.com/ruby-asterism/asterism-zenoh)
  (over zenoh-c)
- mruby / PicoRuby: [picoruby-asterism-zenoh](https://github.com/ruby-asterism/picoruby-asterism-zenoh)
  (over zenoh-pico)

Neither gem is on rubygems.org yet (version 0.2.0 builds from these
repositories with `rake gem`).

## Using it

CRuby (needs CRuby 3.2+ and a C compiler):

```
gem install asterism          # also installs asterism-zenoh (~> 0.2.0) and msgpack
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
gem install --local ../asterism-zenoh/pkg/asterism-zenoh-0.2.0.gem pkg/asterism-0.2.0.gem
```

From the working trees, without installing:

```
ruby -I lib -I ../asterism-zenoh/lib your_script.rb    # after `rake compile` in ../asterism-zenoh
```

`Asterism::ROS::TYPE_PATH` is `data/msgs` there; add your own directories.
MessagePack sends every String as str (compatibility mode), as the boards
do: their MessagePack does not read the bin type.

mruby / PicoRuby: add this repository and picoruby-asterism-zenoh as gems
(`conf.gem "path/to/asterism"`; a `MessagePack` module with `pack` /
`unpack` is needed too), and put `data/msgs` on the device's file system at
`/usr/share/asterism/msgs` (or add the place to
`Asterism::ROS::TYPE_PATH`). Family mruby does this from pinned commits of
these repositories.

## Tests

```
rake                  # every suite
rake test:msgs        # generator, type hashes, CDR, bundled types (CRuby only; no Zenoh, no docker)
rake test:objects     # objects and Asterism::ROS between CRuby sessions over a local peer link
rake test:api         # the Ruby-like API (blocks, receiving threads, Enumerators)
ASTERISM_TEST_ROUTER=tcp/127.0.0.1:7447 rake test:objects test:api   # the same through a zenohd router
```

`test:objects` and `test:api` need asterism-zenoh: built next to this repository
(`../asterism-zenoh`, its `rake compile`), or `ASTERISM_ZENOH_DIR`, or the
installed gem.

## Examples

```
# objects: join the app "demo" of Family mruby's asterism_demo, call a board,
# and answer its calls (its keys s / a call screen.say / apu.play here)
ruby examples/node.rb --router tcp/192.0.2.2:7447 [--peer fmruby-aaaaaa]
ruby examples/node_polled.rb --router tcp/192.0.2.2:7447    # the same, polled

# ROS 2: /chatter and /cmd_vel from a timer, /chatter_in printed,
# /cruby/add_two_ints served, AddTwoInts calls
ruby examples/ros2_talker.rb --router tcp/192.0.2.2:7447 [--service NAME]

# plain Zenoh: run two with different --name
ruby examples/zenoh.rb --router tcp/192.0.2.2:7447 --name pc1
```

## The Ruby-like API (CRuby only)

On CRuby, `require "asterism"` also brings a layer with blocks, a receiving
thread, Enumerators and pattern matching (`lib/asterism/cruby/`). It is
built on the polled API below, which stays as it is: code written for a
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
```

| Call | Notes |
|---|---|
| `Asterism::Zenoh.open(locator = nil, mode:, listen:, interval: 0.002)` | `Session.open` wrapped in a `Connection`. With a block: yields it, closes it after (also on an exception), returns the block's value |
| `Connection.new(session)` | wraps a session opened with the polled API |
| `s.put(key, payload, attachment: nil)` | a payload that is not a String is sent as `to_s` |
| `s.subscribe(key, depth: 16) { \|sample\| }` | the block gets each `Sample` on the receiving thread. Returns a `Subscription` (`close` ends it) |
| `s.subscribe(key, depth: 16)` | a `Subscription` to take from: `each(timeout: nil)` waits for samples (an Enumerator without a block; Enumerable), `each_pending` gives what is there now as Samples, `pending` / `received` / `dropped` / `closed?` / `close` |
| `s.queryable(key, depth: 16, complete: false) { \|q\| }` | each query on the receiving thread, finished when the block returns. `q.reply(payload)` answers on the queryable's key (when it has no wildcard), `q.reply(key, payload, attachment:)` as before. Without a block, `each(timeout:)` yields the queries |
| `s.get(key, timeout: 2.0, params:, payload:, attachment:, target:, consolidation:)` | an Enumerator of `Reply`; each iteration sends the get again. With a block: yields each, returns their number |
| `s.liveliness(key)` | a token (`close`) |
| `s.liveliness_watch(key) { \|key, alive\| }` | on the receiving thread; the tokens alive now come first. Without a block, `each` yields `Liveliness` (`key`, `alive?`) |
| `s.liveliness_get(key, timeout: 2.0)` | the keys alive now (an Array) |
| `s.start` / `s.stop` / `s.running?` | receive on a thread of its own |
| `s.run` | receive on this thread until `stop`, the connection closing, or Ctrl-C (returns nil) |
| `s.on_error { \|error, where\| }` | what the blocks raise (`StandardError`); without a handler it is printed with `warn`. Receiving goes on |
| `s.session`, `zid`, `peers`, `poll`, `closed?`, `close` | |

`Sample`, `Reply` (`key`, `payload`, `attachment`; `text` is the payload as
UTF-8) and `Liveliness` are `Data` values, so they work with pattern
matching: `case sample in {key: %r{/temp\z}, payload:}`. Times are seconds
here (the polled API counts milliseconds).

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
| `Asterism.connect(...) { \|net\| }` | yields an `Asterism::Net`, `Asterism.close` when the block ends; returns the block's value. Without a block, as before |
| `Asterism.net` | the `Net` of the connection made without a block (nil when not connected) |
| `net.expose` / `unexpose` / `exposed` | as `Asterism.expose`. The methods run on the receiving thread, in `run`, or in whatever polls |
| `net[path, timeout: nil]` | a proxy (`timeout` in seconds) |
| `net.each(pattern = "**")` | the proxies alive now; an Enumerator without a block |
| `net.on_join { \|node\| }` / `net.on_leave { \|node\| }` | `Asterism.on_join` / `on_leave` of the polled API (the same blocks, told from `Asterism.poll`), here on the receiving thread; what they raise goes to `on_error` |
| `net.start` / `stop` / `run` / `running?` / `on_error` | as for Zenoh. A method of an exposed object that raises is answered to its caller as a `RemoteError`, as before; `on_error` gets what `on_join` / `on_leave` raise |
| `net.nodes`, `node_id`, `app`, `connected?`, `lost_reason`, `poll`, `close` | |

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
| `ros.node(name, namespace: "/", enclave: "/")` | an `Asterism::ROS::Node` (every method of the polled API) with the calls below |
| `node.subscribe(topic, type) { \|msg, info\| }` | the polled API's (run from `node.poll`), here on the receiving thread; `info` is the `Attachment` or nil. Without a block: a subscription whose `each(timeout: nil)` waits for `[msg, info]` (Enumerable) |
| `node.topic(topic, type).each` | subscribes for the iteration and withdraws after it (`first(n)`, `break`, the time running out) |
| `node.every(seconds) { }` | the polled API's timer (run from `node.poll`), here on the receiving thread; returns a `Timer` (`cancel`, `fired`) |
| `node.service(name, type) { \|req\| response }` | answered while the connection spins (or from `node.poll`). What the block raises goes to `on_error`, and that request gets no answer |
| `node.call(name, type, request = nil, timeout: 2.0, **fields)` | waits for the response |
| `ros.spin` (`run`) / `start` / `stop` / `running?` / `on_error` / `close` | |
| `ros.zenoh` | the `Asterism::Zenoh::Connection` underneath (same receiving thread) |

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
  empties them every 2 ms (`interval:`) with the polled API.
- A tick of the receiving thread holds the connection's lock (a `Monitor`;
  for the object layer, which is one connection per process,
  `Asterism::LOCK`). The application's calls into the same layer take it
  too, so the layers written for one thread are never entered by two at
  once.
- A call that waits for an answer (`proxy.method`, `node.call`) from another
  thread while the receiving thread runs does not poll by itself: it waits
  until a tick brings the answer. On the receiving thread itself (a block
  that calls), or while nothing receives, it polls as on the boards.
- `stop`, `close` and the end of the block wait for the receiving thread to
  end; no thread is left behind. When the connection is lost the receiving
  thread ends by itself, and waiting calls raise as before.
- Enumerators (`each`, `get`, `topic`) wait on the thread that iterates
  them.

## License

MIT (LICENSE) for Asterism's code. The ROS 2 definitions in
`tools/ros2_jazzy/` (with the package.xml of their packages), the types
generated from them in `data/msgs/` and the fixtures computed by ROS 2's
tools in `test/msgs/` are under the Apache License 2.0 (NOTICE,
`data/msgs/NOTICE`, `data/msgs/LICENSE-Apache-2.0.txt`). Each generated
type names its package and license at its top. The gem `asterism` is
therefore `MIT` and `Apache-2.0`, each for its own files.

Not in this repository: the gems Asterism depends on are not bundled.
`msgpack` (CRuby) and `asterism-zenoh` (the CRuby Zenoh binding, which in
turn fetches zenoh-c at build time; see its README) are installed by
RubyGems, and on mruby / PicoRuby the Zenoh binding is the separate mrbgem
`picoruby-asterism-zenoh`. Their licenses are their own.

---

# The API

The same on every Ruby (the polled API; CRuby adds the layer described in
[The Ruby-like API](#the-ruby-like-api-cruby-only)). The examples use PicoRuby's `sleep_ms`; on CRuby
write `sleep`. When PicoRuby's `Machine` is there it is used for the clock
and the short pauses while waiting; otherwise `Time` and `sleep`. Besides
`Asterism::Zenoh`, the layers need a `MessagePack` module with `pack` /
`unpack` (the API of the msgpack gem; whichever gem provides it).

```ruby
# on the machine that has the object
Asterism.connect("tcp/192.0.2.2:7447", node: "fmruby-bbbbbb", app: "demo")
Asterism.expose("apu", apu, methods: [:play, :stop])
loop { Asterism.poll; ... }               # in the update loop

# on another machine
Asterism.connect("tcp/192.0.2.2:7447", node: "linux", app: "demo")
apu = Asterism["fmruby-bbbbbb/demo/apu"]  # <node>/<app>/<object>
apu.play("t120 o4 cdefg")                 # runs there, returns its value
apu.respond_to?(:play)                    # => true (from the exposed list)
f = apu.async.play("cde")                 # does not wait
f.done?; f.value
Asterism.each("*/*/apu") { |a| a.stop }   # every apu alive now
Asterism.nodes                            # => ["linux", "fmruby-bbbbbb"]
```

## API

| Call | Returns | Raises / notes |
|---|---|---|
| `Asterism.connect(locator, node:, app:, mode: nil, listen: nil)` | `Asterism` | `locator`, `mode:`, `listen:` go to `Asterism::Zenoh::Session.open` (client of a router by default; `mode: :peer` with or without `listen:` without one). `node:` is this machine's ID, `app:` the application's name (one key chunk each: no `/ * $ ? #`, not starting with `@`; else `ArgumentError`). `Disconnected` when it cannot connect; `Error` when objects of the same `<node>/<app>` are already alive (a second copy of the application), or when already connected. Waits up to about 1.5 s for that check (a router answers at once). |
| `Asterism.expose(name, obj, methods:)` | `"<node>/<app>/<name>"` | `methods:` is an Array of names, or a Hash `name => number of arguments` (checked before the call; `-1` or the Array form: any). `ArgumentError` when `obj` has no such public method. Exposing a name again replaces it. |
| `Asterism.unexpose(name)` | true / false | |
| `Asterism.poll` | true / false | Call from the update loop: polls Zenoh, answers the calls that came in, follows who is alive and calls the `on_join` / `on_leave` blocks. `false` once the connection is closed or lost. |
| `Asterism.on_join { \|node\| }` / `Asterism.on_leave { \|node\| }` | `Asterism` | Another node appeared (its node token or one of its objects) / is gone (no token and no object left). The nodes there already join on the first polls after connecting; when the connection is lost, every node known until then leaves (on the next `Asterism.poll`). The blocks run from `Asterism.poll` only, never from the polling inside a waiting call; what they raise comes out of `Asterism.poll`. `Asterism.close` forgets them (a lost connection does not). |
| `Asterism[path, timeout_ms = 2000]` | `Proxy` | `path` is `<node>/<app>/<object>` without wildcards (`ArgumentError`). Nothing is sent until a method is called. |
| `proxy.<method>(*args, **kw)` | the remote return value | Waits for the answer (`timeout_ms`). `RemoteError` when it raised there or could not be called (not exposed: `NoMethodError`; wrong number of arguments: `ArgumentError`; no such object: `NameError`), `Timeout` when no answer came in time (also at once when nobody answers that key), `Disconnected`, `EncodeError` (before anything is sent) for a value MessagePack cannot carry. A block cannot be sent (`ArgumentError`). |
| `proxy.async.<method>(...)` | `Future` | Sends and returns at once. `EncodeError` / `Disconnected` are raised here. |
| `future.done?` | true / false | Never waits (`Asterism.poll` moves it on). True once the answer came, the time ran out or the connection closed. |
| `future.value` | the return value | Waits (polling) if not done; raises like a waiting call. `future.took_ms`: time to the answer. |
| `proxy.respond_to?(name)` / `proxy.methods` | true / false, `[Symbol]` | From the object's meta (fetched once, `proxy.asterism_refresh` forgets it). `respond_to?` is false when the object does not answer; `methods` raises then. |
| `proxy.asterism_meta` / `proxy.asterism_path` | Hash, String | `{"methods" => [[name, arity], ...]}` |
| `Asterism.each(pattern = "**") { \|proxy\| }` | count (Array without a block) | The exposed objects alive now (this application's own included) whose `<node>/<app>/<object>` matches; `*` is one chunk, `**` any number. |
| `Asterism.nodes` | `[String]` | Node IDs alive now, this one first. |
| `Asterism.connected?` / `node_id` / `app` / `exposed` / `lost_reason` | | |
| `Asterism.close` | nil | Withdraws every exposed object. Idempotent. |

Errors: `Asterism::Error` (base, a `StandardError`), `EncodeError`, `RemoteError`
(`remote_class`, `remote_message`), `Timeout`, `Disconnected`.

### When the connection is lost

Asterism follows `Asterism::Zenoh`: the connection is closed when the router
(or the only peer) goes away, and is not reopened by itself. From then on
`Asterism.poll` returns `false`, `connected?` is false, `lost_reason` says
why, and calls raise `Asterism::Disconnected`. **`Asterism::Zenoh::Error`
never comes out of Asterism; it is always wrapped in `Disconnected`** (the
message is kept). The exposed objects are gone with the connection: to go
on, the application calls `connect` and `expose` again.

## Values

Only what MessagePack carries: `nil`, `true`, `false`, `Integer` (64 bit),
`Float`, `String`, `Array`, `Hash`. A `Symbol` is sent as a `String` (also
as a Hash key: keyword arguments arrive as Symbols again). Anything else in
the arguments raises `EncodeError` before sending; in a return value the
caller gets `RemoteError` (`Asterism::EncodeError`). Nesting is limited to
16 levels.

## Keys and encoding

| Key | Zenoh | Payload |
|---|---|---|
| `asterism/<node>/<app>/<object>/call` | get / queryable | query: `[method, [args...], {kwargs}]`; reply: `["ok", value]` or `["error", class name, message]` |
| `asterism/<node>/<app>/<object>/meta` | get / queryable | reply: `{"methods" => [[name, arity], ...]}` (arity `-1` when not declared). The object may be `*` in the query: one reply per object |
| `asterism/<node>` | liveliness | the node is connected |
| `asterism/<node>/<app>/<object>` | liveliness | the object is exposed |

One queryable per application (`asterism/<node>/<app>/**`). A call whose
node or app is a wildcard reaches every application that exposes that
object, each answering with its own key; `Asterism` itself only sends calls
to one object.

## How waiting works

Everything is polled; nothing runs behind the application. A call that
waits keeps polling (pausing 2 ms between polls) and answers the calls that
come in meanwhile, so two machines calling each other at the same time do
not lock up. An answered call may itself call and wait; such waits nest at
most `Asterism::MAX_NESTING` (4) deep, beyond that the call raises `Error`
(the caller of the outer call gets it as `RemoteError`). While a call
waits, the rest of that application (drawing, input) waits too; other
applications do not.

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

The blocks the layers call (`Asterism.on_join` / `on_leave`, the ROS
`node.subscribe` and `node.every` blocks) run from `Asterism.poll` /
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

## Limits

- Objects cannot be passed by reference (a return value is a copy), blocks
  cannot be sent, there are no events (later stages).
- The node token `asterism/<node>` is shared by every application of that
  node; when one of them closes, the others still list the node through
  their objects, but a watcher may see the node token go away.
- No authentication: a trusted LAN is assumed.
- Pattern matching on the boards: PicoRuby's compiler (checked on Family
  mruby's application VM) runs `case/in` with `deconstruct_keys`, nested
  hash patterns, array patterns, guards, alternatives, ranges, pins and
  `**rest`, but not two forms: a class as the value in a hash pattern
  (`in {x: Float}` does not match) and, inside a block, binding a variable
  of the enclosing method (`v = nil; list.each { |m| case m in {a: v} ... }`
  leaves it nil). Put the `case` in a method of its own, as in the example
  above.

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
node.every(1) { pub << { data: "tick" } }
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
  res = cli.call(a: 2, b: 3)      # waits (polling), raises Asterism::ROS::Timeout
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
| `sub.each_pending { \|msg, info\| }` | count | `info` is an `Attachment` (`sequence`, `stamp_ns`, `gid`) or nil. Samples that are not valid CDR are skipped and counted in `sub.errors`. |
| `node.service(name, type, qos: DEFAULT_QOS, depth: 8) { \|req\| response }` | `Service` | Serves `name` (`ros2 service list`). The block gets a `type::Request` and returns a `type::Response` or a Hash of its fields. It runs from `node.poll` (or `service.handle_pending`), never behind the application. A request without rmw_zenoh's attachment, or that does not decode, is counted in `service.errors` and gets no answer. An exception from the block ends that request without an answer and is raised from `node.poll`. `service.handled`: answered so far. |
| `node.poll(steps = 8)` | true / false | `session.poll(steps)`, then answers the requests waiting for this node's services, then gives what came to the `subscribe` blocks and fires the `every` timers that are due. Returns what `session.poll` returns. A waiting `client.call` polls only the session and the services (`node.pump`), not the blocks. |
| `node.subscribe(topic, type, qos: DEFAULT_QOS, depth: 16) { \|msg, info\| }` | `Subscription` | `node.subscription` whose messages (decoded, with their `Attachment` or nil) go to the block, from `node.poll`. `sub.close` ends it. Do not wait in the block (see [Stack](#stack)). |
| `node.every(seconds) { }` | `Timer` | Calls the block every `seconds` (a Float works), the first time one period from now, from `node.poll` (so no more often than the update loop polls). It keeps the period; after a long stall it starts again from now instead of firing the missed times at once. `timer.cancel`, `timer.fired` (count), `timer.period`. Do not wait in the block. |
| `node.client(name, type, qos: DEFAULT_QOS)` | `Client` | Declares the client token. |
| `client.call(request = nil, timeout_ms: 2000, **fields)` | `type::Response` | Sends the request (a `type::Request`, a Hash, or the fields as keywords) and waits, polling the node (its services keep answering). `Asterism::ROS::Timeout` when no response came in time, at once when nobody serves the name; `Asterism::Zenoh::Error` when the session closed. |
| `client.call_async(request = nil, timeout_ms: 2000, **fields)` | `Call` | Sends and returns at once. `call.done?` never waits (`node.poll` moves it on); `call.value` waits and returns the response or raises like `call`; `call.response` (nil until it came), `call.took_ms`, `call.sequence`. |
| `node.call(name, type, request = nil, timeout_ms: 2000, **fields)` | `type::Response` | `client.call` through a client made on first use and kept per name. |
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
*Stamped), sensor_msgs (Imu, BatteryState, Temperature, Range,
MagneticField, Illuminance, FluidPressure, RelativeHumidity, JointState,
NavSatStatus, NavSatFix), example_interfaces/srv/AddTwoInts. The list is
`tools/bundled_types.txt`. Nothing of them is compiled into the mrbgem: an
application loads what it uses, and each file loads the types it is made of.

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
are from ros2/common_interfaces, ros2/rcl_interfaces and
ros2/example_interfaces (Apache License 2.0, see NOTICE).

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
