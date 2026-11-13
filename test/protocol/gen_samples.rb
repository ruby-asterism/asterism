# Writes test/protocol/samples.json, the conformance samples of
# docs/protocol.md. The JSON file is what implementations read (in any
# language); this script is only how it is kept. Run it after changing the
# samples and commit both:
#
#   ruby test/protocol/gen_samples.rb            # rewrites samples.json
#   ruby test/protocol/gen_samples.rb --check    # exits 1 when it is stale
#
# The bytes are written out by hand where the point is the encoding (the
# other valid forms a reader must accept); the rest are msgpack-ruby's,
# which is what the CRuby implementation sends.
require "json"
require "msgpack"
require_relative "tv"

ROOT = File.expand_path("../..", __dir__)
OUT = File.join(__dir__, "samples.json")

def pk(v) = MessagePack.pack(v).unpack1("H*")
def tv(v) = TV.from_ruby(v)
def i(n) = { "int" => n.to_s }
def f(x) = { "float" => x }
def m(*pairs) = { "map" => pairs }
ANY_STR = { "any" => "str" }.freeze
KIND_WORD = { "match" => "\\A[a-z][a-z0-9_]{0,31}\\z" }.freeze

IUT = "iut"
APP = "conf"
DRV = "drv"
ICON = File.binread(File.join(ROOT, "data", "icon.png"))
ICON_HASH = "2a8c0626"
MALFORMED = "malformed call (expected a map {\"method\" => name, \"args\" => [...], \"kwargs\" => {...}})"

# A reply value map and an error map, as typed values.
def value(x) = m(["value", x])
def error(kind, cls, msg) = m(["error", m(["kind", kind], ["class", cls], ["message", msg])])

# ------------------------------------------------------------ values
# Each is sent as the single argument of subject.echo
# ({"method" => "echo", "args" => [v]}); the answer must be
# {"value" => v}. encodings: every byte form of the value the sample sends
# (the first is what the CRuby implementation writes). expect: the replies
# when they are not that (a value the protocol does not carry is a
# malformed call).
values = []
v = ->(id, value, *extra, note: nil, portable: true, expect: nil) do
  value_tv = value.is_a?(Hash) && value.key?("__tv") ? value["__tv"] : tv(value)
  canonical = value.is_a?(Hash) && value.key?("__hex") ? value["__hex"] : pk(value)
  h = { "id" => id, "value" => value_tv, "encodings" => [canonical, *extra].uniq }
  h["note"] = note if note
  h["portable"] = portable
  h["expect"] = expect if expect
  values << h
end
raw = ->(hex, t) { { "__hex" => hex, "__tv" => t } }
echo_key = "asterism/#{IUT}/#{APP}/subject/call/#{DRV}"
malformed_reply = [{ "key" => echo_key, "payload" => error("malformed", "ArgumentError", MALFORMED) }]

v.("nil", nil)
v.("true", true)
v.("false", false)
v.("int 0", 0, "cc00", "d000")
v.("int 1", 1, "cc01", "cd0001", "ce00000001", "cf0000000000000001", "d001", "d10001", "d200000001", "d30000000000000001",
   note: "every integer form of 1 is the same value")
v.("int 127", 127)
v.("int 128", 128)
v.("int 255", 255)
v.("int 256", 256)
v.("int 65535", 65_535)
v.("int 65536", 65_536)
v.("int 2^31", 2**31)
v.("int 2^32", 2**32)
v.("int 2^63-1", 2**63 - 1, note: "the largest integer of the protocol")
v.("int -1", -1, "d0ff", "d3ffffffffffffffff")
v.("int -32", -32)
v.("int -33", -33)
v.("int -128", -128)
v.("int -129", -129)
v.("int -32768", -32_768)
v.("int -32769", -32_769)
v.("int -2^31", -(2**31))
v.("int -2^31-1", -(2**31) - 1)
v.("int -2^63", -(2**63), note: "the smallest integer of the protocol")
v.("float 1.5", 1.5, "ca3fc00000", note: "float32 is read as a float (answered as float64)")
v.("float 1.0", 1.0, note: "a float with an integral value stays a float")
v.("float 0.0", 0.0)
v.("float -2.5e-300", -2.5e-300)
v.("float 1e300", 1e300)
v.("float inf", Float::INFINITY)
v.("str empty", "", "d900", "da0000", "db00000000")
v.("str a", "a")
v.("str 31 bytes", "x" * 31)
v.("str 32 bytes", "y" * 32, "da0020" + "79" * 32, "db00000020" + "79" * 32,
   note: "str8 is the shortest form; str16 and str32 are read too")
v.("str 255 bytes", "z" * 255, "da00ff" + "7a" * 255)
v.("str 256 bytes", "w" * 256)
v.("str utf-8", "日本語 é")
v.("str with NUL", "a\u0000b")
v.("str not utf-8", raw.("a2ff00", { "str_hex" => "ff00" }),
   note: "a str carries bytes; a receiver keeps them as they came, also when they are not UTF-8")
