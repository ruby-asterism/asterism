require_relative "lib/asterism/version"

Gem::Specification.new do |s|
  s.name = "asterism"
  s.version = Asterism::VERSION
  s.summary = "Asterism: Ruby objects on other machines, and ROS 2 (rmw_zenoh) nodes, over Zenoh"
  s.description = "Proxies for objects exposed by other Ruby processes and boards, " \
                  "a ROS 2 node speaking rmw_zenoh's wire format, CDR and generated message types. " \
                  "Pure Ruby; the same files are the mrbgem for mruby / PicoRuby."
  s.authors = ["Katsuhiko Kageyama"]
  s.homepage = "https://github.com/ruby-asterism/asterism"
  s.metadata = {
    "homepage_uri" => s.homepage,
    "source_code_uri" => "https://github.com/ruby-asterism/asterism",
    "bug_tracker_uri" => "https://github.com/ruby-asterism/asterism/issues",
    "rubygems_mfa_required" => "true"
  }
  # The licenses apply each to its own files: MIT for Asterism's code,
  # Apache-2.0 for the bundled ROS 2 message types (data/msgs, made from
  # ROS 2's definitions) except tf2_msgs, which is BSD-3-Clause (NOTICE,
  # data/msgs/NOTICE and the license texts in data/msgs ship with the gem).
  s.licenses = ["MIT", "Apache-2.0", "BSD-3-Clause"]
  s.required_ruby_version = ">= 3.2"
  s.files = Dir["lib/**/*.rb", "mrblib/*.rb", "data/msgs/**/*", "tools/asterism_msggen.rb",
                "README.md", "CHANGELOG.md", "LICENSE", "NOTICE"]
  s.require_paths = ["lib"]
  s.add_dependency "asterism-zenoh", "~> 0.4.0"
  s.add_dependency "msgpack", "~> 1.7"
end
