# credentials: (lib/asterism/cruby/credentials.rb): a console's .tar read in
# memory, its certificates handed to zenoh as base64 with mutual TLS, the
# router and the node ID from asterism.json, and the warning for a file
# others may read. The connection test listens with mutual TLS in this
# process (a peer with its own certificate from the same test CA); `rake
# test:credentials` does the same against a zenohd (docker).
require_relative "helper"
require_relative "credentials_helper"
require "asterism"
require "tmpdir"

class TestApiCredentials < Minitest::Test
  include TestHelper

  class Echo
    def echo(v) = v
  end

  def setup
    @dir = Dir.mktmpdir("asterism-cred")
    @ca = CredentialsHelper::CA.new
  end

  def teardown
    Asterism.close
    @listener&.close
    FileUtils.remove_entry(@dir) if @dir
  end

  def tar(name = "alice", mode: 0o600, **kw)
    path = File.join(@dir, "#{name}.tar")
    File.binwrite(path, @ca.tar(name, **kw))
    File.chmod(mode, path)
    path
  end

  def quiet
    out = nil
    _o, err = capture_io { out = yield }
    [out, err]
  end

  def test_reads_the_tar_in_memory
    path = tar("alice", router: "tls/localhost:7448")
    before = Dir.children(@dir).sort
    c, err = quiet { Asterism::Credentials.load(path) }
    assert_equal "", err
    assert_equal ["alice", "client", "tls/localhost:7448"], [c.name, c.kind, c.router]
    cfg = c.zenoh_config
    assert_equal true, cfg["transport/link/tls/enable_mtls"]
    assert_equal @ca.cert.to_pem, cfg["transport/link/tls/root_ca_certificate_base64"].unpack1("m")
    assert_includes cfg["transport/link/tls/connect_private_key_base64"].unpack1("m"), "BEGIN PRIVATE KEY"
    assert_includes cfg["transport/link/tls/connect_certificate_base64"].unpack1("m"), "BEGIN CERTIFICATE"
    assert_equal before, Dir.children(@dir).sort, "nothing is written next to it"
  end

  def test_files_at_the_top_or_in_one_directory
    flat = tar("bob", dir: false)
    c, = quiet { Asterism::Credentials.load(flat) }
    assert_equal "bob", c.name
  end

  def test_name_from_the_key_without_asterism_json
    path = tar("carol", info: false)
    c, = quiet { Asterism::Credentials.load(path) }
    assert_equal ["carol", nil], [c.name, c.router]
  end

  def test_warns_when_others_may_read_it
    path = tar("alice", mode: 0o644)
    _c, err = quiet { Asterism::Credentials.load(path) }
    assert_match(/can be read by others \(mode 0644\); chmod 600/, err)
    path = tar("alice2", mode: 0o640)
    _c, err = quiet { Asterism::Credentials.load(path) }
    assert_match(/mode 0640/, err)
    path = tar("alice3", mode: 0o600)
    _c, err = quiet { Asterism::Credentials.load(path) }
    assert_equal "", err
  end

  def test_refuses_what_is_not_credentials
    bad = File.join(@dir, "x.tar")
    File.binwrite(bad, "not a tar" * 100)
    File.chmod(0o600, bad)
    assert_raises(Asterism::Credentials::Error) { Asterism::Credentials.load(bad) }
    assert_raises(Asterism::Credentials::Error) { Asterism::Credentials.load(File.join(@dir, "none.tar")) }
    other = CredentialsHelper::CA.new
    mixed = File.join(@dir, "mixed.tar")
    File.binwrite(mixed, @ca.tar("alice", key_from: other))
    File.chmod(0o600, mixed)
    e = assert_raises(Asterism::Credentials::Error) { Asterism::Credentials.load(mixed) }
    assert_match(/is not the key of alice.pem/, e.message)
  end

  def test_a_config_string_does_not_combine
    path = tar("alice")
    assert_raises(ArgumentError) { quiet { Asterism::Credentials.merge(path, nil, "{}") } }
    loc, cfg, = quiet { Asterism::Credentials.merge(path, "tls/other:1", { "x/y" => 1 }) }.first
    assert_equal "tls/other:1", loc
    assert_equal 1, cfg["x/y"]
  end

  # A listener with mutual TLS (a peer of this process, certificate
  # "listener" valid for localhost); the node connects with its .tar only.
  def test_connects_with_the_tar_alone
    port = TestHelper.free_port
    files = @ca.files(@dir, "listener", dns: ["localhost"])
    @listener = Z::Session.open(nil, mode: :peer, listen: "tls/localhost:#{port}", config: {
      "transport/link/tls/root_ca_certificate" => files[:ca],
      "transport/link/tls/listen_certificate" => files[:cert],
      "transport/link/tls/listen_private_key" => files[:key],
      "transport/link/tls/enable_mtls" => true
    })
    path = tar("alice", router: "tls/localhost:#{port}")
    got = nil
    Asterism.connect(credentials: path, app: "t", check_timeout: 0.5) do |net|
      assert_equal "alice", net.node_id
      net.expose("echo", Echo.new, methods: [:echo])
      net.start
      q = @listener.get("asterism/alice/t/echo/call/me", payload: MessagePack.pack({ "method" => "echo", "args" => [41] }),
                                                          timeout_ms: 3000)
      deadline = Time.now + 5
      until got || Time.now > deadline
        @listener.poll
        q.each_reply.each { |r| got = MessagePack.unpack(r[1]) }
        sleep 0.02
      end
    end
    assert_equal({ "value" => 41 }, got)
  end

  # Without a certificate the same listener lets nobody in.
  def test_without_the_tar_the_listener_refuses
    port = TestHelper.free_port
    files = @ca.files(@dir, "listener", dns: ["localhost"])
    @listener = Z::Session.open(nil, mode: :peer, listen: "tls/localhost:#{port}", config: {
      "transport/link/tls/root_ca_certificate" => files[:ca],
      "transport/link/tls/listen_certificate" => files[:cert],
      "transport/link/tls/listen_private_key" => files[:key],
      "transport/link/tls/enable_mtls" => true
    })
    assert_raises(Asterism::Disconnected) do
      Asterism.connect("tls/localhost:#{port}", node: "eve", app: "t", connect_timeout: 2,
                       config: { "transport/link/tls/root_ca_certificate" => files[:ca] })
    end
  end

  def test_zenoh_open_takes_credentials
    port = TestHelper.free_port
    files = @ca.files(@dir, "listener", dns: ["localhost"])
    @listener = Z::Session.open(nil, mode: :peer, listen: "tls/localhost:#{port}", config: {
      "transport/link/tls/root_ca_certificate" => files[:ca],
      "transport/link/tls/listen_certificate" => files[:cert],
      "transport/link/tls/listen_private_key" => files[:key],
      "transport/link/tls/enable_mtls" => true
    })
    sub = @listener.subscribe("o1/**")
    path = tar("alice", router: "tls/localhost:#{port}")
    Asterism::Zenoh.open(credentials: path) do |s|
      sleep 0.3
      s.put("o1/x", "hi")
      deadline = Time.now + 3
      got = []
      while got.empty? && Time.now < deadline
        @listener.poll
        got = sub.each_sample
        sleep 0.02
      end
      assert_equal ["hi"], got.map(&:payload)
    end
  end
end
