# Review of the wire protocol: the Ruby-shaped parts (proposal)

Status: **proposal, nothing decided**. It goes with
[protocol.md](protocol.md), which describes protocol 0 as asterism 0.6.0
speaks it. This review lists where protocol 0 follows Ruby rather than
something every language has, what that costs an implementation in
Python, TypeScript or C, and how it could be changed. Nothing here is
implemented: the wire stays as it is until the maintainer decides, and
the decisions are implemented in a later stage (as protocol 1).

Each item has: what protocol 0 does, the trouble in other languages, the
options, a recommendation, and how protocol 0 nodes keep working
(compatibility). Section "Decisions" at the end lists the questions to
answer.

Two facts about protocol 0 readers decide what is compatible:

- **A call must be an array of exactly three elements**: a 0.6.0
  receiver answers anything else as a malformed call. Adding a fourth
  element to the request breaks old receivers.
- **A reply may have more elements**: a 0.6.0 caller reads `raw[0]`,
  `raw[1]` (and `raw[2]` for errors) and ignores the rest. Adding elements
  to replies, keys to the meta and fields to the profile (the reader drops
  unknown fields) is compatible. **Query attachments are ignored** by
  0.6.0 receivers, and keys with more than five chunks are not answered.

## R-1. Positional and keyword arguments

**Now.** `[method, args, kwargs]`: an array of positional arguments and a
map of keyword arguments, always present (an empty map when none). The
receiving Ruby passes the map as keywords only when it is not empty.

**Elsewhere.** Python has both kinds and maps directly. TypeScript, C, Rust
and Java have positional arguments only; a keyword map must become a
trailing options object, or be refused. A JavaScript caller that passes an
options object positionally sends it in `args`, and a Ruby method with
keywords then gets a positional Hash (an `ArgumentError`).

**Options.**

- A. Keep the triple. Write down how a language without keywords maps it:
  as a callee, receive `kwargs` as one extra trailing options argument
  (or refuse a non-empty map); as a caller, expose a way to give the map.
- B. Allow `[method, args]` (two elements) as "no keywords", for senders
  that have none. Receivers of protocol 1 accept both; senders keep three
  until protocol 0 receivers are gone.
- C. Named arguments only (`[method, {name: value}]`). Clear for
  languages with names, but loses positional calls; not worth it.

**Recommendation.** A, plus B on the receiving side only. **Compatibility**:
A changes nothing; B is a receiver relaxation, and senders keep writing the
triple to protocol 0 nodes.

## R-2. Symbols and strings

**Now.** A Symbol is sent as a str, also as a map key and a keyword name.
What comes back is a String: `rec.mode(:fast)` arrives as `"fast"`;
`case v when :fast` never matches.

**Elsewhere.** No other language has Ruby's Symbols; strings are the
natural form. A MessagePack ext type for Symbols would be Ruby-only and
the boards' MessagePack reads ext as nil.

**Options.** A. Keep: Symbols are strings on the wire. B. An ext type.

**Recommendation.** A, and say it in the README (Values): a value that was
a Symbol arrives as a String; keyword names become Symbols again because
Ruby needs them to call. **Compatibility**: no change.

## R-3. Map keys

**Now.** Any value may be a map key (a Hash with Integer, Array or nil keys
travels).

**Elsewhere.** Python's msgpack refuses keys that are not str or bytes by
default (`strict_map_key=True`) and cannot use an array as a dict key at
all. JavaScript objects have string keys only (a `Map` is needed for
others). C has no maps.

**Options.**

- A. Portable keys: str and int. Senders SHOULD use only these; other key
  types are allowed but not portable.
- B. str only.
- C. Anything (now).

**Recommendation.** A (int keys are common in Ruby code and cheap
everywhere but plain JS objects); note `strict_map_key=False` for Python.
**Compatibility**: a rule for senders; nothing changes on the wire.

## R-4. Integer range

