#!/usr/bin/env ruby
# frozen_string_literal: true
#
# ros2_types.rb: refresh the ROS 2 message types bundled with Asterism
# (data/msgs) and the fixtures the tests compare with, from a ROS 2 Jazzy
# docker image.
#
#   ruby tools/ros2_types.rb --image IMAGE              # refresh the bundled types
#   ruby tools/ros2_types.rb --image IMAGE --check      # only compare, change nothing
#   ruby tools/ros2_types.rb --image IMAGE --fixtures   # refresh the test fixtures
#
# IMAGE (or ASTERISM_ROS2_IMAGE) is a ROS 2 Jazzy image with the packages
# below and Python's ROS 2 tools (rclpy, rosidl); docker must be able to run
# it. The official ros:jazzy-ros-base lacks example_interfaces; the Family
# mruby project builds one with it (its tools/fmrb_ros2_types.rb calls this
# script with that image).
#
# 1. Copies the .msg / .srv / .json of the needed packages out of the image
#    into a temporary directory.
# 2. Checks every type hash asterism_msggen.rb computes against the type
#    description JSON of the image; any mismatch stops here.
# 3. Copies the definitions used, with the package.xml of their packages
#    (origin and license), into tools/ros2_jazzy/ and writes the
#    JSON's hashes to tools/ros2_jazzy/type_hashes.txt (the tests read these,
#    so they run without docker).
# 4. Regenerates data/msgs/ from tools/bundled_types.txt.
#
# --fixtures refreshes what the tests (test/msgs) compare with, again from
# the ROS 2 tools in the image (Python there; the image has no Ruby):
# - test_type_hashes.txt: the hashes rosidl_generator_type_description
#   computes for the test package asterism_test_msgs (bounded strings and
#   sequences, wstring, defaults, a service), which Jazzy does not ship.
# - golden_cdr.tsv: for each case of golden_cases.json, the CDR bytes
#   rclpy.serialization.serialize_message makes (rmw_zenoh_cpp, Fast-CDR).

require "fileutils"
require "json"
require "tmpdir"

require "optparse"

ROOT = File.expand_path("..", __dir__)
TOOLS = File.join(ROOT, "tools")
require File.join(TOOLS, "asterism_msggen")

opts = { image: ENV["ASTERISM_ROS2_IMAGE"], check: false, fixtures: false }
OptionParser.new do |o|
  o.banner = "usage: ruby tools/ros2_types.rb --image IMAGE [--check | --fixtures]"
  o.on("--image IMAGE", "ROS 2 Jazzy docker image (or ASTERISM_ROS2_IMAGE)") { |v| opts[:image] = v }
  o.on("--check", "only compare the type hashes, change nothing") { opts[:check] = true }
  o.on("--fixtures", "refresh the test fixtures instead") { opts[:fixtures] = true }
end.parse!
abort "no image: pass --image or set ASTERISM_ROS2_IMAGE" if opts[:image].to_s.empty?

IMAGE = opts[:image]
PACKAGES = %w[std_msgs builtin_interfaces geometry_msgs sensor_msgs example_interfaces service_msgs
              nav_msgs diagnostic_msgs tf2_msgs visualization_msgs rcl_interfaces].freeze
VENDOR = File.join(TOOLS, "ros2_jazzy")
OUT = File.join(ROOT, "data/msgs")
LIST = File.join(TOOLS, "bundled_types.txt")

check_only = opts[:check]
TEST_DIR = File.join(ROOT, "test/msgs")

REF_HASH_PY = <<~PY
  import json, pathlib, tempfile
  from rosidl_adapter.msg import convert_msg_to_idl
  from rosidl_adapter.srv import convert_srv_to_idl
  from rosidl_generator_type_description import generate_type_hash
  pkg = "asterism_test_msgs"
  pkg_dir = pathlib.Path("/work") / pkg
  out = pathlib.Path(tempfile.mkdtemp())
  tuples = []
  for kind, conv in (("msg", convert_msg_to_idl), ("srv", convert_srv_to_idl)):
      for f in sorted((pkg_dir / kind).glob("*." + kind)):
          conv(pkg_dir, pkg, pathlib.Path(kind) / f.name, out / "idl" / kind)
          tuples.append(f"{out / 'idl'}:{kind}/{f.stem}.idl")
  deps = ("std_msgs", "geometry_msgs", "builtin_interfaces", "service_msgs")
  args = {"package_name": pkg, "output_dir": str(out / "td"), "idl_tuples": tuples,
          "include_paths": [f"{p}:/opt/ros/jazzy/share/{p}" for p in deps]}
  (out / "args.json").write_text(json.dumps(args))
  hashes = {}
  for f in generate_type_hash(str(out / "args.json")):
      for th in json.loads(pathlib.Path(f).read_text())["type_hashes"]:
          hashes[th["type_name"]] = th["hash_string"]
  for k in sorted(hashes):
      print("HASH", k, hashes[k])
PY

GOLDEN_PY = <<~PY
  import json
  from rosidl_runtime_py.utilities import get_message, get_service
  from rosidl_runtime_py import set_message_fields
  from rclpy.serialization import serialize_message
  for name, values in json.load(open("/work/golden_cases.json")):
      if "/srv/" in name:
          base, part = name.rsplit("_", 1)
          cls = getattr(get_service(base), part)
      else:
          cls = get_message(name)
      text = json.dumps(values, separators=(",", ":"))
      m = cls()
      set_message_fields(m, values)
      print(name + "\t" + text + "\t" + serialize_message(m).hex())
