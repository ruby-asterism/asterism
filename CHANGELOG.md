# Changelog

All notable changes to asterism (the CRuby gem) and picoruby-asterism (the
mrbgem; the same `mrblib/`). Nothing has been published to rubygems.org
yet; the versions below are the ones in this repository. From 0.4.0 the
two Zenoh bindings (asterism-zenoh, picoruby-asterism-zenoh) carry the
same version number.

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
- README: "Which API?" (the portable API and the CRuby API), the error
  tree, the defaults, the threads table, the deprecations and what 1.0
  changes, reserved keywords. Internal methods are marked `@api private`.

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
