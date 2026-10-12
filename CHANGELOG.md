# Changelog

All notable changes to asterism (the CRuby gem) and picoruby-asterism (the
mrbgem; the same `mrblib/`). 0.4.0 is the first version on rubygems.org;
the earlier ones are only in this repository. From 0.4.0 the two Zenoh
bindings (asterism-zenoh, picoruby-asterism-zenoh) carry the same minor
version (a patch release of one may come without the other).

## 0.7.0

**This release breaks compatibility: it speaks wire protocol 1 only.** A
node of 0.7.0 and a node of 0.6.0 or earlier (protocol 0) do not see each
other's objects, and a call between them fails: a protocol 0 call to a
0.7.0 node is refused with the error kind `protocol`, a 0.7.0 call to an
older node is not answered, and their replies are malformed answers to
each other. Move every node of a network to 0.7.0 together (boards,
browsers, consoles, CRuby programs). The Ruby API stays as it was, with
the additions below. Needs asterism-zenoh / picoruby-asterism-zenoh 0.4.0
(unchanged), and on mruby a MessagePack that reads and writes bin (README,
"Using it").

Protocol 1 (`docs/protocol.md`, normative; `docs/protocol_review.md` says
what was decided and why):

- A call is a get on `asterism/<node>/<app>/<object>/call/<caller>`, where
  `<caller>` is the calling node's ID. Its payload is a map
  `{"method" => name, "args" => [...], "kwargs" => {...}}` (args and
  kwargs left out when empty) instead of the array `[method, args,
  kwargs]`.
- A reply is `{"value" => value}` or `{"error" => {"kind" => ..., "class"
  => ..., "message" => ...}}` instead of `["ok", value]` /
  `["error", class, message]`. The kinds: `raised`, `not_exposed`,
  `no_object`, `arguments`, `malformed`, `unsendable`, `nesting`,
  `protocol`.
- The meta is `{"methods" => [{"name" => name, "arity" => n}, ...]}`.
- Binary Strings go as MessagePack bin (CRuby: ASCII-8BIT Strings, no more
  compatibility mode; mruby: `String#b`), and a bin arrives as a binary
  String. The profile's icon is a bin.
- The profile has `"protocol" => 1`.
- Each application declares its own liveliness token
  `asterism/<node>/<app>`; the node token `asterism/<node>`, which the
  applications of a node shared, is gone. A node is present while any of
  its applications or objects is.
- A payload is exactly one value: bytes after it, ext types and integers
  outside the signed 64-bit range make it malformed. CRuby raises
  `EncodeError` before sending an Integer outside int64 (it raised
  `RangeError` before).
- A protocol 0 call (on the five-chunk `.../call` key) is answered with the
  error kind `protocol`.

Added

- `Asterism.current_call` while an exposed method runs for a call (per
  thread on CRuby, `net.current_call` too): `from` (the calling node),
  `verified` (`:claimed`; `:local` for a call from the same application),
  `object`, `method`. `Asterism::CurrentCall`.
- `Asterism.expose(name, obj, methods:, caller: :from)` (and
  `net.expose`): passes the calling node's ID as the keyword `from:` and
  refuses a call that brings `from:` itself.
- `RemoteError#remote_kind`: the error's kind, as above (nil when the
  answer did not say).
- `proxy.asterism_call(name, *args, **kw)` and `proxy.async.asterism_call`:
  a call by the method's name, for names a proxy cannot forward (`display`,
  `hash`, `class`, `fail`, ...) and names that are not Ruby identifiers.
- `Asterism::PROTOCOL` (1).
- The conformance tests (`test/protocol/`) are protocol 1's: 55 values, 54
  incoming queries, 24 outgoing steps; CRuby and mruby pass them all.

Changed

- `proxy.asterism_meta` returns the new meta form.
- `Asterism.connect`'s duplicate check also finds a copy of the
  application that exposes nothing (it has its application token now).