PY

def in_image(py)
  cmd = "docker run --rm -i -v #{TEST_DIR}:/work:ro #{IMAGE} " \
        "bash -c 'source /opt/ros/jazzy/setup.bash && python3 - 2>/dev/null'"
  out = IO.popen(cmd, "r+") do |io|
    io.write(py)
    io.close_write
    io.read
  end
  abort "failed in the image: #{cmd}" unless $?.success?
  out
end

def sh!(cmd)
  system(cmd) || abort("failed: #{cmd}")
end

abort "docker image #{IMAGE} not found" unless system("docker image inspect #{IMAGE} > /dev/null 2>&1")

if opts[:fixtures]
  lines = in_image(REF_HASH_PY).lines.grep(/\AHASH /).map { |l| l.split[1..].join(" ") }
  File.write(File.join(TEST_DIR, "test_type_hashes.txt"),
             "# RIHS01 hashes of asterism_test_msgs from rosidl_generator_type_description\n" \
             "# (ROS 2 Jazzy, #{IMAGE}). Written by tools/ros2_types.rb --fixtures.\n" +
             lines.map { |l| "#{l}\n" }.join)
  gold = in_image(GOLDEN_PY)
  File.write(File.join(TEST_DIR, "golden_cdr.tsv"), gold)
  puts "#{lines.size} reference hashes, #{gold.lines.size} golden CDR cases -> #{TEST_DIR}"
  exit 0
end

names = File.readlines(LIST).map(&:strip).reject { |l| l.empty? || l.start_with?("#") }

Dir.mktmpdir("asterism_ros2_types") do |tmp|
  dirs = PACKAGES.flat_map { |p| %W[#{p}/msg #{p}/srv #{p}/package.xml] }.join(" ")
  sh!("docker run --rm #{IMAGE} bash -c 'cd /opt/ros/jazzy/share && tar cf - #{dirs} 2>/dev/null; true' " \
      "| tar xf - -C #{tmp}")
  reg = AsterismMsgGen::Registry.new([tmp])
  hasher = AsterismMsgGen::Hasher.new(reg)
  all = AsterismMsgGen.closure(reg, names)
  checked, bad, missing = AsterismMsgGen.check_json(hasher, all, [tmp])
  bad.each { |n, mine, theirs| warn "MISMATCH #{n}: computed #{mine}, json #{theirs}" }
  missing.each { |n| warn "no JSON for #{n}" }
  puts "type hashes against the image's JSON: #{checked} checked, #{bad.size} mismatched, #{missing.size} missing"
  abort "stopping: the type hashes do not match" unless bad.empty? && missing.empty?

  hashes = {}
  all.each do |full|
    pkg, kind, name = AsterismMsgGen.split_name(full)
    JSON.parse(File.read(File.join(tmp, pkg, kind, "#{name}.json")))["type_hashes"].each do |th|
      hashes[th["type_name"]] = th["hash_string"]
    end
  end
  exit 0 if check_only

  FileUtils.rm_rf(VENDOR)
  reg.sources.each do |src|
    rel = src.delete_prefix("#{tmp}/")
    dst = File.join(VENDOR, rel)
    FileUtils.mkdir_p(File.dirname(dst))
    FileUtils.cp(src, dst)
  end
  # Each package's package.xml goes with its definitions: it records where
  # they come from and their license, which the generated files state.
  reg.sources.map { |src| src.delete_prefix("#{tmp}/").split("/").first }.uniq.each do |pkg|
    xml = File.join(tmp, pkg, "package.xml")
    abort "no package.xml for #{pkg} in the image" unless File.file?(xml)
    FileUtils.cp(xml, File.join(VENDOR, pkg, "package.xml"))
  end
  File.open(File.join(VENDOR, "type_hashes.txt"), "w") do |f|
    f.puts "# RIHS01 type hashes from the type description JSON of ROS 2 Jazzy"
    f.puts "# (/opt/ros/jazzy/share/<pkg>/<msg|srv>/<Name>.json in #{IMAGE})."
    f.puts "# Written by tools/ros2_types.rb; the tests compare with these."
    hashes.keys.sort.each { |k| f.puts "#{k} #{hashes[k]}" }
  end
  puts "#{reg.sources.size} definitions and #{hashes.size} hashes -> #{VENDOR}"

  # Regenerate the bundle from the copied definitions (what the tests do).
  reg2 = AsterismMsgGen::Registry.new([VENDOR])
  em = AsterismMsgGen::Emitter.new(reg2, AsterismMsgGen::Hasher.new(reg2))
  # The package directories only; NOTICE and the license text stay.
  Dir.glob(File.join(OUT, "*/")).each { |d| FileUtils.rm_rf(d) }
  files = AsterismMsgGen.closure(reg2, names)
  files.each do |n|
    path = File.join(OUT, AsterismMsgGen::Emitter.rel_path(n))
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, em.file(n))
  end
  bytes = files.sum { |n| File.size(File.join(OUT, AsterismMsgGen::Emitter.rel_path(n))) }
  puts "#{files.size} types (#{bytes} bytes) -> #{OUT}"
end
