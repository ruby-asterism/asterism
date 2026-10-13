# The credentials of one node or router as one file (CRuby only): the .tar
# an Asterism console hands out when it issues a certificate ("Save all
# (.tar)" on the certificate page; the archive is made in the browser that
# made the key). It holds, at its top or in one directory:
#
#   <name>.key      the private key (PKCS#8 PEM)
#   <name>.pem      the certificate (its common name is <name>)
#   ca.pem          the CA that signed it (and the router's certificate)
#   zenoh.json5     an example configuration (for zenohd or another client)
#   asterism.json   {"name": ..., "router": "tls/host:port", "not_after": ..., ...}
#
#   Asterism.connect(credentials: "alice.tar", app: "game") { |net| ... }
#   Asterism::Zenoh.open(credentials: "alice.tar") { |s| ... }
#   Asterism::ROS.connect(credentials: "alice.tar") { |ros| ... }
#
# The file is read into memory (Gem::Package::TarReader, the standard
# library): nothing is written anywhere. The certificates go to zenoh as
# base64 (transport/link/tls/*_base64) with enable_mtls, the router's
# locator and the node ID come from asterism.json unless given, and a file
# that others may read is warned about, as ssh does with a key.
require "rubygems/package"
require "json"
require "stringio"

module Asterism
  class Credentials
    # What a credentials file is missing or holds wrong.
    class Error < ::Asterism::Error; end

    TLS = "transport/link/tls"
    # The largest file read (the real ones are a few KB).
    MAX_SIZE = 1024 * 1024

    attr_reader :path, :name, :kind, :router, :not_after, :key_pem, :cert_pem, :ca_pem, :info

    # Reads path (a String or Pathname of a .tar). warn: false skips the
    # check of who may read the file.
    def self.load(path, warn: true)
      new(path, warn: warn)
    end

    # A credentials file (a path or a Credentials) and the arguments of a
    # connection -> [locator, config Hash, credentials]. The locator given
    # wins over asterism.json's router; config given (a Hash) is laid over
    # the TLS keys. @api private
    def self.merge(credentials, locator, config)
      creds = credentials.is_a?(Credentials) ? credentials : load(credentials)
      if config.is_a?(String)
        raise ArgumentError, "credentials: and a config String cannot be combined; pass config: as a Hash"
      end
      merged = creds.zenoh_config.merge(config || {})
      [locator || creds.router, merged, creds]
    end

    def initialize(path, warn: true)
      @path = path.to_s
      check_mode if warn
      files = read_tar
      @info = parse_info(files["asterism.json"])
      keys = files.keys.select { _1.end_with?(".key") }
      raise Error, "#{@path}: no private key (<name>.key) in it" if keys.empty?
      raise Error, "#{@path}: more than one private key in it (#{keys.sort.join(', ')})" if keys.size > 1
      @name = @info["name"].to_s
      @name = File.basename(keys.first, ".key") if @name.empty?
      @key_pem = files["#{@name}.key"] or raise Error, "#{@path}: the key is not named after #{@name} (#{keys.first})"
      @cert_pem = files["#{@name}.pem"] or raise Error, "#{@path}: no certificate #{@name}.pem in it"
      @ca_pem = files["ca.pem"] or raise Error, "#{@path}: no ca.pem in it"
      @kind = @info["kind"]
      @router = @info["router"].to_s.empty? ? nil : @info["router"].to_s
      @not_after = @info["not_after"]
      check_pair
    end

    # The zenoh configuration keys (a Hash for Session.open's config:):
    # the CA, the certificate and the key as base64, and mutual TLS.
    def zenoh_config
      {
        "#{TLS}/root_ca_certificate_base64" => b64(@ca_pem),
        "#{TLS}/connect_certificate_base64" => b64(@cert_pem),
        "#{TLS}/connect_private_key_base64" => b64(@key_pem),
        "#{TLS}/enable_mtls" => true
      }
    end

    def inspect
      "#<Asterism::Credentials #{@name} #{@router || '(no router)'}#{@not_after ? " until #{@not_after}" : ''}>"
    end
    alias to_s inspect

    private

    def b64(pem)
      [pem].pack("m0")
    end

    # Like ssh with a private key: a file that the group or others may read
    # is told about (it still works).
    def check_mode
      st = File.stat(@path)
      return if Gem.win_platform? || (st.mode & 0o077).zero?
      Kernel.warn("asterism: #{@path} holds a private key and can be read by others " \
                  "(mode #{format('%04o', st.mode & 0o7777)}); chmod 600 #{@path}")
    rescue SystemCallError => e
      raise Error, "#{@path}: #{e.message}"
    end

    # {basename => content} of the regular files, at the top or in one
    # directory.
    def read_tar
      data = File.binread(@path)
      raise Error, "#{@path}: too large for a credentials file" if data.bytesize > MAX_SIZE
      files = {}
      Gem::Package::TarReader.new(StringIO.new(data)) do |tar|
        tar.each do |entry|
          next unless entry.file?
          base = File.basename(entry.full_name)
          raise Error, "#{@path}: #{base} is in it twice" if files.key?(base)
          files[base] = entry.read.to_s
        end
      end
      raise Error, "#{@path}: not a tar file with credentials in it" if files.empty?
      files
    rescue SystemCallError => e
      raise Error, "#{@path}: #{e.message}"
    rescue Gem::Package::TarInvalidError, ArgumentError => e
      raise Error, "#{@path}: not a tar file (#{e.message})"
    end

    def parse_info(text)
      return {} if text.nil?
      h = JSON.parse(text)
      raise Error, "#{@path}: asterism.json is not an object" unless h.is_a?(Hash)
      h
    rescue JSON::ParserError => e
      raise Error, "#{@path}: asterism.json: #{e.message}"
    end

    # The key belongs to the certificate, and the certificate has not
    # expired (a warning: zenoh refuses it anyway). Skipped without openssl.
    def check_pair
      require "openssl"
      cert = OpenSSL::X509::Certificate.new(@cert_pem)
      key = OpenSSL::PKey.read(@key_pem)
      raise Error, "#{@path}: #{@name}.key is not the key of #{@name}.pem" unless cert.check_private_key(key)
      Kernel.warn("asterism: #{@path}: the certificate expired at #{cert.not_after.utc}") if cert.not_after < Time.now
    rescue LoadError
      nil
    rescue OpenSSL::OpenSSLError => e
      raise Error, "#{@path}: #{e.message}"
    end
  end
end
