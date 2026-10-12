# Asterism compared with dRuby and Rinda

Asterism is close in spirit to dRuby: a Ruby object somewhere else is called
through a local proxy. Rinda, on top of dRuby, adds a tuple space and a way
to find it. This page lists what Asterism keeps from them, what it gives up,
and why: Asterism puts Ruby object calls on a network where microcontrollers
(mruby / PicoRuby), browsers (wasm), CRuby and ROS 2 nodes mix, over Zenoh.

## dRuby

| | dRuby | Asterism |
|---|---|---|
| Calling | a method on a proxy (`DRbObject`) runs on the other side | a method on a proxy (`net["node/app/obj"]`) runs on the other side |
| An exception on the other side | raised on the caller's side | raised on the caller's side (`RemoteError`, with a language-neutral `remote_kind`) |
| Connection | direct TCP to `druby://host:port` | through a Zenoh router (or a peer); routers relay, so calls cross the internet |
| Finding the other side | you know its URI (Rinda's ring server can help) | liveliness: `on_join` / `on_leave` as nodes and apps come and go |
| What travels | Marshal (Ruby objects almost as they are) | MessagePack values only (numbers, strings, binary, arrays, maps; [protocol.md](protocol.md)) |
| References and blocks | passed (`DRbUndumped` objects stay remote; blocks are called back) | **not passed**: values only; no remote references, no blocks |
| What can be called | any public method of the front object | only the methods listed in `expose(..., methods:)` |
| Security | yours to add (Marshal is unsafe with untrusted peers) | TLS, certificates and ACLs at the routers; the callee knows the caller (`Asterism.current_call`) |
| Where it runs | CRuby | CRuby, mruby / PicoRuby boards, the browser (wasm) |
| Call style | synchronous (block until the answer; threads for concurrency) | asynchronous and polled on boards (`Asterism.poll`); blocks and a receiving thread on CRuby |
| Also | Rinda | put / subscribe, ROS 2 nodes on the same session, node profiles (name, icon) |

What was given up, and why:

- **References and blocks**: a remote object's lifetime and garbage
  collection cannot be shared with a microcontroller or an untrusted peer.
- **Marshal**: its format differs between Ruby implementations and is
  unsafe with peers you do not trust; MessagePack is read by every language
  (the protocol is language-neutral, with conformance samples).
- **Synchronous calls**: a board that blocks stops its screen and input, and
  each call back from C into Ruby deepens the stack.

What was gained: microcontrollers, browsers and ROS 2 on the same network;
presence (who is here); relaying across the internet; certificates and
ACLs; a console that draws the network, records it and rewinds it.

## Rinda

| | Rinda (on dRuby) | Asterism (on Zenoh) |
|---|---|---|
| Where data lives | one `TupleSpace` in one process; everyone writes to it and reads from it | nowhere by default: a `put` reaches whoever subscribes at that moment (add a Zenoh storage to keep values) |
| Writing | `write(tuple, expiry)` | `Asterism.session.put(key, value)` |
| Reading and waiting | `read` / `take(pattern)` block until a match arrives | `subscribe(key_expr)`: delivered when it arrives (polled); nothing blocks |
| Taking for one consumer | `take` hands a tuple to exactly one taker, atomically | **none**: every subscriber gets it. To hand work to one consumer, put an object in charge and call it |
| Matching | tuple patterns (`nil` matches anything; classes, regexps, ranges with `===`) | key expressions (`*`, `**`) choose keys; filter on values after receiving |
| Hearing about changes | `notify(event, pattern)` (write / take / delete) | `subscribe` (put / delete); liveliness (`on_join` / `on_leave`) |
| Finding peers | `RingServer` / `RingFinger` over UDP broadcast (one LAN) | liveliness tokens, through routers, so the same across the internet |
| Expiry and presence | tuple expiry and renewers | a liveliness token exists while its session is connected |
| Weak spot | the process holding the TupleSpace is a single point of failure; security is yours | no atomic "take for one"; ordering is per key |
| Security | yours to add | TLS, certificates, ACLs |

In short: Rinda is a shared blackboard you write to and take from; Asterism
streams values to whoever listens. Handing a job to exactly one worker is
one `take` in Rinda; in Asterism it needs an owner — an object that holds
the queue and answers calls. A small TupleSpace object exposed over
Asterism (write / take / read) brings Rinda's style back, with that
object's node as the one place the tuples live.
