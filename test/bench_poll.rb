# How heavy one Asterism.poll is, by the number of nodes and objects on the
# network (rake bench:poll; not a test: it prints a table). The other nodes
# and objects are liveliness tokens declared by a second session of this
# process, which is all Asterism.poll sees of them.
#
#   ruby -I lib -I ../asterism-zenoh/lib test/bench_poll.rb [polls]
#
# Columns: the nodes and objects alive besides this one, the time of one
# poll when nothing changed (the usual case), and the Ruby objects one such
# poll allocates; then the same for a poll that takes one liveliness change
# (an object coming or going).
require "socket"
require "asterism"

POLLS = (ARGV[0] || 2000).to_i
SIZES = [[0, 0], [1, 1], [4, 5], [10, 10], [20, 40]].freeze

def free_port
  s = TCPServer.new("127.0.0.1", 0)
  port = s.addr[1]
  s.close
  port
end

def allocated
  GC.stat(:total_allocated_objects)
end

def wait_until(limit = 5.0)
  t = Time.now
  until yield
    raise "timed out" if Time.now - t > limit
    Asterism.poll
    sleep 0.002
  end
end

puts format("%-6s %-8s %12s %12s %14s %12s", "nodes", "objects", "idle us", "idle allocs", "change us", "change allocs")
SIZES.each do |nodes, objects|
  loc = "tcp/127.0.0.1:#{free_port}"
  Asterism.connect(nil, node: "bench", app: "b", mode: :peer, listen: loc)
  joined = 0
  Asterism.on_join { |_n| joined += 1 }
  other = Asterism::Zenoh::Session.open(loc, mode: :peer)
  tokens = []
  nodes.times { |i| tokens << other.liveliness("asterism/n#{i}/main") }
  objects.times { |i| tokens << other.liveliness("asterism/n#{i % [nodes, 1].max}/app/o#{i}") }
  wait_until { Asterism.nodes.size == nodes + 1 && Asterism.each("*/app/*").size == objects && joined == nodes }

  GC.disable
  a0 = allocated
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  POLLS.times { Asterism.poll }
  idle_us = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1e6 / POLLS
  idle_alloc = (allocated - a0).to_f / POLLS
  GC.enable

  # A change: one object comes and goes, a poll each way.
  rounds = 50
  change_us = 0.0
  change_alloc = 0
  rounds.times do |r|
    tok = other.liveliness("asterism/n0/app/flip#{r}")
    sleep 0.005 # let it arrive before the timed poll
    a0 = allocated
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Asterism.poll
    change_us += (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1e6
    change_alloc += allocated - a0
    tok.close
    sleep 0.005
    Asterism.poll
  end
  puts format("%-6d %-8d %12.1f %12.1f %14.1f %12.1f", nodes, objects, idle_us, idle_alloc,
              change_us / rounds, change_alloc.to_f / rounds)
  tokens.each(&:close)
  other.close
  Asterism.close
end
