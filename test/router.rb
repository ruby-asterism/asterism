# A Zenoh router for the tests that need one (rake test:cross: several
# connections of one mruby program reach each other through it; zenoh-pico
# sessions of one process cannot be peers of each other, as a session's
# handshake waits for the other's poll). Listens on LOCATOR, prints
# "ready", and runs until its stdin closes.
#
#   ruby -I ../asterism-zenoh/lib test/router.rb tcp/127.0.0.1:PORT
require "asterism/zenoh"

s = Asterism::Zenoh::Session.open(nil, config: { "mode" => "router", "listen/endpoints" => [ARGV.fetch(0)],
                                                 "scouting/multicast/enabled" => false })
$stdout.puts "ready"
$stdout.flush
$stdin.read
s.close