v.("bin", "\xff\x00".b, "c50002ff00", "c600000002ff00", note: "binary data: bin, read as bytes and sent back as bin")
v.("bin empty", "".b, "c50000")
v.("bin 300 bytes", ("\x01" * 300).b)
v.("array empty", [], "dc0000", "dd00000000")
v.("array 3", [1, 2, 3], "dc0003010203")
v.("array 16", (1..16).to_a)
v.("array nested", [1, [2, [3, [nil]]], "s"])
v.("map empty", {}, "de0000", "df00000000")
v.("map str keys", { "a" => 1, "b" => [true] }, "de0002a16101a16291c3")
v.("map int keys", { 1 => "one", -2 => "minus two" }, note: "str and int are the portable keys")
v.("map 16", (1..16).to_h { |n| ["k#{n}", n] })
v.("map nested", { "outer" => { "inner" => [{}] } })
v.("mixed", [nil, true, 1, 1.5, "s", "b".b, [], {}])
# Not values of the protocol: the call is malformed.
v.("uint64 above 2^63-1", raw.("cfffffffffffffffff", i(2**64 - 1)), "cf8000000000000000",
   expect: malformed_reply, note: "outside the signed 64-bit range: not a value of the protocol")
v.("ext", raw.("d40100", nil), "c70101ff", expect: malformed_reply, note: "ext types are not values of the protocol")
v.("timestamp ext", raw.("d6ff00000000", nil), expect: malformed_reply,
   note: "times are int nanoseconds since the epoch by convention, not the timestamp ext")

# ------------------------------------------------------------ incoming
# Gets the driver sends to the implementation under test (node iut, app
# conf), and the replies it must give (an empty list: no reply at all).
# The driver calls as node drv: the call key's last chunk.
base = "asterism/#{IUT}/#{APP}"
call_key = "#{base}/subject/call/#{DRV}"
inc = []
q = ->(id, key, payload_hex, replies, params: nil, note: nil, portable: true) do
  h = { "id" => id, "key" => key, "params" => params, "payload_hex" => payload_hex, "replies" => replies }
  h["note"] = note if note
  h["portable"] = portable
  inc << h
end
req = ->(method, args = nil, kwargs = nil) do
  r = { "method" => method }
  r["args"] = args if args
  r["kwargs"] = kwargs if kwargs
  pk(r)
end
ok = ->(x, key = call_key) { [{ "key" => key, "payload" => value(x) }] }
err = ->(kind, cls, msg, key = call_key) { [{ "key" => key, "payload" => error(kind, cls, msg) }] }
bad = ->(id, payload_hex, note: nil) { q.(id, call_key, payload_hex, err.("malformed", "ArgumentError", MALFORMED), note: note) }

q.("call add", call_key, req.("add", [2, 3]), ok.(i(5)))
q.("call with an empty kwargs map", call_key, req.("add", [2, 3], {}), ok.(i(5)))
q.("call kwargs", call_key, req.("kw", [1], { "b" => 2 }), ok.([i(1), i(2), nil]))
q.("call kwargs two", call_key, req.("kw", [1], { "c" => "x", "b" => 2 }), ok.([i(1), i(2), "x"]))
q.("call kwargs nil", call_key, req.("kw", [1], { "b" => nil }), ok.([i(1), nil, nil]),
  note: "a keyword given as nil and a keyword left out are different on the wire (the callee's default applies to the absent one)")
q.("call no args key", call_key, req.("any"), ok.(i(0)), note: "args absent: no positional arguments")
q.("call unknown keyword", call_key, req.("kw", [1], { "z" => 2 }), err.("raised", "ArgumentError", ANY_STR),
  note: "the message is the language's own")
q.("call method with ?", call_key, req.("ok?"), ok.(true))
q.("call any arity, 3", call_key, req.("any", [1, 2, 3]), ok.(i(3)))
q.("call any arity, 0", call_key, req.("any", []), ok.(i(0)))
q.("call ignores unknown request keys", call_key, pk({ "method" => "add", "args" => [1, 2], "later" => true }), ok.(i(3)),
  note: "room for later additions to the request")
q.("call wrong arity", call_key, req.("add", [1]),
  err.("arguments", "ArgumentError", "wrong number of arguments (given 1, expected 2)"))
q.("call not exposed", call_key, req.("secret"),
  err.("not_exposed", "NoMethodError", "undefined method 'secret' for #{IUT}/#{APP}/subject (not exposed)"))
q.("call no such method", call_key, req.("nope"),
  err.("not_exposed", "NoMethodError", "undefined method 'nope' for #{IUT}/#{APP}/subject (not exposed)"))
q.("call raises", call_key, req.("boom"), err.("raised", "RuntimeError", "boom"),
  note: "the class name and message of the exception the method raised")
q.("call no such object", "#{base}/nothing/call/#{DRV}", req.("echo", [1]),
  err.("no_object", "NameError", "no object nothing exposed by #{IUT}/#{APP}", "#{base}/nothing/call/#{DRV}"))
q.("call returns what cannot be sent", call_key, req.("unsendable"),
  err.("unsendable", "Asterism::EncodeError", { "match" => "\\Athe return value: " }))
q.("call reports the caller", call_key, req.("whoami"), ok.(["drv", "claimed", "subject", "whoami"]),
  note: "the callee learns the caller from the key's last chunk")
q.("call another caller", "#{base}/subject/call/someone", req.("whoami"),
  ok.(["someone", "claimed", "subject", "whoami"], "#{base}/subject/call/someone"),
  note: "the caller chunk is a claim: only a router's access control makes it binding")
