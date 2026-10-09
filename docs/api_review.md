# API review toward 1.0 (proposal)

Status: **proposal only**. Nothing here has been changed in the code. Every
API change below is for the maintainer to accept, change or reject; the
"Decisions" section at the end lists the choices that block the rest.

Scope: the public Ruby API of the two gems at version 0.3.0.

- `asterism-zenoh` (CRuby, over zenoh-c) and its board twin
  `picoruby-asterism-zenoh` (mruby / PicoRuby, over zenoh-pico), which has
  the 0.2.0 part of the API.
- `asterism`: `mrblib/` (shared by CRuby and the boards) and
  `lib/asterism/cruby/` (the Ruby-like layer, CRuby only).

The review starts from item 1 of "gem の課題" in fmruby-core's
`doc/ruby_asterism/plan.md`: time units are mixed (milliseconds in the
polled layer, seconds in the Ruby-like layer); there are two styles (polled
and blocks) with weak guidance on which to use; and names drift (`peers` is
a count, `peer_zids` a list). The reports C1-C7 give the history of each
choice.

## How to read this

Layers (the first tag of each entry):

| Tag | Layer | Where the code is |
|---|---|---|
| ZP | Zenoh, polled | asterism-zenoh `ext/` and `lib/`; picoruby-asterism-zenoh `src/zenoh.c` |
| ZR | Zenoh, Ruby-like (blocks, receiving thread, Enumerators) | asterism `lib/asterism/cruby/zenoh.rb`, `runner.rb` |
| OP | Objects, polled (`Asterism.connect / expose / [] / poll`) | asterism `mrblib/asterism.rb`, `proxy.rb`, `future.rb` |
| OR | Objects, Ruby-like (`Asterism::Net`) | asterism `lib/asterism/cruby/objects.rb` |
| RP | ROS 2, polled (`Asterism::ROS::Node`, ...) | asterism `mrblib/ros.rb` |
| RR | ROS 2, Ruby-like (`Asterism::ROS.connect`, `Connection`) | asterism `lib/asterism/cruby/ros.rb` |
| TY | Message types and CDR | asterism `mrblib/ros.rb`, `mrblib/cdr.rb`, `data/msgs/` |

Where it runs (the second tag):

- **both**: CRuby and the boards. A change here changes `mrblib/` or the
  board binding, so it reaches the boards through Family mruby's pinned
  commits, and needs a firmware rebuild (mrblib is compiled into the
  firmware) and, for the C binding, a reflash.
- **CRuby**: CRuby only. A change here does not reach the boards.

Proposals carry an ID (`U1`, `N2`, ...). Each says:

- **Breaking**: whether existing code stops working or behaves differently.
- **Boards**: whether `mrblib/` or picoruby-asterism-zenoh must change.
- **Migration**: how to get there without a flag day.

## 1. Inventory of the public API

Units are given as **ms** (Integer milliseconds), **s** (seconds, Integer
or Float), **ns** or **-** (none). "Raises" lists what the call itself
raises; `ArgumentError` / `TypeError` for bad arguments are left out unless
they are part of the contract.

### 1.1 ZP: Zenoh, polled

Module `Asterism::Zenoh`.

| Call | Runs | Arguments and keywords | Units | Returns | Raises |
|---|---|---|---|---|---|
| `Session.open(locator = nil, mode: :client, listen: nil)` | both | `mode:` `:client` / `:peer`; `listen:` needs `:peer` | waits up to `CONNECT_TIMEOUT_MS` (3000 ms) | `Session` | `Zenoh::Error` (nobody answered, bad locator) |
| `Session.open(..., scouting:, timestamping:, config:, config_file:)` | CRuby | `config:` Hash of zenoh keys or JSON5 String; `config_file:` path | `connect/timeout_ms` inside `config:` | `Session` | `Zenoh::Error`, `ArgumentError` (bad config) |
| `session.put(key, payload, attachment: nil)` | both | `payload`, `attachment` Strings | - | nil | `Zenoh::Error` (closed), `TypeError` (payload not a String) |
| `session.put(..., encoding:, priority:, congestion_control:, express:, reliability:, timestamp:, allowed_destination:)` | CRuby | Symbols (`:data_high`, `:block`, ...), `timestamp:` true or `Timestamp` | - | nil | as above |
| `session.delete(key, **opts)` | CRuby | put's options without payload / attachment / encoding | - | nil | `Zenoh::Error` |
| `session.subscribe(key, depth = 16)` | both | `depth` 1..1024, positional | - | `Subscriber` | `Zenoh::Error` |
| `sub.each_pending { \|key, payload, attachment\| }` | both | - | - | count with a block; Array of `[key, payload, attachment]` without | - |
| `sub.each_sample { \|sample\| }` | CRuby | same queue as `each_pending` | - | count / Array of `Sample` | - |
| `sub.pending` / `received` / `dropped` / `close` / `closed?` | both | - | - | Integer / nil / bool | - |
| `session.get(key, timeout_ms = 2000, params = nil, payload = nil, attachment: nil, target: :all, consolidation: :none)` | both | 4 positional; `target:` `:all` / `:all_complete` / `:best_matching`; `consolidation:` `:none` / `:latest` / `:monotonic` / `:auto` | **ms**, 1..600000, positional | `Get` (returns at once) | `Zenoh::Error` |
| `session.get(..., encoding:, priority:, congestion_control:, express:, accept_replies:)` | CRuby | | | `Get` | |
| `get.each_reply { \|key, payload, attachment\| }` | both | error replies left out | - | count / Array | - |
| `get.each_result { \|reply\| }` | CRuby | error replies included | - | count / Array of `Reply` | - |
| `get.done?` / `pending` / `received` / `dropped` / `errors` | both | `errors`: number of error replies | - | bool / Integer | - |
| `session.queryable(key, depth = 16, complete: false)` | both | `depth` positional | - | `Queryable` (`each_pending { \|q\| }`, counters, `close`) | `Zenoh::Error` |
| `q.key` / `params` / `payload` / `attachment` / `finish` / `finished?` | both | | | | |
| `q.reply([key,] payload, attachment: nil)` | both | one argument: answers on the **query's** key | - | nil | `Zenoh::Error` (finished) |
| `q.reply(..., encoding:, timestamp:, priority:, congestion_control:, express:)`, `q.reply_err(payload, encoding:)`, `q.reply_del(key = nil)`, `q.encoding` | CRuby | | | | |
| `session.liveliness(key)` | both | | | `LivelinessToken` (`close`, `closed?`) | `Zenoh::Error` |
| `session.liveliness_watch(key, depth = 16)` | both | `depth` positional | | `LivelinessWatch` (`each_pending { \|key, alive\| }`, counters) | `Zenoh::Error` |
| `session.liveliness_get(key, timeout_ms = 2000)` | both | | **ms**, positional | `Get` | `Zenoh::Error` |
| `session.poll(steps = 8)` | both | `steps` ignored on CRuby | - | true while open | - |
| `session.closed?` / `close` / `zid` | both | | | bool / nil / hex String | - |
| `session.peers` | both | | - | **Integer**: connected peers, or routers for a client | - |
| `session.peer_zids` / `router_zids` | CRuby | | | `[String]` | `Zenoh::Error` |
| `session.transports` / `links` | CRuby | | | `[Transport]` / `[Link]` | |
| `session.publisher(key, encoding:, priority:, congestion_control:, express:, reliability:, allowed_destination:)` | CRuby | | | `Publisher` (`put(payload, attachment:, encoding:, timestamp:)`, `delete(timestamp:)`, `matching?`, `matching_listener(depth = 16)`, `close`, `closed?`) | `Zenoh::Error` |
| `session.advanced_publisher(key, cache:, sample_miss_detection:, publisher_detection:, ...)` | CRuby | `cache:` Integer / true / Hash | | `AdvancedPublisher` (as `Publisher`) | |
| `session.querier(key, target:, consolidation:, timeout_ms:, ...)` | CRuby | | **ms** (keyword) | `Querier` (`get(params = nil, payload = nil, attachment:, encoding:)`, `matching?`, `matching_listener`, `close`) | |
| `session.advanced_subscriber(key, depth = 16, history:, recovery:, subscriber_detection:, query_timeout_ms:)` | CRuby | `history:` true / Hash (`max_age:` s) | **ms** (`query_timeout_ms:`) | `AdvancedSubscriber` (+ `detect_publishers(depth, history:)`, `miss_listener(depth)`) | |
| `session.transport_events(depth = 16, history: false)` / `link_events(...)` | CRuby | | | `EventListener` (`each_pending`, counters, `close`) | |
| `session.new_timestamp` | CRuby | | NTP64 | `Timestamp` (`ntp64`, `id`, `to_time`, Comparable) | |
| `session.declare_keyexpr(key)` | CRuby | | | `KeyExpr` | |
| `Asterism::Zenoh.scout(what: [:router, :peer], timeout: 1.0, timeout_ms: nil, config: nil)` | CRuby | | **s** or **ms** (both keywords) | `[Hello]` | `Zenoh::Error` |
| `Asterism::Zenoh.init_log(level = nil)` | CRuby | | | | `ArgumentError` |
| `KeyExpr.new(str, autocanonize: false)`, `.canonize`, `.valid?`, `#intersects?`, `#includes?`, `#relation_to`, `#join`, `#concat`, `#declared?`, `#undeclare` | CRuby | | | | `ArgumentError` |
| Values (`Data`): `Sample`, `Reply`, `Hello`, `Transport`, `TransportEvent`, `Link`, `LinkEvent`, `Miss` | CRuby | `Sample#text`, `put?`, `delete?`; `Reply#ok?`, `error?`, `text`; events `added?`, `removed?` | | | |
| Constants: `CONNECT_TIMEOUT_MS`, `SEND_TIMEOUT_MS` (3000), `PEER`, `MAX_PEERS` (CRuby 1000, boards 3), `C_VERSION` (CRuby) / `PICO_VERSION` (boards), `VERSION` (CRuby) | both | | ms | | |
| `Asterism::Zenoh::Error < StandardError` | both | one class for every failure | | | |
| `require "asterism/zenoh/global"` defines `Zenoh` | CRuby | | | | |

