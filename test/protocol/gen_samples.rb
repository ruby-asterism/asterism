# Writes test/protocol/samples.json, the conformance samples of
# docs/protocol.md. The JSON file is what implementations read (in any
# language); this script is only how it is kept. Run it after changing the
# samples and commit both:
#
#   ruby test/protocol/gen_samples.rb            # rewrites samples.json
#   ruby test/protocol/gen_samples.rb --check    # exits 1 when it is stale
#
# The bytes are written out by hand where the point is the encoding (the
# other valid forms a reader must accept); the rest are msgpack-ruby's in
# compatibility mode, which is what the CRuby implementation sends.
require "json"
require "msgpack"
require_relative "tv"

ROOT = File.expand_path("../..", __dir__)
OUT = File.join(__dir__, "samples.json")

def pk(v) = MessagePack.pack(v, compatibility_mode: true).unpack1("H*")
def tv(v) = TV.from_ruby(v)
def i(n) = { "int" => n.to_s }
def f(x) = { "float" => x }
def m(*pairs) = { "map" => pairs }
ANY_STR = { "any" => "str" }.freeze

IUT = "iut"
APP = "conf"
DRV = "drv"
ICON = File.binread(File.join(ROOT, "data", "icon.png"))
ICON_HASH = "2a8c0626"
MALFORMED = "malformed call (expected [method, args, kwargs])"

# ------------------------------------------------------------ values
# Each is sent as the single argument of subject.echo; the answer must be
# ["ok", value]. encodings: every byte form of the value the sample sends
# (the first is what the CRuby implementation writes).
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
v.("int 2^63-1", 2**63 - 1, note: "the largest integer every implementation carries")
v.("int -1", -1, "d0ff", "d3ffffffffffffffff")
v.("int -32", -32)
v.("int -33", -33)
v.("int -128", -128)
v.("int -129", -129)
v.("int -32768", -32_768)
v.("int -32769", -32_769)
v.("int -2^31", -(2**31))
v.("int -2^31-1", -(2**31) - 1)
v.("int -2^63", -(2**63), note: "the smallest integer every implementation carries")
v.("float 1.5", 1.5, "ca3fc00000", note: "float32 is read as a float (answered as float64)")
v.("float 1.0", 1.0, note: "a float with an integral value stays a float")
v.("float 0.0", 0.0)
v.("float -2.5e-300", -2.5e-300)
v.("float 1e300", 1e300)
v.("float inf", Float::INFINITY)
v.("str empty", "", "d900", "da0000", "db00000000")
v.("str a", "a")
v.("str 31 bytes", "x" * 31)
v.("str 32 bytes", "y" * 32, "d920" + "79" * 32, "db00000020" + "79" * 32,
   note: "CRuby writes str16 (compatibility mode), the boards str8; both are read")
v.("str 255 bytes", "z" * 255, "d9ff" + "7a" * 255)
v.("str 256 bytes", "w" * 256)
v.("str utf-8", "日本語 é")
v.("str with NUL", "a\u0000b")
v.("str not utf-8", raw.("a2ff00", { "str_hex" => "ff00" }),
   note: "a str may carry bytes that are not UTF-8; they come back unchanged (binary data travels as str today: Review R-7)")
v.("array empty", [], "dc0000", "dd00000000")
v.("array 3", [1, 2, 3], "dc0003010203")
v.("array 16", (1..16).to_a)
v.("array nested", [1, [2, [3, [nil]]], "s"])
v.("map empty", {}, "de0000", "df00000000")
v.("map str keys", { "a" => 1, "b" => [true] }, "de0002a16101a16291c3")
v.("map int keys", { 1 => "one", -2 => "minus two" }, note: "keys are not limited to str (Review R-3)")
v.("map 16", (1..16).to_h { |n| ["k#{n}", n] })
v.("map nested", { "outer" => { "inner" => [{}] } })
v.("mixed", [nil, true, 1, 1.5, "s", [], {}])
# Not portable today: the implementations disagree (docs/protocol.md 3.3).
v.("bin", raw.("c402ff00", { "bin_hex" => "ff00" }), "c50002ff00",
   portable: false, note: "CRuby reads bin as a binary String (answered as str ff00); the boards' MessagePack reads it as nil")