bad.("malformed: an array (protocol 0's form)", pk(["add", [2, 3], {}]))
bad.("malformed: no method", pk({ "args" => [1] }))
bad.("malformed: method empty", req.(""))
bad.("malformed: method an int", pk({ "method" => 5 }))
bad.("malformed: args a map", pk({ "method" => "add", "args" => {} }))
bad.("malformed: args nil", pk({ "method" => "add", "args" => nil }))
bad.("malformed: kwargs an array", pk({ "method" => "kw", "args" => [1], "kwargs" => [] }))
bad.("malformed: kwargs with an int key", pk({ "method" => "kw", "args" => [1], "kwargs" => { 1 => 2 } }))
bad.("malformed: no payload", nil)
bad.("malformed: not MessagePack", "c1")
bad.("malformed: trailing bytes", req.("add", [2, 3]) + "00", note: "a payload is exactly one value")
bad.("malformed: two values", req.("add", [2, 3]) + req.("add", [2, 3]))
q.("protocol 0 call (no caller chunk)", "#{base}/subject/call", pk(["add", [2, 3], {}]),
  err.("protocol", "Asterism::Error", ANY_STR, "#{base}/subject/call"),
  note: "a call on protocol 0's key is refused at once, whatever its payload")
q.("ignored: object *", "#{base}/*/call/#{DRV}", req.("echo", [1]), [])
q.("ignored: caller *", "#{base}/subject/call/*", req.("echo", [1]), [],
  note: "the caller chunk must be a name: a wildcard is not answered (the method is not run)")
q.("ignored: caller **", "#{base}/subject/call/**", req.("echo", [1]), [])
q.("ignored: caller verbatim", "#{base}/subject/call/@x", req.("echo", [1]), [])
q.("ignored: another kind", "#{base}/subject/other", req.("echo", [1]), [])
q.("ignored: seven chunks", "#{call_key}/x", req.("echo", [1]), [])
q.("ignored: meta with six chunks", "#{base}/subject/meta/#{DRV}", nil, [])
q.("ignored: node and app only", base, nil, [])
q.("call through a wildcard node", "asterism/*/#{APP}/subject/call/#{DRV}", req.("add", [1, 1]), ok.(i(2)),
  note: "the reply key is the object's own key, not the query's")
q.("call through **", "asterism/#{IUT}/**/subject/call/#{DRV}", req.("add", [1, 2]), ok.(i(3)))
meth = ->(name, n) { m(["name", name], ["arity", i(n)]) }
meta_subject = m(["methods", { "unordered" => [meth.("echo", 1), meth.("kw", 1), meth.("add", 2), meth.("boom", 0),
                                                meth.("any", -1), meth.("ok?", 0), meth.("unsendable", 0),
                                                meth.("whoami", 0)] }])
meta_other = m(["methods", [m(["name", "ping"], ["arity", i(0)], ["args", []], ["doc", "Answers pong."])]],
               ["doc", "Another object."])
q.("meta", "#{base}/subject/meta", nil,
  [{ "key" => "#{base}/subject/meta", "payload" => meta_subject }],
  note: "arity -1: any number of arguments (exposed without counts)")
q.("meta ignores a payload", "#{base}/other/meta", req.("x"),
  [{ "key" => "#{base}/other/meta", "payload" => meta_other }],
  note: "the arguments' names and the descriptions given at expose (args, doc; the object's own doc)")
q.("meta of every object", "#{base}/*/meta", nil,
  [{ "key" => "#{base}/subject/meta", "payload" => meta_subject },
   { "key" => "#{base}/other/meta", "payload" => meta_other }],
  note: "one reply per exposed object, in any order")
q.("meta of no such object", "#{base}/nothing/meta", nil, [],
  note: "no reply (the caller sees nobody answer)")
prof = ->(icon) do
  pairs = [["protocol", i(2)], ["kind", KIND_WORD], ["name", "iut"]]
  pairs << ["icon", { "bin_hex" => ICON.unpack1("H*") }] if icon
  pairs << ["icon_hash", ICON_HASH]
  [{ "key" => "asterism/#{IUT}/@profile", "payload" => m(*pairs) }]
end
q.("profile", "asterism/#{IUT}/@profile", nil, prof.(true), note: "the icon is a bin")
q.("profile icon=0", "asterism/#{IUT}/@profile", nil, prof.(false), params: "icon=0")
q.("profile icon=no among others", "asterism/#{IUT}/@profile", nil, prof.(false), params: "x=1;icon=no")
q.("profile icon=false", "asterism/#{IUT}/@profile", nil, prof.(false), params: "icon=false")
q.("profile icon=1", "asterism/#{IUT}/@profile", nil, prof.(true), params: "icon=1")
q.("profile not under **", "asterism/#{IUT}/**", nil, [],
  note: "@profile is a verbatim chunk: ** does not reach it, and nothing else answers asterism/<node>/**")
q.("profile not under *", "asterism/*/@profile", nil, prof.(true), note: "a wildcard node does reach it")
# The application's own profile: its status, its topics (declared by the
# implementation under test after connecting) and its types (defined before).
app_prof = "asterism/#{IUT}/#{APP}/@profile"
st_tv = m(["st", "wait"], ["n", i(1)])
# The two shared ones (docs/protocol.md 17) are declared under their
# entries: the node's place "<node>/@shared/<name>", the network's
# "@shared/<name>".
shared_tv = [["#{IUT}/@shared/score", m(["t", i(1)])],
             ["@shared/lobby/hello", m(["t", i(7)], ["ts", true])]]