### 1.2 ZR: Zenoh, Ruby-like (CRuby)

| Call | Arguments and keywords | Units | Returns | Raises |
|---|---|---|---|---|
| `Asterism::Zenoh.open(locator = nil, interval: 0.002, **Session.open opts) { \|c\| }` | | `interval:` **s** | `Connection`, or the block's value (closed after) | `Zenoh::Error` |
| `Connection.new(session, interval:)` | | **s** | `Connection` | |
| `c.put(key, payload, **opts)` / `c.delete(key, **opts)` | payload `to_s` when not a String | | nil | `Zenoh::Error` |
| `c.publisher(key, **opts)` / `c.advanced_publisher(key, **opts)` | | | `Connection::Publisher` (`put`, `delete`, `matching?`, `on_matching(depth: 16) { \|listening\| }`, `close`, `closed?`) | |
| `c.advanced_subscriber(key, depth: 16, **opts) { \|sample\| }` | `query_timeout_ms:` passed through | **ms** inside an **s** layer | `AdvancedSubscription` (+ `on_publisher`, `on_miss`) | |
| `c.querier(key, timeout: 2.0, **opts)` | | **s** | `Connection::Querier` (`get(params:, payload:, attachment:, encoding:, errors: false) { \|reply\| }`, `matching?`, `on_matching`, `close`) | |
| `c.on_transport(history: false, depth: 16) { \|ev\| }` / `c.on_link(...)` | block required | | `Events` (`close`, `closed?`) | `ArgumentError` without a block |
| `c.subscribe(key, depth: 16) { \|sample\| }` | | | `Connection::Subscription` | |
| `c.subscribe(key, depth: 16)` | no block | | `Subscription`: `each(timeout: nil)` (Enumerator, blocks), `each_pending` (**Samples**), `pending`, `received`, `dropped`, `closed?`, `close` | `Asterism::Error` from `each` when it has a block |
| `c.queryable(key, depth: 16, complete: false) { \|q\| }` | `q.reply(payload)` answers on the **queryable's** key | | `Connection::Queryable` (`each(timeout:)` without a block) | |
| `c.get(key, timeout: 2.0, params:, payload:, attachment:, target: :all, consolidation: :none, errors: false, **opts) { \|reply\| }` | | **s** | count with a block; an Enumerator without (sends again each time) | `Zenoh::Error` |
| `c.liveliness(key)` | | | `LivelinessToken` | |
| `c.liveliness_watch(key, depth: 16) { \|key, alive\| }` | without a block: `Watch#each` yields `Liveliness` | | `Watch` | |
| `c.liveliness_get(key, timeout: 2.0)` | | **s** | `[String]` (not a `Get`) | |
| `c.start` / `stop` / `run` / `running?` / `on_error { \|error, where\| }` | `run` returns on Ctrl-C | | self / nil / bool | `Asterism::Error` (already running) |
| `c.session`, `runner`, `zid`, `peers`, `peer_zids`, `router_zids`, `transports`, `links`, `new_timestamp`, `declare_keyexpr`, `poll`, `closed?`, `close` | delegated | | | |
| `Liveliness` (`Data`: `key`, `alive`, `alive?`) | | | | |
| Constants `ENUM_STEP` (0.002), `Runner::DEFAULT_INTERVAL` (0.002), `Runner::WAIT_SLICE` (0.05) | | **s** | | |

### 1.3 OP: Objects, polled (both)

| Call | Arguments and keywords | Units | Returns | Raises |
|---|---|---|---|---|
| `Asterism.connect(locator, node:, app:, mode: nil, listen: nil, config: nil)` | `config:` CRuby only | waits up to ~1.5 s for the duplicate check (fixed) | `Asterism` (the module) | `Disconnected`, `Error` (already connected; same `<node>/<app>` alive), `ArgumentError` (bad name) |
| `Asterism.expose(name, obj, methods:)` | Array of names, or Hash name => arity | | `"<node>/<app>/<name>"` | `ArgumentError`, `Disconnected` |
| `Asterism.unexpose(name)` / `exposed` | | | bool / `[String]` | |
| `Asterism.poll` | | | bool | what `on_join` / `on_leave` raise |
| `Asterism.on_join { \|node\| }` / `on_leave { \|node\| }` | | | `Asterism` | `ArgumentError` without a block |
| `Asterism[path, timeout_ms = 2000]` | positional | **ms** | `Proxy` (cached per path and timeout) | `ArgumentError` |
| `proxy.<method>(*args, **kw)` | no block | **ms** (from the proxy) | the remote value | `RemoteError`, `Timeout`, `Disconnected`, `EncodeError`, `Error` (nesting > 4) |
| `proxy.async.<method>(...)` | | | `Future` | `EncodeError`, `Disconnected` |
| `future.done?` / `value` / `took_ms` / `path` / `method_name` | | `took_ms` **ms** | bool / value / Integer | as a waiting call |
| `proxy.respond_to?(name)` / `methods` | `methods` lists only the remote ones | | bool / `[Symbol]` | `methods` raises when nobody answers |
| `proxy.asterism_meta` / `asterism_path` / `asterism_refresh` | | | Hash / String / self | |
| `Asterism.each(pattern = "**") { \|proxy\| }` | | | **count** with a block, Array without | |
| `Asterism.nodes` / `connected?` / `node_id` / `app` / `lost_reason` / `close` | | | | |
| Errors: `Error < StandardError`; `EncodeError`, `Timeout`, `Disconnected`, `RemoteError` (`remote_class`, `remote_message`) `< Error` | | | | |
| Constants: `ROOT`, `DEFAULT_TIMEOUT_MS` (2000), `MAX_NESTING` (4), `WAIT_STEP_MS` (2), `Codec::MAX_DEPTH` (16) | | **ms** | | |
| Public but internal: `Asterism.call`, `call_async`, `meta`, `wait_until`, `pump`, `release`, `lost`, `session!`, `tell`, `tell_nodes`, `answer`, `dispatch`, `invoke`, `check_name`, `split_path`, `glob?`, `now_ms`, `pause`, `machine?`, `depth`, `Codec`, `AsyncProxy`, `Future.answered` | | | | |

