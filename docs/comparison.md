# Asterism compared with dRuby and Rinda

A side-by-side comparison of the mechanisms of dRuby, Rinda and Asterism,
item by item. Asterism here is asterism 0.7.0 (wire protocol 1,
[protocol.md](protocol.md)) over Zenoh 1.10.1.

## dRuby

| | dRuby | Asterism |
|---|---|---|
| Calling | a method on a proxy (`DRbObject`) runs on the other side | a method on a proxy (`net["node/app/obj"]`) runs on the other side |
| An exception on the other side | raised on the caller's side | raised on the caller's side (`RemoteError`, with a language-neutral `remote_kind`) |
| Connection | direct TCP to `druby://host:port` | through a Zenoh router (or a peer); routers relay between networks |
| Finding the other side | you know its URI (Rinda's ring server can help) | liveliness: `on_join` / `on_leave` as nodes and apps come and go |
| What travels | Marshal (Ruby objects almost as they are) | MessagePack values only (numbers, strings, binary, arrays, maps; [protocol.md](protocol.md)) |
| References and blocks | passed (`DRbUndumped` objects stay remote; blocks are called back) | not passed: values only; no remote references, no blocks |
| What can be called | any public method of the front object | only the methods listed in `expose(..., methods:)` |
| Security | TLS (`drb/ssl`) and an IP-address ACL (`drb/acl`) come with it; there is no way to give different callers different methods, and Marshal is unsafe with untrusted peers | certificates and ACLs managed at the routers; the callee knows the caller (`Asterism.current_call`) |
| Where it runs | CRuby | CRuby, mruby / PicoRuby boards, the browser (wasm) |
| Call style | synchronous (block until the answer; threads for concurrency) | asynchronous and polled on boards (`Asterism.poll`); blocks and a receiving thread on CRuby |
| Calling many at once | loop over a proxy per peer yourself, one after another | collect them by a key expression (`net.each("*/rooms/*")`) and `each` / `map` over them |
| When nobody answers | no time limit by default (wrap calls in `Timeout` yourself) | every call has a time limit (`timeout:`); today a call that runs out raises, so `map` over many stops at the first one. How to return partial results (who answered, who did not) is still to be decided |
| Also | Rinda | put / subscribe, ROS 2 nodes on the same session, node profiles (name, icon) |

## Rinda

| | Rinda (on dRuby) | Asterism (on Zenoh) |
|---|---|---|
| Where data lives | one `TupleSpace` in one process; everyone writes to it and reads from it | nowhere by default: a `put` reaches whoever subscribes at that moment (add a Zenoh storage to keep values) |
| Writing | `write(tuple, expiry)` | `Asterism.session.put(key, value)` |
| Reading what is there now | `read(pattern)` (with a time limit of 0, it does not wait) | `get(key_expr)`: ask a queryable or a Zenoh storage for the current value |
| Waiting for what comes | `read` / `take(pattern)` block until a match arrives | `subscribe(key_expr)`: delivered when it arrives (polled); nothing blocks |
| Taking for one consumer | `take` hands a tuple to exactly one taker, atomically | none: every subscriber gets it; a single consumer is reached by calling one object |
| Matching | tuple patterns (`nil` matches anything; classes, regexps, ranges with `===`) | key expressions (`*`, `**`) choose keys; filter on values after receiving |
| Hearing about changes | `notify(event, pattern)` (write / take / delete) | `subscribe` (put / delete); liveliness (`on_join` / `on_leave`) |
| Finding peers | `RingServer` / `RingFinger` over UDP broadcast or multicast (usually within one LAN) | liveliness tokens, carried through routers |
| Expiry and presence | tuple expiry and renewers | a liveliness token exists while its session is connected |
| Single point and ordering | the process holding the TupleSpace; tuples are ordered by that one process | no single store (a router can be one); order is kept per sender and per key: writes from several nodes to the same key have no order between them |
| Security | dRuby's: TLS (`drb/ssl`) and an IP-address ACL (`drb/acl`) | certificates and ACLs at the routers |
