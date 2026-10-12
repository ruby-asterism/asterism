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
meta_other = m(["methods", [meth.("ping", 0)]])
q.("meta", "#{base}/subject/meta", nil,
  [{ "key" => "#{base}/subject/meta", "payload" => meta_subject }],
  note: "arity -1: any number of arguments (exposed without counts)")
q.("meta ignores a payload", "#{base}/other/meta", req.("x"),
  [{ "key" => "#{base}/other/meta", "payload" => meta_other }])
q.("meta of every object", "#{base}/*/meta", nil,
  [{ "key" => "#{base}/subject/meta", "payload" => meta_subject },
   { "key" => "#{base}/other/meta", "payload" => meta_other }],
  note: "one reply per exposed object, in any order")
q.("meta of no such object", "#{base}/nothing/meta", nil, [],
  note: "no reply (the caller sees nobody answer)")
prof = ->(icon) do
  pairs = [["protocol", i(1)], ["kind", KIND_WORD], ["name", "iut"]]
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
q.("method name as bin", call_key, pk({ "method" => "add".b, "args" => [2, 3] }),
  [{ "key" => call_key, "payload" => { "any" => "value" } }], portable: false,
  note: "the name is a str; the Ruby implementations also take a bin name by its bytes (answered 5)")

# ------------------------------------------------------------ outgoing
# What the implementation under test does, in this order, to the driver's
# node drv (app conf, object rec). After each step it calls
# rec.report(id, outcome) (docs/protocol.md 10.4). The request is checked
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
  [pk({ "protocol" => 1, "kind" => "cruby", "name" => "drv", "host" => 5, "extra" => 1, "icon_hash" => "0000abcd" })],
  ["ok", m(["protocol", i(1)], ["kind", "cruby"], ["name", "drv"], ["icon_hash", "0000abcd"])],
  note: "the reader keeps only the known fields that pass their checks")
o.("profile with the icon", { "profile_of" => DRV, "icon" => true },
  { "key" => "asterism/#{DRV}/@profile", "params" => "", "payload" => nil },
  [pk({ "protocol" => 1, "kind" => "cruby", "icon" => ICON, "icon_hash" => "ffffffff" })],
  ["ok", m(["protocol", i(1)], ["kind", "cruby"], ["icon", { "bin_hex" => ICON.unpack1("H*") }], ["icon_hash", ICON_HASH])],
  note: "icon_hash is computed again from the icon; the one sent is not trusted")
o.("profile without a protocol", { "profile_of" => DRV, "icon" => false },
  { "key" => "asterism/#{DRV}/@profile", "params" => "icon=0", "payload" => nil },
  [pk({ "kind" => "cruby" })], ["ok", m(["kind", "cruby"])], note: "a node of protocol 0 (no protocol field)")
o.("profile that is not one", { "profile_of" => DRV, "icon" => false },
  { "key" => "asterism/#{DRV}/@profile", "params" => "icon=0", "payload" => nil },
  [pk({ "kind" => "Not A Word" })], ["ok", nil], note: "no valid kind: no profile (nil)")
o.("change the profile", { "set_profile" => m(["name", "iut 2"]) }, nil, [], ["ok", nil],
  note: "the change is put on asterism/iut/@profile (see profile_puts)")

samples = {
  "format" => "asterism-protocol-samples",
  "version" => 2,
  "protocol" => 1,
  "describes" => "the Asterism wire protocol 1 as asterism 0.7.0 speaks it (docs/protocol.md)",
  "names" => { "iut" => IUT, "app" => APP, "driver" => DRV },
  "icon" => { "hex" => ICON.unpack1("H*"), "icon_hash" => ICON_HASH },
  "iut" => {
    "profile" => m(["name", "iut"]),
    "objects" => [
      { "name" => "subject", "methods" => [["echo", i(1)], ["kw", i(1)], ["add", i(2)], ["boom", i(0)],
                                           ["any", i(-1)], ["ok?", i(0)], ["unsendable", i(0)], ["whoami", i(0)]] },
      { "name" => "other", "methods" => [["ping", i(0)]] }
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
      "payload" => m(["protocol", i(1)], ["kind", KIND_WORD], ["name", "iut"], ["icon_hash", ICON_HASH]) },
    { "when" => "change the profile", "key" => "asterism/#{IUT}/@profile",
      "payload" => m(["protocol", i(1)], ["kind", KIND_WORD], ["name", "iut 2"], ["icon_hash", ICON_HASH]) }
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