- `host_test/msgpack.rb` (the mruby test's MessagePack) writes a binary
  String as bin and reads a bin as one; the mruby test build adds
  mruby-encoding (to tell a binary String).
- The documentation of the wire protocol (docs/protocol.md,
  docs/protocol_review.md) and the conformance tests (X0, unreleased in
  0.6.0) are rewritten for protocol 1.

## 0.6.0

One connection for everything and a lighter `Asterism.poll`; every 0.5.x
call works as before. Needs asterism-zenoh / picoruby-asterism-zenoh 0.4.0
(unchanged).

Added

- `Asterism.session` (README "One connection"): the Zenoh session of
  `Asterism.connect` (an `Asterism::Zenoh::Session`), for put, subscribe, a
  ROS 2 node (`Asterism::ROS::Node.new(Asterism.session, ...)`) and the rest
  of the Zenoh API on the same connection. `Disconnected` when not
  connected. The session stays Asterism's: its `close` does nothing (it
  warns once); `Asterism.close` and a lost connection close it, with
  everything declared on it. A router that lets a one-time password in
  once now takes such an application, and its ROS 2 node has the node's
  Zenoh ID (a console draws it inside the node).
- The CRuby API: `net.session`, the same session as a `Zenoh::Connection`
  on the `Net`'s receiving thread (`shared?`; its `close` does nothing);
  `Asterism::ROS::Connection.new(net.session)` makes ROS 2 nodes on it, and
  its `close` withdraws only its nodes. `Zenoh::Connection#shared?`.
  `ROS::Node#close` on a `ROS::Connection` also stops polling the node.
- `rake bench:poll` (`test/bench_poll.rb`): the time and the allocations
  of one `Asterism.poll` by the number of nodes and objects.
- Tests: `test/test_session.rb`, `test/test_api_session.rb`, and on mruby
  `host_test/test_session.rb` with `host_test/peer.rb` (the mruby test
  build adds mruby-eval for the ROS 2 type files).

Changed

- `Asterism.poll` does less when nothing came: each queue (calls, profile
  queries, liveliness) is read only when its count is not zero, and the
  list of nodes and the comparison behind `on_join` / `on_leave` are made
  again only after a liveliness change, with Hashes instead of `include?`.
  The behaviour is the same (the order and number of the `on_join` /
  `on_leave` calls, the order of `Asterism.nodes`). With 4 other nodes and
  5 objects, a poll in which nothing changed: CRuby 3.2 us and 49
  allocations -> 0.6 us and 7; mruby (host) 14-17 us -> 2.2 us.
  `Asterism.each` drops duplicates with a Hash.

## 0.5.0

Node profiles; every 0.4.x call works as before. Needs asterism-zenoh /
picoruby-asterism-zenoh 0.4.0 (unchanged).

Added

- Node profiles (README "Profiles"): `Asterism.profile(kind:, name:, host:,
  icon:)` sets this node's profile (the fields given; the rest stay) and
  returns it, `Asterism.profile` returns it, `Asterism.profile_of(node,
  icon: true, timeout: 2.0)` asks another node's (nil when it does not
  answer). The CRuby API: `net.profile`, `net.profile_of`. Answered on
  `asterism/<node>/@profile` (a queryable of every connected application,
  MessagePack Hash: `kind`, `host`, `name`, `icon`, `icon_hash`; the
  parameter `icon=0` leaves the icon out), and put on the same key without
  the icon at connect and on each change.
- Defaults: `kind` is `cruby` on CRuby and `picoruby` on mruby / PicoRuby;
  the icon is the file at `Asterism.default_icon_path` when it is there:
  the gem's `data/icon.png` on CRuby (new; a ruby, 32x32), and
  `/usr/share/asterism/icon.png` on the boards.
- `Asterism::Profile`: `png_info` (the icon checks: PNG signature, chunks
  from IHDR to IEND, 8 KB, 256x256; and `icon_hash`, the Adler-32 of the
  chunks' CRCs), `check` (cleans a received profile: an icon that does not
  pass is dropped), the limits as constants.
- `rake test:mruby` and `host_test/`: the shared layer on mruby (built with
  picoruby-asterism-zenoh, MRB_UTF8_STRING as on the boards), profiles
  between two mruby processes. CI runs it.