v.("uint64 above 2^63-1", raw.("cfffffffffffffffff", i(2**64 - 1)),
   portable: false, note: "CRuby carries it; mruby's Integer is int64 (the boards read -1)")
v.("ext type", raw.("d40100", nil), portable: false, note: "no implementation gives ext a meaning")

# ------------------------------------------------------------ incoming
# Gets the driver sends to the implementation under test (node iut, app
# conf), and the replies it must give (an empty list: no reply at all).
call_key = "asterism/#{IUT}/#{APP}/subject/call"
inc = []
q = ->(id, key, payload_hex, replies, params: nil, note: nil, portable: true) do
  h = { "id" => id, "key" => key, "params" => params, "payload_hex" => payload_hex, "replies" => replies }
  h["note"] = note if note
  h["portable"] = portable
  inc << h
end
ok = ->(x) { [{ "key" => call_key, "payload" => ["ok", x] }] }
err = ->(cls, msg, key = call_key) { [{ "key" => key, "payload" => ["error", cls, msg] }] }

q.("call add", call_key, pk(["add", [2, 3], {}]), ok.(i(5)))
q.("call kwargs", call_key, pk(["kw", [1], { "b" => 2 }]), ok.([i(1), i(2), nil]))
q.("call kwargs two", call_key, pk(["kw", [1], { "c" => "x", "b" => 2 }]), ok.([i(1), i(2), "x"]))
q.("call kwargs empty map", call_key, pk(["kw", [1], {}]), ok.([i(1), nil, nil]))
q.("call unknown keyword", call_key, pk(["kw", [1], { "z" => 2 }]), err.("ArgumentError", ANY_STR),
  note: "the message is the language's own")
q.("call method with ?", call_key, pk(["ok?", [], {}]), ok.(true))
q.("call any arity, 3", call_key, pk(["any", [1, 2, 3], {}]), ok.(i(3)))
q.("call any arity, 0", call_key, pk(["any", [], {}]), ok.(i(0)))
q.("call wrong arity", call_key, pk(["add", [1], {}]),
  err.("ArgumentError", "wrong number of arguments (given 1, expected 2)"))
q.("call not exposed", call_key, pk(["secret", [], {}]),
  err.("NoMethodError", "undefined method 'secret' for #{IUT}/#{APP}/subject (not exposed)"))
q.("call no such method", call_key, pk(["nope", [], {}]),
  err.("NoMethodError", "undefined method 'nope' for #{IUT}/#{APP}/subject (not exposed)"))
q.("call raises", call_key, pk(["boom", [], {}]), err.("RuntimeError", "boom"),
  note: "the class name and message of the exception the method raised")
q.("call no such object", "asterism/#{IUT}/#{APP}/nothing/call", pk(["echo", [1], {}]),
  err.("NameError", "no object nothing exposed by #{IUT}/#{APP}", "asterism/#{IUT}/#{APP}/nothing/call"))
q.("call returns what cannot be sent", call_key, pk(["unsendable", [], {}]),
  err.("Asterism::EncodeError", { "match" => "\\Athe return value: " }))
q.("malformed: two elements", call_key, pk(["add", [2, 3]]), err.("ArgumentError", MALFORMED))
q.("malformed: kwargs nil", call_key, pk(["add", [2, 3], nil]), err.("ArgumentError", MALFORMED))
q.("malformed: args a map", call_key, pk(["add", {}, {}]), err.("ArgumentError", MALFORMED))
q.("malformed: method an int", call_key, pk([5, [], {}]), err.("ArgumentError", MALFORMED))
q.("malformed: four elements", call_key, pk(["add", [2, 3], {}, nil]), err.("ArgumentError", MALFORMED))
q.("malformed: no payload", call_key, nil, err.("ArgumentError", MALFORMED))
q.("malformed: not MessagePack", call_key, "c1", err.("ArgumentError", MALFORMED))
q.("ignored: object *", "asterism/#{IUT}/#{APP}/*/call", pk(["echo", [1], {}]), [])
q.("ignored: another kind", "asterism/#{IUT}/#{APP}/subject/other", pk(["echo", [1], {}]), [])
q.("ignored: six chunks", "#{call_key}/x", pk(["echo", [1], {}]), [])
q.("ignored: node and app only", "asterism/#{IUT}/#{APP}", nil, [])
q.("call through a wildcard node", "asterism/*/#{APP}/subject/call", pk(["add", [1, 1], {}]),
  [{ "key" => call_key, "payload" => ["ok", i(2)] }],
  note: "the reply key is the object's own key, not the query's")
