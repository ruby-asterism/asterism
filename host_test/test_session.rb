# The mruby test of Connection#session and the lighter Connection#poll (rake
# test:mruby): the session used for put, subscribe and a ROS 2 node, its
# close, on_join / on_leave through joins and leaves, and the time of one
# poll with 4 other nodes and 5 objects. The other side is peer.rb in
# another process, driven through ctl/ keys on the connection's own session.
#
#   mruby -r msgpack.rb test_session.rb PORT MSGS_DIR
#
# Prints one line per failed check, the poll times, and a summary; exits
# with 1 on failure.
port = ARGV[0]
Asterism::ROS::TYPE_PATH.replace([ARGV[1]])
Asterism.deprecations = :raise
$checks = 0
$fails = 0

def check(cond, what)
  $checks += 1
  return if cond
  $fails += 1
  puts "FAIL: #{what}"
end

def raises(klass, what)
  yield
  check(false, "#{what}: nothing raised")
rescue klass
  check(true, what)
rescue => e
  check(false, "#{what}: #{e.class}: #{e.message} instead of #{klass}")
end

# Polls until the block is true (or the time is up).
def until_true(limit = 3.0)
  t = Time.now
  while Time.now - t < limit
    $net.poll
    return true if yield
    usleep 2000
  end
  false
end

def poll_some(n = 30)
  n.times do
    $net.poll
    usleep 2000
  end
end

# Asks peer.rb for a token on key (true) or to withdraw it (false).
def token(key, on)
  $net.session.put("ctl/token/#{key}", on ? "1" : "0")
end

$net = Asterism.connect("tcp/127.0.0.1:#{port}", node: "me", app: "t", mode: :peer)
s = $net.session
check(s.is_a?(Asterism::Zenoh::Session), "a Zenoh session")
check(s.equal?($net.session), "the same object each time")

# --- put and subscribe on Asterism's session (peer.rb puts g1b/* back on seen/*)
seen = s.subscribe("seen/**")
poll_some(20)
s.put("g1b/state", "hello")
check(until_true { seen.pending > 0 }, "a put on $net.session goes out, a subscriber on it gets the answer")
got = seen.each_pending
check(got[0] && got[0][0] == "seen/state" && got[0][1] == "hello", "its key and payload: #{got.inspect}")

# --- a ROS 2 node on it
node = Asterism::ROS::Node.new(s, "brain")
check(node.zid == s.zid, "the node has Asterism's Zenoh ID")
odom = []
node.subscribe("/g1b/odom", "std_msgs/msg/String") { |m, _| odom << m.data }
poll_some(30)
s.put("ctl/odom", "o1")
check(until_true { node.poll; odom.size > 0 }, "the node's subscription gets a message")
check(odom == ["o1"], "the message: #{odom.inspect}")

# --- close by the application: nothing happens
check(s.close.nil?, "close returns nil")
check(!s.closed?, "the session stays open")
check($net.poll, "Asterism still polls")

# --- on_join / on_leave and nodes
events = []
$net.on_join { |n| events << "+#{n}" }
$net.on_leave { |n| events << "-#{n}" }
apps = []
$net.on_app_join { |n, a| apps << "+#{n}/#{a}" }
$net.on_app_leave { |n, a| apps << "-#{n}/#{a}" }
poll_some
token("asterism/n1/main", true)
check(until_true { events.size == 1 }, "n1 joins")
token("asterism/n2/app/o", true)
token("asterism/n1/app/o2", true)
until_true { $net.each("*/app/*").size == 2 }
poll_some
check(events == ["+n1", "+n2"], "joins: #{events.inspect}")
check(apps == ["+n1/main"], "on_app_join: the application token only (objects are not applications): #{apps.inspect}")
check($net.nodes == ["me", "n1", "n2"], "nodes: #{$net.nodes.inspect}")
poll_some(50)
check(events.size == 2, "nothing more while nothing changes")
token("asterism/n1/main", false)
until_true { !$net.nodes.include?("n1") || $net.nodes[1] == "n2" }
poll_some
check(events.size == 2 && $net.nodes == ["me", "n2", "n1"], "n1 stays by its object: #{$net.nodes.inspect}")
check(apps == ["+n1/main", "-n1/main"], "on_app_leave while the node stays: #{apps.inspect}")
token("asterism/n1/app/o2", false)
check(until_true { events.size == 3 }, "n1 leaves with its last object")
check(events[2] == "-n1", "leave: #{events.inspect}")

# --- the time of one poll: 4 other nodes, 5 objects, nothing changing
names = ["n2", "n3", "n4", "n5"]
names.each { |n| token("asterism/#{n}/main", true) }
4.times { |i| token("asterism/#{names[i]}/app/p#{i}", true) }
until_true { $net.nodes.size == 5 && $net.each("*/app/*").size == 5 }
poll_some
check($net.nodes.size == 5 && $net.each("*/app/*").size == 5, "5 nodes and 5 objects: #{$net.nodes.inspect}")
check(events.size == 6, "n2 stayed, n3-n5 joined: #{events.inspect}")
n = 2000
t = Time.now
i = 0
while i < n
  $net.poll
  i += 1
end
idle_us = (Time.now - t) * 1_000_000.0 / n
# One object coming (and going) before each timed poll.
change_us = 0.0
rounds = 20
rounds.times do |r|
  token("asterism/n3/app/flip#{r}", true)
  usleep 20000 # the token comes while nobody polls: the timed poll takes it
  t = Time.now
  $net.poll
  change_us += (Time.now - t) * 1_000_000.0
  check($net.each("n3/app/flip#{r}").size == 1, "the change came in the timed poll (#{r})") if r == 0
  token("asterism/n3/app/flip#{r}", false)
  until_true(1.0) { $net.each("n3/app/flip#{r}").empty? }
end
puts "poll, 5 nodes and 5 objects: #{idle_us.round(1)} us when nothing changes, " \
     "#{(change_us / rounds).round(1)} us when an object comes"

# --- the connection is lost: every node leaves, once; the session is closed
before = events.size
s.put("ctl/stop", "")
until_true(10) { !$net.connected? }
poll_some(5)
left = events[before, events.size - before]
check(left.size == 4 && left.all? { |e| e.start_with?("-") }, "all leave once: #{left.inspect}")
check(s.closed?, "the session is closed with the connection")
raises(Asterism::Disconnected, "session after the loss") { $net.session }
$net.close

puts "#{$checks} checks, #{$fails} failed"
exit($fails == 0 ? 0 : 1)