pubs_tv = m(["imu", m(["t", i(2)], ["u", "m/s2"], ["d", "acceleration"], ["ts", true])],
            ["board1/strokes", m(["t", "conf/stroke"])],
            ["camera", m(["t", i(4)], ["e", i(17)])], *shared_tv)
types_tv = m(["conf/stroke", m(["f", [["pts", "int[]"], ["color", "str"], ["at", i(2)], ["path", "vector3[]"],
                                     ["pose", "pose"], ["grid", "int[][]"], ["extra", "any"]]], ["d", "one stroke"])])
ap = ->(*pairs) { [{ "key" => app_prof, "payload" => m(*pairs) }] }
q.("app profile", app_prof, nil, ap.(["status", st_tv], ["pubs", pubs_tv]),
  note: "without parameters: the status and the topics (the types only when asked for)")
q.("app profile ?status", app_prof, nil, ap.(["status", st_tv]), params: "status")
q.("app profile ?pubs", app_prof, nil, ap.(["pubs", pubs_tv]), params: "pubs",
  note: "t: a built-in type's number or an application type's name; e: the encoding's number (image/jpeg is 17)")
q.("app profile ?types", app_prof, nil, ap.(["types", types_tv]), params: "types",
  note: "f: [name, type] pairs (a built-in type's number or name, a basic type, another type's name; [] for an array)")
q.("app profile two parts", app_prof, nil, ap.(["status", st_tv], ["types", types_tv]), params: "status;types")
q.("app profile unknown parameters", app_prof, nil, ap.(["status", st_tv], ["pubs", pubs_tv]), params: "x=1",
  note: "parameters naming no part: the default reply")
q.("app profile under */*", "asterism/*/*/@profile", nil, ap.(["status", st_tv], ["pubs", pubs_tv]),
  note: "wildcard node and app chunks reach it (a node's profile has one chunk less)")
q.("app profile not under **", "#{base}/**", nil, [],
  note: "@profile is a verbatim chunk: asterism/<node>/<app>/** does not reach it")
q.("nothing answers @status", "asterism/#{IUT}/#{APP}/@status", nil, [],
  note: "the status is only put there; it is asked for at @profile?status")
q.("app profile of no such app", "asterism/#{IUT}/nothing/@profile", nil, [],
  note: "an application that is not there answers nothing")
q.("method name as bin", call_key, pk({ "method" => "add".b, "args" => [2, 3] }),
  [{ "key" => call_key, "payload" => { "any" => "value" } }], portable: false,
  note: "the name is a str; the Ruby implementations also take a bin name by its bytes (answered 5)")

# ------------------------------------------------------------ outgoing
# What the implementation under test does, in this order, to the driver's
# node drv (app conf, object rec). After each step it calls
# rec.report(id, outcome) (docs/protocol.md 11.4). The request is checked
# after reading absent args / kwargs as empty (a sender may leave them out).
rec = "asterism/#{DRV}/#{APP}/rec"
rec_call = "#{rec}/call/#{IUT}"
outs = []
o = ->(id, act, request, reply_hex, outcome, note: nil) do
  h = { "id" => id, "do" => act, "request" => request, "reply_hex" => reply_hex, "outcome" => outcome }
  h["note"] = note if note
  outs << h
end
call = ->(method, args = [], kwargs = []) { { "call" => method, "args" => args, "kwargs" => m(*kwargs) } }
reqc = ->(method, args = [], kwargs = []) do
  { "key" => rec_call, "params" => "", "call" => { "method" => method, "args" => args, "kwargs" => m(*kwargs) } }
end
okv = ->(x) { [pk({ "value" => x })] }
o.("plain", call.("plain"), reqc.("plain"), okv.(nil), ["ok", nil],
  note: "the caller's node ID is the call key's last chunk")
o.("arguments", call.("args", [i(1), "two", f(3.0), nil, true, false]),
  reqc.("args", [i(1), "two", f(3.0), nil, true, false]),
  okv.([1, "two", 3.0, nil, true, false]), ["ok", [i(1), "two", f(3.0), nil, true, false]])
o.("keywords", { "call" => "kw", "args" => [i(1)], "kwargs" => m(["tag", "sym"], ["n", i(2)]),
                 "ruby" => "rec.kw(1, tag: :sym, n: 2)" },
  reqc.("kw", [i(1)], [["tag", "sym"], ["n", i(2)]]), okv.("kw"), ["ok", "kw"],
  note: "keyword names and Symbol values go as str")
o.("symbols and hashes", { "call" => "sym", "args" => ["abc", m(["a", i(1)], ["b", "c"])],
                           "kwargs" => m, "ruby" => "rec.sym(:abc, { a: 1, \"b\" => :c })" },
  reqc.("sym", ["abc", m(["a", i(1)], ["b", "c"])]), okv.({ "a" => 1 }), ["ok", m(["a", i(1)])],
  note: "Symbols, also as map keys, go as str; they come back as str")
o.("nesting", call.("nest", [[[i(1), [i(2)]], m(["k", [m]])]]),
  reqc.("nest", [[[i(1), [i(2)]], m(["k", [m]])]]), okv.([[1, [2]], { "k" => [{}] }]),
  ["ok", [[i(1), [i(2)]], m(["k", [m]])]])
