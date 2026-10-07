# Asterism for CRuby: two gems in one repository.
#
#   asterism-zenoh/   Asterism::Zenoh, a C extension over zenoh-c
#   asterism/         the pure Ruby layers (objects, CDR, ROS 2, types),
#                     copied from fmruby-core (rake sync)
#
#   rake              fetch zenoh-c, build the extension, run the tests
#   rake zenoh_c:fetch / compile / test / sync / sync:check / clean
require "digest"
require "fileutils"
require "rbconfig"

ROOT = __dir__
VENDOR = File.join(ROOT, "vendor")
ZENOH_C_DIR = File.join(VENDOR, "zenoh-c")
EXT_SRC = File.join(ROOT, "asterism-zenoh/ext/asterism_zenoh")
EXT_BUILD = File.join(ROOT, "tmp/ext")
EXT_LIB = File.join(ROOT, "asterism-zenoh/lib/asterism")
DLEXT = RbConfig::CONFIG["DLEXT"]

# fmruby-core's checkout (the source of the pure Ruby layers). Next to this
# repository in the family-mruby tree; FMRUBY_CORE overrides.
FMRUBY_CORE = ENV["FMRUBY_CORE"] || File.expand_path("../fmruby-core", ROOT)

# What `rake sync` copies: [source in fmruby-core, destination here].
# The copies are not edited here: what CRuby needs on top lives in
# asterism/lib/asterism/cruby.rb.
SYNC = [
  ["lib/add/picoruby-asterism/mrblib", "asterism/lib/asterism/shared"],
  ["flash/usr/share/asterism/msgs", "asterism/data/msgs"],
  ["lib/add/picoruby-asterism/tools/asterism_msggen.rb", "asterism/tools/asterism_msggen.rb"]
].freeze

def pin
  @pin ||= File.readlines(File.join(ROOT, "ZENOH_C_PIN")).each_with_object({}) do |l, h|
    next if l.start_with?("#") || !l.include?(":")
    k, v = l.split(":", 2)
    h[k.strip] = v.strip
  end
end

def platform_key
  cpu = RbConfig::CONFIG["host_cpu"]
  os = RbConfig::CONFIG["host_os"]
  return "x86_64-linux" if cpu =~ /x86_64|amd64/ && os =~ /linux/
  abort "no prebuilt zenoh-c is pinned for #{cpu}-#{os} (ZENOH_C_PIN)"
end

namespace :zenoh_c do
  desc "Download the pinned prebuilt zenoh-c into vendor/zenoh-c"
  task :fetch do
    key = platform_key
    asset = pin["asset.#{key}"] or abort "ZENOH_C_PIN has no asset for #{key}"
    sha = pin["sha256.#{key}"] or abort "ZENOH_C_PIN has no sha256 for #{key}"
    stamp = File.join(ZENOH_C_DIR, ".pin")
    if File.exist?(stamp) && File.read(stamp).strip == sha
      next
    end
    url = "#{pin['repo']}/releases/download/#{pin['tag']}/#{asset}"
    FileUtils.mkdir_p(VENDOR)
    zip = File.join(VENDOR, asset)
    unless File.exist?(zip) && Digest::SHA256.file(zip).hexdigest == sha
      sh "curl", "-sSfL", "-o", zip, url
    end
    got = Digest::SHA256.file(zip).hexdigest
    abort "sha256 mismatch for #{asset}: #{got} (pinned #{sha})" unless got == sha
    FileUtils.rm_rf(ZENOH_C_DIR)
    FileUtils.mkdir_p(ZENOH_C_DIR)
    sh "unzip", "-q", "-o", zip, "-d", ZENOH_C_DIR
    abort "the archive has no include/zenoh.h" unless File.exist?(File.join(ZENOH_C_DIR, "include/zenoh.h"))
    File.write(stamp, sha + "\n")
    puts "zenoh-c #{pin['tag']} (#{key}) in #{ZENOH_C_DIR}"
  end
end

desc "Build the asterism-zenoh C extension"
task compile: "zenoh_c:fetch" do
  FileUtils.mkdir_p(EXT_BUILD)
  Dir.chdir(EXT_BUILD) do
    sh RbConfig.ruby, File.join(EXT_SRC, "extconf.rb")
    sh "make", "-s"
  end
  FileUtils.mkdir_p(EXT_LIB)
  FileUtils.cp(File.join(EXT_BUILD, "asterism_zenoh.#{DLEXT}"), EXT_LIB)
  FileUtils.cp(File.join(ZENOH_C_DIR, "lib/libzenohc.so"), EXT_LIB)
end

# Byte-for-byte differences between the copies and fmruby-core's files.
def sync_diff
  abort "fmruby-core not found at #{FMRUBY_CORE} (set FMRUBY_CORE)" unless File.directory?(FMRUBY_CORE)
  diffs = []
  SYNC.each do |src, dst|
    s = File.join(FMRUBY_CORE, src)
    d = File.join(ROOT, dst)
    if File.file?(s)
      diffs << dst unless File.file?(d) && File.binread(s) == File.binread(d)
      next
    end
    have = Dir.glob("**/*", base: s).select { |f| File.file?(File.join(s, f)) }.sort
    mine = File.directory?(d) ? Dir.glob("**/*", base: d).select { |f| File.file?(File.join(d, f)) }.sort : []
    (have | mine).each do |f|
      a = File.join(s, f)
      b = File.join(d, f)
      diffs << File.join(dst, f) unless File.file?(a) && File.file?(b) && File.binread(a) == File.binread(b)
    end
  end
  diffs
end

desc "Copy the pure Ruby layers from fmruby-core (FMRUBY_CORE)"
task :sync do
  abort "fmruby-core not found at #{FMRUBY_CORE} (set FMRUBY_CORE)" unless File.directory?(FMRUBY_CORE)
  SYNC.each do |src, dst|
    s = File.join(FMRUBY_CORE, src)
    d = File.join(ROOT, dst)
    FileUtils.rm_rf(d)
    FileUtils.mkdir_p(File.dirname(d))
    FileUtils.cp_r(s, d)
  end
  rev = `git -C #{FMRUBY_CORE} rev-parse HEAD 2>/dev/null`.strip
  File.write(File.join(ROOT, "asterism/SYNCED_FROM"),
             "fmruby-core #{rev.empty? ? 'unknown' : rev}\n" + SYNC.map { |s, d| "#{s} -> #{d}\n" }.join)
  puts "synced from #{FMRUBY_CORE} (#{rev[0, 10]})"
end

namespace :sync do
  desc "Check that the copies match fmruby-core"
  task :check do
    d = sync_diff
    abort "copies differ from fmruby-core (rake sync):\n  " + d.join("\n  ") unless d.empty?
    puts "sync: the copies match fmruby-core"
  end
end

desc "Run the tests (two CRuby sessions over a local peer link, no router needed)"
task test: :compile do
  Dir.glob(File.join(ROOT, "test/test_*.rb")).sort.each do |t|
    sh RbConfig.ruby, "-I", File.join(ROOT, "asterism-zenoh/lib"), "-I", File.join(ROOT, "asterism/lib"), t
  end
end

desc "Remove the build products (vendor/ stays)"
task :clean do
  FileUtils.rm_rf(File.join(ROOT, "tmp"))
  FileUtils.rm_f(Dir.glob(File.join(EXT_LIB, "*.{#{DLEXT},so}")))
end

task default: :test
