# The mruby test of several connections in one program (rake test:cross):
# "host/game" and "host/spectate", two applications of one node, and
# "viewer/v", all clients of the router at LOCATOR (test/router.rb). They
# see each other as applications, call each other (also nested: a wait on
# one connection answers the calls of the others), keep their own status
# and topics, answer the node's one profile, refuse the same <node>/<app>
# again, and one goes while the others stay.
#
#   mruby -r msgpack.rb test_connections.rb LOCATOR
#
# Prints one line per failed check and a summary; exits with 1 on failure.
loc = ARGV[0]
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

# Polls every connection until the block is true (or the time is up).
def until_true(limit = 5.0)
  t = Time.now
  while Time.now - t < limit
    Asterism.poll_all
    return true if yield
    usleep 2000
  end
  false
end

class Echo
  def initialize(net)
    @net = net
  end

  def echo(v)
    v
  end

  def who
    c = @net.current_call
    [c.from, c.object]
  end

  def via(path, v)
    @net[path].echo(v)
  end
end

game = Asterism.connect(loc, node: "host", app: "game", check_timeout: 0.5)
spec = Asterism.connect(loc, node: "host", app: "spectate", check_timeout: 0.5)
viewer = Asterism.connect(loc, node: "viewer", app: "v", check_timeout: 0.5)
check(Asterism.connections.size == 3, "three connections")
joined = []
game.on_app_join { |n, a| joined << "#{n}/#{a}" }
check(until_true { game.apps.size == 3 && spec.apps.size == 3 && viewer.apps.size == 3 }, "all see three apps")
check(joined.sort == ["host/spectate", "viewer/v"], "the other connection is another application: #{joined.inspect}")

game.expose("e", Echo.new(game), methods: { echo: 1, who: 0, via: 2 })
spec.expose("e", Echo.new(spec), methods: { echo: 1, who: 0, via: 2 })
check(until_true { spec.each("host/game/e").size == 1 && game.each("host/spectate/e").size == 1 }, "objects seen")
check(spec["host/game/e"].echo(42) == 42, "spectate calls game")
check(game["host/spectate/e"].echo(43) == 43, "game calls spectate")
check(game["host/spectate/e"].who == ["host", "e"], "the caller is the node")
check(viewer["host/game/e"].via("host/spectate/e", "deep") == "deep", "nested: viewer -> game -> spectate")
check(game["host/spectate/e"].via("host/game/e", "back") == "back", "nested back to the waiting connection")

game.status(tables: 2)
spec.status(watching: 1)
st = spec.publish("t1/state", type: :state)
check(spec.published == ["t1/state"] && game.published == [], "topics are the connection's")
check(until_true { viewer.status_of("host", "spectate") == { "watching" => 1 } }, "spectate's status")
check(viewer.status_of("host", "game") == { "tables" => 2 }, "game's status")
check(viewer.pubs_of("host", "spectate") == { "t1/state" => { "t" => 5 } }, "spectate's topics")
check(viewer.pubs_of("host", "game") == {}, "game has no topic: its profile answers without")
got = []
game.subscribe("host/spectate/**") { |v, info| got << [v, info.name] }
t = Time.now
until got.size > 0 || Time.now - t > 5
  st.put("playing")
  Asterism.poll_all
  usleep 20000
end
check(got.size > 0 && got[0] == ["playing", "t1/state"], "a value from one connection to the other: #{got[0].inspect}")

check(game.profile(name: "Host")["name"] == "Host" && spec.profile["name"] == "Host", "one profile for the node")
check(until_true { (viewer.profile_of("host", icon: false) || {})["name"] == "Host" }, "the node answers it")

raises(Asterism::Error, "the same node/app again") { Asterism.connect(loc, node: "host", app: "game") }

game.close
check(!game.connected? && spec.connected?, "one goes, the other stays")
check(Asterism.connections.size == 2, "two left")
check(until_true { viewer.apps.size == 2 }, "the viewer sees it go")
check(viewer["host/spectate/e"].echo(7) == 7, "spectate still answers")
check((viewer.profile_of("host", icon: false) || {})["name"] == "Host", "the node still answers its profile")
raises(Asterism::Disconnected, "a call on the closed one") { game["host/spectate/e"].echo(1) }
spec.close
viewer.close
check(Asterism.connections.empty? && !Asterism.poll_all, "all closed")

puts "#{$checks} checks, #{$fails} failed"
exit($fails == 0 ? 0 : 1)
