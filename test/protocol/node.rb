# The implementation under test for the conformance driver (driver.rb), in
# Ruby: the portable API only, so the same file runs on CRuby and on mruby
# (docs/protocol.md 7.3 says what an implementation in another language
# does in its place).
#
#   ruby -I lib node.rb LOCATOR MODE ICON_FILE            (CRuby, -r asterism)
#   mruby -r host_test/msgpack.rb node.rb LOCATOR MODE ICON_FILE
#
# MODE: "peer" (connect to the driver's listening peer) or "client" (both
# are clients of a router at LOCATOR). Prints "ready" once connected, then
# "done" (or "FAIL ..." lines) at the end.
locator = ARGV[0]
mode = ARGV[1]
icon = File.open(ARGV[2], "r") { |f| f.read }

class Subject
  def echo(v)
    v
  end

  def kw(a, b: nil, c: nil)
    [a, b, c]
  end

  def add(a, b)
    a + b
  end

  def boom
    raise "boom"
  end

  def any(*args)
    args.size
  end

  def ok?
    true
  end

  def unsendable
    Object.new
  end

  def secret
    "not exposed"
  end
end

class Other
  def ping
    "pong"
  end
end

# The outcome of one step, as the samples write it.
def outcome
  ["ok", yield]
rescue Asterism::RemoteError => e
  ["error", e.remote_class, e.remote_message]
rescue Asterism::TimeoutError
  ["timeout"]
rescue Asterism::Disconnected => e
  ["disconnected", e.message]
rescue Asterism::Error => e
  ["failed", e.message]
end

Asterism.profile(name: "iut", icon: icon)
if mode == "peer"
  Asterism.connect(locator, node: "iut", app: "conf", mode: :peer)
else
  Asterism.connect(locator, node: "iut", app: "conf")
end
Asterism.expose("subject", Subject.new,
                methods: { echo: 1, kw: 1, add: 2, boom: 0, any: -1, "ok?" => 0, unsendable: 0 })
Asterism.expose("other", Other.new, methods: { ping: 0 })
puts "ready"

# The driver declares its object rec once it has sent its own calls.
t0 = Asterism.now_ms
while Asterism.each("drv/conf/rec").size == 0
  Asterism.poll
  if Asterism.now_ms - t0 > 60_000
    puts "FAIL: the driver's rec never appeared"
    exit 1
  end
  Asterism.pause(2)
end

rec = Asterism["drv/conf/rec", timeout: 1.5]
steps = [
  ["plain", -> { rec.plain }],
  ["arguments", -> { rec.args(1, "two", 3.0, nil, true, false) }],
  ["keywords", -> { rec.kw(1, tag: :sym, n: 2) }],
  ["symbols and hashes", -> { rec.sym(:abc, { a: 1, "b" => :c }) }],
  ["nesting", -> { rec.nest([[1, [2]], { "k" => [{}] }]) }],
  ["numbers", -> { rec.num(2**62, -(2**62), 1.0, 0) }],
  ["utf-8", -> { rec.utf8("日本語") }],
  ["remote error", -> { rec.oops }],
  ["remote error, namespaced class", -> { rec.oops2 }],
  ["malformed answer, not MessagePack", -> { rec.bad1 }],
  ["malformed answer, not ok or error", -> { rec.bad2 }],
  ["no answer", -> { rec.silent }],
  ["two answers, the first wins", -> { rec.twice }],
  ["meta", -> { [rec.respond_to?(:plain), rec.respond_to?(:x?), rec.respond_to?(:nope)] }],
  ["profile without the icon", -> { Asterism.profile_of("drv", icon: false, timeout: 1.5) }],
  ["profile with the icon", -> { Asterism.profile_of("drv", timeout: 1.5) }],
  ["profile that is not one", -> { Asterism.profile_of("drv", icon: false, timeout: 1.5) }],
  ["change the profile", -> { Asterism.profile(name: "iut 2"); nil }]
]
fails = 0
i = 0
while i < steps.size
  id = steps[i][0]
  out = outcome { steps[i][1].call }
  begin
    rec.report(id, out)
  rescue Asterism::Error => e
    puts "FAIL: report #{id}: #{e.class}: #{e.message}"
    fails += 1
  end
  i += 1
end
begin
  rec.done
rescue Asterism::Error => e
  puts "FAIL: done: #{e.class}: #{e.message}"
  fails += 1
end
# A moment for the last answers to go out before the tokens are withdrawn.
t0 = Asterism.now_ms
while Asterism.now_ms - t0 < 300
  Asterism.poll
  Asterism.pause(2)
end
Asterism.close
puts "done"
exit(fails == 0 ? 0 : 1)