Changed

- The "Ruby profile" (0.4.0) is now called the Ruby feature table, so that
  it is not taken for a node's profile: `docs/ruby_profile.md` is
  `docs/ruby_features.md`. The probes' directory `profile/` and its code
  keep their names.

## 0.4.1

Additions and a fix; every 0.4.0 call works as before. Needs
asterism-zenoh / picoruby-asterism-zenoh 0.4.0 (unchanged).

Added

- More bundled types (`data/msgs`, 62 -> 84 files): rcl_interfaces (Log for
  `/rosout`, ParameterEvent, Parameter, ParameterValue), nav_msgs
  (Odometry, Path, MapMetaData, OccupancyGrid), sensor_msgs (LaserScan,
  PointField, PointCloud2, and CompressedImage for Marker),
  diagnostic_msgs (DiagnosticArray, DiagnosticStatus, KeyValue),
  tf2_msgs/TFMessage, visualization_msgs (Marker, MarkerArray, MeshFile,
  UVCoordinate), geometry_msgs PoseWithCovariance and TwistWithCovariance
  (for Odometry). Every type hash matches ROS 2 Jazzy's type description
  JSON. tf2_msgs is under the BSD 3-Clause License
  (`data/msgs/LICENSE-BSD-3-Clause-tf2_msgs.txt`); the gem's licenses are
  now `MIT`, `Apache-2.0` and `BSD-3-Clause`.
- `FIELD_TYPES` in every generated message: per field
  `[name, base, kind, nested, capacity, string_capacity]`, plain Arrays,
  Strings, Integers and nil (kind is `"scalar"`, `"array"`,
  `"bounded_sequence"` or `"sequence"`). A string sequence and a number
  sequence can now be told apart without the .msg.
- `Asterism::ROS.field_types(type)`: the `FIELD_TYPES` of a type and of
  every message type it is made of, `{ROS name => FIELD_TYPES}` (for a
  service, its Request and Response).

Fixed

- `Asterism::ROS.require_type` checks the type name before it builds a
  path: `pkg/msg/Name` or `pkg/srv/Name`, the package `[a-z][a-z0-9_]*`,
  the name `[A-Z][A-Za-z0-9]*` (checked byte by byte; the boards have no
  Regexp). A package name with `..` could point above a `TYPE_PATH`
  directory. Anything else raises `ArgumentError`, as a malformed name did
  before.

Types generated by the 0.4.0 generator still load; regenerate them to get
`FIELD_TYPES`.

## 0.4.0

The first step of the API review toward 1.0 (docs/api_review.md):
additions, deprecations and fixes. Every 0.3.0 call works as before.
Needs asterism-zenoh / picoruby-asterism-zenoh 0.4.0.

Added

- Time limits in seconds everywhere: `Asterism[path, timeout: 2.0]` (or
  `timeout_ms:`), `client.call` / `node.call(timeout:)`,
  `Asterism.connect(connect_timeout:, check_timeout:)`; on the CRuby API
  `timeout_ms:` next to `timeout:` and `query_timeout:` on
  `advanced_subscriber`. Giving a time limit twice raises `ArgumentError`.
  Time-out messages give both units (`within 2.0 s (2000 ms)`).
- `node.every(ms: 500)`, `Timer#period_ms`.
- `Future#took`, `ROS::Call#took` (seconds).
- `request:` on `client.call` / `call_async` / `node.call`.
- `node.subscribe(topic, type)` without a block returns the subscription
  (as `node.subscription`) instead of raising, on the boards as on CRuby.
- `pending` / `received` on `ROS::Subscription`.
- `Proxy#remote_methods`.
- `Asterism.off_join` / `off_leave` (and on `Net`).
- One error tree under `Asterism::Error`: `TimeoutError` (was `Timeout`),
  `ROS::TimeoutError` (under `TimeoutError`; was `ROS::Timeout`),
  `ROS::UnknownType` and `CDR::DecodeError` moved under it, and the
  bindings' `Zenoh::Error` / `Zenoh::ClosedError` are under it too. The ROS
  layer raises `Zenoh::ClosedError` when its session or entity is closed.
