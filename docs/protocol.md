# The Asterism wire protocol

Status: **descriptive**. This document writes down what asterism 0.6.0
puts on the network and what it expects back, so that an implementation in
another language (Python, MicroPython, TypeScript, C, ...) can join the same
network. It was written from the source (`mrblib/asterism.rb`,
`mrblib/future.rb`, `mrblib/proxy.rb`, `mrblib/profile.rb`,
`lib/asterism/cruby.rb`) and checked against what was captured on the wire
from three implementations: CRuby (asterism 0.6.0 over zenoh-c 1.10.1),
mruby on a PC (`rake test:mruby`'s build over zenoh-pico 1.10.1) and the
Family mruby firmware (the Linux simulation: the boards' code and their
MessagePack, msgpack-c). Nothing here changes the protocol; the proposals
for changing it are in [protocol_review.md](protocol_review.md).

This version of the protocol has no number on the wire. This document calls
it **protocol 0** (the 0.x releases of the gem). How a number could be
added is review item R-13.

The ROS 2 side of Asterism (`Asterism::ROS`) is not part of this protocol:
it speaks rmw_zenoh's format, described in the README ("ROS 2
(rmw_zenoh)").

The words MUST, SHOULD and MAY are used as in RFC 2119. Where this
document says what "the implementation" does, it means asterism 0.6.0 on
every Ruby, unless a difference is named; section 9 lists the differences.

Contents:

1. [Model](#1-model)
2. [Names and keys](#2-names-and-keys)
3. [Values](#3-values)
4. [Calls](#4-calls)
5. [Meta](#5-meta)
6. [Liveliness](#6-liveliness)
7. [Profiles](#7-profiles)
8. [What Zenoh must provide](#8-what-zenoh-must-provide)
9. [Differences between the implementations](#9-differences-between-the-implementations)
10. [Conformance tests](#10-conformance-tests)
11. [Captured examples](#11-captured-examples)

## 1. Model

- A **node** is a machine or a process with an ID (`fmruby-1a2b3c`,
  `linux`, `mypc`). An **application** (app) runs on a node and has a name
  (`demo`). An application **exposes objects** under names (`apu`); each
  exposed object has a set of methods that may be called from elsewhere.
  An object is addressed as `<node>/<app>/<object>`.
- Each application has **one Zenoh session** (since 0.6.0 the same session
  carries the application's own puts, subscriptions and ROS 2 nodes). A
  node with two applications has two sessions; they share the node ID.
- A **call** is a Zenoh query (get) to the object's call key; its answer is
  the query's reply. **Meta** (the list of exposed methods) is a query to
  the object's meta key. **Presence** is told with Zenoh liveliness
  tokens. A node's **profile** (what it is, a name, an icon) is a query to
  the node's profile key, and is also put there on each change.
- There is no server: every application answers the queries for its own
  objects. A Zenoh router (zenohd) usually connects them; a direct peer
  link works the same.
- Payloads are MessagePack. Nothing else is used: no Zenoh encoding, no
  attachment, no Zenoh error reply, no timestamp (section 8).

## 2. Names and keys

### 2.1 Names

A node ID, an application name and an object name are each **one Zenoh key
chunk**:

- not empty;
- MUST NOT contain `/`, `*`, `$`, `?`, `#`;
- MUST NOT start with `@` (chunks starting with `@` are Zenoh's verbatim
  chunks, and Asterism uses them for its own keys, see `@profile`).

`Asterism.connect`, `Asterism.expose` and `Asterism[path]` raise
`ArgumentError` for anything else. Nothing else is checked: there is no
length limit and no character set beyond Zenoh's (UTF-8). Keep them short
on the boards (every key and token carries them). Family mruby's boards use
`fmruby-<6 hex digits>`, the browser build `wasm-<6 hex digits>`, the
simulation `linux`.

A **method name** is any MessagePack str. It is not checked against these
rules: it travels in the payload, not in the key. Ruby method names such as
`ok?`, `save!` and `name=` are exposed and called as they are (review
R-10).

### 2.2 Keys

| Key | Zenoh | Who declares it | Section |
|---|---|---|---|
| `asterism/<node>` | liveliness token | every application of the node (each its own token) | 6 |
| `asterism/<node>/<app>/<object>` | liveliness token | the application, for each exposed object | 6 |
| `asterism/<node>/<app>/**` | queryable | the application (one) | 4, 5 |
| `asterism/<node>/<app>/<object>/call` | get | a caller | 4 |
| `asterism/<node>/<app>/<object>/meta` | get | a caller | 5 |
| `asterism/<node>/@profile` | queryable | every application of the node (each its own) | 7 |
| `asterism/<node>/@profile` | put | every application of the node, at connect and on each change | 7 |

- The root chunk is `asterism`.
- `@profile` is a verbatim chunk: `asterism/**` and `asterism/<node>/**`
  do **not** match it (captured: a get on `asterism/<node>/**` gets no
  profile reply, a subscriber on `asterism/**` does not see the profile
  puts; `asterism/*/@profile` does match). The object layer's wildcards and
  its liveliness watch never see it.
- The application's own keys under `asterism/<node>/<app>/<object>/<more>`
  (puts, subscriptions) do not meet the object layer: puts and
  subscriptions are not queries, and the queryable ignores keys of more
  than five chunks (4.3).
- Reserved for later (not used in 0.6.0): `asterism/<node>/<app>/@profile`
  (an application's own profile).

## 3. Values

### 3.1 The MessagePack subset

Call arguments, keyword arguments, return values, meta and profiles are
MessagePack values built from:

| MessagePack | Ruby | Notes |
|---|---|---|
| nil | `nil` | |
| bool | `true`, `false` | |
| int | `Integer` | signed 64-bit range: -2^63 to 2^63-1 (3.4) |
| float | `Float` | always written as float64 (`cb`); float32 (`ca`) is read |
| str | `String`, `Symbol` | **every** String is written as str, also binary data (3.3) |
| array | `Array` | |
| map | `Hash` | keys may be any value of this table (review R-3) |

- A `Symbol` is written as a str, also as a map key and as a keyword
  argument's name. It is read back as a String (except keyword names, which
  the receiving Ruby turns into Symbols to pass them as keywords).
- Anything else (`Time`, a `Struct`, an object) is refused by the sender
  before sending (`Asterism::EncodeError`); a return value that cannot be
  sent is answered as an error (4.4).
- **Nesting**: the sender refuses a value nested deeper than 16 levels,
  counted from the top of the payload (`Asterism::Codec::MAX_DEPTH`): the
  call's own array is level 0 and its arguments array level 1, so an
  argument may hold 14 levels of arrays and maps; a return value 15. The
  receiver does not check nesting.
- Map key order carries no meaning. The implementation writes keys in the
  Hash's insertion order.

### 3.2 Which byte forms are written

Every implementation reads every valid form of a value (3.3 lists the
exceptions). What each writes:

| Value | CRuby (msgpack-ruby, compatibility mode) | Boards (msgpack-c) |
|---|---|---|
| int | the shortest form; non-negative values in the uint forms (`cc`/`cd`/`ce`/`cf`), negative ones in the int forms (`d0`...`d3`) | the same bytes |
| float | `cb` (float64) | `cb` |
| str of 32-255 bytes | `da` (str16): compatibility mode has no str8 | `d9` (str8) |
| other str | fixstr, str16, str32 | the same |
| array, map | fix, 16, 32 forms, shortest | the same |

The mruby test build's stand-in MessagePack (`host_test/msgpack.rb`, not
used on the boards) writes `dc`/`de` (array16/map16) and `d3` (int64) for
everything, which is valid too. A reader MUST NOT depend on the form;
conformance is about values, not bytes (section 10).

### 3.3 Not portable today

These are what the implementations do with values that protocol 0 senders
do not write, or write only on one side. A new implementation SHOULD NOT
send them, and SHOULD treat them as below if it receives them.

| Input | CRuby | Boards (Family mruby, msgpack-c) | mruby test build |
|---|---|---|---|
| bin (`c4`/`c5`/`c6`) | read as a binary String | **read as `nil`** (no error) | read as a String |
| ext, timestamp ext (`d4`...`c9`, `c7`/`d6`/`d7` type -1) | the payload fails to decode | read as `nil` | fails |
| int above 2^63-1 (`cf` with the top bit set) | read; CRuby also **sends** it for an Integer in that range | **read wrapped** (2^64-1 arrives as -1) | fails |
| bytes after the first value | the payload fails to decode | **ignored** | fails |
| an Integer outside int64 (CRuby Bignum) as an argument | the sender raises `RangeError` (not `EncodeError`) | not possible | not possible |

"Fails to decode" means: a call payload is answered as malformed (4.4), a
reply payload raises `Asterism::Error` "malformed answer" on the caller.
Review R-4 (integers), R-7 (binary) and R-15 (trailing bytes) propose what
protocol 1 says about them.

### 3.4 Strings

- A str carries bytes. Text is UTF-8, but protocol 0 also carries binary
  data as str (a profile's icon, a payload an application relays): CRuby
  sends every String as str (compatibility mode) because the boards'
  MessagePack does not read bin. Receivers MUST keep the bytes of a str as
  they are, whether or not they are valid UTF-8 (captured: `ff 00` sent as
  str comes back unchanged from every implementation).
- CRuby hands a received str to the application as a UTF-8 String (which
  may not be valid UTF-8); a profile's icon is handed out as a binary
  String. The boards' Strings carry bytes (MRB_UTF8_STRING).
- A decoder that turns str into text strictly (Python's msgpack with its
  default `raw=False`, JavaScript decoders) fails on such a str. This is
  review R-7.

## 4. Calls

### 4.1 The request

A call of `method(*args, **kwargs)` on `<node>/<app>/<object>` is a Zenoh
get:

| | |
|---|---|
| key | `asterism/<node>/<app>/<object>/call` (no wildcard: the implementation only calls one object) |
| payload | MessagePack array of exactly three elements: `[method, args, kwargs]` |
| `method` | str: the method's name |
| `args` | array: the positional arguments |
| `kwargs` | map: the keyword arguments, names as str; an empty map when there are none (it is never left out) |
| parameters | none |
| attachment | none |
| encoding | not set (zenoh reports the default, `zenoh/bytes`) |
| target | ALL (`Z_QUERY_TARGET_ALL`) |
| consolidation | NONE |
| timeout | the call's time limit: 2 s by default (`Asterism[path, timeout:]`) |

Captured (every implementation sends these exact bytes for
`info.status`):

```
93                    array of 3
   a6 737461747573    "status"
   90                 []
   80                 {}
```

A block cannot be sent (the caller raises before sending). A call to an
object of the caller's own application does not go on the network: it is
run in place with the same encoding and checks (a Zenoh session does not
see its own queryable).

### 4.2 The queryable

Each connected application declares **one** queryable on
`asterism/<node>/<app>/**`. It is not complete (a get with target
ALL_COMPLETE does not reach it). Queries are taken from a queue (depth 32)
when the application polls, and answered in order; after answering each
query is finished (dropped), which ends the get for that queryable.

### 4.3 Handling a query

For each query the receiver does, in this order:

1. Split the query's key on `/`. Unless it has exactly **five** chunks
   (`asterism`, node, app, object, kind), send no reply. The node and app
   chunks are not compared with this application's (the queryable already
   matched them; they may be wildcards). The object chunk may be a
   wildcard only for meta.
2. If the kind is `meta`: section 5. If the kind is `call` and the object
   chunk is not `*`: continue. Anything else (another kind, `call` with
   object `*`): no reply.
3. Decode the payload. A missing or empty payload, bytes that are not
   MessagePack, or anything but an array of exactly three elements of
   types str, array, map is **malformed**: reply
   `["error", "ArgumentError", "malformed call (expected [method, args, kwargs])"]`.
4. If no object of that name is exposed: reply
   `["error", "NameError", "no object <object> exposed by <node>/<app>"]`.
5. If the method is not in the object's exposed table: reply
   `["error", "NoMethodError", "undefined method '<method>' for <node>/<app>/<object> (not exposed)"]`.
   A public method of the object that was not listed in `expose` is not
   callable.
6. If the method was exposed with a number of arguments `n >= 0` and the
   number of positional arguments differs: reply
   `["error", "ArgumentError", "wrong number of arguments (given <k>, expected <n>)"]`.
   Keyword arguments are not counted. `n = -1` (exposed by name only)
   accepts any number.
7. Call the method with the positional arguments and, when the map is not
   empty, the keyword arguments (each name, whatever its MessagePack type,
   becomes a keyword through its text: an int key `7` becomes `:"7"`).
8. If it returns a value that can be sent: reply `["ok", value]`.
9. If the value cannot be sent: reply
   `["error", "Asterism::EncodeError", "the return value: <reason>"]`.
10. If it raises: reply `["error", <class name of the exception>, <its message>]`.

The reply is a Zenoh reply (not an error reply) on the **object's own
key**, `asterism/<node>/<app>/<object>/call`, also when the query's key had
wildcards. Its payload is MessagePack; no encoding, attachment or
timestamp is set.

A query whose node or app chunk is a wildcard (`asterism/*/demo/info/call`)
reaches every application whose queryable it intersects; each answers on
its own key. Captured: `asterism/*/conf/subject/call` and
`asterism/iut/**/subject/call` are answered.

### 4.4 Replies and errors

| Payload | Meaning |
|---|---|
| `["ok", value]` | the method returned `value` |
| `["error", class, message]` | it raised, or could not be called; `class` is a str naming the exception (in Ruby the class name, with its namespace: `RuntimeError`, `KeyError`, `Asterism::EncodeError`), `message` a str |

The class names the protocol itself produces (steps 3-9 of 4.3):

| Class | When | Message (exact) |
|---|---|---|
| `ArgumentError` | malformed request | `malformed call (expected [method, args, kwargs])` |
| `NameError` | no such object | `no object <object> exposed by <node>/<app>` |
| `NoMethodError` | method not exposed | `undefined method '<method>' for <node>/<app>/<object> (not exposed)` |
| `ArgumentError` | wrong number of positional arguments | `wrong number of arguments (given <k>, expected <n>)` |
| `Asterism::EncodeError` | the return value cannot be sent | `the return value: ` and the reason |
| `Asterism::Error` | the method made a call that waited while too many waits were already open (4.6) | `calls nested too deep (max 4)` |

Everything else (`ArgumentError` for an unknown keyword, `ZeroDivisionError`,
an application's own classes) comes from the language and is free text:
CRuby and mruby word the same error differently (captured: `unknown
keyword: :nope` on CRuby, `unknown keyword: nope` on mruby). Callers MUST
NOT parse messages.

### 4.5 The caller

- The caller takes the **first** non-error reply of the get; others are
  ignored (captured: of two replies `["ok", 1]` and `["ok", 2]`, 1 is the
  answer). Zenoh error replies are ignored, so an implementation MUST NOT
  use them to answer a call.
- A reply payload that is not MessagePack, or not an array whose first
  element is `"ok"` or `"error"`, is a malformed answer
  (`Asterism::Error`). `["ok", value]` gives `value` (more elements are
  ignored); `["error", class, message]` raises `Asterism::RemoteError` with
  `remote_class` and `remote_message` (more elements are ignored).
- When the get ends without a reply before the time limit (every matching
  queryable finished without answering, or none matched), the caller raises
  `Asterism::TimeoutError` at once ("nobody answers"); when the time limit
  passes first, `Asterism::TimeoutError` too.
- The caller's time limit is that of the get; the caller keeps polling
  meanwhile (and answers the calls that come in).

### 4.6 Waiting inside a call

A method may itself call and wait. The waits of one application nest at
most 4 deep (`Asterism::MAX_NESTING`); a fifth raises `Asterism::Error`,
which the outer call answers as an error (4.4). This is a property of the
implementation, not of the wire, but it is visible in the error class.

## 5. Meta

A get on `asterism/<node>/<app>/<object>/meta` (no payload, no parameters;
a payload is ignored) is answered with:

```
{"methods" => [[name, arity], ...]}
```

- `name` is a str, `arity` an int: the number of positional arguments
  given at `expose` (`methods: { play: 1 }`), or `-1` when exposed by name
  only (`methods: [:say]`). It is not Ruby's arity: `-1` means "not
  checked", and other negative numbers do not occur.
- The pairs are in the order they were exposed; readers MUST NOT rely on it.
- The reply key is the object's own meta key.
- With object `*` (`asterism/<node>/<app>/*/meta`) there is one reply per
  exposed object, each on its own key.
- For an object that is not exposed there is **no reply** (the caller
  sees nobody answer; `proxy.respond_to?` is then false and
  `remote_methods` raises `TimeoutError`).
- The implementation fetches the meta once per proxy and keeps it
  (`proxy.asterism_refresh` forgets it).

## 6. Liveliness

### 6.1 Tokens

- At connect, the application declares the node token `asterism/<node>`.
  Every application of a node declares its own token with that key, so a
  watcher may see the node token go away when one of them closes while
  another still runs (README, Limits; review R-16).
- For each exposed object it declares `asterism/<node>/<app>/<object>`.
  Exposing a name again withdraws the old token and declares a new one.
- Tokens go away when the application unexposes the object, closes, or its
  session is lost (Zenoh withdraws a lost session's tokens). Captured at
  close: the object tokens, then the node token.
- A node is **alive** while its node token or any of its object tokens is
  alive.

### 6.2 Following

The implementation declares a liveliness subscriber on `asterism/**` with
history (the tokens alive when it is declared come first) and reads each
change by the number of chunks after `asterism/`: one is a node token,
three an object token; anything else is ignored. `Asterism.nodes`,
`Asterism.each` and `on_join` / `on_leave` come from this. ROS 2's tokens
(`@ros2_lv/...`) and the profile are outside `asterism/**`.

### 6.3 The duplicate check

Before declaring anything, `Asterism.connect` does a liveliness get on
`asterism/<node>/<app>/**` (1 s; the check gives up after 1.5 s,
`check_timeout:`). If any token answers, another copy of the same
`<node>/<app>` is running and connect refuses (`Asterism::Error`). An
application that exposes no objects is not detected. Implementations
SHOULD make the same check: two queryables for the same `<node>/<app>`
answer every call twice.

## 7. Profiles

### 7.1 Keys

- Each connected application declares a queryable on
  `asterism/<node>/@profile` (depth 4) and answers every query there with
  the node's profile, on the same key.
- At connect, and each time the profile changes while connected, it puts
  the profile **without the icon** on the same key.
- Several applications of a node each answer; a reader takes the first
  answer (`profile_of`), a follower the last put.

### 7.2 The query

The query has no payload. Its parameters say whether the icon is wanted:
the parameter string is split on `;`, each part on `=`; a part whose name
is `icon` and value is `0`, `no` or `false` asks for the profile without
the icon bytes. Anything else (no parameters, `icon=1`, other names)
includes the icon. The implementation sends `icon=0` or no parameters.

### 7.3 The reply and the put

A MessagePack map with str keys, written in this order:

| Key | Value | Present |
|---|---|---|
| `kind` | str, what runs the node: `family_mruby`, `picoruby`, `cruby`, `console`; any word of 1-32 bytes, first `a-z`, then `a-z`, `0-9`, `_` | always |
| `host` | str, where it runs (`atoms3r`, `tab5`, `sim`, `browser`), 1-32 bytes | when set |
| `name` | str, a display name, 1-64 bytes | when set |
| `icon` | str carrying the bytes of a PNG (3.4), at most 8192 bytes, at most 256x256 | when there is an icon and it was asked for |
| `icon_hash` | str, 8 lower-case hex digits (7.4) | when there is an icon (also when its bytes are left out) |

Captured put of the simulation: `{"kind" => "family_mruby", "host" =>
"sim", "icon_hash" => "26c00593"}`.

### 7.4 The icon and its hash

A PNG is acceptable when:

1. it is 45 to 8192 bytes long;
2. it starts with the PNG signature `89 50 4e 47 0d 0a 1a 0a`;
3. from byte 8 it is a sequence of chunks (4-byte big-endian length,
   4-byte type, data, 4-byte CRC) that ends exactly at the end of the bytes
   with an `IEND` chunk; every length is below 65536 (its first two bytes
   are zero);
4. the first chunk is `IHDR` of length 13, whose width and height (its
   first two 4-byte fields) are each 1 to 256.

The CRCs are not checked against the data. `icon_hash` is the Adler-32 of
the concatenated 4-byte CRC fields of all chunks in order, from `IHDR` to
`IEND`, written as 8 lower-case hex digits (the high 16 bits first): on
CRuby `format("%08x", Zlib.adler32(crcs))`. The gem's `data/icon.png` has
hash `2a8c0626`. A reader that already holds the icon of that hash asks
with `icon=0`.

### 7.5 Reading a profile

The reader cleans what it gets (`Asterism::Profile.check`):

- not a map, or no `kind` that is a valid word: **no profile** (nil);
- `host` / `name` kept only when they are a str of the right length;
- `icon` kept only when it is a str and an acceptable PNG; then
  `icon_hash` is **computed again** from it (the one sent is not used);
  an unacceptable icon is dropped together with its hash;
- without an icon str, `icon_hash` kept when it is 8 lower-case hex digits;
- any other key dropped.

A node that does not answer (an older version, a ROS 2 node) has no
profile; that is not an error.

## 8. What Zenoh must provide

Zenoh 1.x. Checked with zenoh-c 1.10.1 (CRuby), zenoh-pico 1.10.1 (boards,
mruby, the browser build over WebSocket) and zenohd 1.10.1.

| Feature | Used for |
|---|---|
| Session, client mode (a router) or peer mode (a direct link) | everything |
| Get with payload, parameters, timeout, target ALL, consolidation NONE | calls, meta, profiles |
| Queryable (not complete) and replies on a key of the replier's choosing (the object's own key under a wildcard query) | answering |
| Liveliness token | presence |
| Liveliness subscriber with history | following presence |
| Liveliness get | the duplicate check |
| Put and subscriber | profile notices |

Not used, and not to be relied on: encodings (left at the default),
attachments, Zenoh error replies, delete replies, timestamps, source info,
complete queryables, queriers, advanced publishers/subscribers, TLS (a
deployment choice; boards have none). An implementation MAY set an
encoding; the receivers ignore it.

## 9. Differences between the implementations

Captured, protocol 0:

| | CRuby | Boards (Family mruby) | mruby test build |
|---|---|---|---|
| str of 32-255 bytes written as | str16 | str8 | str16 |
| arrays / maps / ints written as | shortest | shortest | 16-bit / int64 forms |
| bin / ext read as | String / fails | nil / nil | String / fails |
| uint64 above 2^63-1 | carried | wraps to negative | fails |
| bytes after the value | malformed | ignored | malformed |
| Bignum argument | `RangeError` before sending | n/a | n/a |
| error messages from the language | CRuby's | mruby's | mruby's |
| answer latency (simulation) | 2-4 ms | 50 ms (the app's update loop) | 2-4 ms |

The mruby test build's MessagePack (`host_test/msgpack.rb`) is a stand-in;
what the boards do is the msgpack-c column.

## 10. Conformance tests

### 10.1 What there is

| File | What |
|---|---|
| `test/protocol/samples.json` | the samples: values, the queries a node must answer and how, the calls a node must make and what it must send, the tokens and the profile puts. Language-neutral (JSON) |
| `test/protocol/gen_samples.rb` | how samples.json is written (edit this, run it, commit both; `--check` tells whether the JSON is stale) |
| `test/protocol/driver.rb` | the driver: plays the other side over Zenoh (plain Zenoh and MessagePack only, never the object layer) and checks an implementation against the samples |
| `test/protocol/node.rb` | the implementation under test in Ruby, portable API only: the same file runs on CRuby and mruby |
| `test/protocol/tv.rb` | the typed values below, for the driver |
| `test/protocol/test_samples.rb` | checks the samples themselves (each byte form decodes to its value, CRuby writes the first form, the matchers reject what they should) |

```
rake test:protocol          # samples + driver against CRuby (part of `rake`)
rake test:protocol_mruby    # driver against mruby (builds mruby like test:mruby)
ASTERISM_TEST_ROUTER=tcp/127.0.0.1:7447 rake test:protocol   # through a router
```

### 10.2 Typed values

JSON cannot tell an int from a float or a str from a bin, so values are
written as typed values:

| JSON | MessagePack |
|---|---|
| `null`, `true`, `false` | nil, true, false |
| `"text"` or `{"str": "text"}` | str (UTF-8) |
| `{"str_hex": "ff00"}` | str carrying these bytes |
| `{"bin_hex": "ff00"}` | bin |
| `{"int": "-12"}` | int (decimal text, so that every 64-bit value fits) |
| `{"float": 1.5}`, `{"float": "inf"}`, `"-inf"`, `"nan"` | float |
| `[v, ...]` | array |
| `{"map": [[k, v], ...]}` | map (pairs; their order is not significant) |

Expected values may also hold matchers: `{"any": "str"}` (or `"int"`,
`"float"`, `"value"`), `{"match": "<regex>"}` (a str matching it),
`{"unordered": [v, ...]}` (an array with these elements in any order).

### 10.3 samples.json

```
{
  "format": "asterism-protocol-samples", "version": 1,
  "names":  {"iut": "iut", "app": "conf", "driver": "drv"},
  "icon":   {"hex": "<the PNG>", "icon_hash": "2a8c0626"},
  "iut":    {"profile": ..., "objects": [{"name": "subject", "methods": [[name, arity], ...]}, ...]},
  "values":   [{"id", "value", "encodings": [hex, ...], "portable", "note"?}, ...],
  "incoming": [{"id", "key", "params", "payload_hex", "replies": [{"key", "payload"}], "portable", "note"?}, ...],
  "outgoing": [{"id", "do", "request": {"key", "params", "payload"} | null, "reply_hex": [hex, ...], "outcome"}, ...],
  "liveliness":   {"alive": [key, ...], "gone_after_close": [key, ...]},
  "profile_puts": [{"when", "key", "payload"}, ...]
}
```

- **values**: each encoding (hex of one value) is sent as the only argument
  of `subject.echo`; the reply must be `["ok", value]`. The first encoding
  is what CRuby writes, the others are other valid forms a reader must
  accept.
- **incoming**: the driver sends a get on `key` with `params` and the
  payload; the replies must be exactly `replies` (in any order; an empty
  list means no reply).
- **outgoing**: what the implementation under test does, in order (`do`):
  `{"call": method, "args": [...], "kwargs": {"map": ...}}` on
  `drv/conf/rec`; `{"respond_to": [names]}` (from the object's meta);
  `{"profile_of": "drv", "icon": bool}`; `{"set_profile": {"map": ...}}`.
  The driver checks the request it receives against `request`, answers
  with the replies in `reply_hex` (none: it finishes the query without a
  reply) and then expects the implementation's report of the `outcome`.
- **portable: false** samples are what the implementations disagree on
  (section 9): the driver prints what came back and does not fail.

### 10.4 The implementation under test

An implementation in another language writes its own node program; the
driver runs it as `COMMAND LOCATOR MODE ICON_FILE` (MODE is `peer`: connect
to the driver, which listens on LOCATOR; or `client`: both are clients of
the router at LOCATOR). The program:

1. sets its profile name to `iut` and its icon to the PNG in ICON_FILE;
2. connects as node `iut`, application `conf`;
3. exposes `subject` with `echo(v) -> v` (1), `kw(a, b: nil, c: nil) ->
   [a, b, c]` (1), `add(a, b) -> a + b` (2), `boom` raising a `RuntimeError`
   "boom" (0), `any(*args) -> number of args` (-1), `ok? -> true` (0),
   `unsendable` returning something that cannot be sent (0), and a public
   method `secret` that is **not** exposed; and `other` with `ping ->
   "pong"` (0);
4. prints `ready`, then waits until the object `drv/conf/rec` is alive (the
   driver declares it after its own queries);
5. does each `outgoing` step in order, and after each calls
   `drv/conf/rec.report(id, outcome)`, where outcome is `["ok", value]`,
   `["error", class, message]` (a remote error), `["timeout"]`,
   `["failed", message]` (a malformed answer) or `["disconnected", message]`;
6. calls `drv/conf/rec.done()`, closes, prints `done` and exits (0).

Then:

```
ruby -I lib -I ../asterism-zenoh/lib test/protocol/driver.rb --name python -- python3 my_node.py
```

The driver needs CRuby with asterism-zenoh and msgpack. Another language
may also read samples.json directly for its own unit tests (the values,
and the request and reply payloads, are all there).

## 11. Captured examples

From the Linux simulation (the boards' code and msgpack-c), node `linux`,
app `demo`:

```
liveliness  asterism/linux                  alive
liveliness  asterism/linux/demo/apu         alive
liveliness  asterism/linux/demo/screen      alive
liveliness  asterism/linux/demo/info        alive
put         asterism/linux/@profile
            83 a4 6b696e64 ac 66616d696c795f6d72756279 a4 686f7374 a3 73696d
               a9 69636f6e5f68617368 a8 3236633030353933
            {"kind" => "family_mruby", "host" => "sim", "icon_hash" => "26c00593"}
get         asterism/cap/demo/screen/call   (the board calls screen.say)
            93 a3 736179 91 b2 68656c6c6f20312066726f6d206c696e7578 80
            ["say", ["hello 1 from linux"], {}]
get         asterism/cap/demo/info/meta     (no payload, no parameters)
reply       asterism/linux/demo/info/meta
            81 a7 6d6574686f6473 95 92 a6 737461747573 00 92 a5 72656c6179 02 ...
            {"methods" => [["status", 0], ["relay", 2], ["boom", 0], ["echo", 1], ["profile", 2]]}
reply       asterism/linux/demo/info/call   (to ["boom", [], {}])
            93 a5 6572726f72 ac 52756e74696d654572726f72 ad 626f6f6d206f6e206c696e7578
            ["error", "RuntimeError", "boom on linux"]
reply       asterism/linux/demo/info/call   (to ["secret", [], {}])
            93 a5 6572726f72 ad 4e6f4d6574686f644572726f72 d9 3b 756e646566...
            ["error", "NoMethodError", "undefined method 'secret' for linux/demo/info (not exposed)"]
```

The same request from CRuby has the same bytes; CRuby's replies differ
only in `da 00 3b` (str16) where the board writes `d9 3b` (str8).