**Now.** README says "Integer (64 bit)". CRuby sends an Integer of 2^63 to
2^64-1 as uint64, which the boards read wrapped (2^64-1 arrives as -1,
captured), and raises `RangeError` (not `EncodeError` as documented) for a
larger one. The boards' Integer is int64.

**Elsewhere.** JavaScript numbers are exact to 2^53 only; decoders return
BigInt or lose precision depending on an option. Python and C are fine.

**Options.**

- A. Signed 64-bit (-2^63 .. 2^63-1). Senders MUST NOT send others; CRuby's
  `Codec.check` raises `EncodeError` for them (a code fix). Receivers MAY
  refuse a larger uint64 as malformed.
- B. Allow uint64 as a separate range (receivers that cannot hold it
  refuse).

**Recommendation.** A. Say in the spec that JavaScript implementations
use BigInt for integers outside 2^53. **Compatibility**: CRuby stops sending
values the boards misread anyway; no valid exchange changes. The
`RangeError` vs `EncodeError` difference is a small bug of 0.6.0 that this
fixes.

## R-5. Floats and integers

**Now.** A Float is always float64 and stays a Float (1.0 arrives as 1.0);
an Integer stays an Integer. NaN and infinities travel.

**Elsewhere.** JavaScript has one number type: a JS `1.0` is sent as int
`1` by every MessagePack library, so a Ruby method that expects a Float
gets an Integer. Python and C keep the difference.

**Options.** A. Keep, and tell callees that an integral float may arrive as
an int from such languages (convert: `Float(x)`). B. Require float for
"real" parameters (impossible to enforce from JS).

**Recommendation.** A. **Compatibility**: no change.

## R-6. Time

**Now.** There is no time type; a `Time` cannot be sent (`EncodeError`).
Applications use their own numbers (milliseconds, seconds; the ROS layer
uses nanoseconds, `stamp_ns`).

**Elsewhere.** MessagePack has a timestamp ext (type -1); Python and JS
libraries map it to their datetime/Date. The boards' MessagePack reads any
ext as nil.

**Options.**

- A. A convention, no type: an absolute time is an int of nanoseconds since
  the Unix epoch (UTC), a duration is in the unit its name says
  (`timeout_ms`, `period`), as the README's units rule does.
- B. The timestamp ext, after the boards' MessagePack reads ext.

**Recommendation.** A now; B can be added later as an extension.
**Compatibility**: no change.

## R-7. Bytes and text (bin and str)

**Now.** Every String goes as str, binary or not: CRuby uses compatibility
mode because the boards' MessagePack reads bin as nil. A profile's icon is
a str of PNG bytes.

**Elsewhere.** This is the item that hurts most. Python's msgpack decodes
str as UTF-8 by default and raises `UnicodeDecodeError` on a profile with
an icon (the whole reply fails); a Python reader must use `raw=True` and
decode text itself. JavaScript decoders turn str into strings (invalid
bytes become U+FFFD: the icon is silently corrupted). A Python `bytes` or
a JS `Uint8Array` is sent as bin, which the boards read as nil: a binary
argument from Python to a board arrives as `nil` without an error.

**Options.**

- A. Keep str for everything; other implementations decode str as bytes
  and decide what is text themselves. Simple for Ruby, a trap for
  everyone else.
- B. bin for binary data, str for text, in protocol 1:
  1. the boards' MessagePack reads bin (as a String) and stops turning
     unknown types into nil (fmruby-core `picoruby-fmrb-msgpack`: a case
     for `MSGPACK_OBJECT_BIN`, and an error instead of nil for ext);
  2. CRuby sends a binary (ASCII-8BIT) String as bin, any other String
     as str; mruby Strings have no encoding tag, so the boards send bin
     only for what the gem marks (the profile icon; an application value
     wrapped as `Asterism.bytes(s)` or similar);
  3. the profile icon goes as bin.
- C. Only the icon as bin; everything else stays str.

