# The answering side of the mruby test (rake test:mruby runs it as its own
# process): node "mnode", listening, with a profile set before connecting
# and the gem's icon (data/icon.png) as its icon.
#
#   mruby -r msgpack.rb node.rb PORT ICON_FILE
#
# Lines: prints "ready", then polls until "stop" comes on pz-style key
# test/stop or 60 s pass. A put on test/name changes the profile's name,
# one on test/status the status's n (the same n again puts nothing).
port = ARGV[0]
icon = File.open(ARGV[1], "r") { |f| f.read }
Asterism.profile(name: "mruby node", host: "host_test", icon: icon)
Asterism.status({ "n" => 1, "st" => "wait" })
Asterism.connect(nil, node: "mnode", app: "t", mode: :peer, listen: "tcp/127.0.0.1:#{port}")
s = Asterism.session
sub = s.subscribe("test/**")
puts "ready"
stop = false
deadline = Time.now + 60
until stop || Time.now > deadline
  Asterism.poll
  sub.each_pending do |key, payload|
    stop = true if key == "test/stop"
    Asterism.profile(name: payload) if key == "test/name"
    Asterism.status(n: payload.to_i) if key == "test/status"
  end
  usleep 2000
end
Asterism.close
puts "node done"
