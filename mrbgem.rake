# picoruby-asterism: call Ruby objects on other machines, for mruby /
# PicoRuby. The same mrblib/ is the CRuby gem `asterism` (lib/asterism.rb
# loads it); nothing is copied between the two.
#
# Pure Ruby (mrblib only). Built on Asterism::Zenoh (picoruby-asterism-zenoh)
# and a MessagePack module with pack / unpack (the msgpack gem's API; any gem
# that provides it will do). Also a minimal ROS 2 (rmw_zenoh) node,
# Asterism::ROS, with its CDR encoding, Asterism::CDR (these need only
# Asterism::Zenoh). The message types (data/msgs) are not compiled in: put
# them on the device's file system (Asterism::ROS::TYPE_PATH, by default
# /usr/share/asterism/msgs) and they are loaded at run time (require_type).
# The other directories (lib/, tools/, test/, host_test/) are not part of an
# mruby build: lib/, tools/ and test/ are for CRuby (mrbtest must not pick up
# test/), host_test/ is `rake test:mruby` (a build of its own). The default
# profile icon of the boards is a file (/usr/share/asterism/icon.png), not
# compiled in.
MRuby::Gem::Specification.new('picoruby-asterism') do |spec|
  spec.license = 'MIT'
  spec.authors = ['Katsuhiko Kageyama']
  spec.summary = 'Asterism: proxies for Ruby objects on other machines, over Zenoh'
  spec.version = '0.5.0'
  spec.add_dependency 'picoruby-asterism-zenoh'
  spec.test_rbfiles = []
end
