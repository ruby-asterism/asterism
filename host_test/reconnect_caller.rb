# Calls stay/rc/obj after the router restarted (rake test:reconnect, CRuby).
Asterism.connect(ARGV[0], node: "caller", app: "rc")
t = Time.now
Asterism.poll until Asterism.nodes.include?("stay") || Time.now - t > 5
ok = Asterism.nodes.include?("stay")
puts "nodes: #{Asterism.nodes.inspect}"
r = Asterism["stay/rc/obj"].ping("hi")
puts "ping: #{r.inspect}"
ok &&= r == "pong hi"
Asterism["stay/rc/obj"].ping("stop")
Asterism.close
exit(ok ? 0 : 1)