q.("call through **", "asterism/#{IUT}/**/subject/call", pk(["add", [1, 2], {}]),
  [{ "key" => call_key, "payload" => ["ok", i(3)] }])
meta_subject = m(["methods", { "unordered" => [["echo", i(1)], ["kw", i(1)], ["add", i(2)], ["boom", i(0)],
                                                ["any", i(-1)], ["ok?", i(0)], ["unsendable", i(0)]] }])
meta_other = m(["methods", [["ping", i(0)]]])
q.("meta", "asterism/#{IUT}/#{APP}/subject/meta", nil,
  [{ "key" => "asterism/#{IUT}/#{APP}/subject/meta", "payload" => meta_subject }],
  note: "arity -1: any number of arguments (exposed without counts)")
q.("meta ignores a payload", "asterism/#{IUT}/#{APP}/other/meta", pk(["x", [], {}]),
  [{ "key" => "asterism/#{IUT}/#{APP}/other/meta", "payload" => meta_other }])
q.("meta of every object", "asterism/#{IUT}/#{APP}/*/meta", nil,
  [{ "key" => "asterism/#{IUT}/#{APP}/subject/meta", "payload" => meta_subject },
   { "key" => "asterism/#{IUT}/#{APP}/other/meta", "payload" => meta_other }],
  note: "one reply per exposed object, in any order")
q.("meta of no such object", "asterism/#{IUT}/#{APP}/nothing/meta", nil, [],
  note: "no reply (the caller sees nobody answer)")
prof = ->(icon) do
  pairs = [["kind", { "match" => "\\A[a-z][a-z0-9_]{0,31}\\z" }], ["name", "iut"]]
  pairs << ["icon", { "str_hex" => ICON.unpack1("H*") }] if icon
  pairs << ["icon_hash", ICON_HASH]
  [{ "key" => "asterism/#{IUT}/@profile", "payload" => m(*pairs) }]
end
q.("profile", "asterism/#{IUT}/@profile", nil, prof.(true))
q.("profile icon=0", "asterism/#{IUT}/@profile", nil, prof.(false), params: "icon=0")
q.("profile icon=no among others", "asterism/#{IUT}/@profile", nil, prof.(false), params: "x=1;icon=no")
q.("profile icon=false", "asterism/#{IUT}/@profile", nil, prof.(false), params: "icon=false")
q.("profile icon=1", "asterism/#{IUT}/@profile", nil, prof.(true), params: "icon=1")
q.("profile not under **", "asterism/#{IUT}/**", nil, [],
  note: "@profile is a verbatim chunk: ** does not reach it, and nothing else answers asterism/<node>/**")
q.("profile not under *", "asterism/*/@profile", nil, prof.(true), note: "a wildcard node does reach it")
q.("ignored: trailing bytes", call_key, pk(["add", [2, 3], {}]) + "00",
  [{ "key" => call_key, "payload" => { "any" => "value" } }], portable: false,
  note: "CRuby answers malformed call; the boards ignore the extra bytes and answer 5")
q.("method name as bin", call_key, MessagePack.pack(["add".b, [2, 3], {}]).unpack1("H*"),
  [{ "key" => call_key, "payload" => { "any" => "value" } }], portable: false,
  note: "CRuby reads the name and answers 5; the boards read bin as nil (malformed call)")