o.("numbers", call.("num", [i(2**62), i(-(2**62)), f(1.0), i(0)]),
  reqc.("num", [i(2**62), i(-(2**62)), f(1.0), i(0)]), okv.(2**63 - 1), ["ok", i(2**63 - 1)])
o.("utf-8", call.("utf8", ["日本語"]), reqc.("utf8", ["日本語"]), okv.("é"), ["ok", "é"])
o.("bytes", { "call" => "bytes", "args" => [{ "bin_hex" => "ff00" }], "kwargs" => m, "ruby" => "rec.bytes(\"\\xff\\x00\".b)" },
  reqc.("bytes", [{ "bin_hex" => "ff00" }]), okv.("\x01\x02".b), ["ok", { "bin_hex" => "0102" }],
  note: "a binary String goes as a bin, and a bin comes back as one")
o.("remote error", call.("oops"), reqc.("oops"),
  [pk({ "error" => { "kind" => "raised", "class" => "KeyError", "message" => "missing key" } })],
  ["error", "KeyError", "missing key", "raised"], note: "RemoteError with the kind, class name and message as they came")
o.("remote error, namespaced class", call.("oops2"), reqc.("oops2"),
  [pk({ "error" => { "kind" => "unsendable", "class" => "Asterism::EncodeError",
                     "message" => "the return value: cannot send a Object" } })],
  ["error", "Asterism::EncodeError", "the return value: cannot send a Object", "unsendable"])
o.("remote error without a kind", call.("oops3"), reqc.("oops3"),
  [pk({ "error" => { "class" => "Oops", "message" => "m" } })], ["error", "Oops", "m", nil],
  note: "a missing kind is unknown (nil)")
o.("an error wins over a value", call.("both"), reqc.("both"),
  [pk({ "value" => 1, "error" => { "kind" => "raised", "class" => "E", "message" => "m" } })],
  ["error", "E", "m", "raised"])
o.("malformed answer, not MessagePack", call.("bad1"), reqc.("bad1"), ["c1"], ["failed", ANY_STR])
o.("malformed answer, protocol 0's array", call.("bad2"), reqc.("bad2"), [pk(["ok", 1])], ["failed", ANY_STR])
o.("malformed answer, neither value nor error", call.("bad3"), reqc.("bad3"), [pk({ "huh" => 1 })], ["failed", ANY_STR])
o.("malformed answer, error not a map", call.("bad4"), reqc.("bad4"), [pk({ "error" => "x" })], ["failed", ANY_STR])
o.("no answer", call.("silent"), reqc.("silent"), [], ["timeout"],
  note: "the get ends without a reply: the caller does not wait for the time limit")
o.("two answers, the first wins", call.("twice"), reqc.("twice"), [pk({ "value" => 1 }), pk({ "value" => 2 })], ["ok", i(1)])
o.("meta", { "respond_to" => ["plain", "x?", "nope"], "ruby" => "[:plain, :x?, :nope].map { |n| rec.respond_to?(n) }" },
  { "key" => "#{rec}/meta", "params" => "", "payload" => nil },
  [pk({ "methods" => [{ "name" => "plain", "arity" => 0 }, { "name" => "x?", "arity" => -1 }] })], ["ok", [true, true, false]],
  note: "the meta is fetched once per proxy")
o.("profile without the icon", { "profile_of" => DRV, "icon" => false },
  { "key" => "asterism/#{DRV}/@profile", "params" => "icon=0", "payload" => nil },
  [pk({ "protocol" => 2, "kind" => "cruby", "name" => "drv", "host" => 5, "extra" => 1, "icon_hash" => "0000abcd" })],
  ["ok", m(["protocol", i(2)], ["kind", "cruby"], ["name", "drv"], ["icon_hash", "0000abcd"])],
  note: "the reader keeps only the known fields that pass their checks")
o.("profile with the icon", { "profile_of" => DRV, "icon" => true },
  { "key" => "asterism/#{DRV}/@profile", "params" => "", "payload" => nil },
  [pk({ "protocol" => 2, "kind" => "cruby", "icon" => ICON, "icon_hash" => "ffffffff" })],
  ["ok", m(["protocol", i(2)], ["kind", "cruby"], ["icon", { "bin_hex" => ICON.unpack1("H*") }], ["icon_hash", ICON_HASH])],
  note: "icon_hash is computed again from the icon; the one sent is not trusted")
o.("profile without a protocol", { "profile_of" => DRV, "icon" => false },
  { "key" => "asterism/#{DRV}/@profile", "params" => "icon=0", "payload" => nil },
  [pk({ "kind" => "cruby" })], ["ok", m(["kind", "cruby"])], note: "a node without a protocol field (protocol 0)")
o.("profile that is not one", { "profile_of" => DRV, "icon" => false },
  { "key" => "asterism/#{DRV}/@profile", "params" => "icon=0", "payload" => nil },
  [pk({ "kind" => "Not A Word" })], ["ok", nil], note: "no valid kind: no profile (nil)")
o.("change the profile", { "set_profile" => m(["name", "iut 2"]) }, nil, [], ["ok", nil],
  note: "the change is put on asterism/iut/@profile (see profile_puts)")
