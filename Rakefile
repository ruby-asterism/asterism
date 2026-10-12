# Asterism: the pure Ruby layers (remote objects, CDR, ROS 2), the message
# type generator and the bundled types. One source for both forms:
#   - CRuby gem `asterism`: asterism.gemspec, lib/asterism.rb loads mrblib/
#   - mrbgem `picoruby-asterism` (mruby / PicoRuby): mrbgem.rake + mrblib/
#
#   rake               all the test suites (the default)
#   rake test:msgs     the generator, the type hashes, CDR, the bundled
#                      types and the layout (CRuby only: no Zenoh, no docker)
#   rake test:objects  the object layer, node profiles and Asterism::ROS
#                      between CRuby sessions; needs asterism-zenoh (below)
#   rake test:api      the Ruby-like API of CRuby (lib/asterism/cruby/):
#                      blocks, receiving threads, Enumerators; needs
#                      asterism-zenoh too
#   rake test:mruby    the shared layer on mruby (MRB_UTF8_STRING, as on the
#                      boards): node profiles between two mruby processes,
#                      Asterism.session and on_join / on_leave in one.
#                      Builds mruby with picoruby-asterism-zenoh, whose
#                      checkout (../picoruby-asterism-zenoh or
#                      PICORUBY_ASTERISM_ZENOH_DIR) provides the pinned mruby
#                      and zenoh-pico (its `rake mruby:fetch zenoh:fetch`).
#                      Not part of `rake` (it builds a C toolchain's worth)
#   rake bench:poll    the time and allocations of one Asterism.poll by the
#                      number of nodes and objects (CRuby; prints a table)
#   rake gem           build pkg/asterism-<version>.gem (publishing is a
#                      separate, manual step)
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
    sh RbConfig.ruby, *incs, File.join(ROOT, "test/test_profile.rb")
    sh RbConfig.ruby, *incs, File.join(ROOT, "test/test_session.rb")
  end

  desc "The Ruby-like API of CRuby (blocks, threads, Enumerators) for Zenoh, objects and ROS 2 (needs asterism-zenoh)"
  task :api do
    lib = asterism_zenoh_lib
    unless lib || asterism_zenoh_gem?
      abort "asterism-zenoh not found: build it next to this repository " \
            "(../asterism-zenoh, rake compile), set ASTERISM_ZENOH_DIR, or install the gem"
    end
    incs = ["-I", File.join(ROOT, "lib")]
    incs += ["-I", lib] if lib
    Dir.glob(File.join(ROOT, "test/test_api_*.rb")).sort.each do |t|
      sh RbConfig.ruby, *incs, t
    end
  end
end

def picoruby_asterism_zenoh_dir
  dir = ENV["PICORUBY_ASTERISM_ZENOH_DIR"].to_s
  dir = File.expand_path("../picoruby-asterism-zenoh", ROOT) if dir.empty?
  dir = File.expand_path(dir)
  abort "picoruby-asterism-zenoh not found at #{dir} (PICORUBY_ASTERISM_ZENOH_DIR)" unless File.file?(File.join(dir, "mrbgem.rake"))
  dir
end

MRUBY_BUILD_DIR = File.join(ROOT, "tmp", "mruby_build")

namespace :mruby do
  desc "Build mruby with picoruby-asterism-zenoh and this gem (for test:mruby)"
  task :build do
    pz = picoruby_asterism_zenoh_dir
    mruby = ENV["MRUBY_DIR"].to_s.empty? ? File.join(pz, "vendor", "mruby") : File.expand_path(ENV["MRUBY_DIR"])
    abort "no mruby at #{mruby}: run `rake mruby:fetch zenoh:fetch` in #{pz}, or set MRUBY_DIR" unless File.directory?(mruby)
    env = { "MRUBY_CONFIG" => File.join(ROOT, "host_test", "build_config.rb"), "MRUBY_BUILD_DIR" => MRUBY_BUILD_DIR,
            "PICORUBY_ASTERISM_ZENOH_DIR" => pz }
    Dir.chdir(mruby) { sh env, RbConfig.ruby, "-S", "rake", "-j#{ENV['JOBS'] || 8}", "all" }
  end
end

namespace :test do
  desc "The shared layer on mruby: profiles, Asterism.session, on_join / on_leave (builds mruby)"
  task mruby: "mruby:build" do
    require "socket"
    require "timeout"
    bin = File.join(MRUBY_BUILD_DIR, "host", "bin", "mruby")
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    icon = File.join(ROOT, "data", "icon.png")
    stub = File.join(ROOT, "host_test", "msgpack.rb")
    node = IO.popen([bin, "-r", stub, File.join(ROOT, "host_test", "node.rb"), port.to_s, icon], err: [:child, :out])
    begin
      line = Timeout.timeout(10) { node.gets }
      abort "host_test/node.rb did not start: #{line.inspect}" unless line&.start_with?("ready")
      ok = system(bin, "-r", stub, File.join(ROOT, "host_test", "test_profile.rb"), port.to_s, icon)
      abort "test:mruby failed" unless ok
      rest = Timeout.timeout(10) { node.read }
      puts "node: #{rest}" unless rest.to_s.empty?
    ensure
      begin
        Process.kill("TERM", node.pid)
      rescue Errno::ESRCH
        nil
      end
      node.close
    end
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    msgs = File.join(ROOT, "data", "msgs")
    peer = IO.popen([bin, "-r", stub, File.join(ROOT, "host_test", "peer.rb"), port.to_s, msgs], err: [:child, :out])
    begin
      line = Timeout.timeout(10) { peer.gets }
      abort "host_test/peer.rb did not start: #{line.inspect}" unless line&.start_with?("ready")
      ok = system(bin, "-r", stub, File.join(ROOT, "host_test", "test_session.rb"), port.to_s, msgs)
      abort "test:mruby failed (session)" unless ok
      rest = Timeout.timeout(10) { peer.read }
      puts "peer: #{rest}" unless rest.to_s.empty?
    ensure
      begin
        Process.kill("TERM", peer.pid)
      rescue Errno::ESRCH
        nil
      end
      peer.close
    end
  end
end

namespace :bench do
  desc "How long one Asterism.poll takes, by the nodes and objects alive (CRuby; prints a table)"
  task :poll do
    lib = asterism_zenoh_lib
    incs = ["-I", File.join(ROOT, "lib")]
    incs += ["-I", lib] if lib
    sh RbConfig.ruby, *incs, File.join(ROOT, "test/bench_poll.rb")
  end
end

desc "Run the test suites"
task test: ["test:msgs", "test:objects", "test:api"]

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

desc "Build the gem file into pkg/ (only builds; publishing is a separate, manual step)"
task :gem do
  require_relative "lib/asterism/version"
  mkdir_p File.join(ROOT, "pkg")
  Dir.chdir(ROOT) do
    sh "gem", "build", "asterism.gemspec", "--output", "pkg/asterism-#{Asterism::VERSION}.gem"
  end
end

task default: :test
