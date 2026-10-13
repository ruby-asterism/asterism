# A throwaway CA for the credentials tests: certificates as an Asterism
# console issues them (ECDSA P-256, the common name is the node's name), and
# the .tar its certificate page saves ("Save all (.tar)").
require "openssl"
require "time"
require "json"
require "rubygems/package"
require "stringio"
require "fileutils"

module CredentialsHelper
  class CA
    attr_reader :key, :cert

    def initialize(name = "test CA")
      @key = OpenSSL::PKey::EC.generate("prime256v1")
      @cert = OpenSSL::X509::Certificate.new
      @cert.version = 2
      @cert.serial = rand(2**63)
      @cert.subject = @cert.issuer = OpenSSL::X509::Name.parse("/CN=#{name}")
      @cert.public_key = @key
      @cert.not_before = Time.now - 60
      @cert.not_after = Time.now + 86_400
      ef = OpenSSL::X509::ExtensionFactory.new(@cert, @cert)
      @cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
      @cert.add_extension(ef.create_extension("keyUsage", "keyCertSign,cRLSign", true))
      @cert.sign(@key, OpenSSL::Digest.new("SHA256"))
    end

    # [key, certificate] for name (clientAuth and serverAuth, DNS names).
    def issue(name, dns: [])
      key = OpenSSL::PKey::EC.generate("prime256v1")
      c = OpenSSL::X509::Certificate.new
      c.version = 2
      c.serial = rand(2**63)
      c.subject = OpenSSL::X509::Name.parse("/CN=#{name}")
      c.issuer = @cert.subject
      c.public_key = key
      c.not_before = Time.now - 60
      c.not_after = Time.now + 3600
      ef = OpenSSL::X509::ExtensionFactory.new(c, @cert)
      c.add_extension(ef.create_extension("extendedKeyUsage", "serverAuth,clientAuth"))
      c.add_extension(ef.create_extension("subjectAltName", ([name] + dns).map { "DNS:#{_1}" }.join(","))) unless dns.empty?
      c.sign(@key, OpenSSL::Digest.new("SHA256"))
      [key, c]
    end

    # The three files in dir (for a listener's configuration):
    # {ca:, cert:, key:} paths.
    def files(dir, name, dns: [])
      key, c = issue(name, dns: dns)
      FileUtils.mkdir_p(dir)
      out = { ca: File.join(dir, "ca.pem"), cert: File.join(dir, "#{name}.pem"), key: File.join(dir, "#{name}.key") }
      File.write(out[:ca], @cert.to_pem)
      File.write(out[:cert], c.to_pem)
      File.write(out[:key], key.private_to_pem)
      File.chmod(0o600, out[:key])
      out
    end

    # The bytes of a console's .tar for name. dir: entries under <name>/
    # (the console's layout) or at the top. info: false leaves out
    # asterism.json. key_from: another CA whose key goes in (a wrong pair).
    def tar(name, router: nil, dir: true, info: true, key_from: nil)
      key, c = issue(name)
      key = key_from.issue(name).first if key_from
      prefix = dir ? "#{name}/" : ""
      io = StringIO.new("".b)
      Gem::Package::TarWriter.new(io) do |t|
        t.mkdir(prefix.chomp("/"), 0o755) if dir
        add = ->(file, mode, text) { t.add_file_simple("#{prefix}#{file}", mode, text.bytesize) { _1.write(text) } }
        add.("#{name}.key", 0o600, key.private_to_pem)
        add.("#{name}.pem", 0o644, c.to_pem)
        add.("ca.pem", 0o644, @cert.to_pem)
        add.("zenoh.json5", 0o644, "{ mode: \"client\" }\n")
        if info
          add.("asterism.json", 0o644, JSON.generate({ "format" => 1, "name" => name, "kind" => "client",
                                                        "router" => router, "not_after" => c.not_after.utc.iso8601 }))
        end
      end
      io.string
    end
  end
end