drv_prof = "asterism/#{DRV}/#{APP}/@profile"
askp = ->(part) { { "key" => drv_prof, "params" => part, "payload" => nil } }
o.("status of another app", { "status_of" => [DRV, APP] }, askp.("status"),
  [pk({ "status" => { "seats" => 2, 5 => "x", "" => 1, "list" => [1, { "a" => nil }] } })],
  ["ok", m(["seats", i(2)], ["list", [i(1), m(["a", nil])]])],
  note: "asked at the application's profile with ?status; the reader keeps the entries with a non-empty str key")
o.("status that is not one", { "status_of" => [DRV, APP] }, askp.("status"),
  [pk({ "status" => [1, 2] })], ["ok", nil], note: "not a map: no status (nil)")
o.("status too large", { "status_of" => [DRV, APP] }, askp.("status"),
  [pk({ "status" => { "big" => "x" * 1100 } })], ["ok", nil], note: "more than 1024 bytes: no status (nil)")
o.("status left out", { "status_of" => [DRV, APP] }, askp.("status"),
  [pk({})], ["ok", nil], note: "an application without a status leaves the part out: no status (nil)")
o.("app profile that is not a map", { "status_of" => [DRV, APP] }, askp.("status"),
  [pk([1, 2])], ["ok", nil], note: "no status (nil)")
o.("no status", { "status_of" => [DRV, APP] }, askp.("status"),
  [], ["ok", nil], note: "nobody answers: no status (nil), not an error")
o.("topics of another app", { "pubs_of" => [DRV, APP] }, askp.("pubs"),
  [pk({ "pubs" => { "a" => { "t" => 2, "x" => 1 }, "b/c" => { "t" => "x/y", "e" => 17, "u" => "m", "d" => "d", "ts" => true },
                    "odd" => { "t" => 0, "e" => "jpeg", "ts" => 1, "u" => 5 }, 5 => {}, "nomap" => 1,
                    "@shared/g/h" => { "t" => 1 }, "#{DRV}/@shared/s" => { "t" => 7 }, "other/@shared/s" => { "t" => 7 },
                    "@other/x" => {}, "@shared" => {}, "a/*" => {} } })],
  ["ok", m(["a", m(["t", i(2)])], ["b/c", m(["t", "x/y"], ["e", i(17)], ["u", "m"], ["d", "d"], ["ts", true])],
           ["odd", m], ["@shared/g/h", m(["t", i(1)])], ["#{DRV}/@shared/s", m(["t", i(7)])])],
  note: "the reader keeps the declarations (maps under a str name that is a topic of the application's own or a " \
        "shared entry of the network's place or the application's own node's) and their known keys that pass; " \
        "another node's place, another verbatim chunk, a name that is not one are left out")
o.("no topics", { "pubs_of" => [DRV, APP] }, askp.("pubs"), [pk({ "status" => {} })], ["ok", m],
  note: "an application that answers without topics has none (an empty map)")
o.("topics of nobody", { "pubs_of" => [DRV, APP] }, askp.("pubs"), [], ["ok", nil],
  note: "nobody answers: nil")
o.("types of another app", { "types_of" => [DRV, APP] }, askp.("types"),
  [pk({ "types" => { "x/p" => { "f" => [["x", "float"], ["y", 1]], "d" => "a point", "z" => 1 },
                     "x/bad" => { "f" => [["x"]] }, "x/nof" => {} } })],
  ["ok", m(["x/p", m(["f", [["x", "float"], ["y", i(1)]]], ["d", "a point"])])],
  note: "the reader keeps the definitions whose f is a list of [str, int or str]")
o.("change the status", { "set_status" => m(["st", "play"], ["n", i(1)]) }, nil, [], ["ok", nil],
  note: "the change is put on asterism/iut/conf/@status (see status_puts)")
o.("the same status again", { "set_status" => m(["st", "play"], ["n", i(1)]) }, nil, [], ["ok", nil],
  note: "nothing is put (see status_puts)")
JPEG = "\xff\xd8\xff\xe0JFIF\xff\xd9".b
stroke = m(["pts", [i(1), i(2)]], ["color", "red"], ["at", [i(0), i(0), i(0)]])
o.("put values", { "put" => [["imu", [f(1.5), i(-2), f(9.8)]], ["camera", { "bin_hex" => JPEG.unpack1("H*") }],
                             ["board1/strokes", stroke], ["imu", [f(1.5), i(-2), f(9.8)]],
                             ["#{IUT}/@shared/score", i(3)], ["@shared/lobby/hello", "hi"]] },
  nil, [], ["ok", nil], note: "each value goes on its topic's key (see data_puts)")
o.("withdraw a topic", { "unpublish" => "camera" }, nil, [], ["ok", nil],
  note: "the declarations are put again without it (see pubs_puts)")
# Values the driver puts on asterism/drv/conf/feed/... while it answers
# rec.feed; the implementation's subscription to drv/conf/** hands them to
# its block, and the implementation reports what each came with:
# [path, value, seq, time, encoding, lost, restarted] (the bytes of a value
# with an encoding as a bin).
feed = "asterism/#{DRV}/#{APP}/feed"
fp = ->(name, payload_hex, att, enc = nil) do
  { "key" => "#{feed}/#{name}", "payload_hex" => payload_hex, "attachment_hex" => att && pk(att), "encoding" => enc }
