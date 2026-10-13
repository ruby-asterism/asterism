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
#   rake test:protocol the conformance samples (test/protocol/samples.json,
#                      docs/protocol.md 7) and the driver against a CRuby
#                      node; needs asterism-zenoh
#   rake test:protocol_mruby  the same driver against an mruby node (builds
#                      mruby as test:mruby does; needs asterism-zenoh too).
#                      Not part of `rake`
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

# The conformance driver (test/protocol/driver.rb, CRuby) against the node
# command given (test/protocol/node.rb on CRuby or mruby).
def protocol_driver(name, node_cmd)
  lib = asterism_zenoh_lib
  unless lib || asterism_zenoh_gem?
    abort "asterism-zenoh not found: build it next to this repository " \
          "(../asterism-zenoh, rake compile), set ASTERISM_ZENOH_DIR, or install the gem"
  end
  incs = ["-I", File.join(ROOT, "lib")]
  incs += ["-I", lib] if lib
  router = ENV["ASTERISM_TEST_ROUTER"].to_s
  opts = router.empty? ? [] : ["--router", router]
  sh RbConfig.ruby, *incs, File.join(ROOT, "test/protocol/driver.rb"), "--name", name, *opts, "--", *node_cmd.call(incs)
end

namespace :test do
  desc "Protocol conformance: the samples, and the driver against a CRuby node (needs asterism-zenoh)"
  task :protocol do
    lib = asterism_zenoh_lib
    incs = ["-I", File.join(ROOT, "lib")]
    incs += ["-I", lib] if lib
    sh RbConfig.ruby, *incs, File.join(ROOT, "test/protocol/test_samples.rb")
    protocol_driver("cruby", ->(i) { [RbConfig.ruby, *i, "-r", "asterism", File.join(ROOT, "test/protocol/node.rb")] })
  end

  desc "Protocol conformance: the driver against an mruby node (builds mruby; needs asterism-zenoh)"
  task protocol_mruby: "mruby:build" do
    bin = File.join(MRUBY_BUILD_DIR, "host", "bin", "mruby")
    stub = File.join(ROOT, "host_test", "msgpack.rb")
    protocol_driver("mruby", ->(_) { [bin, "-r", stub, File.join(ROOT, "test/protocol/node.rb")] })
  end
end

# A node that stays while its router restarts, then is called by a newcomer
# (rake test:reconnect): node_cmd runs host_test/reconnect_node.rb.
def reconnect_check(name, node_cmd)
  require "socket"
  require "timeout"
  lib = asterism_zenoh_lib
  incs = ["-I", File.join(ROOT, "lib")]
  incs += ["-I", lib] if lib
  port = TCPServer.new("127.0.0.1", 0).then { |sv| sv.addr[1].tap { sv.close } }
  image = ENV["ZENOHD_IMAGE"] || "eclipse/zenoh:1.10.1"
  ctr = "asterism-reconnect-#{Process.pid}-#{name}"
  sh "docker run -d --rm --name #{ctr} -p 127.0.0.1:#{port}:7447 #{image} " \
     "--no-multicast-scouting -l tcp/0.0.0.0:7447 > /dev/null"
  locator = "tcp/127.0.0.1:#{port}"
  node = nil
  begin
    sleep 1.5
    node = IO.popen([*node_cmd.call(incs), File.join(ROOT, "host_test", "reconnect_node.rb"), locator],
                    err: [:child, :out])
    line = Timeout.timeout(10) { node.gets }
    abort "#{name}: reconnect_node.rb did not start: #{line.inspect}" unless line&.start_with?("ready")
    t = Time.now
    sh "docker restart -t 1 #{ctr} > /dev/null"
    puts "#{name}: router restarted (#{(Time.now - t).round(2)} s)"
    out = []
    Timeout.timeout(30) do
      while (l = node.gets)
        puts "#{name}: #{l}"
        out << l
        break if l.start_with?("back", "closed")
      end
    end
    abort "#{name}: no reconnection" unless out.last.to_s.start_with?("back")
    ok = system(RbConfig.ruby, *incs, "-r", "asterism", File.join(ROOT, "host_test", "reconnect_caller.rb"), locator)
    rest = Timeout.timeout(15) { node.read }
    puts rest.lines.map { "#{name}: #{_1}" }.join
    abort "#{name}: not called after the reconnection" unless ok && rest.include?("summary 2 1 true")
    puts "#{name}: reconnection ok"
  ensure
    if node
      begin
        Process.kill("TERM", node.pid)
      rescue Errno::ESRCH
        nil
      end
      node.close
    end
    system("docker rm -f #{ctr} > /dev/null 2>&1")
  end
end

namespace :test do
  desc "Reconnection: a node (CRuby and mruby) keeps its objects while its router restarts (needs docker)"
  task reconnect: "mruby:build" do
    reconnect_check("cruby", ->(i) { [RbConfig.ruby, *i, "-r", "asterism"] })
    bin = File.join(MRUBY_BUILD_DIR, "host", "bin", "mruby")
    reconnect_check("mruby", ->(_) { [bin, "-r", File.join(ROOT, "host_test", "msgpack.rb")] })
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
task test: ["test:msgs", "test:objects", "test:api", "test:protocol"]

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
