# Calls stay/rc/obj after the router restarted (rake test:reconnect, CRuby).
net = Asterism.connect(ARGV[0], node: "caller", app: "rc")
t = Time.now
net.poll until net.nodes.include?("stay") || Time.now - t > 5
ok = net.nodes.include?("stay")
puts "nodes: #{net.nodes.inspect}"
r = net["stay/rc/obj"].ping("hi")
puts "ping: #{r.inspect}"
ok &&= r == "pong hi"
net["stay/rc/obj"].ping("stop")
net.close
exit(ok ? 0 : 1)
