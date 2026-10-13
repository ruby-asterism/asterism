# The node that stays while the router restarts (rake test:reconnect), on
# CRuby or mruby: exposes stay/rc/obj (ping), follows the other nodes and
# prints, with milliseconds since start: "ready", "lost" / "back" (the
# binding reconnecting), "leave <node>" / "join <node>", "ping <arg>". Ends
# on ping("stop") with "summary <pings> <reconnected> <connected?>".
class Obj
  def initialize
    @pings = []
  end
  attr_reader :pings

  def ping(x)
    @pings << x
    "pong #{x}"
  end
end

t0 = Asterism.now_ms
say = lambda do |s|
  puts "#{s} #{Asterism.now_ms - t0}"
  $stdout.flush
end
Asterism.connect(ARGV[0], node: "stay", app: "rc")
obj = Obj.new
Asterism.expose("obj", obj, methods: { ping: 1 })
Asterism.on_join { |n| say.call("join #{n}") }
Asterism.on_leave { |n| say.call("leave #{n}") }
say.call("ready")
was = false
back = 0
while Asterism.now_ms - t0 < 90_000
  unless Asterism.poll
    say.call("closed #{Asterism.lost_reason}")
    break
  end
  now = Asterism.reconnecting?
  if now != was
    say.call(now ? "lost" : "back")
    back += 1 unless now
    was = now
  end
  break if obj.pings.include?("stop")
  Asterism.pause(5)
end
puts "summary #{obj.pings.size} #{back} #{Asterism.connected?}"
$stdout.flush
Asterism.close