**Recommendation.** B, in steps: first every receiver reads bin (no wire
change: the boards' MessagePack fix, already true of CRuby), then
protocol 1 senders write bin to nodes that say protocol 1 (R-13).
**Compatibility**: a protocol 1 node keeps sending str to protocol 0 nodes
(it knows from the profile); a protocol 0 node's str is read as before.

## R-8. nil, true, false

**Now.** Direct mappings. A keyword given as `nil` and a keyword left out
are different on the wire (key present with nil, or absent).

**Elsewhere.** Every language has a null and booleans (C needs a tagged
value). JS `undefined` must be left out, not sent.

**Recommendation.** Keep. Say that an absent keyword and a nil keyword
differ (the callee's default applies only to the absent one).

## R-9. Errors: class names

**Now.** `["error", class, message]`; `class` is a Ruby class name with its
namespace (`NoMethodError`, `Asterism::EncodeError`). Errors the protocol
itself makes (malformed call, no object, not exposed, wrong number of
arguments, unsendable return value, nesting) use Ruby class names too, and
callers can only tell them apart by those names.

**Elsewhere.** A Python callee would send `TypeError`, `KeyError`,
`ZeroDivisionError`; a TypeScript one `Error`. A caller in any language
cannot tell "you called it wrong" from "it raised" without knowing Ruby's
names.

**Options.**

- A. Keep, and list the class names the protocol makes (protocol.md 4.4)
  as fixed strings every implementation sends, whatever its language.
- B. Add a fourth element, a map: `["error", class, message, {"kind" =>
  kind, ...}]`, where `kind` is a protocol word: `malformed`, `no_object`,
  `not_exposed`, `arguments`, `unsendable`, `nesting`, `raised` (the
  method raised; `class` is then the language's own name), plus room for
  details (`"backtrace"`, `"language" => "cruby"`).
- C. Replace the array with a map. Breaks protocol 0 callers.

**Recommendation.** B (with A's fixed names kept in `class` for the
protocol's own errors, so old callers see what they see now).
**Compatibility**: protocol 0 callers ignore the fourth element (checked in
the source: `Future#value` reads elements 0-2), so B needs no version gate;
a protocol 1 caller treats a missing fourth element as `kind` unknown.

## R-10. Method names

**Now.** Any str; Ruby's `ok?`, `save!`, `name=` are exposed and called as
they are. On the calling side, the Ruby proxy forwards whatever
`method_missing` gets, so names that `Object` or `Kernel` already define
cannot be called through a proxy (`rec.display`, `rec.hash`, `rec.class`),
and a private Kernel method behaves differently by Ruby: `rec.fail` reaches
the remote side on CRuby (method_missing) but raises `NoMethodError`
locally on mruby (found while writing the conformance node; the samples
avoid such names).

**Elsewhere.** Python, TypeScript and C identifiers cannot contain `?`,
`!` or `=`. A Python callee cannot define `ok?`; a Python caller cannot
write `proxy.ok?()`.

**Options.**

- A. Names stay opaque strings. Other languages call with a generic form
  (`proxy.call("ok?")`) and expose under an explicit name
  (`expose("subject", obj, methods={"ok?": obj.is_ok})`).
- B. Protocol 1 restricts exposed names to `[a-z_][a-z0-9_]*`; Ruby
  exposers alias (`ok?` exposed as `is_ok`).
- C. A fixed mapping (`ok?` <-> `ok_p`, `save!` <-> `save_bang`), applied by
  non-Ruby bindings.

**Recommendation.** A, with a guideline: names meant for other languages
SHOULD be `[a-z_][a-z0-9_]*`; a Ruby application can expose an alias.
Separately (API, not wire): give the Ruby proxy a generic
`proxy.asterism_call(name, *args, **kw)` for names `Object` already has.
**Compatibility**: no wire change.

## R-11. Arity in the meta

**Now.** `[name, n]`: exact number of positional arguments, or -1 for "not
checked". Not Ruby's arity (where -2 means "at least one"); optional
arguments and keywords cannot be described.

**Elsewhere.** Fine for any language; it is just thin.

**Options.** A. Keep. B. Protocol 1 adds an optional third element per
method: `[name, n, {"min" => 1, "max" => 2, "keywords" => ["tag"]}]`
(protocol 0 readers take only `pair[0]`, checked in `Proxy#remote_names`).

**Recommendation.** A for now; B when a console or another language needs
it. **Compatibility**: B is an addition.

## R-12. Meta shape

**Now.** `{"methods" => [[name, arity], ...]}`. A map, so new keys can be
added; protocol 0 readers read only `"methods"`.

**Recommendation.** Keep. It is the natural place for per-object
additions (`"doc"`, R-11), not for the protocol version (R-13).

## R-13. The protocol version

**Now.** None. A node cannot tell what the other speaks; a protocol 0 node
that receives something it does not know answers it as malformed or
ignores it.

**Options.**

- A. A profile field `protocol` (int). Absent means 0. A reader that needs
  it (to choose bin over str, R-7) fetches the profile once per node when
  it joins (as the console already does) and keeps it.
- B. In the meta (`"protocol" => 1`): per object, but callers do not fetch
  the meta before calling, and an extra round trip per object is costly on
  the boards.
- C. In the key (`asterism/v1/...`): a separate network; protocol 0 and 1
  nodes would not see each other.
- D. On every request (an attachment `{"v" => 1}`): self-describing per
  message, ignored by protocol 0 receivers.

**Recommendation.** A for "what can I send this node" (absent = 0), and D
only if a per-message marker turns out to be needed. Rules:

- Additions that protocol 0 readers ignore (reply elements, meta keys,
  profile fields, attachments, new tokens of more or fewer chunks) need no
  new number.
- A change that protocol 0 readers would misread (bin, a different call
  form, new keys of exactly five chunks) is protocol 1: a node sends it
  only to nodes whose profile says `protocol >= 1`, and keeps reading the
  protocol 0 forms.
- A node of protocol 1 MUST still answer protocol 0 requests (the triple)
  as long as the gem's 0.x versions are in use; when to drop them is
  decided at 2.0.

**Compatibility**: protocol 0 readers drop the unknown profile field.

## R-14. Who called (caller identity)

The maintainer chose (2026-10-12) that the gem tells the called object who
called and verifies it ("option C"). Today a callee cannot know: the
applications pass their node ID by hand (rover_brain's `from:` keyword on
five methods, othello's first argument `from`), which any caller can set
to anything. This item writes down what Zenoh 1.10.1 can give, what is
missing in the bindings, and how option C could look. Nothing is changed.

### What Zenoh 1.10.1 provides

| | zenoh-c 1.10.1 (CRuby) | zenoh-pico 1.10.1 (boards, mruby, browser) |
|---|---|---|
| A querier attaching its source (ZID + entity id) to a get | `z_get_options_t.source_info` (unstable API; the prebuilt library has it) | `z_get_options_t.source_info`, only with `Z_FEATURE_UNSTABLE_API` |
| The callee reading it | `z_query_source_info()` (unstable) | `z_query_source_info()` (present without the define, but nothing can be set without it) |
| Default | not set (checked: a put's `source_zid` is nil; a get sets nothing) | not set (`z_get_options_default` leaves it NULL) |
| A reply's replier ZID | `z_reply_replier_id()`: exposed by asterism-zenoh as `Reply#replier_zid` | `z_reply_replier_id()` (unstable) |
| What the bindings expose today | `Sample#source_zid`, `Reply#replier_zid`; **not** `Query#source_zid`, **not** a `source_info:` option of `get` | nothing of this (picoruby-asterism-zenoh builds without `Z_FEATURE_UNSTABLE_API`) |

The decisive fact: **the source info is written by the querier itself.**
`z_source_info_new()` takes any ZID, and nothing in the API or the
router's configuration compares it with the session that sent the message
(not tried on the wire: neither binding can set it yet) (the router knows
the real ZID of each session attached to it, but there is no API for a
callee further away to learn it). Liveliness tokens do not carry the ZID
of their declarer either. So, with Zenoh 1.10.1 alone, a callee can check
that a caller is **consistent** (the node it claims and the ZID it claims
belong together), not that it is **authentic**: a modified client can
claim another node's ZID as easily as its name.

### Option C as it can be built

1. **Claim.** The caller's gem attaches `{"from" => <node ID>}` to every
   call as the query's attachment (MessagePack). Protocol 0 receivers
   ignore attachments, so this is compatible at once. Applications stop
   passing their ID by hand.
2. **Bind ZID to node.** Each application declares, next to its node
   token, a liveliness token `asterism/<node>/@zid/<zid>` (a verbatim
   chunk: protocol 0 watchers on `asterism/**` do not see it). Since 0.6.0
   one application is one session, so node and ZID are 1:1 per
   application (a node with two applications has two ZIDs, both bound).
3. **Check.** The caller's gem also sets the get's source info to its own
   session's ZID (binding additions below). The callee's gem compares:
   the claimed node, the query's source ZID, and the bindings it has seen.
4. **Hand it to the method** (API, see below), with how far it was checked.

| Case | What the callee gets |
|---|---|
| no attachment (a protocol 0 caller, a plain Zenoh or ROS 2 querier) | caller unknown (nil) |
| a claim, no source ZID (a board before its binding has the unstable API) | the node, marked **claimed** |
| a claim whose source ZID is bound to that node | the node, marked **consistent** |
| a claim whose source ZID is bound to another node, or a ZID with no binding while the claimed node has one | **mismatch**: the call is refused with `["error", "Asterism::CallerMismatch", ...]` (R-9 kind `caller`) |

On CRuby all of this can be built over zenoh-c (asterism-zenoh adds
`get(source_info: true)` and `Query#source_zid`). On the boards, mruby
and the browser build, picoruby-asterism-zenoh would have to build
zenoh-pico with `Z_FEATURE_UNSTABLE_API` (other structures change with it;
to be measured for size and RAM) and expose the same two calls; until then
their calls are **claimed** and, as callees, they can only report claims.

### Through routers and from browsers

- **A home router that forwards to a cloud router**: the source info is
  part of the request message and is forwarded with it (by design; not
  checked here, because neither binding exposes it yet). Either way it is
  still what the caller wrote.
- **Real verification needs the router.** zenohd's access control (ACL)
  allows or denies each message type (put, query, liveliness token, ...)
  by key expression and by subject: the client certificate's common name
  (mutual TLS, W1), a username, or the network interface. That makes a
  router able to vouch for the **key** a client uses, not for anything in
  the payload or the source info. Option C becomes authentic only if the
  claim is put in the key and the router restricts it: for example calls
  sent to `asterism/<node>/<app>/<object>/call/<caller>`, with an ACL rule
  per caller that lets the certificate `<caller>` query only keys ending
  in `/<caller>` (W2 already generates the cloud router's ACL from the
  console's ledger, so the rules can be generated the same way). That key
  has six chunks: protocol 0 callees do not answer it, so it is protocol 1
  and needs R-13.
- **Boards** have no TLS: they reach the internet through a router on
  their own network. That router can only tell them apart by interface or
  address, so their claims are as good as the trust in that network.
- **Browser nodes** connect over WebSocket (behind the `wss://` relay with
  its one-time password). zenohd sees the relay's connection, not a client
  certificate; zenoh-pico 1.10.1 defines the user and password
  configuration keys but does not use them (no user/password
  authentication). Their calls are
  **claimed**, whatever the gem does, unless the relay itself becomes the
  router that applies the ACL.

### The API (options)

- a. `Asterism.caller` during a call: short, but it shadows Ruby's
  `Kernel#caller` (the backtrace) for the module, and readers will confuse
  the two.
- b. `Asterism.current_call` during a call: an object with `from` (the
  node ID or nil), `verified` (`nil`, `:claimed`, `:consistent`, later
  `:router`), `object`, `method`; nil outside a call. Works the same on
  the boards (no threads: the call runs inside `Asterism.poll`).
- c. Opt-in keyword injection: `Asterism.expose(name, obj, methods: ...,
  caller: :from)` passes `from: <node>` to each method and refuses a call
  that brings its own `from:`. It fits the existing `from:` methods of
  rover_brain, but hides the verification level.

**Recommendation.** b, plus c as a migration aid for the methods that
already take `from:`. Steps: (1) the claim in the attachment and
`Asterism.current_call` (compatible, protocol 0, both Rubies); (2) the ZID
binding and source info (CRuby first, the boards after the unstable-API
build is measured); (3) router-verified callers in the key, protocol 1,
for the internet routers with mutual TLS. Without (3), document that
`from` is a convenience against mistakes, not access control; access
control stays the router's ACL (W1/W2).

**What is missing for option C**: in asterism-zenoh, `get(source_info:)`
and `Query#source_zid` (zenoh-c has both); in picoruby-asterism-zenoh, the
unstable-API build of zenoh-pico and the same two calls; in Zenoh itself,
any way for a callee to learn a querier's ZID that the querier cannot
choose (none in 1.10.1). The fallback is the claim alone (step 1), and the
router's ACL with the claim in the key (step 3) where authentication
matters.

## R-15. Malformed input the receivers disagree on

**Now** (protocol.md 3.3, captured): the boards ignore bytes after a value
and read bin and ext as nil; CRuby refuses trailing bytes and reads bin as
a String.

**Recommendation.** The spec says: a payload MUST be exactly one value
(trailing bytes are malformed); a receiver MUST NOT turn a type it cannot
read into nil (it is malformed). The fixes are in the boards' MessagePack
(fmruby-core `picoruby-fmrb-msgpack`: check that `msgpack_unpack_next`
used every byte; error on unsupported types) and need no version: no
protocol 0 sender writes these.

## R-16. Node tokens shared by applications

**Now.** Every application of a node declares the same `asterism/<node>`
token; when one closes, a watcher may see the node go while another
application still runs (README, Limits).

**Options.** A. Keep. B. Also declare `asterism/<node>/<app>` (two
chunks): protocol 0 watchers ignore two-chunk keys, so it is compatible; a
protocol 1 watcher counts a node alive while any of its application tokens
is.

**Recommendation.** B in protocol 1's set of additions (no number needed).

## R-17. Zenoh error replies

**Now.** Asterism never uses them, and callers ignore them (a Zenoh error
reply looks like "nobody answers").

**Recommendation.** Keep, and say it in the spec (done: protocol.md 4.5),
so that an implementation in another language does not answer with
`reply_err`.

## Decisions

Answer by number (the recommendation in brackets):

1. R-1 arguments: keep `[method, args, kwargs]`; receivers of protocol 1
   also accept `[method, args]`? [yes]
2. R-2 Symbols travel as strings and come back as strings? [yes, document]
3. R-3 portable map keys: str and int (A), str only (B), anything (C)? [A]
4. R-4 integers: signed 64-bit only, CRuby refuses others with
   `EncodeError`? [yes]
5. R-5 an integral float may arrive as an int from JavaScript: document
   only? [yes]
6. R-6 time: int nanoseconds since the epoch by convention (A), or the
   timestamp ext (B)? [A now]
7. R-7 bytes: str for everything (A), bin for binary in protocol 1 (B), only
   the icon as bin (C)? [B, receivers first]
8. R-8 nil and absent keywords differ: document? [yes]
9. R-9 errors: add the fourth element `{"kind" => ...}`? [yes]
10. R-10 method names: opaque, with a portable-name guideline and a
    generic call form? [yes]
11. R-11 arity: keep `[name, n]` for now? [yes]
12. R-13 protocol version: a profile field `protocol`, absent = 0? [yes]
13. R-14 caller identity: API `Asterism.current_call` (b), plus
    `caller: :from` injection (c)? Steps 1-3 as written? Refuse on
    mismatch? [b + c; steps 1-3; refuse]
14. R-15 trailing bytes and unreadable types are malformed (fix the boards'
    MessagePack)? [yes]
15. R-16 add the application token `asterism/<node>/<app>`? [yes]
