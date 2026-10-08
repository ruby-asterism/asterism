# A CRuby Asterism node: exposes objects that boards (and other Ruby
# processes) can call, and calls the objects of a board.
#
#   ruby examples/node.rb --router tcp/192.0.2.2:7447 [--node cruby]
#        [--peer fmruby-aaaaaa] [--calls 20] [--serve 30]
#
# It joins the app "demo", the app of fmruby-core's asterism_demo, so a
# board running asterism_demo takes this node as its peer: it calls
# info.status every 3 s, and its keys call screen.say / apu.play here.
# This node then calls the board's info.status and screen.say (the text
# shows in the board's window), times --calls more status calls, and keeps
# answering for --serve seconds.
# This repository's lib, and asterism-zenoh's next to it (ASTERISM_ZENOH_DIR
# overrides; an installed asterism-zenoh gem works too).
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__),
                   File.join(ENV["ASTERISM_ZENOH_DIR"] || File.expand_path("../../asterism-zenoh", __dir__), "lib"))
require "asterism"
require "optparse"

opt = { router: "tcp/127.0.0.1:7447", node: "cruby", peer: nil, calls: 20, serve: 30, app: "demo" }
OptionParser.new do |o|
  o.on("--router LOC") { |v| opt[:router] = v }
  o.on("--node ID") { |v| opt[:node] = v }
  o.on("--peer ID", "the board to call (default: the first other node of the app)") { |v| opt[:peer] = v }
  o.on("--calls N", Integer) { |v| opt[:calls] = v }
  o.on("--serve SECONDS", Float) { |v| opt[:serve] = v }
end.parse!

def log(text)
  puts "#{Time.now.strftime('%H:%M:%S.%L')} #{text}"
  $stdout.flush
end

def ms_since(t)
  ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
end

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# The objects asterism_demo exposes, with the same names and methods.
class Screen
  def say(text)
    log("screen.say #{text.inspect}")
    text.to_s.length
  end
end

class Apu
  def play(mml)
    log("apu.play #{mml.inspect} (no sound on the PC)")
    mml.to_s.length
  end

  def stop
    log("apu.stop")
    true
  end
end

class Info
  def initialize(node)
    @node = node
    @started = now
  end

  def status
    log("info.status")
    { "name" => @node, "board" => "cruby #{RUBY_VERSION}", "iram_free" => nil, "free" => nil,
      "pool_used" => nil, "up_ms" => ((now - @started) * 1000).to_i }
  end

  def relay(from, n)
    st = Asterism["#{from}/demo/info"].status
    [n, st["name"]]
  end

  def boom
    raise "boom on #{@node}"
  end

  def echo(value, tag: nil)
    [value, tag]
  end
end

Asterism.connect(opt[:router], node: opt[:node], app: opt[:app])
Asterism.expose("apu", Apu.new, methods: { play: 1, stop: 0 })
Asterism.expose("screen", Screen.new, methods: [:say])
Asterism.expose("info", Info.new(opt[:node]), methods: { status: 0, relay: 2, boom: 0, echo: 1 })
log("#{opt[:node]}/#{opt[:app]} connected to #{opt[:router]}")

peer = opt[:peer]
t0 = now
until peer
  Asterism.poll
  Asterism.each("*/#{opt[:app]}/screen") do |px|
    n = px.asterism_path.split("/")[0]
    peer ||= n unless n == opt[:node]
  end
  abort "no peer of app #{opt[:app]} within 10 s" if now - t0 > 10
  sleep 0.01
end
log("peer: #{peer} (nodes: #{Asterism.nodes.join(' ')})")

info = Asterism["#{peer}/#{opt[:app]}/info"]
screen = Asterism["#{peer}/#{opt[:app]}/screen"]
t = now
st = info.status
log("#{peer} info.status -> #{st.inspect} (#{ms_since(t)} ms)")
t = now
n = screen.say("hello from CRuby (#{opt[:node]})")
log("#{peer} screen.say -> #{n} (#{ms_since(t)} ms)")
log("#{peer} respond_to?(:status)=#{info.respond_to?(:status)} methods=#{info.methods.inspect}")

if opt[:calls] > 0
  times = []
  opt[:calls].times do
    t = now
    info.status
    times << ms_since(t)
    Asterism.poll
    sleep 0.05
  end
  s = times.sort
  log("#{opt[:calls]} x info.status: min #{s.first} ms, median #{s[s.size / 2]} ms, max #{s.last} ms")
end

log("serving for #{opt[:serve]} s")
t = now
while now - t < opt[:serve]
  break unless Asterism.poll
  sleep 0.01
end
log(Asterism.connected? ? "done" : "disconnected: #{Asterism.lost_reason}")
Asterism.close