### 1.4 OR: Objects, Ruby-like (CRuby)

| Call | Arguments and keywords | Units | Returns | Raises |
|---|---|---|---|---|
| `Asterism.connect(...) { \|net\| }` | as OP | | the block's value (closed after) | as OP |
| `Asterism.net` | | | `Net` or nil | |
| `net.expose` / `unexpose` / `exposed` / `nodes` / `node_id` / `app` / `connected?` / `lost_reason` / `poll` / `close` | as OP | | | |
| `net[path, timeout: nil]` (`proxy`) | | **s** | `Proxy` | |
| `net.each(pattern = "**")` | Enumerable | | count with a block, Enumerator without | |
| `net.on_join` / `on_leave` / `on_error` / `start` / `stop` / `run` / `running?` | | | self / nil / bool | |
| `Asterism::LOCK` (a `Monitor`), `Asterism::Runner` | | | | |

### 1.5 RP: ROS 2, polled (both)

| Call | Arguments and keywords | Units | Returns | Raises |
|---|---|---|---|---|
| `Node.new(session, name, namespace: "/", domain: 0, enclave: "/")` | | | `Node` | `ArgumentError`, `Zenoh::Error` |
| `node.publisher(topic, type, qos: DEFAULT_QOS)` | `type` a class or ROS name | | `Publisher` (`publish(msg)` nil, `<<` self, `close`, `topic_key`, `gid`, `sequence`) | `UnknownType`, `Zenoh::Error` |
| `node.subscription(topic, type, qos:, depth: 16)` | | | `Subscription` (`each_pending { \|msg, info\| }` count / Array, `dropped`, `errors`, `close`, `closed?`) | |
| `node.subscribe(topic, type, qos:, depth: 16) { \|msg, info\| }` | block **required** on the boards | | `Subscription` | `ArgumentError` without a block |
| `node.every(seconds) { }` | | **s** (the only seconds in the polled layers) | `Timer` (`cancel`, `fired`, `period`) | `ArgumentError` (period rounds to 0 ms) |
| `node.service(name, type, qos:, depth: 8) { \|req\| response }` | | | `Service` (`handle_pending`, `handled`, `errors`, `close`) | the block's exception from `node.poll` |
| `node.client(name, type, qos:)` | | | `Client` | |
| `client.call(request = nil, timeout_ms: 2000, **fields)` | fields as keywords next to `timeout_ms:` | **ms** | `type::Response` | `ROS::Timeout`, **`Zenoh::Error`** (closed) |
| `client.call_async(request = nil, timeout_ms: 2000, **fields)` | | **ms** | `Call` (`done?`, `value`, `response`, `took_ms`, `sequence`) | `Zenoh::Error` |
| `node.call(name, type, request = nil, timeout_ms: 2000, **fields)` | | **ms** | `type::Response` | as `client.call` |
| `node.poll(steps = 8)` / `pump` / `close` / `closed?` | | | bool / nil | |
| `ROS::Timeout < StandardError` (not under `Asterism::Error`) | | | | |
| Constants: `DEFAULT_QOS`, `GID_SIZE`, `LIVELINESS_ROOT`, `Client::DEFAULT_TIMEOUT_MS`, `Client::WAIT_STEP_MS` | | **ms** | | |
| Public but internal: `Node#deliver`, `fire_timers`, `handle`, `fire`, `entity_keys`, `ROS.mangle`, `resolve`, `strip_slashes`, `gid_for`, `now_ns`, `now_ms`, `pause`, `type_constant`, `load_type_file`, `fields_of`, `Client#wait_for`, `decode_response`, `session_closed?` | | | | |

### 1.6 RR: ROS 2, Ruby-like (CRuby)

| Call | Arguments and keywords | Units | Returns | Raises |
|---|---|---|---|---|
| `ROS.connect(locator = nil, domain: 0, type_path: nil, interval:, **Session.open opts) { \|ros\| }` | | `interval:` **s** | `ROS::Connection` or the block's value | `Zenoh::Error` |
| `ros.node(name, namespace:, enclave:)` | | | `Node` extended with `Spinning` | |
| `node.subscribe(topic, type, ...)` without a block | Enumerable `each(timeout: nil)` yields `msg, info` | **s** | `Subscription` | |
| `node.topic(topic, type, qos:, depth:)` | subscribes only while iterated | | `Topic` | |
| `node.call(name, type, request = nil, timeout: nil, timeout_ms: nil, **fields)` | both units accepted | **s** or **ms** | `type::Response` | as RP |
| `ros.spin` (alias `run`) / `start` / `stop` / `running?` / `on_error` / `close` / `nodes` / `zenoh` / `session` / `runner` / `domain` | | | | |
| `ROS::ServiceFailed < StandardError` (internal signal, but a public constant) | | | | |

### 1.7 TY: Message types and CDR (both)

| Call | Returns | Raises |
|---|---|---|
| `ROS.require_type(name)` / `ROS::TYPE_PATH` / `ROS.type_path` | the class | `UnknownType < StandardError`, `ArgumentError` |
| `Type.new(**fields)`, `.from(hash_or_msg)`, `.encode(msg)`, `.decode(bytes)`, `#to_h`, `#==`, `#deconstruct_keys`, `ROS_NAME`, `TYPE_NAME`, `TYPE_HASH`, `FIELDS` | | `ArgumentError` (unknown field, over bound), `NotImplementedError` (wstring) |
| `ROS::Attachment` (`sequence`, `stamp_ns` (**ns**), `gid`, `encode`, `.decode`, `deconstruct_keys`) | | |
| `CDR::Writer` / `CDR::Reader` (per-kind methods, `array`, `bytes`, `structs`) | | `CDR::DecodeError < StandardError` |
| `Asterism::MSGS_DIR` | CRuby only | |

## 2. What the Ruby community does

The proposals lean on these conventions. They are what Ruby users will
expect, so departing from them costs documentation and surprise.

**Timeouts are seconds, as Float, in a keyword named for what it limits.**

- Net::HTTP: `open_timeout`, `read_timeout`, `write_timeout`,
  `keep_alive_timeout`, `ssl_timeout`, all seconds (Float allowed); errors
  `Net::OpenTimeout` and `Net::ReadTimeout`, both subclasses of
  `Timeout::Error`.
- redis-rb (and redis-client): `timeout:` (sets the three below at once),
  `connect_timeout:`, `read_timeout:`, `write_timeout:`, seconds;
  `reconnect_attempts:`; errors `Redis::TimeoutError`,
  `Redis::CannotConnectError`, `Redis::ConnectionError` under one base
  (`Redis::BaseError`).
- Bunny: `connection_timeout`, `read_timeout`, `write_timeout`,
  `heartbeat` in seconds, but `continuation_timeout` in **milliseconds**.
  That one exception is a long-standing source of user confusion and is a
  good example of what mixed units cost.
- Ruby itself: `Thread::Queue#pop(timeout:)` (3.2), `Socket.tcp(...,
  connect_timeout:)`, `ConditionVariable#wait(mutex, timeout)`,
  `IO#wait_readable(timeout)`, `sleep`: seconds everywhere. When a
  different unit is needed it is said explicitly
  (`Process.clock_gettime(..., :millisecond)`).
- Faraday: `timeout`, `open_timeout`, `read_timeout`, `write_timeout`,
  seconds.

**Errors**: one gem-wide base class under `StandardError`
(`Redis::BaseError`, `Faraday::Error`, `Bunny::Exception`), subclasses
named `...Error` (`TimeoutError`, `ConnectionError`). Net::HTTP's
`ReadTimeout` is the well-known exception to the `Error` suffix.

**Iteration**: `each` with a block returns the receiver; without a block,
an Enumerator. Methods that return a count are named so (`count`, `size`).
Predicates end in `?`, and a `Data` / `Struct` with a boolean member often
adds one (`Data.define(:alive) { def alive? = alive }`).

