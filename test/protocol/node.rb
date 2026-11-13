# The implementation under test for the conformance driver (driver.rb), in
# Ruby: the portable API only, so the same file runs on CRuby and on mruby
# (docs/protocol.md 11.4 says what an implementation in another language
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

  # Who called: [from, verified, object, method] (Asterism.current_call).
  def whoami
    c = Asterism.current_call
    [c.from, c.verified.to_s, c.object, c.method]
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
  ["error", e.remote_class, e.remote_message, e.remote_kind]
rescue Asterism::TimeoutError
  ["timeout"]
rescue Asterism::Disconnected => e
  ["disconnected", e.message]
rescue Asterism::Error => e
  ["failed", e.message]
end

Asterism.profile(name: "iut", icon: icon)
Asterism.status({ "st" => "wait", "n" => 1 })
Asterism.define_type("conf/stroke", [["pts", "int[]"], ["color", "str"], ["at", 2], ["path", "vector3[]"],
                                     ["pose", "pose"], ["grid", "int[][]"], ["extra", "any"]], desc: "one stroke")
# A type told by another name of this connection (define_type app:).
Asterism.define_type("conf/cell", [["mb", "any[]"]], app: "watch")
if mode == "peer"
  Asterism.connect(locator, node: "iut", app: "conf", mode: :peer)
else
  Asterism.connect(locator, node: "iut", app: "conf")
end
imu = Asterism.publish("imu", type: :vector3, unit: "m/s2", desc: "acceleration", ts: true)
strokes = Asterism.publish("board1/strokes", type: "conf/stroke")
cam = Asterism.publish("camera", type: :image, encoding: "image/jpeg")
# What the subscription got: [path, value, seq, time, encoding, lost,
# restarted] (the bytes of a value with an encoding as a bin).
got = []
Asterism.subscribe("drv/conf/**") do |v, info|
  v = Asterism::Profile.binary(v) unless info.encoding == "msgpack"
  got << [info.path, v, info.seq, info.time, info.encoding, info.lost, info.restarted?]
end
Asterism.expose("subject", Subject.new,
                methods: { echo: 1, kw: 1, add: 2, boom: 0, any: -1, "ok?" => 0, unsendable: 0, whoami: 0 })
Asterism.expose("other", Other.new, methods: { ping: { args: [], doc: "Answers pong." } }, doc: "Another object.")
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
  ["bytes", -> { rec.bytes("\xff\x00".b) }],
  ["remote error", -> { rec.oops }],
  ["remote error, namespaced class", -> { rec.oops2 }],
  ["remote error without a kind", -> { rec.oops3 }],
  ["an error wins over a value", -> { rec.both }],
  ["malformed answer, not MessagePack", -> { rec.bad1 }],
  ["malformed answer, protocol 0's array", -> { rec.bad2 }],
  ["malformed answer, neither value nor error", -> { rec.bad3 }],
  ["malformed answer, error not a map", -> { rec.bad4 }],
  ["no answer", -> { rec.silent }],
  ["two answers, the first wins", -> { rec.twice }],
  ["meta", -> { [rec.respond_to?(:plain), rec.respond_to?(:x?), rec.respond_to?(:nope)] }],
  ["profile without the icon", -> { Asterism.profile_of("drv", icon: false, timeout: 1.5) }],
  ["profile with the icon", -> { Asterism.profile_of("drv", timeout: 1.5) }],
  ["profile without a protocol", -> { Asterism.profile_of("drv", icon: false, timeout: 1.5) }],
  ["profile that is not one", -> { Asterism.profile_of("drv", icon: false, timeout: 1.5) }],
  ["change the profile", -> { Asterism.profile(name: "iut 2"); nil }],
  ["status of another app", -> { Asterism.status_of("drv", "conf", timeout: 1.5) }],
  ["status that is not one", -> { Asterism.status_of("drv", "conf", timeout: 1.5) }],
  ["status too large", -> { Asterism.status_of("drv", "conf", timeout: 1.5) }],
  ["status left out", -> { Asterism.status_of("drv", "conf", timeout: 1.5) }],
  ["app profile that is not a map", -> { Asterism.status_of("drv", "conf", timeout: 1.5) }],
  ["no status", -> { Asterism.status_of("drv", "conf", timeout: 1.5) }],
  ["topics of another app", -> { Asterism.pubs_of("drv", "conf", timeout: 1.5) }],
  ["no topics", -> { Asterism.pubs_of("drv", "conf", timeout: 1.5) }],
  ["topics of nobody", -> { Asterism.pubs_of("drv", "conf", timeout: 1.5) }],
  ["types of another app", -> { Asterism.types_of("drv", "conf", timeout: 1.5) }],
  ["change the status", -> { Asterism.status({ "st" => "play", "n" => 1 }); nil }],
  ["the same status again", -> { Asterism.status({ "st" => "play", "n" => 1 }); nil }],
  ["put values", lambda do
    imu.put([1.5, -2, 9.8])
    cam.put("\xff\xd8\xff\xe0JFIF\xff\xd9".b)
    strokes.put({ "pts" => [1, 2], "color" => "red", "at" => [0, 0, 0] })
    imu.put([1.5, -2, 9.8])
    nil
  end],
  ["withdraw a topic", -> { cam.close; nil }],
  ["receive values", lambda do
    rec.feed
    t0 = Asterism.now_ms
    while got.size < 10 && Asterism.now_ms - t0 < 3000
      Asterism.poll
      Asterism.pause(2)
    end
    got
  end]
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
