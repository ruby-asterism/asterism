# The Asterism wire protocol

Status: **normative, protocol 2**. This document says what an Asterism
node puts on the network and what it expects back, so that an
implementation in another language (Python, MicroPython, TypeScript, C,
...) can join the same network. asterism (CRuby, and the mrbgem
picoruby-asterism on mruby / PicoRuby, the same `mrblib/`) implements it,
and the conformance tests (section 15) check implementations against it.

**Protocol 2 is the only protocol.** Every node speaks it; there is no
sending of older forms side by side. Protocol 2 adds to the calls of its
predecessors the data an application streams on its own keys: values
whose format is told by the Zenoh encoding (none for MessagePack), a
sequence number with each value, the declarations of an application's
topics and types, and an application's own profile that answers its
status, topics and types (sections 8 to 12). Calls are what they were
designed to be from the review of protocol 0
([protocol_review.md](protocol_review.md)): every request and reply is a
map with named fields, binary data is a MessagePack bin, the caller is in
the key, errors say what kind they are, and each application has its own
liveliness token. A node of protocol 2 refuses a protocol 0 call (4.3,
step 2).

The number is told in each node's profile (`"protocol" => 2`, section 7).
A change that a protocol 2 reader would misread gets a new number; an
addition that protocol 2 readers ignore (a field in a map: requests,
replies, errors, meta entries, profiles, declarations; a new key) does not.

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
8. [Application profiles and status](#8-application-profiles-and-status)
9. [Data](#9-data)
10. [Topic declarations](#10-topic-declarations)
11. [Types](#11-types)
12. [Times](#12-times)
13. [What Zenoh must provide](#13-what-zenoh-must-provide)
14. [Differences between the implementations](#14-differences-between-the-implementations)
15. [Conformance tests](#15-conformance-tests)
16. [Examples](#16-examples)
- [Appendix A. Protocol 0 (discarded)](#appendix-a-protocol-0-discarded)

## 1. Model

- A **node** is a machine or a process with an ID (`fmruby-1a2b3c`,
  `linux`, `mypc`). An **application** (app) runs on a node and has a name
  (`demo`). An application **exposes objects** under names (`apu`); each
  exposed object has a set of methods that may be called from elsewhere.
  An object is addressed as `<node>/<app>/<object>`.
- An application is **one connection**: one Zenoh session, which carries
  everything of the application (its token, its objects, its own profile,
  status, topics and types, and its own puts, subscriptions and ROS 2
  nodes). A node with two applications has two sessions; they share the
  node ID. One program may hold several connections, each a whole
  application of its own (1.1).
- A **call** is a Zenoh query (get) to the object's call key, which ends
  with the calling node's ID; its answer is the query's reply. **Meta**
  (the list of exposed methods) is a query to the object's meta key.
  **Presence** is told with Zenoh liveliness tokens, one per application
  and one per exposed object. A node's **profile** (the protocol it
  speaks, what it is, a name, an icon) is a query to the node's profile
  key, and is also put there on each change. An **application's profile**
  answers its **status** (a small map of its own that changes while it
  runs), its **topics** and its **types**; the status and the topics are
  also put on keys of their own when they change.
- An application streams **data** on **topics** it declares: each value is
  a put on `asterism/<node>/<app>/<topic>`, with a sequence number (and,
  when the topic says so, the sender's time) in the attachment. The type,
  unit and description of a topic are said once, in its declaration.
- There is no server: every application answers the queries for its own
  objects. A Zenoh router (zenohd) usually connects them; a direct peer
  link works the same.
- Payloads are MessagePack, each exactly one value, with no Zenoh
  encoding. The one exception is a topic declared with an encoding (an
  image as JPEG): its values are the bytes in that encoding, and the
  encoding goes with each value (9.2). Calls, meta, profiles, statuses
  and declarations use no encoding, no attachment, no Zenoh error reply, no
  timestamp and no source info (section 13).

### 1.1 Several connections in one program

A program that is several applications (a game host that is also the
spectators' view, `host/game` and `host/spectate`) opens one connection
for each. Nothing on the wire tells them apart from applications of
different programs: each has its own application token, its own
queryables and its own `<node>/<app>` keys, and they reach each other as
any two applications do (through the router, with its access control).
What one program shares between its connections:

- the **node's profile** (7): every connection of a node answers
  `asterism/<node>/@profile`, and in one program they all answer the same
  profile (it belongs to the node, not to an application);
- the **waits** (4.6): a call waiting on one connection keeps answering the
  calls that come to the others (one of them may be the one called), and
  the nesting limit counts the waits of all of them;
- the duplicate check (6.3) also looks at the program's own connections.

**What a connection costs on a board.** Each is a Zenoh session of its
own: a TCP or TLS link to the router (TLS with its record buffers), a seat
at the router (a router that admits each certificate once, or a limited
number of clients, counts it), the object layer's queryables (calls with
a queue of 32, the node's profile, and the application's profile once it
has a status, topic or type, each with its queue), a liveliness
subscriber, and the application token. One connection is the usual on a
board; a second is for a second application, not for a second purpose of
the same one. Two zenoh-pico sessions of one program reach each other
through a router only: a peer link between them cannot open, as the
opening session's handshake waits for the other's poll.

## 2. Names and keys

### 2.1 Names

A node ID, an application name and an object name are each **one Zenoh key
chunk**:

- not empty;
- MUST NOT contain `/`, `*`, `$`, `?`, `#`;
- MUST NOT start with `@` (chunks starting with `@` are Zenoh's verbatim
  chunks, and Asterism uses them for its own keys, see `@profile`).

The Ruby implementation's `Asterism.connect`, `Connection#expose` and
`Connection#[]` raise `ArgumentError` for anything else. There is no
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
| `asterism/<node>/<app>/@profile` | queryable | the application, once it has a status, a topic or a type | 8 |
| `asterism/<node>/<app>/@status` | put | the application, at connect and when its status changes | 8 |
| `asterism/<node>/<app>/@pubs` | put | the application, when its topics change | 10 |
| `asterism/<node>/<app>/<topic>` | publisher, put | the application, for each value of a topic (`<topic>` may have several chunks) | 9 |

- The root chunk is `asterism`.
- There is no token for the node alone: a node is present while any of
  its applications is (6.1).
- `@profile` is a verbatim chunk: `asterism/**` and `asterism/<node>/**`
  do **not** match it (a get on `asterism/<node>/**` gets no profile
  reply, a subscriber on `asterism/**` does not see the profile puts;
  `asterism/*/@profile` does match). The object layer's wildcards and its
  liveliness watch never see it.
- The application's `@profile`, `@status` and `@pubs` are verbatim chunks
  too: `asterism/**`, `asterism/<node>/**` and `asterism/<node>/<app>/**`
  do **not** match them (the application's queryable on
  `asterism/<node>/<app>/**` does not get its profile queries, a
  subscriber on `asterism/<node>/<app>/**` sees the topics' values and not
  the declarations); `asterism/*/*/@profile`, `asterism/<node>/*/@status`
  and the like do. A node's profile key has one chunk less than an
  application's, so `asterism/*/@profile` and `asterism/*/*/@profile`
  never meet. An access control rule written for `asterism/**` does not
  reach them either: a router lets them through only with rules of their
  own (a reader: query on `asterism/*/*/@profile`, subscription on
  `asterism/*/*/@status` and `asterism/*/*/@pubs`; a writer: queryable and
  reply on `asterism/<node>/*/@profile`, put on `asterism/<node>/*/@status`
  and `asterism/<node>/*/@pubs`).
- The topics' keys `asterism/<node>/<app>/<topic>` do not meet the object
  layer: puts and subscriptions are not queries, and the queryable answers
  only the key shapes of 4.3. A topic may share its first chunk with an
  object's name (an object `board1`, a topic `board1/strokes`): the
  object's token and calls and the topic's puts do not meet. A topic
  SHOULD NOT be named like a call or meta key (`x/meta`, `x/call/y`), so
  that a reader of the keys does not take one for the other.
- Other verbatim chunks under `asterism/` are reserved for this protocol.

## 3. Values

### 3.1 The MessagePack subset

Call arguments, keyword arguments, return values, errors, meta, profiles,
statuses, declarations and the values of topics without an encoding (9)
are MessagePack values built from:

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
  Conformance is about values, not bytes (section 15).

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
  names, declaration fields, type names) are str. A receiver MAY accept a bin where a str is expected (the
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
| timeout | the call's time limit: 2 s by default (`net[path, timeout:]`) |

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
| `protocol` | a protocol 0 call (4.3 step 2) | `Asterism::Error` | free text naming this protocol (the implementation says `<node>/<app> speaks Asterism protocol 2: ...`) |
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

A method may itself call and wait. The waits of one program (all its
connections, 1.1) nest at most 4 deep (`Asterism::MAX_NESTING`); a fifth
raises `Asterism::Error`,
which the outer call answers as `nesting` (4.4). This is a property of the
implementation, not of the wire, but it is visible in the error.

### 4.7 Who called

The caller's node ID is the call key's last chunk. The callee's binding
hands it to the method:

- Ruby: `Connection#current_call` while the method runs (nil outside a
  call; per thread on CRuby): `from` (the caller's node ID), `verified`
  (`:claimed`; `:local` for a call from the same application, which does
  not go on the network), `object`, `method`.
- Ruby: `Connection#expose(name, obj, methods:, caller: :from)` passes the
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
such rules from its roles (`asterism/*/<app>/*/call/${node}`).

Clients that come through a gateway that holds the certificates for them
can still be told apart if the names are fixed beforehand. asterism-console
0.3.0 does so for the browsers in its rooms: each room slot has a number of
seats, each with a certificate made in advance, and the rooms' door gives
each page a seat and connects with that seat's certificate. The seat's
node ID is fixed by the seat (`wasm-0103`: slot 01, seat 03), and the ACL
lets the seat write only under `room/<slot>/asterism/<its node>` and call
only with `.../call/<its node>`. zenohd lets a deny win over an allow
within one subject and any subject's allow win over the others, so the
rule "no call but as yourself" takes two subjects for one certificate: one
(the common name) with a deny on `.../call/**`, one (the common name and
the link protocol) with an allow on `.../call/<its node>`. A callee in such
a room can take `from` as bound, as for a client with a certificate of its
own. Zenoh's source info (the querier's session ID that a
get may carry) is written by the querier and not checked by routers; this
protocol does not use it.

## 5. Meta

A get on `asterism/<node>/<app>/<object>/meta` (no payload, no parameters;
a payload is ignored) is answered with:

```
{"methods" => [{"name" => name, "arity" => n, "args" => [names], "doc" => text}, ...],
 "doc" => text}
```

- `name` is a str, `arity` an int: the number of positional arguments
  given at `expose` (`methods: { play: 1 }`), or `-1` when exposed by name
  only (`methods: [:say]`). It is not Ruby's arity: `-1` means "not
  checked", and other negative numbers do not occur. Entries are maps so
  that fields can be added (optional arguments, keywords, a description);
  readers ignore fields they do not know.
- `args` (optional): an array of str, the names of the positional
  arguments in order (non-empty, at most 64 bytes each, at most 16). When
  `arity` is not `-1`, there are exactly `arity` names; with `-1` they name
  the leading arguments. Keywords and the caller keyword (4.7) are not in
  it.
- `doc` (optional) in an entry: a str, what the method does and what it
  answers (at most 2048 bytes); the first line is a summary. `doc` at the
  top of the reply: the same for the object.
- Both are given at `expose`: `methods: { "move" => { args: %w[token n
  square], doc: "..." } }` (the names give the arity; `arity:` overrides it,
  `-1` for any), mixed freely with `name => n`; `doc: "..."` for the
  object. They are for people and tools that show them (`asterism mcp`
  makes a tool's inputs and description from them, the command line prints
  them); nothing checks a call against the names. A reader drops an `args`
  that is not an array of str or whose size does not match `arity`, and a
  `doc` that is not a str. Both are optional: a node may send neither,
  and a reader that does not show them ignores them.
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
token, three an object token; anything else is ignored. `Connection#nodes`,
`#each` and `on_join` / `on_leave` come from this. Each connection
follows on its own; the program's other connections are applications
like any other. ROS 2's tokens
(`@ros2_lv/...`) and the profiles are outside `asterism/**`. Topics have
no tokens of their own (10.3).

### 6.3 The duplicate check

Before declaring anything, `Asterism.connect` does a liveliness get on
`asterism/<node>/<app>/**` (which also matches the application token
itself; 1 s, the check gives up after 1.5 s, `check_timeout:`). If any
token answers, another copy of the same `<node>/<app>` is running and
connect refuses (`Asterism::Error`). Implementations SHOULD make the same
check: two queryables for the same `<node>/<app>` answer every call twice.
The check is per `<node>/<app>`: the same node with another application
passes. A program that holds several connections also refuses a
`<node>/<app>` that one of its own connections has (without waiting for
the network).

## 7. Profiles

### 7.1 Keys

- Each connected application declares a queryable on
  `asterism/<node>/@profile` (depth 4) and answers every query there with
  the node's profile, on the same key.
- At connect, and each time the profile changes while connected, it puts
  the profile **without the icon** on the same key.
- Several applications of a node each answer; a reader takes the first
  answer (`profile_of`), a follower the last put. The connections of one
  program answer the same profile (1.1); applications of a node in
  different programs (two VMs on a board) answer the same when they are
  given the same.
- Each application also has a profile of its own, one chunk further down
  (`asterism/<node>/<app>/@profile`, section 8).

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
| `protocol` | int, the protocol the node speaks: `2` | always |
| `kind` | str, what runs the node: `family_mruby`, `picoruby`, `cruby`, `console`; any word of 1-32 bytes, first `a-z`, then `a-z`, `0-9`, `_` | always |
| `host` | str, where it runs (`atoms3r`, `tab5`, `p4nano`, `sim`, `browser`), 1-32 bytes | when set |
| `name` | str, a display name, 1-64 bytes | when set |
| `icon` | **bin**, the bytes of a PNG, at most 8192 bytes, at most 256x256 | when there is an icon and it was asked for |
| `icon_hash` | str, 8 lower-case hex digits (7.4) | when there is an icon (also when its bytes are left out) |

A node without `protocol` speaks protocol 0 (appendix A): its calls and
replies are not protocol 2's. A node with another number speaks another
protocol; a reader shows the number and does not call it.

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

## 8. Application profiles and status

A node's profile (7) says once what the node is. An **application's
profile** says what the application has to tell about itself: its
**status** (what changes while it runs: how many tables a game host has
open and who sits at them, a battery level, the mode a robot is in), its
**topics** (10) and its own **types** (11). It is one queryable per
application that answers each part, so that an application has as many
queryables as before (its `**` and this one) whatever it tells.

### 8.1 Keys

- An application that has a status, a topic or a type of its own declares
  a queryable on `asterism/<node>/<app>/@profile` (depth 4) and answers
  every query there on the same key (8.2, 8.3). An application with none of
  them MAY declare nothing there (the implementation declares it with the
  first of them and keeps it until it closes); then nothing answers, and
  the reader sees no reply: "nothing to tell", not an error.
- It puts its status on `asterism/<node>/<app>/@status` at connect (when
  it already has one), each time the status **changes**, and after a lost
  connection comes back (a put made while the router was away reached
  nobody). Setting the same status again puts nothing: an implementation
  compares the encoded map with the one it last put on this connection.
  Nothing answers queries on `@status`: the status is asked for at
  `@profile?status`.
- It puts its topics' declarations on `asterism/<node>/<app>/@pubs` (10.2).
- The profile belongs to the application (one per `<node>/<app>`), not to
  the node: two applications of one node have one each.
- There is no delete: when the application goes, its tokens go (6), and
  readers forget its status, topics and types with them.

### 8.2 The query

The query has no payload (one is ignored). Its parameters name the parts
wanted: the parameter string is split on `;`, the name of each part is
what comes before `=` (or all of it), and the names that count are
`status`, `pubs` and `types`; the others are ignored. A query that names
none of them (no parameters, or only other names) gets the **default
reply**: the status and the topics. The implementation asks with one name
(`status`, `pubs` or `types`).

### 8.3 The reply

A MessagePack map with the parts asked for, under their names:

| Key | Value | Present |
|---|---|---|
| `status` | the status: a map with str keys (8.4) | when asked for (or by default) and the application has a status |
| `pubs` | the topics' declarations (10.1) | when asked for (or by default) and the application has a topic |
| `types` | the application's own types (11.2) | when asked for (never by default) and it has defined one |

A part the application does not have is **left out** (not nil, not an
empty map): an application without a status answers `?status` with `{}`.

```
get    asterism/games/games/@profile          (no parameters)
reply  {"status" => {"mahjong1" => {"st" => "play", "members" => 4}},
        "pubs" => {"mahjong1/state" => {"t" => "asterism-games/table.state"}}}
get    asterism/games/games/@profile?types
reply  {"types" => {"asterism-games/table.state" => {"f" => [["st", "str"], ["members", "int"]]}}}
```

### 8.4 The status

A MessagePack **map with str keys** (not empty strings). The values are any
values of the protocol (3.1), nested at most **4 levels below the map**
(the map is level 0; `{"a" => [[[[1]]]]}` is the deepest allowed). The
encoded map is at most **1024 bytes**. The sender refuses a status that
breaks these rules before sending (Ruby: `ArgumentError` from
`Connection#status`). The same map is the `status` of the reply and the
payload of the put on `@status`.

Its content is the application's own. Readers show it (a console's
details, a command line `watch`) and do not interpret it unless they know
the application.

Example, a game host (asterism-games) with two tables:

```
put    asterism/games/games/@status
       {"mahjong1" => {"st" => "play", "members" => 4, "humans" => 1, "cpus" => 3, "away" => 0},
        "othello1" => {"st" => "wait", "members" => 0, "humans" => 0, "cpus" => 0, "away" => 0}}
```

A status SHOULD hold counts and states, not secrets: whoever may read
`asterism/*/*/@profile` or `asterism/*/*/@status` reads it (a game host
leaves out the members' names, their node IDs and their tokens).

### 8.5 Reading

The reader cleans what it gets:

- a reply that is not a map: nothing (no status, no topics, no types);
- the status (`Asterism::Status.check`): not a map, or a map that encodes
  into more than 1024 bytes: **no status** (nil); entries whose key is not
  a non-empty str are dropped; the nesting is not checked. A reply without
  `status` is no status;
- the topics (`Asterism::Pubs.check`, 10.1) and the types
  (`Asterism::Types.check`, 11.2): a reply without the part has none (an
  empty map); nobody answering is nil.

A follower subscribes to `asterism/*/*/@status` and `asterism/*/*/@pubs`
(or with the node named) and takes the last put of each `<node>/<app>`; it
asks `@profile` once for an application that appeared (only changes are
put). An application that does not answer has nothing to tell; that is not
an error.

## 9. Data

An application streams values on its own keys: a sensor's readings, a
game table's state, a camera's frames, a drawing's strokes, a log. Each
stream is a **topic**, declared once (10) and then put on, value by value.
What goes with each value is kept as small as it can be: the value itself,
its encoding only when it is not MessagePack, and a sequence number.

### 9.1 Keys

The values of the topic `<topic>` of `<node>/<app>` go on
`asterism/<node>/<app>/<topic>`. `<topic>` is one or more chunks separated
by `/`, each a name (2.1): `imu`, `board1/strokes`. An implementation
declares the key as a Zenoh **publisher** when the topic is declared, so
that Zenoh sends the key as a number with each value instead of the whole
key (zenoh-c and zenoh-pico both do), and puts each value on it.

A reader subscribes to the keys, with wildcards as it likes
(`asterism/*/demo/imu`, `asterism/linux/demo/**`; the latter does not
reach `@profile`, `@status` or `@pubs`, 2.2).

### 9.2 The payload and the encoding

| The topic's values | Payload | Zenoh encoding |
|---|---|---|
| MessagePack (the default) | exactly one value (3.1) | **none** (Zenoh reports its default, `zenoh/bytes`) |
| in another format (declared with an encoding, 10.1) | the bytes as they are | the declared encoding, one Zenoh gives a fixed number (below) |

- **No encoding means MessagePack.** MessagePack has no number of its own
  in Zenoh (`application/msgpack` as a string would add 20 to 30 bytes to
  every value), so a MessagePack value carries none, and costs nothing.
  A sender MUST NOT set `zenoh/bytes` to mean anything else.
- A topic of another format uses an encoding with a **fixed Zenoh
  number** (Zenoh 1.x numbers 0 to 52), which costs one byte or two with
  each value: `text/plain` 4, `application/cdr` 7, `image/png` 16,
  `image/jpeg` 17 (the whole table: 0 `zenoh/bytes`, 1 `zenoh/string`,
  2 `zenoh/serialized`, 3 `application/octet-stream`, 4 `text/plain`,
  5 `application/json`, 6 `text/json`, 7 `application/cdr`,
  8 `application/cbor`, 9 `application/yaml`, 10 `text/yaml`,
  11 `text/json5`, 12 `application/python-serialized-object`,
  13 `application/protobuf`, 14 `application/java-serialized-object`,
  15 `application/openmetrics-text`, 16 `image/png`, 17 `image/jpeg`,
  18 `image/gif`, 19 `image/bmp`, 20 `image/webp`, 21 `application/xml`,
  22 `application/x-www-form-urlencoded`, 23 `text/html`, 24 `text/xml`,
  25 `text/css`, 26 `text/javascript`, 27 `text/markdown`, 28 `text/csv`,
  29 `application/sql`, 30 `application/coap-payload`,
  31 `application/json-patch+json`, 32 `application/json-seq`,
  33 `application/jsonpath`, 34 `application/jwt`, 35 `application/mp4`,
  36 `application/soap+xml`, 37 `application/yang`, 38 `audio/aac`,
  39 `audio/flac`, 40 `audio/mp4`, 41 `audio/ogg`, 42 `audio/vorbis`,
  43 `video/h261`, 44 `video/h263`, 45 `video/h264`, 46 `video/h265`,
  47 `video/h266`, 48 `video/mp4`, 49 `video/ogg`, 50 `video/raw`,
  51 `video/vp8`, 52 `video/vp9`). A schema may follow the name
  (`text/plain;charset=utf-8`); it travels with each value as Zenoh sends
  it.
- So a JPEG goes as its bytes with `image/jpeg`, not wrapped in a
  MessagePack bin; a binary blob that is not in any of these formats goes
  as a MessagePack bin (no encoding).
- Calls, replies, meta, profiles, statuses and declarations carry no
  encoding: they are MessagePack.

### 9.3 The attachment

Every value of a topic carries a Zenoh attachment: a MessagePack array

| Form | When |
|---|---|
| `[seq]` | always, unless the topic sends the time |
| `[seq, time]` | the topic is declared with `ts` (10.1) |

- `seq`: an int, the **sequence number** of the value in its topic: 0 for
  the first value after the topic is declared, then one more for each
  value put, and back to 0 after `2^31 - 1` (2147483647), so that every
  board's integers hold it. It is per topic and per declaration: a topic
  declared again, or an application that connects again, starts over at 0.
- `time`: an int, the **sender's time** when the value was put (or
  measured), in **milliseconds since 1970-01-01 UTC** (12).
- A reader ignores elements after these (room for later additions). A
  value without an attachment, or with one that is not an array starting
  with an int from 0 to `2^31 - 1`, has no sequence number; a `time` that
  is not an int is no time.

The cost: 2 to 6 bytes with the array's header: a `seq` below 128 takes
2 bytes, up to 65535 four, beyond six; a time adds 9 bytes. Replies to queries (calls, meta,
profiles) carry no attachment.

### 9.4 Reading the sequence numbers

A reader keeps the last number of each key it receives and reads the next
one by its distance forward, `d = (seq - last) mod 2^31`:

- `0 < d < 2^30`: a step forward; `d - 1` values were **lost** (put but
  not received: a full queue, a link that dropped them, the router away);
- otherwise (the number went back, or stayed, or jumped by half the range
  or more): the sender **restarted** the topic (it declared it again, or
  connected again). The values of the new run before this one, `seq` of
  them, were not received;
- the first value of a key: nothing lost, `lost` 0 (a reader that
  subscribes late does not count what came before it). Zenoh may also
  leave out the first values a publisher puts before it knows of the
  subscriber.

The step from `2^31 - 1` to `0` is `d = 1`, the wrap: a step forward,
nothing lost. A restart is told apart from it (`info.restarted?` in Ruby,
9.5). A value without an encoding that does not decode as one MessagePack
value is not handed to the application; it is counted (`malformed`).

### 9.5 Subscribing (the Ruby API)

`net.subscribe("<node>/<app>/<topic>") { |v, info| ... }` (wildcards
allowed) gives each value decoded (MessagePack) or as its bytes (another
encoding), and an `Asterism::SampleInfo`: `key`, `node`, `app`, `name`,
`seq`, `time`, `encoding` (`"msgpack"` for no encoding, the MCAP word;
else Zenoh's name), `timestamp` (the router's, 12), `lost` and
`restarted?` (9.4). A value without an encoding that is not one
MessagePack value is left out (counted in the subscription's `malformed`).
The blocks run from `net.poll`, never inside a waiting call. An
application's subscription does not get the values the application puts
itself (neither binding delivered them in the tests); a reader MUST NOT
rely on either. Another connection of the same program is another
application: it gets them.

## 10. Topic declarations

### 10.1 The declaration

An application declares each topic once
(`net.publish("imu", type: :vector3, unit: "m/s2", ts: true)`). The
declarations are a MessagePack map, topic name => declaration, each a map
with short keys:

| Key | Value | Absent means |
|---|---|---|
| `t` | the type: an int, a built-in type's number (11.1); or a str, an application type's name (11.2) | no type (the reader guesses from the values) |
| `e` | an int, the number of the topic's encoding (9.2) | MessagePack |
| `u` | a str, the unit (`m/s2`, `degC`), at most 64 bytes | no unit |
| `d` | a str, what the topic is, for people and tools, at most 2048 bytes | no text |
| `ts` | `true`: each value carries the sender's time (9.3) | no time |

```
{"board1/strokes" => {"t" => "asterism-games/board.strokes"},
 "imu"            => {"t" => 2, "u" => "m/s2", "d" => "acceleration", "ts" => true},
 "camera"         => {"t" => 4, "e" => 17}}
```

A reader (`Asterism::Pubs.check`) keeps the declarations that are maps
under a non-empty str name, and in each the keys above that have the right
shape (`t` an int above 0 or a non-empty str, `e` an int above 0, `u` and
`d` str, `ts` true); it drops the rest.

### 10.2 Where they are told

- The application answers them as the `pubs` part of its profile (8.3):
  `asterism/<node>/<app>/@profile?pubs`.
- It puts the whole map on `asterism/<node>/<app>/@pubs` each time it
  changes (a topic declared or withdrawn), and after a lost connection
  comes back. Declaring a topic again with the same declaration changes
  nothing and puts nothing; the order of the map stays. An implementation
  MAY put once for several topics declared together. Withdrawing the last
  topic puts the empty map.
- An application with no topic puts nothing there.

### 10.3 No tokens

Topics have no liveliness tokens of their own (a token per topic would
cost each board a declaration and its memory). A topic lives as long as
its application's token (6.1); who wants to know the topics follows
`asterism/*/*/@pubs`.

## 11. Types

### 11.1 Built-in types

The built-in types have numbers, so that a declaration says them in one
byte. Their values are MessagePack in the shapes below (arrays where there
are several numbers):

| Number | Name | Value |
|---|---|---|
| 1 | number | an int or a float |
| 2 | vector3 | `[x, y, z]`, ints or floats |
| 3 | pose | `[x, y, z, qx, qy, qz, qw]`: the position, then the orientation as a quaternion, flat, in ROS 2's `Pose` order (ints or floats) |
| 4 | image | the image's bytes, in the topic's encoding (`image/jpeg`, `image/png`, ...) |
| 5 | state | a str or an int: a scene, a mode, on / off |
| 6 | log | a map: `level` (`"debug"`, `"info"`, `"warn"`, `"error"`, `"fatal"`, or 10 to 50 as ROS 2), `msg` (str), `time` (seconds since 1970, a float); optional `name`, `file`, `line`, `function` |
| 7 | text | a str |

Numbers are added, never changed: a reader that does not know a number
treats the topic as having no type.

### 11.2 Application types

An application names a type of its own with a str, namespaced by whoever
defines it (`asterism-games/board.strokes`). It MAY tell the definition:
the `types` part of its profile (8.3), `asterism/<node>/<app>/@profile?types`,
is a map, type name => definition:

```
{"asterism-games/board.strokes" => {"f" => [["pts", "int[]"], ["color", "str"], ["at", 2]],
                                    "d" => "the strokes of one board"}}
```

| Key | Value |
|---|---|
| `f` | the fields, in order: an array of `[name, type]`, name a str; type an int (a built-in type's number), or a str: a built-in type's name (`number`, `vector3`, `pose`, `image`, `state`, `log`, `text`), a basic type (`int`, `float`, `str`, `bin`, `bool`, `any`) or another application type's name, any of them with `[]` at the end for an array of them (`vector3[]`, `int[]`, `asterism-games/point[]`), repeated for arrays of arrays (`int[][]`: an array of arrays of ints) |
| `d` | optional, a str: what the type is |

`any` is a value of any shape (what the type does not say: a list of
mixed parts such as `[name, seat, flags]` is an `any`, a list of them
`any[]`). `[]` alone, with no type before it, is not a type.

The value of such a type is a MessagePack map with the fields as str keys.
A built-in type is written in a field by its number or by its name (an
array of one only by its name, `"vector3[]"`); the implementation sends
the form the application wrote. A topic's declaration (`t`, 10.1) always
uses the number. The names of the built-in types and of the basic types
are not application types' names. A reader
(`Asterism::Types.check`) keeps the definitions with a non-empty str name
whose `f` is an array of `[str, int or non-empty str]`, and `d` when it is
a str.

## 12. Times

Three times can be told apart:

| Time | From | What it says | For |
|---|---|---|---|
| the sender's time | the attachment (9.3), only for a topic declared with `ts` | when the value was measured or put, by the sender's clock, in ms since 1970 | the intervals within one topic (a plot's axis) |
| the router's timestamp | Zenoh (zenohd stamps what passes through it: `timestamping` is on for routers by default) | when the value passed the router (Zenoh's HLC) | the order across nodes |
| the receiving time | the reader | when the reader got it | a recording's log time |

A board's clock may be off: the sender's time is right for the intervals
within a topic, the router's for the order of everything. Values on a
direct peer link carry no router timestamp, and replies to queries carry
none either. Without `ts`, a reader uses the router's timestamp.

## 13. What Zenoh must provide

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
| Put and subscriber | profile notices, status and declaration changes |
| Publisher (declared key), put with an attachment | the values of topics (9) |
| Encodings with a fixed number, read from a received value | the values of topics that are not MessagePack (9.2) |
| Timestamps read from a received value (when a router stamped it) | the router's time (12) |

Not used, and not to be relied on: encodings other than on the values of
topics, attachments other than theirs, Zenoh error replies, delete
replies, source info, complete queryables, queriers, advanced
publishers/subscribers. TLS and access control are a deployment's choice
(4.7); boards have no TLS.

## 14. Differences between the implementations

Checked with the conformance tests (section 15) and the Family mruby
simulation:

| | CRuby | Boards (Family mruby, msgpack-c) | mruby test build |
|---|---|---|---|
| str of 32-255 bytes written as | str8 | str8 | str16 |
| arrays / maps / ints written as | shortest | shortest | 16-bit / int64 forms |
| a binary String | ASCII-8BIT | the binary flag (`String#b`) | the binary flag |
| a Zenoh payload handed to the application | ASCII-8BIT (relayed as bin) | a plain String (relayed as str unless `.b`) | a plain String |
| error messages from the language | CRuby's | mruby's | mruby's |
| `Connection#current_call` | per connection and thread | per connection | per connection |
| subscription blocks (`Connection#subscribe`) | from `net.poll`, or the connection's receiving thread (`net.start`) | from `net.poll` | from `net.poll` |
| answer latency (simulation) | 2-4 ms | 50 ms (the app's update loop) | 2-4 ms |

The mruby test build's MessagePack (`host_test/msgpack.rb`) is a stand-in;
what the boards do is the msgpack-c column (fmruby-core
`lib/add/picoruby-fmrb-msgpack`).

## 15. Conformance tests

### 15.1 What there is

| File | What |
|---|---|
| `test/protocol/samples.json` | the samples: values, the queries a node must answer and how, the calls and queries a node must make and what it must send, the values it must put and read on topics, the tokens and the puts on its profile, status and declaration keys. Language-neutral (JSON) |
| `test/protocol/gen_samples.rb` | how samples.json is written (edit this, run it, commit both; `--check` tells whether the JSON is stale) |
| `test/protocol/driver.rb` | the driver: plays the other side over Zenoh (plain Zenoh and MessagePack only, never the object layer) and checks an implementation against the samples |
| `test/protocol/node.rb` | the implementation under test in Ruby, portable API only: the same file runs on CRuby and mruby |
| `test/protocol/tv.rb` | the typed values below, for the driver |
| `test/protocol/test_samples.rb` | checks the samples themselves (each byte form decodes to its value, CRuby writes the first form, what is not a value does not decode, the matchers reject what they should) |

```
rake test:protocol          # samples + driver against CRuby (part of `rake`)
rake test:protocol_mruby    # driver against mruby (builds mruby like test:mruby)
rake test:cross             # topics between an mruby node and a CRuby one, both through Asterism
ASTERISM_TEST_ROUTER=tcp/127.0.0.1:7447 rake test:protocol   # through a router
```

Through a router, use one that no other Asterism node is connected to:
the sample "profile not under *" asks `asterism/*/@profile`, and every
node there answers it.

### 15.2 Typed values

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

### 15.3 samples.json

```
{
  "format": "asterism-protocol-samples", "version": 5, "protocol": 2,
  "names":  {"iut": "iut", "app": "conf", "driver": "drv"},
  "icon":   {"hex": "<the PNG>", "icon_hash": "2a8c0626"},
  "iut":    {"profile": ..., "status": ..., "types": [...], "topics": [...], "subscribe": "drv/conf/**",
             "objects": [{"name": "subject", "methods": [[name, arity], ...]}, ...]},
  "values":   [{"id", "value", "encodings": [hex, ...], "portable", "expect"?, "note"?}, ...],
  "incoming": [{"id", "key", "params", "payload_hex", "replies": [{"key", "payload"}], "portable", "note"?}, ...],
  "outgoing": [{"id", "do", "request": {"key", "params", "call" | "payload"} | null, "reply_hex": [hex, ...], "outcome"}, ...],
  "liveliness":   {"alive": [key, ...], "gone_after_close": [key, ...]},
  "profile_puts": [{"when", "key", "payload"}, ...],
  "status_puts":  [{"when", "key", "payload"}, ...],
  "pubs_puts":    {"key", "declared", "after_unpublish"},
  "data_puts":    [{"key", "encoding", "payload" | "payload_hex", "attachment"}, ...]
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
  `{"profile_of": "drv", "icon": bool}`; `{"set_profile": {"map": ...}}`;
  `{"status_of": ["drv", "conf"]}`, `{"pubs_of": [...]}`,
  `{"types_of": [...]}` (a query of `asterism/drv/conf/@profile` with
  `status`, `pubs` or `types`); `{"set_status": {"map": ...}}` (the whole
  status); `{"put": [[topic, value], ...]}` (values put on the topics, in
  order); `{"unpublish": topic}`; `{"feed": [...], "expect": n}`: call
  `rec.feed()`; while answering it, the driver puts the values listed
  (`key`, `payload_hex`, `attachment_hex`, `encoding`; nil: none) on
  `asterism/drv/conf/feed/...`, and the implementation reports what its
  subscription to `drv/conf/**` got (9.5): `[path, value, seq, time,
  encoding, lost, restarted]` for each value in the order they came, a
  value with an encoding as a bin.
  The driver checks the request it receives against `request` (for a
  call, `call` is the request map with absent `args` / `kwargs` read as
  empty), answers with the replies in `reply_hex` (none: it finishes the
  query without a reply) and then expects the implementation's report of
  the `outcome`.
- **profile_puts**, **status_puts**: the puts the implementation must make
  on its profile key and its status key, in this order, and no others (the
  same status set again puts nothing).
- **pubs_puts**: the last two puts on `@pubs` are `declared` (the three
  topics) and `after_unpublish`; puts before them (one per topic as they
  are declared) are not checked.
- **data_puts**: the puts on the topics' keys, in order, and no others:
  the encoding Zenoh reports (`zenoh/bytes` for none), the payload (a
  MessagePack value, or the bytes as they are) and the attachment.
- **portable: false** samples are where the implementations may differ
  (section 14): the driver prints what came back and does not fail.

### 15.4 The implementation under test

An implementation in another language writes its own node program; the
driver runs it as `COMMAND LOCATOR MODE ICON_FILE` (MODE is `peer`: connect
to the driver, which listens on LOCATOR; or `client`: both are clients of
the router at LOCATOR). The program:

1. sets its profile name to `iut` and its icon to the PNG in ICON_FILE,
   and its status to `{"st" => "wait", "n" => 1}`, and defines the type
   in `iut.types`;
2. connects as node `iut`, application `conf`, declares the topics in
   `iut.topics` and subscribes to `drv/conf/**`;
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

## 16. Examples

Node `linux`, app `demo` (Family mruby's asterism_demo in the simulation),
called by a CRuby node `mypc`:

```
liveliness  asterism/linux/demo                 alive (the application)
liveliness  asterism/linux/demo/apu             alive
liveliness  asterism/linux/demo/screen          alive
liveliness  asterism/linux/demo/info            alive
put         asterism/linux/@profile
            84 a8 70726f746f636f6c 02 a4 6b696e64 ac 66616d696c795f6d72756279
               a4 686f7374 a3 73696d a9 69636f6e5f68617368 a8 3236633030353933
            {"protocol" => 2, "kind" => "family_mruby", "host" => "sim", "icon_hash" => "26c00593"}
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

The same application with a topic `imu` (`net.publish("imu", type:
:vector3, unit: "m/s2", ts: true)`), read by `mypc`:

```
put         asterism/linux/demo/@pubs
            81 a3 696d75 83 a1 74 02 a1 75 a4 6d2f7332 a2 7473 c3
            {"imu" => {"t" => 2, "u" => "m/s2", "ts" => true}}
put         asterism/linux/demo/imu       (a declared publisher: the key goes as a number)
            payload     93 cb 3fe0000000000000 ff 03     [0.5, -1, 3]   (no encoding)
            attachment  92 07 cf 000001a1d3ebac7b        [7, 1794556800123]
get         asterism/linux/demo/@profile?pubs
reply       asterism/linux/demo/@profile
            {"pubs" => {"imu" => {"t" => 2, "u" => "m/s2", "ts" => true}}}
```

Per value, besides the key: the payload and 11 bytes of attachment (2
without `ts`); no encoding.

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
