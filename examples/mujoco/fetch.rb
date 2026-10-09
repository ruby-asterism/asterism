# Fetch the pinned MuJoCo release (MUJOCO_PIN) into vendor/: download the
# official prebuilt archive, check its sha256, unpack it. Standard library
# only; nothing is built and nothing is installed outside this directory.
#
#   ruby examples/mujoco/fetch.rb            # vendor/mujoco-<tag>/lib/libmujoco.so
#   ruby examples/mujoco/fetch.rb --archive FILE   # use an archive downloaded by hand
#
# The library is found by lib/mujoco.rb in vendor/ (or MUJOCO_LIB).
require "digest"
require "fileutils"
require "net/http"
require "optparse"
require "uri"

DIR = __dir__

def pin
  @pin ||= File.readlines(File.join(DIR, "MUJOCO_PIN"), chomp: true)
                .reject { |l| l.start_with?("#") || l.strip.empty? }
                .to_h { |l| l.split(/:\s*/, 2) }
end

def platform_key
  cpu = RbConfig::CONFIG["host_cpu"]
  cpu = "x86_64" if cpu == "amd64"
  os = RbConfig::CONFIG["host_os"]
  abort "fetch.rb: only Linux is pinned (this is #{os})" unless os.include?("linux")
  "#{cpu}-linux"
end

def download(url, to, limit = 5)
  abort "fetch.rb: too many redirects" if limit.zero?
  uri = URI(url)
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
    http.request(Net::HTTP::Get.new(uri)) do |res|
      case res
      when Net::HTTPRedirection then return download(res["location"], to, limit - 1)
      when Net::HTTPSuccess
        File.open(to, "wb") { |f| res.read_body { |chunk| f.write(chunk) } }
      else
        abort "fetch.rb: #{url}: #{res.code} #{res.message}"
      end
    end
  end
end

archive = nil
OptionParser.new { |o| o.on("--archive FILE") { |v| archive = v } }.parse!

key = platform_key
asset = pin["asset.#{key}"] or abort "fetch.rb: no MuJoCo release pinned for #{key}"
want = pin["sha256.#{key}"]
tag = pin["tag"]
vendor = File.join(DIR, "vendor")
dest = File.join(vendor, "mujoco-#{tag}")
if File.exist?(File.join(dest, "lib", "libmujoco.so.#{tag}"))
  puts "MuJoCo #{tag} is already in #{dest}"
  exit
end

FileUtils.mkdir_p(vendor)
unless archive
  archive = File.join(vendor, asset)
  unless File.exist?(archive)
    url = "#{pin['repo']}/releases/download/#{tag}/#{asset}"
    puts "downloading #{url}"
    download(url, archive)
  end
end
got = Digest::SHA256.file(archive).hexdigest
abort "fetch.rb: sha256 of #{archive} is #{got}, pinned #{want}" unless got == want
system("tar", "xzf", archive, "-C", vendor, exception: true)
abort "fetch.rb: #{dest} is not in the archive" unless File.directory?(dest)
puts "MuJoCo #{tag} (#{key}), sha256 OK: #{dest}"