**Lifecycle**: `open` / `connect` with a block closes the resource after
it (`File.open`, `Net::HTTP.start`, `Bunny.new.start` / `close`); `close`
is idempotent. Clients document fork behaviour (redis-rb reconnects after
fork; Bunny and most C-backed clients say "connect after fork").

**Thread-safety** is stated per object in the README (redis-rb: a client
is thread-safe but serialises; Bunny: a channel must not be shared between
threads).

## 3. Problems and proposals

### 3.1 Units

#### U1. Two units for the same thing, chosen by layer

Problem. The same limit is milliseconds in the polled layers and seconds in
the Ruby-like layers:

```ruby
s.get("demo/**", 2000)                 # ZP: ms, positional
c.get("demo/**", timeout: 2.0)         # ZR: s
Asterism["n/app/obj", 2000]            # OP: ms, positional
net["n/app/obj", timeout: 2.0]         # OR: s
client.call(a: 1, timeout_ms: 2000)    # RP: ms
node.call(..., timeout: 2.0)           # RR: s (and timeout_ms: too)
```

Code that moves from a board to CRuby, or from the polled to the Ruby-like
API on CRuby, has to convert every number, and a wrong guess is caught only by luck. On
CRuby, `s.get(key, 2.0)` in ZP is taken as 2 ms (the C side truncates the
Float) and simply gets no reply; `c.get(key, timeout: 2000)` in ZR becomes
2,000,000 ms and is rejected only because the C side checks the range
(1..600000 ms). `Asterism[path, 2.0]` on the object layer makes a proxy
whose calls wait 2 ms.

Options (decision D1):

- **A. Seconds everywhere, ms as an explicit alternative.** Every call that
  takes a time accepts `timeout:` in seconds, in every layer, on both
  Rubies. The polled layer also keeps `timeout_ms:` (board code computes in
  milliseconds from `Machine.board_millis`, and that stays natural there).
  Positional ms arguments are deprecated.
- **B. The unit is in the name, nothing more.** Keep ms in the polled layer
  and seconds in the Ruby-like one, but make every time a keyword whose
  name says the unit (`timeout_ms:` / `timeout:`), so the unit is visible
  at the call site. No layer accepts the other unit.
- **C. Keep 0.3.0 as it is** and document the split.

Recommendation: **A**. It matches every Ruby client in section 2, removes
the conversion when code moves between layers, and the `_ms` spelling
remains for the boards. The cost on the boards is one Float multiply per
call, which is nothing next to a Zenoh round trip; mruby on the boards has
Float (the ROS types use it).

After (A):

```ruby
s.get("demo/**", timeout: 2.0)            # ZP, both Rubies
s.get("demo/**", timeout_ms: 2000)        # ZP, the same
Asterism["n/app/obj", timeout: 2.0]       # OP
client.call(a: 1, timeout: 2.0)           # RP
```

- Breaking: no in 0.4.0 (new keywords next to the old forms). Removing the
  positional forms in 1.0 is breaking (see I2).
- Boards: yes. `timeout:` / `timeout_ms:` on `get` / `liveliness_get` need
  picoruby-asterism-zenoh (C, `MRB_ARGS_KEY`); `Asterism[]`, `client.call`,
  `node.call` are mrblib. Board apps that pass positional ms today:
  `zenoh_nodes.app.rb` (`@session.get(..., 2000)`), and every app that calls
  `Asterism[path, ms]`.
- Migration: 0.4.0 adds the keywords (both units) everywhere and documents
  `timeout:` as the primary spelling; positional ms keep working with a
  one-time deprecation warning (see section 4.3); 1.0 removes positional
  ms, keeps `timeout_ms:`.

#### U2. Positional milliseconds are invisible at the call site

Problem. `s.get(key, 2000, nil, payload)`, `s.liveliness_get(key, 1000)`,
`Asterism[path, 2000]`: the reader sees a bare number with no unit and no
name. Covered by U1 (A) and I2; listed separately because it applies even
under option B.

#### U3. `node.every(seconds)` is the one seconds argument in the polled layers

Problem. On the boards, everything else in the polled API is
milliseconds, so applications keep their periods in `_MS` constants and
divide: `ros2_talker.app.rb` has `@node.every(PUBLISH_EVERY_MS / 1000)`.
That is Integer division: with `PUBLISH_EVERY_MS = 500` it becomes
`every(0)` and raises `ArgumentError` ("the period must be positive"); with
1500 it silently runs every second.

Proposal. Accept both units, by keyword for the non-default one:

```ruby
node.every(0.5) { ... }        # seconds, as now
node.every(ms: 500) { ... }    # new: milliseconds
```

- Breaking: no.
- Boards: yes (mrblib only, `Node#every` and `Timer`).
- Migration: none needed. Fix `ros2_talker.app.rb` to `every(ms:
  PUBLISH_EVERY_MS)` when it is next touched.

#### U4. Milliseconds leak into the seconds layer

Problem. The Ruby-like layer is documented as "seconds here", but:

- `c.advanced_subscriber(key, query_timeout_ms: 500)` is passed through.
- `Future#took_ms` and `Call#took_ms` are the only elapsed times.
- `node.call` accepts `timeout:` **and** `timeout_ms:` (RR), and
  `Zenoh.scout` accepts `timeout:` **and** `timeout_ms:` (ZP, CRuby), with
  no rule for which wins (the `_ms` one does).
- Error messages say `within 2000 ms` even when the caller wrote
  `timeout: 2.0`.

Proposal.

- ZR `advanced_subscriber` accepts `query_timeout:` (s) and converts.
- Add `Future#took` / `Call#took` (Float seconds) next to `took_ms`.
- Rule: when both `timeout:` and `timeout_ms:` are given, raise
  `ArgumentError` instead of silently preferring one.
- Error messages state the limit in the unit the caller used, or both
  (`within 2.0 s (2000 ms)`).

- Breaking: the "both given" rule is breaking only for code that passes
  both today (unlikely). The rest is additive.
- Boards: `took` and the messages are mrblib (yes); `query_timeout:` is
  CRuby only.

#### U5. Constants mix units without a rule

Problem. `CONNECT_TIMEOUT_MS`, `SEND_TIMEOUT_MS`, `DEFAULT_TIMEOUT_MS`,
`Client::DEFAULT_TIMEOUT_MS`, `WAIT_STEP_MS` are ms (and say so);
`Runner::DEFAULT_INTERVAL`, `Runner::WAIT_SLICE`, `Zenoh::ENUM_STEP` are
seconds and do not say so.

Proposal. Write the rule down: a constant or keyword with no unit suffix is
seconds; anything else carries its unit (`_MS`, `_NS`). Under that rule the
existing names are already correct; the rule just has to be documented and
kept. Add seconds companions only where users read them
(`DEFAULT_TIMEOUT = 2.0`).

- Breaking: no. Boards: `DEFAULT_TIMEOUT` would be mrblib (yes, additive).

#### U6. No keyword for the connect timeout

Problem. `Session.open` waits `CONNECT_TIMEOUT_MS` (3 s, compiled in). On
CRuby it can be changed only through the zenoh key
`config: {"connect/timeout_ms" => 300}`; on the boards not at all. Every
client in section 2 has a `connect_timeout` / `open_timeout`.

Proposal. `Session.open(..., connect_timeout: 3.0)` (seconds; CRuby maps
it to `connect/timeout_ms`, the boards to the zenoh-pico open timeout if
the build allows it), passed through `Asterism.connect`,
`Asterism::Zenoh.open` and `ROS.connect`.

- Breaking: no. Boards: optional (C); CRuby can go first.

### 3.2 Naming

#### N1. `peers` is a count; `peer_zids` is the list

Problem. `session.peers` returns an Integer, and for a client session it
counts **routers**, not peers. 0.3.0 added `peer_zids` / `router_zids`
(Arrays) under different names only to keep `peers` unchanged (C7). In
zenoh-c, `peers` means the IDs. So the most natural name has the least
natural meaning, and it is wrong for clients.

Proposal.