- CRuby API: `Connection#connection_count`, `Subscription#each_sample`,
  `c.liveliness(key) { }` and `c.publisher(key) { |pub| }` (closed after
  the block), `net[path, timeout_ms:]`.
- `DEFAULT_TIMEOUT`, `CHECK_TIMEOUT`, `Client::DEFAULT_TIMEOUT` (seconds).
- CRuby API: `depth:` on `Connection#get`, `#liveliness_get` and
  `Querier#get`. A get's queue held 16 and could not be changed, so a
  wildcard get past the 16th reply lost the rest (a router answers in one
  burst; `liveliness_get("@ros2_lv/**")` returned 16 of 31).
- CRuby API: `dropped` (with `received`, and `errors` for gets) on what a
  get gives: `liveliness_get` returns a `KeyList` (an Array with
  `dropped` / `received`), `get` and `Querier#get` without a block a
  `GetEnumerator` (an Enumerator with the counts of the last get it sent).
  `Watch#dropped` / `pending` / `received` (before only through
  `w.watch.dropped`).
- CRuby API: a get, liveliness watch or subscription whose depth was left
  at the default warns once (`Asterism.warn_once`) when something was
  dropped. So does the object layer's watch, on every Ruby.
- README: "Which API?" (the portable API and the CRuby API), the error
  tree, the defaults, the threads table, the deprecations and what 1.0
  changes, reserved keywords. Internal methods are marked `@api private`.

Changed

- CRuby API: the default depth of `get`, `liveliness_get`, `Querier#get`
  and `liveliness_watch` is the binding's `DEFAULT_GET_DEPTH` /
  `DEFAULT_WATCH_DEPTH`, 1024 (was 16; the boards stay at 16).
- The object layer's liveliness watch (behind `Asterism.each` and
  `Asterism.nodes`) holds 1024 on CRuby (64 on the boards, as before).

Deprecated (each warns once per name; `Asterism.deprecations = :raise`
raises instead)

- `Asterism[path, ms]` (the time as a positional argument; a Float there
  warns with its own message: it is milliseconds).
- `Asterism::Timeout`, `Asterism::ROS::Timeout` (the names; they still
  rescue the same errors, through `const_missing`, so that inside
  `module Asterism` the name `Timeout` is Ruby's again).
- `Proxy#methods` returning the remote methods: `remote_methods`.
- CRuby API: `Connection#peers` (`connection_count`) and
  `Connection::Subscription#each_pending` (`each_sample`).
- A request field named `timeout` / `timeout_ms` given as a keyword to
  `client.call` (use `request:`).

Fixed

- A Float as the positional time limit was taken as milliseconds and
  truncated (`Asterism[path, 2.0]` waited 2 ms); it now warns and says so.
- A service whose request has a field named like the time-limit keyword
  could not be called with keyword fields: `request:` (or a Hash) now
  carries the request, and `timeout:` the time limit.

## 0.3.0

- CRuby API: publishers, queriers, the advanced publisher / subscriber and
  events with blocks; `Asterism.connect(config:)` for TLS.
- Strings are built from a fresh String (frozen literals); CI on Ruby 3.2
  to 4.0 and with frozen literals, against asterism-zenoh main, and an
  installed-gem check.
- docs/api_review.md (the review this version starts on) and profile/
  (the Ruby profile of the shared layer across implementations).

## 0.2.0

- The CRuby API: blocks, a receiving thread and Enumerators over the
  portable API (`Asterism::Zenoh.open`, `Asterism.connect { |net| }`,
  `Asterism::ROS.connect`).
- In the shared layer: `on_join` / `on_leave`, `node.every`,
  `node.subscribe` blocks and `deconstruct_keys`.

## 0.1.0

- The pure Ruby layers as one source for the CRuby gem and the mrbgem: the
  object layer (`Asterism.connect / expose / [] / poll`), `Asterism::CDR`,
  `Asterism::ROS` (topics and services over rmw_zenoh's wire format), the
  type generator and the bundled ROS 2 Jazzy types.
