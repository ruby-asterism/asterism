# A CRuby Asterism node with the Ruby-like API: exposes objects that boards
# (and other Ruby processes) can call, and calls the objects of a board.
# examples/node_polled.rb is the same with the polled API of the boards.
#
#   ruby examples/node.rb --router tcp/192.0.2.2:7447 [--node cruby]
#        [--peer fmruby-aaaaaa] [--calls 20] [--serve 30] [--relay]
#
# It joins the app "demo", the app of fmruby-core's asterism_demo, so a
# board running asterism_demo takes this node as its peer: it calls
# info.status every 3 s, and its keys call screen.say / apu.play here.
# This node calls the board's info.status and screen.say (the text shows in
# the board's window) while a receiving thread answers the board, times
# --calls more status calls, then answers on the main thread (net.run) for
# --serve seconds or until Ctrl-C.
#
# The board's key m calls info.relay here ten times; each relay calls the
# board's info.status back before it answers (a nested call), and is logged.
# With --relay, this node does the same to the board meanwhile: during
# --serve it calls the board's info.relay ten at a time, over and over,
# while the receiving thread answers the board. Pressing m on the board
# then makes both sides call each other at once.
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
  o.on("--relay", "call the board's info.relay over and over while serving") { opt[:relay] = true }
end.parse!

def log(text)
  puts "#{Time.now.strftime('%H:%M:%S.%L')} #{text}"
  $stdout.flush
end

def timed
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  v = yield
  [v, ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)]
end

# The objects asterism_demo exposes, with the same names and methods. Their
# methods run on the receiving thread (or in net.run).
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
    @started = Time.now
  end

  def status
    log("info.status")
    { "name" => @node, "board" => "cruby #{RUBY_VERSION}", "iram_free" => nil, "free" => nil,
      "pool_used" => nil, "up_ms" => ((Time.now - @started) * 1000).to_i }
  end

  # A call that calls back (the board's key m).
  def relay(from, n)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    name = Asterism["#{from}/demo/info"].status["name"]
    log(format("info.relay from %s #%d (called %s back: %.1f ms)", from, n, name,
               (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000))
    [n, name]
  end

  def boom
    raise "boom on #{@node}"
  end

  def echo(value, tag: nil)
    [value, tag]
  end
end

Asterism.connect(opt[:router], node: opt[:node], app: opt[:app]) do |net|
  net.expose("apu", Apu.new, methods: { play: 1, stop: 0 })
  net.expose("screen", Screen.new, methods: [:say])
  net.expose("info", Info.new(opt[:node]), methods: { status: 0, relay: 2, boom: 0, echo: 1 })
  log("#{opt[:node]}/#{opt[:app]} connected to #{opt[:router]}")

  net.on_join { |n| log("joined: #{n}") }
  net.on_leave { |n| log("left: #{n}") }
  net.start # answer the board's calls on a thread of its own from now on

  peer = opt[:peer]
  t0 = Time.now
  until peer
    peer = net.each("*/#{opt[:app]}/screen").map { _1.asterism_path.split("/")[0] }.find { _1 != opt[:node] }
    abort "no peer of app #{opt[:app]} within 10 s" if Time.now - t0 > 10
    sleep 0.05
  end
  log("peer: #{peer} (nodes: #{net.nodes.join(' ')})")

  info = net["#{peer}/#{opt[:app]}/info"]
  screen = net["#{peer}/#{opt[:app]}/screen"]
  st, ms = timed { info.status }
  log("#{peer} info.status -> #{st.inspect} (#{ms} ms)")
  case st.values_at("board", "up_ms")
  in [String => board, Integer => up]
    log("#{peer} is a #{board}, up #{up / 1000} s")
  else
    nil
  end
  n, ms = timed { screen.say("hello from CRuby (#{opt[:node]})") }
  log("#{peer} screen.say -> #{n} (#{ms} ms)")
  log("#{peer} respond_to?(:status)=#{info.respond_to?(:status)} methods=#{info.methods.inspect}")
  paths = net.each("*/#{opt[:app]}/info").map(&:asterism_path)
  log("every info now: #{paths.inspect}")

  if opt[:calls] > 0
    times = opt[:calls].times.map do
      sleep 0.05
      timed { info.status }[1]
    end.sort
    log("#{opt[:calls]} x info.status: min #{times.first} ms, median #{times[times.size / 2]} ms, max #{times.last} ms")
  end

  if opt[:relay]
    # The receiving thread keeps answering the board; this thread relays.
    log("relaying to #{peer} for #{opt[:serve]} s (Ctrl-C ends)")
    until_t = Time.now + opt[:serve]
    begin
      while Time.now < until_t && net.connected?
        ok = 0
        _, ms = timed do
          10.times do |i|
            r = info.relay(opt[:node], i)
            ok += 1 if r[0] == i
          rescue Asterism::Error => e
            log("relay #{i}: #{e.class}: #{e.message}")
          end
        end
        log("relay x10 to #{peer}: #{ok} ok (#{ms} ms)")
        sleep 0.2
      end
    rescue Interrupt
      nil
    end
  else
    net.stop
    log("serving on the main thread for #{opt[:serve]} s (Ctrl-C ends)")
    Thread.new do
      sleep opt[:serve]
      net.stop
    end
    net.run
  end
  log(net.connected? ? "done" : "disconnected: #{net.lost_reason}")
end