end
got = ->(name, v, seq, time, enc, lost, restarted) do
  ["#{DRV}/#{APP}/feed/#{name}", v, seq, time, enc, lost, restarted, "#{DRV}/#{APP}"]
end
# Values on the shared places: the driver's node's (drv/@shared/feed/s) and
# the network's (@shared/feed/g); the sender is the attachment's third
# element, and the numbers are counted per sender.
sfp = ->(key, payload_hex, att) { { "key" => key, "payload_hex" => payload_hex, "attachment_hex" => pk(att), "encoding" => nil } }
sk = "asterism/#{DRV}/@shared/feed/s"
gk = "asterism/@shared/feed/g"
sgot = ->(path, v, seq, time, lost, restarted, from) { [path, v, seq, time, "msgpack", lost, restarted, from] }
mx = 2**31 - 1
o.("receive values", { "feed" => [
  fp.("a", pk(1), [0]),
  fp.("a", pk("two"), [1, 1_700_000_000_123]),
  fp.("a", pk(nil), [4]),
  fp.("cam", JPEG.unpack1("H*"), [0], "image/jpeg"),
  fp.("a", pk([1]), [2]),
  fp.("w", pk(0), [mx]),
  fp.("w", pk(1), [0]),
  fp.("n", pk({ "k" => 1 }), nil),
  fp.("bad", "c1", [0]),
  fp.("t", "hello".unpack1("H*"), [0], "text/plain;charset=utf-8"),
  fp.("a", pk(5), [3, "x"]),
  sfp.(sk, pk(1), [0, nil, "#{DRV}/a"]),
  sfp.(sk, pk(2), [0, nil, "#{DRV}/b"]),
  sfp.(sk, pk(3), [2, nil, "#{DRV}/a"]),
  sfp.(sk, pk(4), [1, nil, "#{DRV}/b"]),
  sfp.(sk, pk(5), [7]),
  sfp.(sk, pk(6), [8, nil, 3]),
  sfp.(gk, pk("hi"), [5, 1_700_000_000_123, "x/y"])
], "expect" => 17 },
  { "key" => rec_call, "params" => "", "call" => { "method" => "feed", "args" => [], "kwargs" => m } }, okv.(nil),
  ["ok", [got.("a", i(1), i(0), nil, "msgpack", i(0), false),
          got.("a", "two", i(1), i(1_700_000_000_123), "msgpack", i(0), false),
          got.("a", nil, i(4), nil, "msgpack", i(2), false),
          got.("cam", { "bin_hex" => JPEG.unpack1("H*") }, i(0), nil, "image/jpeg", i(0), false),
          got.("a", [i(1)], i(2), nil, "msgpack", i(2), true),
          got.("w", i(0), i(mx), nil, "msgpack", i(0), false),
          got.("w", i(1), i(0), nil, "msgpack", i(0), false),
          got.("n", m(["k", i(1)]), nil, nil, "msgpack", i(0), false),
          got.("t", { "bin_hex" => "hello".unpack1("H*") }, i(0), nil, "text/plain;charset=utf-8", i(0), false),
          got.("a", i(5), i(3), nil, "msgpack", i(0), false),
          sgot.("#{DRV}/@shared/feed/s", i(1), i(0), nil, i(0), false, "#{DRV}/a"),
          sgot.("#{DRV}/@shared/feed/s", i(2), i(0), nil, i(0), false, "#{DRV}/b"),
          sgot.("#{DRV}/@shared/feed/s", i(3), i(2), nil, i(1), false, "#{DRV}/a"),
          sgot.("#{DRV}/@shared/feed/s", i(4), i(1), nil, i(0), false, "#{DRV}/b"),
          sgot.("#{DRV}/@shared/feed/s", i(5), i(7), nil, i(0), false, nil),
          sgot.("#{DRV}/@shared/feed/s", i(6), i(8), nil, i(0), false, nil),
          sgot.("@shared/feed/g", "hi", i(5), i(1_700_000_000_123), i(0), false, "x/y")]],
  note: "no encoding: MessagePack (\"msgpack\"); 4 after 1: 2 lost; 2 after 4: the sender started again (2 lost of " \
        "its new run); 0 after 2^31-1: the numbers wrapped; no attachment: no number; not MessagePack without " \
        "an encoding: left out; a time that is not an int: none; the reports end with the sender (an application's " \
        "own key: its node/app; the subscriptions' blocks run one subscription after the other, the network's place last). Shared places: the sender from the attachment's third element, the numbers per " \
        "sender (drv/a: 1 lost; drv/b counted on its own); no sender, or one that is not node/app: none, and the " \
        "numbers of the key without a sender")

