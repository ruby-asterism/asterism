# Asterism: the pure Ruby layers (remote objects, CDR, ROS 2), the message
# type generator and the bundled types. One source for both forms:
#   - CRuby gem `asterism`: asterism.gemspec, lib/asterism.rb loads mrblib/
#   - mrbgem `picoruby-asterism` (mruby / PicoRuby): mrbgem.rake + mrblib/
#
#   rake               both test suites (the default)
#   rake test:msgs     the generator, the type hashes, CDR, the bundled
#                      types and the layout (CRuby only: no Zenoh, no docker)
#   rake test:objects  the object layer and Asterism::ROS between CRuby
#                      sessions; needs asterism-zenoh (below)
#   rake types:check   compare the type hashes with a ROS 2 Jazzy image
#   rake types:refresh regenerate tools/ros2_jazzy and data/msgs from it
#                      (both need docker and ASTERISM_ROS2_IMAGE)
#
# asterism-zenoh (the CRuby Zenoh binding) is looked up in
# ASTERISM_ZENOH_DIR, else next to this repository (../asterism-zenoh, after
# its `rake compile`), else as an installed gem.
require "rbconfig"

ROOT = __dir__

def asterism_zenoh_lib
  dir = ENV["ASTERISM_ZENOH_DIR"].to_s
  dir = File.expand_path("../asterism-zenoh", ROOT) if dir.empty?
  lib = File.join(File.expand_path(dir), "lib")
  return lib if Dir.glob(File.join(lib, "asterism", "asterism_zenoh.*")).any?
  nil
end

def asterism_zenoh_gem?
  system(RbConfig.ruby, "-e", "require 'asterism/zenoh'", out: File::NULL, err: File::NULL)
end

namespace :test do
  desc "Message types: generator, type hashes, CDR, bundled types (no Zenoh)"
  task :msgs do
    sh RbConfig.ruby, File.join(ROOT, "test/msgs/run.rb")
    sh RbConfig.ruby, File.join(ROOT, "test/test_layout.rb")
  end

  desc "Object layer and ROS 2 node between CRuby sessions (needs asterism-zenoh)"
  task :objects do
    lib = asterism_zenoh_lib
    unless lib || asterism_zenoh_gem?
      abort "asterism-zenoh not found: build it next to this repository " \
            "(../asterism-zenoh, rake compile), set ASTERISM_ZENOH_DIR, or install the gem"
    end
    incs = ["-I", File.join(ROOT, "lib")]
    incs += ["-I", lib] if lib
    sh RbConfig.ruby, *incs, File.join(ROOT, "test/test_asterism.rb")
  end
end

desc "Run both test suites"
task test: ["test:msgs", "test:objects"]

def ros2_image!
  img = ENV["ASTERISM_ROS2_IMAGE"].to_s
  abort "set ASTERISM_ROS2_IMAGE to a ROS 2 Jazzy image (see tools/ros2_types.rb)" if img.empty?
  img
end

namespace :types do
  desc "Compare the type hashes with a ROS 2 Jazzy image (ASTERISM_ROS2_IMAGE)"
  task :check do
    sh RbConfig.ruby, File.join(ROOT, "tools/ros2_types.rb"), "--image", ros2_image!, "--check"
  end

  desc "Regenerate tools/ros2_jazzy and data/msgs from a ROS 2 Jazzy image (ASTERISM_ROS2_IMAGE)"
  task :refresh do
    sh RbConfig.ruby, File.join(ROOT, "tools/ros2_types.rb"), "--image", ros2_image!
  end
end

task default: :test
