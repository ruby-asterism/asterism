# Asterism for CRuby: Ruby objects on other machines called like local ones
# (Asterism.connect / expose / [] / poll), and a ROS 2 node over rmw_zenoh's
# wire format (Asterism::ROS, Asterism::CDR, generated message types).
#
# The Ruby code is shared with the mruby / PicoRuby boards: lib/asterism/
# shared is a copy of fmruby-core's picoruby-asterism mrblib (rake sync), and
# lib/asterism/cruby.rb adds what CRuby needs. The Zenoh binding is the
# asterism-zenoh gem (Asterism::Zenoh, over zenoh-c), with the same API as
# the boards' zenoh-pico binding.
require "msgpack"
require "asterism/zenoh"
require_relative "asterism/version"

# The same order as an mrbgem's mrblib (alphabetical).
%w[asterism cdr future proxy ros].each do |f|
  require_relative "asterism/shared/#{f}"
end
require_relative "asterism/cruby"
