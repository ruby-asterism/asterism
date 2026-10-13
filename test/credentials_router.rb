# rake test:credentials (needs docker): a zenohd that asks for client
# certificates (mutual TLS) from a test CA, and two CRuby nodes that connect
# to it with nothing but a console's .tar each (credentials:). alice exposes
# an object, bob calls it; a node without a certificate is refused; a .tar
# that others may read is warned about.
#
#   ruby -I lib -I ../asterism-zenoh/lib test/credentials_router.rb
require_relative "credentials_helper"
require "asterism"
require "socket"
require "timeout"
require "tmpdir"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
IMAGE = ENV["ZENOHD_IMAGE"] || "eclipse/zenoh:1.10.1"

def free_port
  s = TCPServer.new("127.0.0.1", 0)
  s.addr[1].tap { s.close }
end

def fail!(msg)
  warn "credentials: FAIL #{msg}"
  exit 1
end

dir = Dir.mktmpdir("asterism-cred-router")
ca = CredentialsHelper::CA.new
port = free_port
ctr = "asterism-credentials-#{Process.pid}"
router_dir = File.join(dir, "router")
ca.files(router_dir, "zenohd-test", dns: ["localhost"])
File.chmod(0o644, File.join(router_dir, "zenohd-test.key")) # zenohd in the container runs as another user
File.write(File.join(router_dir, "router.json5"), <<~JSON5)
  {
    mode: "router",
    listen: { endpoints: ["tls/[::]:7448"] },
    scouting: { multicast: { enabled: false } },
    transport: { link: { tls: {
      root_ca_certificate: "/certs/ca.pem",
      listen_certificate: "/certs/zenohd-test.pem",
      listen_private_key: "/certs/zenohd-test.key",
      enable_mtls: true,
    } } },
  }
JSON5
locator = "tls/localhost:#{port}"
tar = lambda do |name, mode|
  path = File.join(dir, "#{name}.tar")
  File.binwrite(path, ca.tar(name, router: locator))
  File.chmod(mode, path)
  path
end
alice = tar.("alice", 0o600)
bob = tar.("bob", 0o600)
loose = tar.("carol", 0o644)
child = nil
begin
  system("docker", "run", "-d", "--rm", "--name", ctr, "-p", "127.0.0.1:#{port}:7448",
         "-v", "#{router_dir}:/certs:ro", IMAGE, "-c", "/certs/router.json5", out: File::NULL) or fail!("docker run")
  sleep 1.5
  # alice: a separate process (Asterism is one connection per process).
  script = <<~RUBY
    require "asterism"
    class Echo; def echo(v) = "echo \#{v}"; end
    Asterism.connect(credentials: ARGV[0], app: "cred") do |net|
      net.expose("echo", Echo.new, methods: [:echo])
      puts "ready \#{net.node_id}"
      $stdout.flush
      net.run
    end
  RUBY
  incs = $LOAD_PATH.select { File.exist?(File.join(_1, "asterism.rb")) || File.exist?(File.join(_1, "asterism/zenoh.rb")) }
               .flat_map { ["-I", _1] }
  child = IO.popen([RbConfig.ruby, *incs, "-e", script, alice], err: [:child, :out])
  line = Timeout.timeout(15) { child.gets }
  fail!("alice did not start: #{line.inspect}") unless line == "ready alice\n"
  puts "credentials: alice connected with #{File.basename(alice)} alone"

  # A node without a certificate (the CA only) is refused by the router.
  begin
    Asterism.connect(locator, node: "eve", app: "cred", connect_timeout: 2,
                     config: { "transport/link/tls/root_ca_certificate" => File.join(router_dir, "ca.pem") })
    fail!("a node without a certificate was let in")
  rescue Asterism::Disconnected
    puts "credentials: a node without a certificate was refused"
  end

  # A .tar others may read: told, and it still connects.
  r, w = IO.pipe
  saved = $stderr.dup
  $stderr.reopen(w)
  Asterism::Credentials.load(loose)
  $stderr.reopen(saved)
  w.close
  err = r.read
  fail!("no warning for a 0644 .tar: #{err.inspect}") unless err.include?("can be read by others (mode 0644)")
  puts "credentials: warned: #{err.strip}"

  Asterism.connect(credentials: bob, app: "cred") do |net|
    fail!("node is #{net.node_id}") unless net.node_id == "bob"
    got = nil
    Timeout.timeout(10) do
      loop do
        got = begin
          net["alice/cred/echo"].echo("hi")
        rescue Asterism::Error
          nil
        end
        break if got
        sleep 0.2
      end
    end
    fail!("bob's call: #{got.inspect}") unless got == "echo hi"
    puts "credentials: bob (#{File.basename(bob)} alone) called alice: #{got.inspect}"
  end
  puts "credentials: ok"
ensure
  if child
    begin
      Process.kill("TERM", child.pid)
    rescue Errno::ESRCH
      nil
    end
    child.close
  end
  system("docker", "rm", "-f", ctr, out: File::NULL, err: File::NULL)
  FileUtils.remove_entry(dir)
end
