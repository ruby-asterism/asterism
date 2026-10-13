# The Asterism wire protocol

Status: **normative, protocol 1**. This document says what an Asterism
node puts on the network and what it expects back, so that an
implementation in another language (Python, MicroPython, TypeScript, C,
...) can join the same network. asterism 0.7.0 (CRuby, and the mrbgem
picoruby-asterism on mruby / PicoRuby, the same `mrblib/`) implements it,
and the conformance tests (section 10) check implementations against it.

**Protocol 1 is the only protocol.** asterism 0.7.0 does not speak the
protocol of the 0.x releases before it (protocol 0, appendix A): a node of
protocol 1 refuses a protocol 0 call (4.3, step 2) and is not seen by a
protocol 0 node's object layer. Protocol 1 was designed again from the
review of protocol 0 ([protocol_review.md](protocol_review.md)), without
keeping protocol 0's forms: every request and reply is a map with named
fields, binary data is a MessagePack bin, the caller is in the key, errors
say what kind they are, and each application has its own liveliness token.

The number is told in each node's profile (`"protocol" => 1`, section 7).
A change that a protocol 1 reader would misread gets a new number; an
addition that protocol 1 readers ignore (a field in a map: requests,
replies, errors, meta entries, profiles) does not.

The ROS 2 side of Asterism (`Asterism::ROS`) is not part of this protocol:
it speaks rmw_zenoh's format, described in the README ("ROS 2
(rmw_zenoh)").