```ruby
# before
s.peers                 # => 1  (a client: the router)
# after (0.4.0)
s.connection_count      # => 1  (what is connected now, peers or routers)
s.peer_zids             # => ["a1b2..."]  (unchanged)
s.peers                 # => 1, with a one-time deprecation warning
```

The new name is decision D3: `connection_count` (says what it counts for
both modes) or `peer_count` (closer to the old name, still wrong for a
client). For 1.0, either remove `peers`, or re-use it as the Array of peer
IDs like zenoh-c (a silent change of type, so only after a release where it
warns).

- Breaking: no in 0.4.0; yes in 1.0 (removal or new meaning).
- Boards: yes (C binding: add the new name; `zenoh_nodes.app.rb` prints
  `@session.peers`).
- Migration: alias with warning in 0.4.0; removal in 1.0. If `peers` is
  to become the ID list, do it in a later minor after one full release with
  `peers` absent, never in the same release that removes the count.

#### N2. Three objects called "connection", two verbs to make them

Problem. `Asterism::Zenoh.open` returns `Asterism::Zenoh::Connection`;
`Asterism.connect` yields an `Asterism::Net`; `Asterism::ROS.connect`
returns an `Asterism::ROS::Connection`. Underneath there is also
`Asterism::Zenoh::Session`. The reader has to learn which word belongs to
which layer.

Proposal (light): keep the names, and add one table to the README that maps
each entry point to what it returns and what is underneath (`ros.zenoh` is
the Zenoh `Connection`, `c.session` the `Session`). Consider aliases
`Asterism::Zenoh.connect` for `open` and `Asterism::Connection` for `Net`
only if the maintainer wants one verb (decision D9).

- Breaking: no. Boards: no (all CRuby).

#### N3. `subscribe` and `subscription` mean different things per layer

Problem. In ZP, `session.subscribe(key)` returns a subscriber to poll. In
RP, `node.subscribe` **requires** a block on the boards and
`node.subscription` is the one to poll; on CRuby (RR) `node.subscribe`
without a block works. The same line of code raises on a board and works on
CRuby.

Proposal. In mrblib, `node.subscribe(topic, type)` without a block returns
the same as `node.subscription` (no Enumerator on the boards; just the
Subscription to poll with `each_pending`). `subscription` stays as an
alias.

- Breaking: no (it raised before). Boards: yes (mrblib).

#### N4. Abbreviated reply names

Problem. `q.reply_err` and `q.reply_del` copy zenoh-c's C names. Ruby
spells words out (`delete`, `error`), and the session has `delete`, not
`del`.

Proposal. Add `reply_error` and `reply_delete`; keep the short names as
aliases (no warning needed; they cost nothing).

- Breaking: no. Boards: no today (CRuby only); if these are ported to
  zenoh-pico, port the long names.

#### N5. Counters named `errors`, `fired`, `handled` mean different things

Problem. `Get#errors` counts error replies; `ROS::Subscription#errors`
counts samples that did not decode; `Service#errors` counts requests
without an attachment or that did not decode. `Timer#fired` and
`Service#handled` are counts with verb names. `ROS::Subscription` has
`dropped` and `errors` but not `pending` / `received`, which the Zenoh
subscriber has.

Proposal. Keep the names (they are short and documented), but document each
counter in one place, and add `pending` / `received` to
`ROS::Subscription` (delegated to the Zenoh subscriber) so the counters
line up across layers.

- Breaking: no. Boards: yes (mrblib, additive).

#### N6. `Proxy#methods` returns only the remote methods

Problem. `proxy.methods` is overridden to return the exposed remote names.
`Object#methods` has a contract (all methods of the object) that irb
completion, `pp`, debuggers and RSpec doubles rely on. The remote list
also performs a network round trip from a method that users call casually.

Proposal.

```ruby
proxy.remote_methods     # new: [:play, :stop] (from the meta)
proxy.methods            # 1.0: Object#methods, as everywhere else
```

`respond_to?` keeps answering for remote methods (that one is the
documented `method_missing` companion and is what users want).

- Breaking: yes in 1.0 (`methods` changes). Boards: yes (mrblib).
- Migration: 0.4.0 adds `remote_methods` and warns once when `methods` is
  called; 1.0 drops the override (decision D8).

#### N7. Backend constants differ per Ruby

Problem. CRuby has `C_VERSION`, the boards `PICO_VERSION`; `MAX_PEERS`
means a different limit on each; `PEER` is a boolean whose name does not
say so.

Proposal. Add on both: `BACKEND` (`:zenoh_c` / `:zenoh_pico`) and
`BACKEND_VERSION`; add `PEER_SUPPORTED` as the readable name of `PEER`.
Keep the old constants.

- Breaking: no. Boards: yes (C, additive).

#### N8. `Asterism::Timeout` shadows the standard `Timeout`

Problem. Inside `module Asterism` (where users who extend the gem write
code), `Timeout.timeout(1) { }` resolves to `Asterism::Timeout`, an
exception class, and fails with `NoMethodError`. The name also breaks the
`...Error` convention. `Asterism::ROS::Timeout` does the same inside
`Asterism::ROS`.

Proposal. Rename to `Asterism::TimeoutError` and
`Asterism::ROS::TimeoutError`, keep the old names as constant aliases. On
CRuby, `deprecate_constant` can mark the old ones (it warns only when
`Warning[:deprecated]` is on, which is off by default since Ruby 2.7.2, so
it is a soft signal); mruby has no `deprecate_constant`, so there the
alias is documentation only. Whether `Disconnected` also gets a suffix
(`DisconnectedError`, or `ConnectionError` as in redis-rb) is decision D4.

- Breaking: no while the aliases exist; removing them in 1.0 is breaking
  for `rescue Asterism::Timeout`. Recommendation: keep the aliases through
  1.x (they cost one line each).
- Boards: yes (mrblib).

### 3.3 Consistency between layers

#### L1. One name, two shapes

Problem. The same method name returns different things depending on the
object:

| Name | Polled (ZP / RP) | Ruby-like (ZR / RR) |
|---|---|---|
| `each_pending` on a Zenoh subscription | `[key, payload, attachment]` Arrays | `Sample` values |
| `liveliness_get` | a `Get` to poll | an Array of keys (waits) |
| `get` | a `Get` | an Enumerator of `Reply` |
| `subscribe` | `Subscriber` | `Connection::Subscription` |

The last three are deliberate (the Ruby-like layer waits; the polled one
never does) and read naturally on their own objects. The first is not:
`each_pending` is the polled layer's name for "arrays, now", and the
Ruby-like `Subscription#each_pending` yields Samples.

Proposal. In ZR, name the Sample form `each_sample` (the polled layer's
name for the Sample form) and deprecate `Subscription#each_pending`. Write
the rule in the README: a method name has one result shape across layers;
the Ruby-like layer may wait where the polled one returns at once, and says
so in its name or docs.

- Breaking: no in 0.4.0 (alias with warning); yes in 1.0 (removed).
- Boards: no (CRuby only).

#### L2. Small Ruby-like conveniences that the boards could have

Problem. Some CRuby-only differences are not about threads at all:
`node.subscribe` without a block (N3), `timeout:` in seconds (U1),
`node.call(timeout:)`. Each makes board code and CRuby code differ for no
reason.

Proposal. Move into mrblib whatever needs no thread, no Enumerator and no
`Data`: N3, U1, U3, U4's `took`. Keep receiving threads, Enumerators,
`Data` values and `on_error` CRuby only (C5 section 7 reached the same
line).

- Breaking: no. Boards: yes (mrblib, additive).

#### L3. `q.reply(payload)` answers on different keys

Problem. With one argument, the polled `Query#reply` answers on the
**query's** key, which may be a pattern (`demo/**`); the Ruby-like
queryable answers on the **queryable's** own key when it has no wildcard
(C5 section 8). The same line answers differently depending on the layer.

Proposal (decision D7). Either:

- make the polled one-argument `reply` answer on the queryable's key when
  that key is plain, and on the query's key otherwise (what ZR does); or
- keep the polled behaviour and make ZR require the key when the queryable
  key has a wildcard (raise `ArgumentError` instead of choosing).

Recommendation: the first. A reply on a pattern key is rarely what anyone
means.

