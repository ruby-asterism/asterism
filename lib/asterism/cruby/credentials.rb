# The credentials of one node or router as one file, CRuby's part (the
# class itself is mrblib/credentials.rb, shared with the boards): the .tar
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
  # The portable class is mrblib/credentials.rb (the boards read the .tar
  # with it); CRuby reads the file with the standard library and checks
  # more: who may read the file, and the key pair (prepended, so the
  # portable methods are not redefined).
  class Credentials
    module CRuby
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
    prepend CRuby
  end
end