The words MUST, SHOULD and MAY are used as in RFC 2119.

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
11. [Examples](#11-examples)
- [Appendix A. Protocol 0 (discarded)](#appendix-a-protocol-0-discarded)

## 1. Model

- A **node** is a machine or a process with an ID (`fmruby-1a2b3c`,
  `linux`, `mypc`). An **application** (app) runs on a node and has a name
  (`demo`). An application **exposes objects** under names (`apu`); each
  exposed object has a set of methods that may be called from elsewhere.
  An object is addressed as `<node>/<app>/<object>`.
- Each application has **one Zenoh session** (the same session carries the
  application's own puts, subscriptions and ROS 2 nodes). A node with two
  applications has two sessions; they share the node ID.
- A **call** is a Zenoh query (get) to the object's call key, which ends
  with the calling node's ID; its answer is the query's reply. **Meta**
  (the list of exposed methods) is a query to the object's meta key.
  **Presence** is told with Zenoh liveliness tokens, one per application
  and one per exposed object. A node's **profile** (the protocol it
  speaks, what it is, a name, an icon) is a query to the node's profile
  key, and is also put there on each change.
- There is no server: every application answers the queries for its own
  objects. A Zenoh router (zenohd) usually connects them; a direct peer
  link works the same.
- Payloads are MessagePack, each exactly one value. Nothing else is used:
  no Zenoh encoding, no attachment, no Zenoh error reply, no timestamp, no
  source info (section 8).

## 2. Names and keys

### 2.1 Names

A node ID, an application name and an object name are each **one Zenoh key
chunk**:

- not empty;
- MUST NOT contain `/`, `*`, `$`, `?`, `#`;
- MUST NOT start with `@` (chunks starting with `@` are Zenoh's verbatim
  chunks, and Asterism uses them for its own keys, see `@profile`).

The Ruby implementation's `Asterism.connect`, `Asterism.expose` and
`Asterism[path]` raise `ArgumentError` for anything else. There is no
length limit and no character set beyond Zenoh's (UTF-8). Keep them short
on the boards (every key and token carries them). Family mruby's boards use
`fmruby-<6 hex digits>`, the browser build `wasm-<6 hex digits>`, the
simulation `linux`.

A **method name** is a MessagePack str (4.1). It is not checked against
these rules: it travels in the payload, not in the key, and is an opaque
string. Ruby method names such as `ok?`, `save!` and `name=` are exposed
and called as they are. Names meant for other languages SHOULD be
`[a-z_][a-z0-9_]*`; a Ruby application can expose an alias under such a
name. A binding SHOULD offer a way to call a method by its name as a
string (Ruby: `proxy.asterism_call("ok?")`), for names its language cannot
write or its proxies cannot forward.

### 2.2 Keys

| Key | Zenoh | Who declares it | Section |
|---|---|---|---|
| `asterism/<node>/<app>` | liveliness token | the application | 6 |
| `asterism/<node>/<app>/<object>` | liveliness token | the application, for each exposed object | 6 |
| `asterism/<node>/<app>/**` | queryable | the application (one) | 4, 5 |
| `asterism/<node>/<app>/<object>/call/<caller>` | get | a caller (`<caller>` is its node ID) | 4 |
| `asterism/<node>/<app>/<object>/meta` | get | a caller | 5 |
| `asterism/<node>/@profile` | queryable | every application of the node (each its own) | 7 |
| `asterism/<node>/@profile` | put | every application of the node, at connect and on each change | 7 |

- The root chunk is `asterism`.
- There is no token for the node alone: a node is present while any of
  its applications is (6.1).
- `@profile` is a verbatim chunk: `asterism/**` and `asterism/<node>/**`
  do **not** match it (a get on `asterism/<node>/**` gets no profile
  reply, a subscriber on `asterism/**` does not see the profile puts;
  `asterism/*/@profile` does match). The object layer's wildcards and its
  liveliness watch never see it.
- The application's own keys under `asterism/<node>/<app>/<object>/<more>`
  (puts, subscriptions: a state, a log) do not meet the object layer: puts
  and subscriptions are not queries, and the queryable answers only the
  key shapes of 4.3.
- Reserved for later: `asterism/<node>/<app>/@profile` (an application's
  own profile).

## 3. Values

### 3.1 The MessagePack subset

Call arguments, keyword arguments, return values, errors, meta and
profiles are MessagePack values built from:

| MessagePack | Ruby | Notes |
|---|---|---|
| nil | `nil` | |
| bool | `true`, `false` | |
| int | `Integer` | signed 64-bit only: -2^63 to 2^63-1 (3.3) |
| float | `Float` | float32 and float64 are read; the implementation writes float64 |
| str | `String`, `Symbol` | text (UTF-8 by intent; 3.4) |
| bin | a binary `String` (`String#b`: ASCII-8BIT on CRuby, the binary flag on mruby) | bytes (3.4) |
| array | `Array` | |
| map | `Hash` | keys SHOULD be str or int (3.2) |

Nothing else is a value: **ext types** (including the timestamp ext) are
not part of the protocol. A payload that holds one, an int outside the
signed 64-bit range, or bytes after its value, is not a valid payload (a
malformed call, 4.3; a malformed answer, 4.5). A receiver MUST NOT turn
something it cannot read into nil or another value.

- **Symbols** are written as str, also as map keys and keyword names. They
  are read back as Strings: a Symbol sent arrives as a String (Ruby turns
  keyword names back into Symbols to pass them as keywords). There is no
  Symbol type.
- Anything else (`Time`, a `Struct`, an object) is refused by the sender
  before sending (`Asterism::EncodeError`); a return value that cannot be
  sent is answered as an error (`unsendable`, 4.4).
- **Nesting**: the sender refuses a value nested deeper than 16 levels,
  counted from the top of the payload (`Asterism::Codec::MAX_DEPTH`): the
  request map is level 0 and its `args` array level 1, so an argument may
  hold 14 levels of arrays and maps; a return value 15 (the reply map is
  level 0). The receiver does not check nesting.
- Map key order carries no meaning. The implementation writes keys in the
  Hash's insertion order.
- **Byte forms**: every implementation reads every valid form of a value
  (fixint and the 8/16/32/64-bit int forms, str8/16/32, bin8/16/32,
  array16/32, map16/32); none may depend on the form a sender chose.
  Conformance is about values, not bytes (section 10).

### 3.2 Map keys

The portable map keys are **str and int**. Senders SHOULD use only these:
Python's msgpack refuses other keys by default (`strict_map_key`) and
cannot use an array as a dict key, JavaScript objects have string keys only.
Other key types are values of the protocol and are carried, but are not
portable. Keyword argument names (4.1) MUST be str.

### 3.3 Integers and floats

- Integers are signed 64-bit. A sender MUST NOT send others: the Ruby
  implementation raises `EncodeError` before sending an Integer outside
  -2^63..2^63-1. A uint64 above 2^63-1 on the wire makes the payload
  malformed. JavaScript implementations use BigInt for integers outside
  2^53.
- A float with an integral value stays a float in Ruby, Python and C, but
  JavaScript has one number type: a JavaScript caller's `1.0` arrives as
  the int `1`. A callee that wants a float converts (`Float(x)`). NaN and
  the infinities travel.
- **Times** have no type. By convention an absolute time is an int of
  nanoseconds since the Unix epoch (UTC), and a duration is in the unit its
  name says (`timeout_ms`, `period_s`; the ROS layer's `stamp_ns`).

### 3.4 Text and bytes

- A **str** is text. Implementations write UTF-8; a receiver MUST keep the
  bytes of a str as they came, also when they are not valid UTF-8 (a Ruby
  String from a str may be invalid UTF-8; a strict decoder such as
  Python's default may refuse such a payload).
- A **bin** is bytes: a profile's icon, an image, a payload relayed. The
  Ruby implementation sends a binary String as bin and any other String as
  str. On CRuby a String is binary when its encoding is ASCII-8BIT
  (`String#b`, `File.binread`, payloads from Zenoh); on mruby when it has
  the binary flag (`String#b`). A received bin is a binary String on both.
  Python's `bytes` and JavaScript's `Uint8Array` are bin, `str` / `string`
  are str: with the defaults of their MessagePack libraries (`raw=False`
  in Python) every payload of this protocol decodes.
- The protocol's own text fields (method names, keyword names, error
  `kind`, `class` and `message`, profile fields other than `icon`, meta
  names) are str. A receiver MAY accept a bin where a str is expected (the
  Ruby implementations take a bin method name by its bytes), but MUST NOT
  send one.

### 3.5 nil and absent

A keyword given as nil and a keyword left out are different: the key is
there with nil, or not there. The callee's default applies only to the
absent one. JavaScript's `undefined` is left out, never sent.

## 4. Calls

### 4.1 The request

A call of `method(*args, **kwargs)` on `<node>/<app>/<object>` by the node
`<caller>` is a Zenoh get:

| | |
|---|---|
| key | `asterism/<node>/<app>/<object>/call/<caller>`; `<caller>` is the calling node's ID, a name (2.1) |
| payload | a MessagePack map (below) |
| parameters | none |
| attachment | none |
| encoding | not set (zenoh reports the default, `zenoh/bytes`) |
| target | ALL (`Z_QUERY_TARGET_ALL`) |
| consolidation | NONE |
| timeout | the call's time limit: 2 s by default (`Asterism[path, timeout:]`) |

The request map:

| Field | Value | Present |
|---|---|---|
| `method` | str, the method's name (not empty) | always |
| `args` | array, the positional arguments | when there are any (absent: none) |
| `kwargs` | map with str keys, the keyword arguments | when there are any (absent: none) |

A receiver ignores other fields (room for later additions). A language
without keyword arguments sends no `kwargs`; as a callee it may receive a
`kwargs` map as one trailing options argument, or refuse a non-empty one
(an `arguments` error).

Example, `info.status` called by `linux` (no arguments):

```
key      asterism/fmruby-1a2b3c/demo/info/call/linux
payload  81 a6 6d6574686f64 a6 737461747573
         {"method" => "status"}
```

A block cannot be sent (the Ruby caller raises before sending). A call to
an object of the caller's own application does not go on the network: it
is run in place with the same encoding and checks (a Zenoh session does
not see its own queryable).

### 4.2 The queryable

Each connected application declares **one** queryable on
`asterism/<node>/<app>/**`. It is not complete (a get with target
ALL_COMPLETE does not reach it). Queries are taken from a queue (depth 32)
when the application polls, and answered in order; after answering, each
query is finished (dropped), which ends the get for that queryable.

### 4.3 Handling a query

For each query the receiver does, in this order:

1. Split the query's key on `/`. The node and app chunks are not compared
   with this application's (the queryable already matched them; they may
   be wildcards). Let `object` be the fourth chunk and `kind` the fifth.
   - Five chunks and kind `meta`: section 5.
   - Five chunks and kind `call` (protocol 0's call key), object a name:
     step 2.
   - Six chunks and kind `call`, object a name, and the sixth chunk (the
     caller) a name (2.1: not a wildcard, not verbatim): step 3.
   - Anything else (another kind, a wildcard or verbatim object or caller,
     fewer or more chunks): **no reply**, nothing is run.
2. **Protocol 0 call**: reply on `asterism/<node>/<app>/<object>/call` with
   the error `protocol` (4.4), whatever the payload. The method is not run.
3. Decode the payload. It is **malformed** unless it is exactly one value
   (3.1) and that value is a map whose `method` is a non-empty str, whose
   `args` (when present) is an array and whose `kwargs` (when present) is
   a map with str keys only. A missing or empty payload is malformed.
   Reply the error `malformed`.
4. If no object of that name is exposed: the error `no_object`.
5. If the method is not in the object's exposed table: the error
   `not_exposed`. A public method of the object that was not listed in
   `expose` is not callable.
6. If the method was exposed with a number of arguments `n >= 0` and the
   number of positional arguments differs: the error `arguments`. Keyword
   arguments are not counted. `n = -1` (exposed by name only) accepts any
   number.
7. Call the method with the positional arguments and the keyword
   arguments. While it runs, the callee's binding tells it who called
   (4.7).
8. If it returns a value that can be sent: reply `{"value" => value}`.
9. If the value cannot be sent: the error `unsendable`.
10. If it raises: the error `raised` with the exception's class name and
    message (or `nesting`, 4.6).

The reply is a Zenoh reply (not an error reply) on the **object's own
key**, `asterism/<node>/<app>/<object>/call/<caller>`, also when the
query's key had wildcards in the node or app. Its payload is MessagePack;
no encoding, attachment or timestamp is set.

A query whose node or app chunk is a wildcard
(`asterism/*/demo/info/call/linux`) reaches every application whose
queryable it intersects; each answers on its own key.

### 4.4 Replies and errors

A reply payload is a map with **one** of:

| Field | Meaning |
|---|---|
| `value` | the method returned this value (any value, also nil) |
| `error` | it raised, or could not be called: a map `{"kind" => str, "class" => str, "message" => str}` |

Other fields are ignored. The error map:

| Field | Value |
|---|---|
| `kind` | what happened, a protocol word (below) |
| `class` | for `raised`, the exception's class in the callee's language (Ruby: with its namespace, `RuntimeError`, `KeyError`, `MyApp::Busy`); for the other kinds, the fixed name below (the same from every implementation, so that Ruby callers see Ruby's names) |
| `message` | a human-readable message; callers MUST NOT parse it |

The kinds (more may be added; a caller treats an unknown kind as an error
of unknown kind):

| Kind | When | Class | Message (exact for the protocol's own) |
|---|---|---|---|
| `malformed` | the request cannot be read (4.3 step 3) | `ArgumentError` | `malformed call (expected a map {"method" => name, "args" => [...], "kwargs" => {...}})` |
| `protocol` | a protocol 0 call (4.3 step 2) | `Asterism::Error` | free text naming this protocol (the implementation says `<node>/<app> speaks Asterism protocol 1: ...`) |
| `no_object` | no such object | `NameError` | `no object <object> exposed by <node>/<app>` |
| `not_exposed` | the method is not exposed | `NoMethodError` | `undefined method '<method>' for <node>/<app>/<object> (not exposed)` |
| `arguments` | wrong number of positional arguments | `ArgumentError` | `wrong number of arguments (given <k>, expected <n>)` |
| `arguments` | a keyword the callee's binding fills in itself was given (4.7) | `ArgumentError` | free text |
| `unsendable` | the return value cannot be sent | `Asterism::EncodeError` | `the return value: ` and the reason |
| `nesting` | the method made a call that waited while too many waits were already open (4.6) | `Asterism::Error` | `calls nested too deep (max 4)` |
| `raised` | the method raised | the language's | the language's |

Errors the language makes while calling (an unknown keyword, a type
error) are `raised`, with the language's own class and text (CRuby says
`unknown keyword: :nope`, mruby `unknown keyword: nope`).

### 4.5 The caller

- The caller takes the **first** reply of the get that is not a Zenoh
  error reply; others are ignored. Zenoh error replies are ignored, so an
  implementation MUST NOT use them to answer a call.
- A reply payload that is not exactly one MessagePack value, or not a map,
  or a map with neither `value` nor `error`, or whose `error` is not a
  map, is a **malformed answer** (`Asterism::Error` "malformed answer").
  With `error` (also when `value` is there too), the call raises
  `Asterism::RemoteError` with `remote_kind`, `remote_class` and
  `remote_message` (a missing `kind` is nil); otherwise it returns `value`.
- When the get ends without a reply before the time limit (every matching
  queryable finished without answering, or none matched), the caller
  raises `Asterism::TimeoutError` at once ("nobody answers"); when the time
  limit passes first, `Asterism::TimeoutError` too.
- The caller's time limit is that of the get; the caller keeps polling
  meanwhile (and answers the calls that come in).

### 4.6 Waiting inside a call

A method may itself call and wait. The waits of one application nest at
most 4 deep (`Asterism::MAX_NESTING`); a fifth raises `Asterism::Error`,
which the outer call answers as `nesting` (4.4). This is a property of the
implementation, not of the wire, but it is visible in the error.

### 4.7 Who called

The caller's node ID is the call key's last chunk. The callee's binding
hands it to the method:

- Ruby: `Asterism.current_call` while the method runs (nil outside a call;
  per thread on CRuby): `from` (the caller's node ID), `verified`
  (`:claimed`; `:local` for a call from the same application, which does
  not go on the network), `object`, `method`.
- Ruby: `Asterism.expose(name, obj, methods:, caller: :from)` passes the
  caller's node ID to each method as the keyword `from:`. A call that
  brings that keyword itself is refused with the error `arguments`, so the
  value is always the one taken from the key.

**The name is a claim.** Any client can put any name in the key. What
makes it binding is a router's access control: zenohd's ACL can allow a
client (identified by its TLS certificate's common name, mutual TLS) to
query only keys whose last chunk is its own name, for example
`asterism/*/*/*/call/<its name>`, and deny the rest. With such a rule on
every router a client reaches, the caller chunk is the client's
certificate name. Without it, `from` guards against mistakes, not against
someone pretending.

When the ACL binds it: a router that connects on behalf of several nodes
(a home router in front of boards) has one certificate, so its rule lists
the caller chunk of each of those nodes; they can then use each other's
names, and nobody else's. Clients that the router cannot tell apart (all
WebSocket sessions, which carry no certificate) share one rule, for
example `asterism/*/*/*/call/wasm-$*`. Meta (5) and profile (7) queries
need no caller and stay open to whoever may read. asterism-console makes
such rules from its roles (`asterism/*/<app>/*/call/${node}`). Zenoh's source info (the querier's session ID that a
get may carry) is written by the querier and not checked by routers; this
protocol does not use it.

## 5. Meta

A get on `asterism/<node>/<app>/<object>/meta` (no payload, no parameters;
a payload is ignored) is answered with:

```
{"methods" => [{"name" => name, "arity" => n}, ...]}
```

- `name` is a str, `arity` an int: the number of positional arguments
  given at `expose` (`methods: { play: 1 }`), or `-1` when exposed by name
  only (`methods: [:say]`). It is not Ruby's arity: `-1` means "not
  checked", and other negative numbers do not occur. Entries are maps so
  that fields can be added (optional arguments, keywords, a description);
  readers ignore fields they do not know.
- The entries are in the order they were exposed; readers MUST NOT rely
  on it.
- The reply key is the object's own meta key.
- With object `*` (`asterism/<node>/<app>/*/meta`) there is one reply per
  exposed object, each on its own key.
- For an object that is not exposed there is **no reply** (the caller
  sees nobody answer; `proxy.respond_to?` is then false and
  `remote_methods` raises `TimeoutError`).
- The Ruby implementation fetches the meta once per proxy and keeps it
  (`proxy.asterism_refresh` forgets it).

## 6. Liveliness

### 6.1 Tokens

- At connect, the application declares its **application token**
  `asterism/<node>/<app>`. Each application of a node has its own, so a
  node stays present while any of its applications runs.
- For each exposed object it declares `asterism/<node>/<app>/<object>`.
  Exposing a name again withdraws the old token and declares a new one.
- Tokens go away when the application unexposes the object, closes, or its
  session is lost (Zenoh withdraws a lost session's tokens).
- A node is **alive** while any of its application tokens or object tokens
  is alive. There is no token for the node alone.

### 6.2 Following

The implementation declares a liveliness subscriber on `asterism/**` with
history (the tokens alive when it is declared come first) and reads each
change by the number of chunks after `asterism/`: two is an application
token, three an object token; anything else is ignored. `Asterism.nodes`,
`Asterism.each` and `on_join` / `on_leave` come from this. ROS 2's tokens
(`@ros2_lv/...`) and the profile are outside `asterism/**`.

### 6.3 The duplicate check

Before declaring anything, `Asterism.connect` does a liveliness get on
`asterism/<node>/<app>/**` (which also matches the application token
itself; 1 s, the check gives up after 1.5 s, `check_timeout:`). If any
token answers, another copy of the same `<node>/<app>` is running and
connect refuses (`Asterism::Error`). Implementations SHOULD make the same
check: two queryables for the same `<node>/<app>` answer every call twice.

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
| `protocol` | int, the protocol the node speaks: `1` | always |
| `kind` | str, what runs the node: `family_mruby`, `picoruby`, `cruby`, `console`; any word of 1-32 bytes, first `a-z`, then `a-z`, `0-9`, `_` | always |
| `host` | str, where it runs (`atoms3r`, `tab5`, `p4nano`, `sim`, `browser`), 1-32 bytes | when set |
| `name` | str, a display name, 1-64 bytes | when set |
| `icon` | **bin**, the bytes of a PNG, at most 8192 bytes, at most 256x256 | when there is an icon and it was asked for |
| `icon_hash` | str, 8 lower-case hex digits (7.4) | when there is an icon (also when its bytes are left out) |

A node without `protocol` speaks protocol 0 (appendix A): its calls and
replies are not protocol 1's.

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
- `protocol` kept when it is a non-negative int (absent: protocol 0);
- `host` / `name` kept only when they are a str of the right length;
- `icon` kept only when it is an acceptable PNG (a bin; the Ruby reader
  also takes a str's bytes); then `icon_hash` is **computed again** from it
  (the one sent is not used); an unacceptable icon is dropped together
  with its hash;
- without an icon, `icon_hash` kept when it is 8 lower-case hex digits;
- any other key dropped.

A node that does not answer (a ROS 2 node) has no profile; that is not an
error.

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
complete queryables, queriers, advanced publishers/subscribers. An
implementation MAY set an encoding; the receivers ignore it. TLS and
access control are a deployment's choice (4.7); boards have no TLS.

## 9. Differences between the implementations

Checked with the conformance tests (section 10) and the Family mruby
simulation:

| | CRuby | Boards (Family mruby, msgpack-c) | mruby test build |
|---|---|---|---|
| str of 32-255 bytes written as | str8 | str8 | str16 |
| arrays / maps / ints written as | shortest | shortest | 16-bit / int64 forms |
| a binary String | ASCII-8BIT | the binary flag (`String#b`) | the binary flag |
| a Zenoh payload handed to the application | ASCII-8BIT (relayed as bin) | a plain String (relayed as str unless `.b`) | a plain String |
| error messages from the language | CRuby's | mruby's | mruby's |
| `Asterism.current_call` | per thread | per VM | per process |
| answer latency (simulation) | 2-4 ms | 50 ms (the app's update loop) | 2-4 ms |

The mruby test build's MessagePack (`host_test/msgpack.rb`) is a stand-in;
what the boards do is the msgpack-c column (fmruby-core
`lib/add/picoruby-fmrb-msgpack`).

## 10. Conformance tests

### 10.1 What there is

| File | What |
|---|---|
| `test/protocol/samples.json` | the samples: values, the queries a node must answer and how, the calls a node must make and what it must send, the tokens and the profile puts. Language-neutral (JSON) |
| `test/protocol/gen_samples.rb` | how samples.json is written (edit this, run it, commit both; `--check` tells whether the JSON is stale) |
| `test/protocol/driver.rb` | the driver: plays the other side over Zenoh (plain Zenoh and MessagePack only, never the object layer) and checks an implementation against the samples |
| `test/protocol/node.rb` | the implementation under test in Ruby, portable API only: the same file runs on CRuby and mruby |
| `test/protocol/tv.rb` | the typed values below, for the driver |
| `test/protocol/test_samples.rb` | checks the samples themselves (each byte form decodes to its value, CRuby writes the first form, what is not a value does not decode, the matchers reject what they should) |

```
rake test:protocol          # samples + driver against CRuby (part of `rake`)
rake test:protocol_mruby    # driver against mruby (builds mruby like test:mruby)
ASTERISM_TEST_ROUTER=tcp/127.0.0.1:7447 rake test:protocol   # through a router
```

Through a router, use one that no other Asterism node is connected to:
the sample "profile not under *" asks `asterism/*/@profile`, and every
node there answers it.

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
  "format": "asterism-protocol-samples", "version": 2, "protocol": 1,
  "names":  {"iut": "iut", "app": "conf", "driver": "drv"},
  "icon":   {"hex": "<the PNG>", "icon_hash": "2a8c0626"},
  "iut":    {"profile": ..., "objects": [{"name": "subject", "methods": [[name, arity], ...]}, ...]},
  "values":   [{"id", "value", "encodings": [hex, ...], "portable", "expect"?, "note"?}, ...],
  "incoming": [{"id", "key", "params", "payload_hex", "replies": [{"key", "payload"}], "portable", "note"?}, ...],
  "outgoing": [{"id", "do", "request": {"key", "params", "call" | "payload"} | null, "reply_hex": [hex, ...], "outcome"}, ...],
  "liveliness":   {"alive": [key, ...], "gone_after_close": [key, ...]},
  "profile_puts": [{"when", "key", "payload"}, ...]
}
```

- **values**: each encoding (hex of one value) is sent as the only argument
  of `subject.echo` (`{"method" => "echo", "args" => [v]}`) by the driver
  as caller `drv`; the reply must be `{"value" => v}`, or the replies in
  `expect` (what is not a value of the protocol: a malformed call). The
  first encoding is what CRuby writes, the others are other valid forms a
  reader must accept.
- **incoming**: the driver sends a get on `key` with `params` and the
  payload; the replies must be exactly `replies` (in any order; an empty
  list means no reply).
- **outgoing**: what the implementation under test does, in order (`do`):
  `{"call": method, "args": [...], "kwargs": {"map": ...}}` on
  `drv/conf/rec`; `{"respond_to": [names]}` (from the object's meta);
  `{"profile_of": "drv", "icon": bool}`; `{"set_profile": {"map": ...}}`.
  The driver checks the request it receives against `request` (for a
  call, `call` is the request map with absent `args` / `kwargs` read as
  empty), answers with the replies in `reply_hex` (none: it finishes the
  query without a reply) and then expects the implementation's report of
  the `outcome`.
- **portable: false** samples are where the implementations may differ
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
   `unsendable` returning something that cannot be sent (0), `whoami ->
   [caller node, "claimed", object name, method name]` (0; from what the
   binding tells about the call being answered, 4.7) and a public method
   `secret` that is **not** exposed; and `other` with `ping -> "pong"` (0);
4. prints `ready`, then waits until the object `drv/conf/rec` is alive (the
   driver declares it after its own queries);
5. does each `outgoing` step in order, and after each calls
   `drv/conf/rec.report(id, outcome)`, where outcome is `["ok", value]`,
   `["error", class, message, kind]` (a remote error; kind nil when the
   answer had none), `["timeout"]`, `["failed", message]` (a malformed
   answer) or `["disconnected", message]`;
6. calls `drv/conf/rec.done()`, closes, prints `done` and exits (0).

Then:

```
ruby -I lib -I ../asterism-zenoh/lib test/protocol/driver.rb --name python -- python3 my_node.py
```

The driver needs CRuby with asterism-zenoh and msgpack. Another language
may also read samples.json directly for its own unit tests (the values,
and the request and reply payloads, are all there).

## 11. Examples

Node `linux`, app `demo` (Family mruby's asterism_demo in the simulation),
called by a CRuby node `mypc`:

```
liveliness  asterism/linux/demo                 alive (the application)
liveliness  asterism/linux/demo/apu             alive
liveliness  asterism/linux/demo/screen          alive
liveliness  asterism/linux/demo/info            alive
put         asterism/linux/@profile
            84 a8 70726f746f636f6c 01 a4 6b696e64 ac 66616d696c795f6d72756279
               a4 686f7374 a3 73696d a9 69636f6e5f68617368 a8 3236633030353933
            {"protocol" => 1, "kind" => "family_mruby", "host" => "sim", "icon_hash" => "26c00593"}
get         asterism/linux/demo/screen/call/mypc
            82 a6 6d6574686f64 a3 736179 a4 61726773 91 a5 68656c6c6f
            {"method" => "say", "args" => ["hello"]}
reply       asterism/linux/demo/screen/call/mypc
            81 a5 76616c7565 05
            {"value" => 5}
get         asterism/linux/demo/info/call/mypc
            81 a6 6d6574686f64 a4 626f6f6d
            {"method" => "boom"}
reply       asterism/linux/demo/info/call/mypc
            81 a5 6572726f72 83 a4 6b696e64 a6 726169736564 a5 636c617373
               ac 52756e74696d654572726f72 a7 6d657373616765 ad 626f6f6d206f6e206c696e7578
            {"error" => {"kind" => "raised", "class" => "RuntimeError", "message" => "boom on linux"}}
get         asterism/linux/demo/info/meta       (no payload, no parameters)
reply       asterism/linux/demo/info/meta
            81 a7 6d6574686f6473 95 82 a4 6e616d65 a6 737461747573 a5 6172697479 00 ...
            {"methods" => [{"name" => "status", "arity" => 0}, {"name" => "relay", "arity" => 1}, ...]}
```

## Appendix A. Protocol 0 (discarded)

The 0.x releases before 0.7.0 spoke a protocol without a number, called
protocol 0 here. It is not spoken by asterism 0.7.0 and later; it is kept
here only so that its messages can be recognised:

- liveliness: `asterism/<node>` (one token shared by the applications of a
  node) and `asterism/<node>/<app>/<object>`;
- call: a get on `asterism/<node>/<app>/<object>/call` (five chunks, no
  caller) with the array `[method, args, kwargs]` (kwargs always present);
- reply: `["ok", value]` or `["error", class, message]`;
- meta: `{"methods" => [[name, arity], ...]}`;
- profile: no `protocol` field; the icon a str;
- every String sent as str (binary data too), uint64 accepted, the boards
  reading bin and ext as nil and ignoring trailing bytes.

Why it was replaced: positional arrays could not take new fields without
breaking old receivers (a call had to be exactly three elements), the icon
as a str broke Python's and JavaScript's default decoders, errors could be
told apart only by Ruby class names, callers could not be known except by
an argument any caller could set, and the node token shared by
applications made a node look gone while one of its applications still
ran ([protocol_review.md](protocol_review.md)).