samples = {
  "format" => "asterism-protocol-samples",
  "version" => 6,
  "protocol" => 2,
  "describes" => "the Asterism wire protocol 2 (docs/protocol.md)",
  "names" => { "iut" => IUT, "app" => APP, "driver" => DRV },
  "icon" => { "hex" => ICON.unpack1("H*"), "icon_hash" => ICON_HASH },
  "iut" => {
    "profile" => m(["name", "iut"]),
    "status" => m(["st", "wait"], ["n", i(1)]),
    "types" => [{ "name" => "conf/stroke", "fields" => [["pts", "int[]"], ["color", "str"], ["at", 2], ["path", "vector3[]"],
                                                                ["pose", "pose"], ["grid", "int[][]"], ["extra", "any"]],
                  "desc" => "one stroke" }],
    "topics" => [{ "name" => "imu", "type" => "vector3", "unit" => "m/s2", "desc" => "acceleration", "ts" => true },
                 { "name" => "board1/strokes", "type" => "conf/stroke" },
                 { "name" => "camera", "type" => "image", "encoding" => "image/jpeg" },
                 { "name" => "score", "shared" => "node", "type" => "number" },
                 { "name" => "lobby/hello", "shared" => "global", "type" => "text", "ts" => true }],
    "subscribe" => ["#{DRV}/#{APP}/**", "#{DRV}/@shared/**", "@shared/feed/**"],
    "objects" => [
      { "name" => "subject", "methods" => [["echo", i(1)], ["kw", i(1)], ["add", i(2)], ["boom", i(0)],
                                           ["any", i(-1)], ["ok?", i(0)], ["unsendable", i(0)], ["whoami", i(0)]] },
      { "name" => "other", "methods" => [["ping", i(0)]], "doc" => "Another object.",
        "method_docs" => { "ping" => { "args" => [], "doc" => "Answers pong." } } }
    ]
  },
  "values" => values,
  "incoming" => inc,
  "outgoing" => outs,
  "liveliness" => {
    "alive" => ["asterism/#{IUT}/#{APP}", "asterism/#{IUT}/#{APP}/subject", "asterism/#{IUT}/#{APP}/other"],
    "gone_after_close" => ["asterism/#{IUT}/#{APP}", "asterism/#{IUT}/#{APP}/subject", "asterism/#{IUT}/#{APP}/other"]
  },
  "profile_puts" => [
    { "when" => "connect", "key" => "asterism/#{IUT}/@profile",
      "payload" => m(["protocol", i(2)], ["kind", KIND_WORD], ["name", "iut"], ["icon_hash", ICON_HASH]) },
    { "when" => "change the profile", "key" => "asterism/#{IUT}/@profile",
      "payload" => m(["protocol", i(2)], ["kind", KIND_WORD], ["name", "iut 2"], ["icon_hash", ICON_HASH]) }
  ],
  "status_puts" => [
    { "when" => "connect", "key" => "asterism/#{IUT}/#{APP}/@status", "payload" => m(["st", "wait"], ["n", i(1)]) },
    { "when" => "change the status", "key" => "asterism/#{IUT}/#{APP}/@status",
      "payload" => m(["st", "play"], ["n", i(1)]) }
  ],
  # The last two puts on asterism/iut/conf/@pubs: the declarations once the
  # three topics are there (an implementation may put once per topic before
  # it, or once for several), then without the camera.
  "pubs_puts" => {
    "key" => "asterism/#{IUT}/#{APP}/@pubs",
    "declared" => pubs_tv,
    "after_unpublish" => m(["imu", m(["t", i(2)], ["u", "m/s2"], ["d", "acceleration"], ["ts", true])],
                           ["board1/strokes", m(["t", "conf/stroke"])], *shared_tv)
  },
  # The puts on the topics' keys (asterism/iut/conf/<name>), in order, and
  # no others: the payload (a value: MessagePack; payload_hex: the bytes as
  # they are), the encoding zenoh reports, the attachment (MessagePack).
  "data_puts" => [
    { "key" => "asterism/#{IUT}/#{APP}/imu", "encoding" => "zenoh/bytes", "payload" => [f(1.5), i(-2), f(9.8)],
      "attachment" => [i(0), { "any" => "int" }] },
    { "key" => "asterism/#{IUT}/#{APP}/camera", "encoding" => "image/jpeg", "payload_hex" => JPEG.unpack1("H*"),
      "attachment" => [i(0)] },
    { "key" => "asterism/#{IUT}/#{APP}/board1/strokes", "encoding" => "zenoh/bytes", "payload" => stroke,
      "attachment" => [i(0)] },
    { "key" => "asterism/#{IUT}/#{APP}/imu", "encoding" => "zenoh/bytes", "payload" => [f(1.5), i(-2), f(9.8)],
      "attachment" => [i(1), { "any" => "int" }] },
    # The shared places: [seq, time or nil, "<node>/<app>"].
    { "key" => "asterism/#{IUT}/@shared/score", "encoding" => "zenoh/bytes", "payload" => i(3),
      "attachment" => [i(0), nil, "#{IUT}/#{APP}"] },
    { "key" => "asterism/@shared/lobby/hello", "encoding" => "zenoh/bytes", "payload" => "hi",
      "attachment" => [i(0), { "any" => "int" }, "#{IUT}/#{APP}"] }
  ]
}

json = JSON.pretty_generate(samples) + "\n"
if ARGV.include?("--check")
  # Compare what the file says, not how it is laid out: the json gem's
  # pretty printer differs between versions (empty arrays, float exponents).
  if File.exist?(OUT) && JSON.parse(File.read(OUT)) == JSON.parse(json)
    puts "samples.json is up to date"
  else
    warn "samples.json is stale: run ruby test/protocol/gen_samples.rb"
    exit 1
  end
else
  File.write(OUT, json)
  puts "wrote #{OUT} (#{values.size} values, #{inc.size} incoming, #{outs.size} outgoing)"
end
