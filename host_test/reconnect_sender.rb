# A sender that starts again (rake test:reconnect), on CRuby or mruby:
# connects as pub/rc, publishes the topic n and puts COUNT values 100 ms
# apart, the first numbered SKIP (as when a reader misses the first values
# of a run), then prints "sent <run id>" and waits to be killed (as a
# crash: no close).
loc = ARGV[0]
skip = ARGV[1].to_i
count = ARGV[2].to_i
net = Asterism.connect(loc, node: "pub", app: "rc", check_timeout: 0.5)
topic = net.publish("n", type: :number)
skip.times { topic.advance }
t0 = Asterism.now_ms
net.poll while Asterism.now_ms - t0 < 1000 # the publisher learns of the readers
i = 0
while i < count
  topic.put(i)
  i += 1
  t0 = Asterism.now_ms
  net.poll while Asterism.now_ms - t0 < 100
end
puts "sent #{net.run_id}"
$stdout.flush
loop do
  net.poll
  Asterism.pause(20)
end
