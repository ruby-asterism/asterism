require_relative "lib/asterism/version"

Gem::Specification.new do |s|
  s.name = "asterism"
  s.version = Asterism::VERSION
  s.summary = "Asterism: Ruby objects on other machines, and ROS 2 (rmw_zenoh) nodes, over Zenoh"
  s.description = "Proxies for objects exposed by other Ruby processes and boards, " \
                  "a ROS 2 node speaking rmw_zenoh's wire format, CDR and generated message types. " \
                  "Pure Ruby shared with Asterism's mruby / PicoRuby boards."
  s.authors = ["Katsuhiko Kageyama"]
  s.license = "MIT"
  s.required_ruby_version = ">= 3.2"
  s.files = Dir["lib/**/*.rb", "data/**/*.rb", "tools/*.rb", "SYNCED_FROM", "README.md"]
  s.require_paths = ["lib"]
  s.add_dependency "asterism-zenoh", "= #{Asterism::VERSION}"
  s.add_dependency "msgpack", "~> 1.7"
end
