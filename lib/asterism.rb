# Asterism for CRuby: Ruby objects on other machines called like local ones
# (Asterism.connect / expose / [] / poll), and a ROS 2 node over rmw_zenoh's
# wire format (Asterism::ROS, Asterism::CDR, generated message types).
#
# The Ruby code is the one the mruby / PicoRuby boards run: mrblib/ of this
# repository, which is also the mrbgem (mrbgem.rake). Nothing is copied:
# this file loads mrblib/ as it is, and lib/asterism/cruby.rb adds what
# CRuby needs. The Zenoh binding is the asterism-zenoh gem (Asterism::Zenoh,
# over zenoh-c), with the same API as the boards' zenoh-pico binding.
require "msgpack"
require "asterism/zenoh"
require_relative "asterism/version"

# The same order as an mrbgem's mrblib (alphabetical).
%w[asterism cdr future proxy ros].each do |f|
  require_relative "../mrblib/#{f}"
end
require_relative "asterism/cruby"
# The Ruby-like API on top (blocks, a receiving thread, Enumerators,
# pattern matching): CRuby only, see README "The Ruby-like API".
%w[runner zenoh objects ros].each do |f|
  require_relative "asterism/cruby/#{f}"
end