# ------------------------------------------------------------ outgoing
# What the implementation under test does, in this order, to the driver's
# node drv (app conf, object rec). After each step it calls
# rec.report(id, outcome) (docs/protocol.md 7.3).
rec = "asterism/#{DRV}/#{APP}/rec"
outs = []
o = ->(id, act, request, reply_hex, outcome, note: nil) do
  h = { "id" => id, "do" => act, "request" => request, "reply_hex" => reply_hex, "outcome" => outcome }
  h["note"] = note if note
  outs << h
end
call = ->(method, args = [], kwargs = []) { { "call" => method, "args" => args, "kwargs" => m(*kwargs) } }
reqc = ->(method, args = [], kwargs = []) do
  { "key" => "#{rec}/call", "params" => "", "payload" => [method, args, m(*kwargs)] }
end
o.("plain", call.("plain"), reqc.("plain"), [pk(["ok", nil])], ["ok", nil])
o.("arguments", call.("args", [i(1), "two", f(3.0), nil, true, false]),
  reqc.("args", [i(1), "two", f(3.0), nil, true, false]),
  [pk(["ok", [1, "two", 3.0, nil, true, false]])], ["ok", [i(1), "two", f(3.0), nil, true, false]])
o.("keywords", { "call" => "kw", "args" => [i(1)], "kwargs" => m(["tag", "sym"], ["n", i(2)]),
                 "ruby" => "rec.kw(1, tag: :sym, n: 2)" },
  reqc.("kw", [i(1)], [["tag", "sym"], ["n", i(2)]]), [pk(["ok", "kw"])], ["ok", "kw"],
  note: "keyword names and Symbol values go as str")
o.("symbols and hashes", { "call" => "sym", "args" => ["abc", m(["a", i(1)], ["b", "c"])],
                           "kwargs" => m, "ruby" => "rec.sym(:abc, { a: 1, \"b\" => :c })" },
  reqc.("sym", ["abc", m(["a", i(1)], ["b", "c"])]), [pk(["ok", { "a" => 1 }])], ["ok", m(["a", i(1)])],
  note: "Symbols, also as map keys, go as str; they come back as str")
o.("nesting", call.("nest", [[[i(1), [i(2)]], m(["k", [m]])]]),
  reqc.("nest", [[[i(1), [i(2)]], m(["k", [m]])]]), [pk(["ok", [[1, [2]], { "k" => [{}] }]])],
  ["ok", [[i(1), [i(2)]], m(["k", [m]])]])
o.("numbers", call.("num", [i(2**62), i(-(2**62)), f(1.0), i(0)]),
  reqc.("num", [i(2**62), i(-(2**62)), f(1.0), i(0)]), [pk(["ok", 2**63 - 1])], ["ok", i(2**63 - 1)])
o.("utf-8", call.("utf8", ["日本語"]), reqc.("utf8", ["日本語"]), [pk(["ok", "é"])], ["ok", "é"])
o.("remote error", call.("oops"), reqc.("oops"), [pk(["error", "KeyError", "missing key"])],
  ["error", "KeyError", "missing key"], note: "RemoteError with the class name and message as they came")
o.("remote error, namespaced class", call.("oops2"), reqc.("oops2"),
  [pk(["error", "Asterism::EncodeError", "the return value: cannot send a Object"])],
  ["error", "Asterism::EncodeError", "the return value: cannot send a Object"])
o.("malformed answer, not MessagePack", call.("bad1"), reqc.("bad1"), ["c1"], ["failed", ANY_STR])
o.("malformed answer, not ok or error", call.("bad2"), reqc.("bad2"), [pk(["huh", 1])], ["failed", ANY_STR])
o.("no answer", call.("silent"), reqc.("silent"), [], ["timeout"],
  note: "the get ends without a reply: the caller does not wait for the time limit")
o.("two answers, the first wins", call.("twice"), reqc.("twice"), [pk(["ok", 1]), pk(["ok", 2])], ["ok", i(1)])
o.("meta", { "respond_to" => ["plain", "x?", "nope"], "ruby" => "[:plain, :x?, :nope].map { |n| rec.respond_to?(n) }" },
  { "key" => "#{rec}/meta", "params" => "", "payload" => nil },
  [pk({ "methods" => [["plain", 0], ["x?", -1]] })], ["ok", [true, true, false]],
  note: "the meta is fetched once per proxy")
