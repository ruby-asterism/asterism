# A reader through Asterism (rake test:reconnect), on CRuby or mruby:
# subscribes to pub/rc/n and prints "got <seq> <run id> <lost> <restarted>"
# for each value, and "leave pub/rc" when its token goes, for DURATION ms.
loc = ARGV[0]
duration = ARGV[1].to_i
net = Asterism.connect(loc, node: "reader", app: "rc", check_timeout: 0.5)
net.subscribe("pub/rc/n") do |_v, info|
  puts "got #{info.seq} #{info.run_id} #{info.lost} #{info.restarted?}"
  $stdout.flush
end
net.on_app_leave do |n, a|
  puts "leave #{n}/#{a}"
  $stdout.flush
end
puts "ready"
$stdout.flush
t0 = Asterism.now_ms
while Asterism.now_ms - t0 < duration
  net.poll
  Asterism.pause(5)
end
net.close
puts "done"
