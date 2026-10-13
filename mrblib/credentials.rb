# The credentials of one node or router as one file: the .tar an Asterism
# console hands out when it issues a certificate ("Save all (.tar)" on the
# certificate page; the archive is made in the browser that made the key).
# It holds, at its top or in one directory:
#
#   <name>.key      the private key (PKCS#8 PEM)
#   <name>.pem      the certificate (its common name is <name>)
#   ca.pem          the CA that signed it (and the router's certificate)
#   zenoh.json5     an example configuration (for zenohd or another client)
#   asterism.json   {"name": ..., "router": "tls/host:port", "not_after": ..., ...}
#
#   Asterism.connect(credentials: "/home/asterism/alice.tar", app: "game")
#
# The certificates go to zenoh as base64 (transport/link/tls/*_base64) with
# enable_mtls, and the router's locator and the node ID come from
# asterism.json unless given. This is the portable part, in plain Ruby for
# the boards (mruby / PicoRuby: no Regexp, no pack, no File.binread): the
# file is read whole and the tar taken apart with byteslice / getbyte.
# CRuby replaces the reading and adds checks (lib/asterism/cruby/credentials.rb:
# the standard library's tar reader, file modes, the key pair).
module Asterism
  class Credentials
    # What a credentials file is missing or holds wrong.
    class Error < ::Asterism::Error; end

    TLS = "transport/link/tls"
    # The largest file read (the real ones are a few KB).
    MAX_SIZE = 1024 * 1024
    BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    attr_reader :path, :name, :kind, :router, :not_after, :key_pem, :cert_pem, :ca_pem, :info

    # Reads path (a String of a .tar). warn: false skips the check of who
    # may read the file (CRuby; the boards have no file modes).
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
      merged = creds.zenoh_config
      (config || {}).each { |k, v| merged[k] = v }
      [locator || creds.router, merged, creds]
    end

    # {basename => content} of the regular files of a ustar archive (data,
    # a String of its bytes), at its top or in one directory. @api private
    def self.untar(data, path = "the file")
      files = {}
      pos = 0
      total = data.bytesize
      while pos + 512 <= total
        break if data.getbyte(pos) == 0 # the end: blocks of zeros
        name = field(data, pos, 100)
        prefix = field(data, pos + 345, 155)
        size_text = field(data, pos + 124, 12).strip
        type = data.getbyte(pos + 156)
        size = size_text.empty? ? 0 : size_text.to_i(8)
        pos += 512
        raise Error, "#{path}: not a tar file (a member runs past the end)" if pos + size > total
        if type == 48 || type == 0 # '0' or NUL: a regular file
          full = prefix.empty? ? name : "#{prefix}/#{name}"
          base = full.split("/").last.to_s
          raise Error, "#{path}: #{base} is in it twice" if files.key?(base)
          files[base] = data.byteslice(pos, size) unless base.empty?
        end
        pos += (size + 511) / 512 * 512
      end
      raise Error, "#{path}: not a tar file with credentials in it" if files.empty?
      files
    end

    # The text of a NUL-terminated header field. @api private
    def self.field(data, pos, len)
      n = 0
      n += 1 while n < len && data.getbyte(pos + n) != 0
      data.byteslice(pos, n).to_s
    end

    # base64 of s without line breaks (CRuby's [s].pack("m0")). @api private
    def self.base64(s)
      out = ""
      n = s.bytesize
      i = 0
      while i < n
        b0 = s.getbyte(i)
        b1 = i + 1 < n ? s.getbyte(i + 1) : 0
        b2 = i + 2 < n ? s.getbyte(i + 2) : 0
        v = (b0 << 16) | (b1 << 8) | b2
        out << BASE64[(v >> 18) & 63] << BASE64[(v >> 12) & 63]
        out << (i + 1 < n ? BASE64[(v >> 6) & 63] : "=")
        out << (i + 2 < n ? BASE64[v & 63] : "=")
        i += 3
      end
      out
    end

    # The string fields of asterism.json without a JSON library (only for
    # a build that has none). @api private
    def self.json_strings(text)
      h = {}
      %w[format name kind router serial not_after fingerprint console issued_at].each do |k|
        key = "\"#{k}\""
        i = text.index(key)
        next unless i
        rest = text[i + key.size, text.size - i - key.size].to_s
        colon = rest.index(":")
        next unless colon
        q1 = colon + 1
        q1 += 1 while rest[q1] == " "
        next unless rest[q1] == "\""
        q2 = rest.index("\"", q1 + 1)
        next unless q2
        h[k] = rest[q1 + 1, q2 - q1 - 1]
      end
      h
    end

    def initialize(path, warn: true)
      @path = path.to_s
      check_mode if warn
      files = read_tar
      @info = parse_info(files["asterism.json"])
      keys = files.keys.select { |f| f.end_with?(".key") }
      raise Error, "#{@path}: no private key (<name>.key) in it" if keys.empty?
      raise Error, "#{@path}: more than one private key in it (#{keys.sort.join(', ')})" if keys.size > 1
      @name = @info["name"].to_s
      @name = keys.first[0, keys.first.size - 4] if @name.empty?
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
      Credentials.base64(pem)
    end

    # The boards have no file modes (CRuby warns like ssh).
    def check_mode; end

    # The key pair is checked by CRuby (openssl); on the boards the router
    # refuses a wrong one.
    def check_pair; end

    def read_tar
      data = begin
        ::File.open(@path, "r") { |f| f.read }
      rescue StandardError => e
        raise Error, "#{@path}: #{e.message}"
      end
      raise Error, "#{@path}: cannot be read" if data.nil?
      raise Error, "#{@path}: too large for a credentials file" if data.bytesize > MAX_SIZE
      Credentials.untar(data, @path)
    end

    def parse_info(text)
      return {} if text.nil?
      return Credentials.json_strings(text) unless Object.const_defined?(:JSON)
      h = ::JSON.parse(text)
      raise Error, "#{@path}: asterism.json is not an object" unless h.is_a?(Hash)
      h
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "#{@path}: asterism.json: #{e.message}"
    end
  end
end