o.("profile without the icon", { "profile_of" => DRV, "icon" => false },
  { "key" => "asterism/#{DRV}/@profile", "params" => "icon=0", "payload" => nil },
  [pk({ "kind" => "cruby", "name" => "drv", "host" => 5, "extra" => 1, "icon_hash" => "0000abcd" })],
  ["ok", m(["kind", "cruby"], ["name", "drv"], ["icon_hash", "0000abcd"])],
  note: "the reader keeps only the known fields that pass their checks")
o.("profile with the icon", { "profile_of" => DRV, "icon" => true },
  { "key" => "asterism/#{DRV}/@profile", "params" => "", "payload" => nil },
  [MessagePack.pack({ "kind" => "cruby", "icon" => ICON, "icon_hash" => "ffffffff" }, compatibility_mode: true).unpack1("H*")],
  ["ok", m(["kind", "cruby"], ["icon", { "str_hex" => ICON.unpack1("H*") }], ["icon_hash", ICON_HASH])],
  note: "icon_hash is computed again from the icon; the one sent is not trusted")
o.("profile that is not one", { "profile_of" => DRV, "icon" => false },
  { "key" => "asterism/#{DRV}/@profile", "params" => "icon=0", "payload" => nil },
  [pk({ "kind" => "Not A Word" })], ["ok", nil], note: "no valid kind: no profile (nil)")
o.("change the profile", { "set_profile" => m(["name", "iut 2"]) }, nil, [], ["ok", nil],
  note: "the change is put on asterism/iut/@profile (see profile_puts)")

samples = {
  "format" => "asterism-protocol-samples",
  "version" => 1,
  "describes" => "the Asterism wire protocol as asterism 0.6.0 speaks it (docs/protocol.md)",
  "names" => { "iut" => IUT, "app" => APP, "driver" => DRV },
  "icon" => { "hex" => ICON.unpack1("H*"), "icon_hash" => ICON_HASH },
  "iut" => {
    "profile" => m(["name", "iut"]),
    "objects" => [
      { "name" => "subject", "methods" => [["echo", i(1)], ["kw", i(1)], ["add", i(2)], ["boom", i(0)],
                                           ["any", i(-1)], ["ok?", i(0)], ["unsendable", i(0)]] },
      { "name" => "other", "methods" => [["ping", i(0)]] }
    ]
  },
  "values" => values,
  "incoming" => inc,
  "outgoing" => outs,
  "liveliness" => {
    "alive" => ["asterism/#{IUT}", "asterism/#{IUT}/#{APP}/subject", "asterism/#{IUT}/#{APP}/other"],
    "gone_after_close" => ["asterism/#{IUT}", "asterism/#{IUT}/#{APP}/subject", "asterism/#{IUT}/#{APP}/other"]
  },
  "profile_puts" => [
    { "when" => "connect", "key" => "asterism/#{IUT}/@profile",
      "payload" => m(["kind", { "match" => "\\A[a-z][a-z0-9_]{0,31}\\z" }], ["name", "iut"], ["icon_hash", ICON_HASH]) },
    { "when" => "change the profile", "key" => "asterism/#{IUT}/@profile",
      "payload" => m(["kind", { "match" => "\\A[a-z][a-z0-9_]{0,31}\\z" }], ["name", "iut 2"], ["icon_hash", ICON_HASH]) }
  ]
}

json = JSON.pretty_generate(samples) + "\n"
if ARGV.include?("--check")
  if File.exist?(OUT) && File.read(OUT) == json
    puts "samples.json is up to date"
  else
    warn "samples.json is stale: run ruby test/protocol/gen_samples.rb"
    exit 1
  end
else
  File.write(OUT, json)
  puts "wrote #{OUT} (#{values.size} values, #{inc.size} incoming, #{outs.size} outgoing)"
end