- Breaking: yes, for code that relies on the reply carrying the query's
  key with one argument. Boards: yes (C binding).

#### L4. Lost connections surface as different errors

Problem. The object layer always turns `Asterism::Zenoh::Error` into
`Asterism::Disconnected` (README: "never comes out of Asterism"). The ROS
layer, in the same gem, raises `Asterism::Zenoh::Error` when the session is
closed (`publish`, `call`, `call_async`). The Ruby-like Zenoh layer raises
`Zenoh::Error` too. Code that handles a lost connection needs to know which
layer it is in. See E1 for the hierarchy that fixes it.

#### L5. `config:` is accepted by `Asterism.connect` on the boards and then fails

Problem. `Asterism.connect(..., config: x)` passes `config:` to the board
binding, which does not take it: the error is an mruby keyword error from
C, not a message about TLS or zenoh-pico.

Proposal. The board binding (or mrblib) raises
`ArgumentError, "config: is not supported by zenoh-pico (no TLS on the
boards)"`. Document which `Session.open` keywords exist per backend.

- Breaking: no (it already fails). Boards: yes (small).

### 3.4 Error classes

#### E1. Error classes are not one family

Problem. Today:

```
StandardError
├── Asterism::Error
│   ├── EncodeError, Timeout, Disconnected, RemoteError
├── Asterism::Zenoh::Error            (every Zenoh failure: closed, lost, bad declaration)
├── Asterism::ROS::Timeout
├── Asterism::ROS::UnknownType
├── Asterism::ROS::ServiceFailed      (an internal signal of the CRuby layer)
└── Asterism::CDR::DecodeError
```

`rescue Asterism::Error` misses ROS timeouts, unknown types, decode errors
and every Zenoh failure. Ruby clients have one base (section 2).

Proposal (1.0 shape):

```
StandardError
└── Asterism::Error                     (defined by both Zenoh bindings, reopened by asterism)
    ├── Asterism::Zenoh::Error          (binding failures)
    │   └── Asterism::Zenoh::ClosedError   (new: the session is closed or was lost)
    ├── Asterism::Disconnected          (object and ROS layers: connection closed or lost)
    ├── Asterism::TimeoutError          (alias Timeout)
    │   └── Asterism::ROS::TimeoutError (alias ROS::Timeout)
    ├── Asterism::EncodeError
    ├── Asterism::RemoteError
    ├── Asterism::ROS::UnknownType
    └── Asterism::CDR::DecodeError
```

`ServiceFailed` becomes private (`Asterism::ROS::Spinning::ServiceFailed`)
or a non-`StandardError` signal, so it cannot be caught by accident.

Reparenting a class from `StandardError` to a subclass of `StandardError`
is not breaking: every existing `rescue` still matches. Defining
`Asterism::Error` in the bindings is needed because the Zenoh gem loads
first; both definitions use `StandardError` as the superclass, so the
reopen is safe on both Rubies.

Whether `TimeoutError` should also be a `::Timeout::Error` on CRuby (as
Net::HTTP does) is decision D4. Ruby has single inheritance, so it can be
under `Asterism::Error` or under `::Timeout::Error`, not both; the boards
have no `Timeout` module. Recommendation: under `Asterism::Error`, one tree
on both Rubies.

- Breaking: no for the reparenting and the new subclass. L4 (ROS raising
  `Disconnected` instead of `Zenoh::Error` when closed) is breaking for
  code that rescues `Zenoh::Error` around ROS calls.
- Boards: yes (C binding defines `Asterism::Error` and the superclass of
  `Zenoh::Error`; mrblib reparents the rest).
- Migration: 0.4.0 reparents everything and adds `ClosedError` (both
  additive). For L4, 0.4.0 makes ROS raise `Zenoh::ClosedError` (still a
  `Zenoh::Error`, so old rescues work) and documents that 1.0 raises
  `Disconnected`; 1.0 switches.

#### E2. `Zenoh::Error` carries everything in the message

Problem. "session is closed", "the connection is lost", "cannot declare a
publisher on ..." and "reply failed (-3)" are the same class; code that
wants to reconnect must match message text.

Proposal. `ClosedError` (E1) covers the case code acts on. Keep the rest as
`Zenoh::Error` with the zenoh-c / zenoh-pico code as an attribute
(`error.code`), not only in the text.

- Breaking: no. Boards: yes (C, additive).

### 3.5 Return types

#### R1. `each` with a block returns a count

Problem. `Asterism.each(pattern) { }` and `net.each(pattern) { }` return the
number of proxies; `Connection#get { }` and `Querier#get { }` return the
number of replies. Ruby's `each` returns the receiver; code such as
`net.each("*/demo/info") { ... }.something` or `each` in a method chain
behaves unexpectedly. (The Ruby-like `Subscription#each` does return
`self`, so the layer is inconsistent with itself.)

Proposal.

- `Asterism.each` / `Net#each` with a block: return the Array of proxies
  that were yielded (module functions have no meaningful receiver) /
  `self` for `Net`. The count is `.size` of that, or `net.count`.
- `get { }` is not named `each`; returning the number of replies is fine
  and documented. Leave it.
- The polled `each_pending { }` returning a count stays (boards, and it is
  not `each`).

- Breaking: yes, for code that uses the count from `Asterism.each { }`.
  Boards: yes (mrblib). Migration: 1.0 only; document in 0.4.0 (decision
  D6).

#### R2. `Asterism.connect` returns the module

Problem. Without a block, `Asterism.connect` returns `Asterism` itself (a
module), and `on_join` / `on_leave` return it for chaining. It reads oddly
next to the CRuby layer, where a `Net` is yielded.

Proposal. Leave it. On the boards the module is the connection (one per
application), and changing the return value buys nothing. Document it.

#### R3. Polled `each_pending` returns an Array, not an Enumerator, without a block

Problem. Ruby users expect `each_*` without a block to be an Enumerator.
Here it **takes** the entries out of the queue at once and returns them as
an Array.

Proposal. Leave it, and document it as "drains the queue". The Array form
is what the boards need: a block called from C costs an interpreter entry
on a 16 KB stack (README, Stack), and mrblib uses this form on purpose. An
Enumerator would change "take now" into "take when iterated", which is the
wrong meaning for a queue that is filled behind the application's back.

### 3.6 Defaults

#### D-1. Defaults are consistent but undocumented as a set

