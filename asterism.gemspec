require_relative "lib/asterism/version"

Gem::Specification.new do |s|
  s.name = "asterism"
  s.version = Asterism::VERSION
  s.summary = "Asterism: Ruby objects on other machines, and ROS 2 (rmw_zenoh) nodes, over Zenoh"
  s.description = "Proxies for objects exposed by other Ruby processes and boards, " \
                  "a ROS 2 node speaking rmw_zenoh's wire format, CDR and generated message types. " \
                  "Pure Ruby; the same files are the mrbgem for mruby / PicoRuby."
  s.authors = ["Katsuhiko Kageyama"]
  # Asterism's code. The bundled ROS 2 message types (data/msgs) are made
  # from ROS 2's definitions and keep their Apache-2.0: NOTICE and
  # data/msgs/LICENSE-Apache-2.0.txt ship with the gem. How to state both in
  # the gem's metadata is left until the gem is published.
  s.license = "MIT"
  s.required_ruby_version = ">= 3.2"
  s.files = Dir["lib/**/*.rb", "mrblib/*.rb", "data/msgs/**/*", "tools/asterism_msggen.rb",
                "README.md", "LICENSE", "NOTICE"]
  s.require_paths = ["lib"]
  s.add_dependency "asterism-zenoh", "= #{Asterism::VERSION}"
  s.add_dependency "msgpack", "~> 1.7"
end