The defaults are reasonable and mostly consistent: every request waits 2 s
(get, liveliness_get, querier, proxy call, service call), connecting 3 s,
queues 16 (services 8; the object layer's own queryable 32 and watch 64),
full queues drop the oldest, receiving pause 2 ms, nesting 4, encoding
depth 16. They are spread over five READMEs and three source files.

Proposal. One "Defaults" table in the README with the value, the unit and
the keyword that changes it. No code change.

#### D-2. `consolidation: :none` differs from zenoh's default

Problem. zenoh's default consolidation is `:auto`; Asterism's `get` (both
layers) defaults to `:none`, so a user who knows zenoh can get duplicate
replies they did not expect. The reason (rmw_zenoh services and the object
layer want every reply) is in the code, not in the docs.

Proposal. Keep `:none` (changing it would change replies on the boards),
and say in the `get` documentation that it differs from zenoh and why.

#### D-3. `errors: false` hides error replies in the Ruby-like `get`

Problem. In ZR, a queryable that answers with `reply_err` is silently
skipped unless `errors: true` is passed. A user debugging "no replies" does
not see the error.

Proposal. Keep the default (it matches the polled `each_reply`, which
never returns errors), but count them on the Enumerator's result or log
them under `$VERBOSE`. Decision is minor; recommendation: document only.

#### D-4. Plain text and no authentication by default

This is plan item 3 and not an API question, but it touches defaults: the
README should say near the first example that the default is plaintext
without authentication, and point at the TLS section. No warning at
runtime (it would fire on every board).

#### D-5. The duplicate check in `connect` is fixed at about 1.5 s

Problem. `Asterism.connect` waits up to ~1.5 s (`liveliness_get` with 1000
ms plus a 1500 ms loop limit) to see whether the same `<node>/<app>` is
already alive. It is not configurable, and over a slow relay (W1) it may
be too short.

Proposal. A `check_timeout:` keyword (seconds) on `Asterism.connect`,
default unchanged. Breaking: no. Boards: yes (mrblib, additive).

### 3.7 Discoverability

#### X1. Two styles, little guidance

Problem. The README has both styles but no rule for choosing. A new user
on CRuby reads the "Ruby-like" section first, writes blocks, and later
finds the code cannot run on a board; or reads "The API" and polls on CRuby
without knowing a receiving thread exists.

Proposal. A short "Which API?" section at the top of the README:

| You write for | Use | Why |
|---|---|---|
| A board, or code that must run on both | the polled API (`Asterism.poll`, `node.poll`, `each_pending`) | the only one on the boards; nothing runs behind your back |
| CRuby only (tools, servers, Rails, scripts) | the Ruby-like API (`Asterism.connect { }`, `Zenoh.open { }`, `ROS.connect { }`) | blocks, a receiving thread, Enumerators, seconds |
| CRuby, but you own the loop (a game loop, a test) | the polled API | same as the boards |

Name the two consistently everywhere ("portable API" and "CRuby API"
read better than "polled" and "Ruby-like" to a newcomer; decision D9). No
code change.

#### X2. Internals are public

Problem. Inventory 1.3 and 1.5 list about forty public methods that are
implementation (`Asterism.pump`, `release`, `lost`, `dispatch`,
`Node#deliver`, `entity_keys`, `ROS.mangle`, ...). Users cannot tell them
from the API, and any of them could become a compatibility promise by
accident.

Proposal.

- 0.4.0: mark them `@api private` in YARD and leave them out of the
  reference (plan item 2); list the public API in one place.
- 1.0: move them out of sight where the boards allow it. Ruby's
  `private_class_method` and `private` work on CRuby; check that the
  boards' compiler honours them before relying on it. Otherwise prefix
  with `_` or move into `Asterism::Internal`. The CRuby layer overrides
  several of them by `prepend` (`tell`, `wait_until`, `handle`, `fire`,
  `pump`), so they must stay callable from the layer.

- Breaking: only for code that calls internals. Boards: yes (mrblib).

#### X3. Units in the reference

Every time argument in the YARD reference should say its unit in the type
line (`@param timeout [Float] seconds`). This is what made U1 hard to see
in the first place: the README tables mention units in prose, not next to
each argument.

#### X4. Pattern of names for queues

The polled layer uses `*_pending` for "take what is there now"
(`each_pending`, `handle_pending`) but `Get` uses `each_reply` /
`each_result` for the same idea. Renaming would churn the boards for
little gain; document the rule ("every `each_*` on a polled object drains
without waiting") instead. `each_result` (the value form with errors) is
the least clear name; leave it with documentation (it reads like a Result
type with `ok?` / `error?`).

### 3.8 Ruby idioms

#### I1. Booleans in `Data` values without `?`

Problem. `Sample#express`, `Transport#multicast`, `Link#streamed`,
`TransportEvent#multicast` are booleans without predicates; `Reply` has
`error` and `error?`; `Liveliness` has `alive` and `alive?`. Half are done
the Ruby way.

Proposal. Add `express?`, `multicast?`, `streamed?`. Keep the plain
readers (pattern matching uses the member names).

- Breaking: no. Boards: no (CRuby `Data` values).

#### I2. Positional optional arguments in the polled API

Problem. `subscribe(key, 16)`, `queryable(key, 16)`,
`liveliness_watch(key, 16)`, `get(key, 2000, params, payload)`,
`querier.get(params, payload)`, `matching_listener(16)`,
`transport_events(16, history: true)`, `Asterism[path, 2000]`. The
Ruby-like layer uses keywords for the same things (`depth:`, `timeout:`,
`params:`, `payload:`). Positional optionals are hard to read and cannot
be skipped (`get(key, 2000, nil, payload)`).

Proposal. Accept keywords in the polled layer too, next to the positional
forms:

```ruby
# before
s.get("a/b", 2000, nil, payload, attachment: att)
s.subscribe("a/**", 32)
# after
s.get("a/b", timeout: 2.0, payload: payload, attachment: att)
s.subscribe("a/**", depth: 32)
```

1.0: decision D2, whether to drop the positional forms. Recommendation:
drop the positional **time** (U1) and keep positional `depth` (it is short
and unambiguous on the boards, where every keyword parsed in C is a little
code).

- Breaking: no in 0.4.0; partly in 1.0. Boards: yes (C binding and mrblib).

#### I3. Keywords for the call collide with message fields

Problem. `client.call(request = nil, timeout_ms: 2000, **fields)` and the
CRuby `node.call(..., timeout:, timeout_ms:, **fields)` share one keyword
space with the request's fields. A service whose request has a field named
`timeout_ms` (or `timeout` on CRuby) cannot be called with keyword fields:
the field is taken as the time limit. The same holds for any future option.

Proposal. Keep the keyword fields (they read well) but document the
reserved names, and recommend the Hash form when a field might collide:

```ruby
client.call({ timeout: 5 }, timeout: 2.0)   # the request as a Hash, then options
```

For 1.0, consider reserving a prefix-free set explicitly (`timeout`,
`timeout_ms`) and raising `ArgumentError` when a type has a field of that
name and the caller uses keyword fields, so the collision is loud.

- Breaking: no (documentation; the 1.0 check only turns a silent bug into
  an error). Boards: yes (mrblib).

#### I4. Block forms for lifecycle

Problem. The Ruby-like layer has `open { }` / `connect { }` that close
after the block. The polled `Session.open` has none, and tokens,
publishers and subscriptions have no scoped form.

Proposal (CRuby first, additive):

```ruby
Asterism::Zenoh::Session.open(loc) { |s| ... }        # closes after
c.liveliness("me/alive") { ... }                       # token withdrawn after
c.publisher("demo/temp") { |pub| 3.times { pub.put(_1) } }
```

On the boards, `Session.open` with a block is cheap to add (C yields once);
the others are not needed there.

- Breaking: no. Boards: optional.

#### I5. `on_*` handlers: register many or replace one?

Problem. `Asterism.on_join` appends (several blocks), `on_error`
replaces (one handler), `Publisher#on_matching` appends. There is no way
to remove an `on_join` block except `Asterism.close`.

Proposal. Document the rule ("`on_error` replaces; every other `on_*`
adds"), and make the adding ones return something that can be removed
(`handle = net.on_join { }`, `handle.close`), as `Events` already does for
`on_transport`.

- Breaking: no if the return value stays chainable (return a handle that
  also responds to the old chained calls), otherwise a small break for
  `net.on_join { }.on_leave { }` chains. Decision is minor; recommendation:
  keep chaining, add `off_join(block)` instead.
- Boards: yes for `Asterism.on_join` (mrblib).

### 3.9 Thread-safety expectations

#### T1. State the contract per object

The design is careful (C5, C6), but the README's "Threads" section
describes mechanisms, not promises. Users need the promise:

| Object | Use from several threads? |
|---|---|
| `Asterism::Zenoh::Session` and its subscribers, queryables, gets, publishers, queriers (CRuby) | yes; each queued entry goes to exactly one taker |
| `Zenoh::Connection` (ZR) | yes; blocks run one at a time on the receiving thread |
| A `Subscription#each` / `Watch#each` / `get` Enumerator | one thread per iteration |
| The object layer (`Asterism.*`, `Net`, proxies, `Future`) | yes; serialised by `Asterism::LOCK` (one connection per process) |
| `ROS::Connection` and the nodes it makes | yes (its runner's lock) |
| A `ROS::Node` made with `Node.new` (polled) on CRuby | **no**; one thread, as on the boards |
| Boards | one thread (the application's update loop) |
| Ractors | not supported |

Proposal. Put this table in the README (documentation only).

#### T2. Fork

Problem. zenoh-c runs its own threads; they do not survive `fork`. A
session opened before `fork` (Puma / Unicorn preload, Resque, the
asterism-console bridge if it ever runs under a forking server) is broken
in the child, and the failure will be a hang or a crash, not an error.

Proposal. On CRuby, remember the pid at `Session.open`; every call from a
different pid raises `Zenoh::ClosedError, "opened in process N; open a new
session after fork"`. Document "connect after fork", as Bunny and most
C-backed clients do.

- Breaking: no (it turns undefined behaviour into an error). Boards: no.

#### T3. Blocks that wait

Problem. A block on the receiving thread that waits (a proxy call, a
service call) is allowed on CRuby (it polls, nested up to `MAX_NESTING`),
but forbidden on the boards (stack). A long block delays everything else
on that connection. Both are documented, in different sections.

Proposal. One rule in one place: "Do not wait in a block. On CRuby it
works but delays every other block on that connection; on a board it can
overflow the stack." Optionally, on CRuby, warn once when a block runs
longer than a threshold (e.g. 100 ms) under `$VERBOSE`. Boards: no.

#### T4. Module-level state (one object-layer connection per process)

The object layer keeps its state in the `Asterism` module, so a process
has one connection (`Asterism::LOCK` serialises it). On a board that is
exactly one application VM; on CRuby it rules out, for example, one
process bridging two networks. Making the connection an instance
(`Asterism::Net.new(...)`, with the module functions delegating to a
default instance, as `Redis.current` once did) is a large change to
mrblib. Recommendation: **leave it for after 1.0**, and say in the README
that it is one per process.

## 4. Recommended plan

### 4.1 0.4.0: additive, plus deprecations

Nothing in 0.4.0 breaks existing code; old forms warn once (4.3).

| ID | Change | Boards |
|---|---|---|
| U1 | `timeout:` (s) on every call that takes a time, both Rubies; `timeout_ms:` on the polled layer; positional ms warn | yes (C + mrblib) |
| U3 | `node.every(ms:)` | yes (mrblib) |
| U4 | `query_timeout:` (ZR), `took` (s), "both given" raises, messages in the caller's unit | partly (mrblib) |
| U6 | `connect_timeout:` | CRuby first |
| N1 | new count name (D3), `peers` warns | yes (C) |
| N3 | `node.subscribe` without a block on the boards | yes (mrblib) |
| N4 | `reply_error` / `reply_delete` | no |
| N5 | `pending` / `received` on `ROS::Subscription` | yes (mrblib) |
| N6 | `remote_methods`; `Proxy#methods` warns | yes (mrblib) |
| N7 | `BACKEND`, `BACKEND_VERSION`, `PEER_SUPPORTED` | yes (C) |
| N8 | `TimeoutError` names, old ones as aliases | yes (mrblib) |
| L1 | ZR `Subscription#each_sample`; its `each_pending` warns | no |
| L5 | clear error for `config:` on the boards | yes |
| E1 | one error tree; `Zenoh::ClosedError`; ROS raises `ClosedError` | yes (C + mrblib) |
| E2 | `Zenoh::Error#code` | yes (C) |
| I1 | `express?`, `multicast?`, `streamed?` | no |
| I2 | keyword forms of the positional optionals | yes (C + mrblib) |
| I4 | `Session.open { }`, scoped token / publisher | CRuby first |
| T2 | fork detection | no |
| D-5 | `check_timeout:` on `connect` | yes (mrblib) |
| docs | X1 "Which API?", X2 `@api private`, X3 units in the reference, X4, D-1 defaults table, D-2, D-4, T1 thread table, T3, I3 reserved names, I5 handler rule | no |

The board changes split into two groups with different costs: mrblib only
(rebuild the firmware) and the C binding (rebuild and reflash; also a new
picoruby-asterism-zenoh version). Batch the C ones (U1 `get` keywords, N1,
N7, E1, E2, I2) into one board release.

### 4.2 1.0: the breaking part

| ID | Change | Boards |
|---|---|---|
| U1 / I2 | positional time arguments removed (`timeout_ms:` stays) | yes |
| N1 | `peers` removed (or re-defined later, see N1) | yes |
| N6 | `Proxy#methods` back to `Object#methods` | yes |
| L1 | ZR `Subscription#each_pending` removed | no |
| L3 | one-argument `reply` answers on the queryable's key (if D7 says so) | yes |
| L4 / E1 | ROS raises `Disconnected` when the session is closed | yes |
| R1 | `Asterism.each { }` / `Net#each { }` return the proxies / `self` (if D6 says so) | yes |
| X2 | internals hidden or prefixed | yes |
| E1 | `ServiceFailed` made private | no |

Before tagging 1.0: one minor release (0.4.x or 0.5.0) in which every item
above has warned, and the board apps in fmruby-core (`flash/app/test/`)
have been moved off the deprecated forms.

### 4.3 How deprecation works

- A small shared helper in mrblib, `Asterism.deprecated(old, new)`, warns
  once per `old` per process: `warn` on CRuby (so `Warning` filters and
  `-W:no-deprecated` apply), and on the boards whatever the VM has
  (`warn` if it exists, else `puts`), still once. A global switch
  (`Asterism.deprecations = :warn / :raise / :silent`) lets CI use `:raise`
  and lets a board application silence it.
- Constant aliases cannot warn on mruby; on CRuby `deprecate_constant`
  gives a soft warning (only with `Warning[:deprecated]`). For constants,
  rely on the changelog.
- Each deprecated form lives for at least one minor release, and the
  changelog lists the replacement next to it.

### 4.4 Leave as it is

| ID | What | Why |
|---|---|---|
| R2 | `Asterism.connect` returns the module | one connection per application on the boards |
| R3 | `each_pending` returns an Array | board stack; "take now" is the right meaning |
| X4 | `each_reply` / `each_result` names | churn on the boards for little gain; document |
| D-2 | `consolidation: :none` | the object layer and rmw_zenoh need every reply |
| D-3 | `errors: false` | matches `each_reply`; document |
| T4 | module-level object layer | large; after 1.0 |
| N2 | `open` / `connect` / `Net` names | document the map; alias only if wanted |
| - | Arrays instead of `Data` on the boards | the boards have neither `Data` nor `Struct` (R3) |
| - | Receiving interval (2 ms) and the polling design | plan item 7: measure first |

## 5. Decisions for the maintainer

1. **D1 Units**: A (seconds everywhere, `_ms` kept on the polled layer),
   B (unit in the keyword name, each layer keeps its unit) or C (keep
   0.3.0). Recommended: A.
2. **D2 Positional arguments**: in 1.0, remove positional time arguments
   only (recommended), all positional optionals, or none.
3. **D3 `peers`**: the new name (`connection_count` or `peer_count`), and
   whether `peers` is removed in 1.0 or later re-used as the Array of peer
   IDs.
4. **D4 Error names and tree**: define `Asterism::Error` in both Zenoh
   bindings and put every error under it (recommended); `TimeoutError`
   under `Asterism::Error` rather than `::Timeout::Error` (recommended);
   whether `Disconnected` is renamed (`DisconnectedError` /
   `ConnectionError`) or kept.
5. **D5 Deprecation warnings on the boards**: once per name (recommended),
   silent, or none (changelog only).
6. **D6 `each` return value**: change `Asterism.each { }` /
   `Net#each { }` to Ruby's convention in 1.0, or keep the count.
7. **D7 One-argument `reply`**: answer on the queryable's own key in the
   polled layer too (recommended; changes the board binding), or make the
   Ruby-like layer stricter instead.
8. **D8 `Proxy#methods`**: restore `Object#methods` in 1.0 and add
   `remote_methods` (recommended), or keep the override.
9. **D9 Names in the docs**: call the two styles "portable API" and
   "CRuby API" (or keep "polled" / "Ruby-like"); whether to add one verb
   (`connect`) everywhere.
10. **D10 Release path**: 0.4.0 then 1.0, or 0.4.0, 0.5.0 (a second
    deprecation window) then 1.0; and whether picoruby-asterism-zenoh is
    versioned in lockstep with asterism-zenoh from now on.
11. **D11 Board work**: which C-binding changes (U1 `get` keywords, N1,
    N7, E1, E2, I2) go into the next board release, given each needs a
    firmware rebuild and reflash.
