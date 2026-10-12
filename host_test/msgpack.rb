# A small MessagePack for the mruby test only (rake test:mruby): the
# pack / unpack API of the msgpack gem for the values Asterism sends (nil,
# true, false, Integer, Float, String as str, a binary String (String#b,
# mruby's binary flag; mruby-encoding tells it) as bin, Array, Hash). It
# reads every format but ext (and a uint64 above int64), and refuses bytes
# after the value, so the conformance samples (test/protocol) can be sent to
# it in any of their forms; a bin is read as a binary String. It writes the
# longer forms (array16, map16, int64), which are valid too. The boards use
# a MessagePack gem of their own; this stands in for it here.
module MessagePack
  def self.pack(v)
    out = ""
    put(out, v)
    out
  end

  def self.put(out, v)
    if v.nil?
      out << [0xc0].pack("C")
    elsif v == true
      out << [0xc3].pack("C")
    elsif v == false
      out << [0xc2].pack("C")
    elsif v.is_a?(Integer)
      if v >= 0 && v < 128
        out << [v].pack("C")
      elsif v < 0 && v >= -32
        out << [v & 0xff].pack("C")
      else
        out << [0xd3].pack("C") << [(v >> 32) & 0xffffffff, v & 0xffffffff].pack("NN")
      end
    elsif v.is_a?(Float)
      out << [0xcb].pack("C") << [v].pack("G")
    elsif v.is_a?(String) && v.encoding == "ASCII-8BIT"
      n = v.bytesize
      if n < 256
        out << [0xc4, n].pack("CC")
      elsif n < 65536
        out << [0xc5, n].pack("Cn")
      else
        out << [0xc6, n].pack("CN")
      end
      out << v
    elsif v.is_a?(String)
      n = v.bytesize
      if n < 32
        out << [0xa0 | n].pack("C")
      elsif n < 65536
        out << [0xda, n].pack("Cn")
      else
        out << [0xdb, n].pack("CN")
      end
      out << v
    elsif v.is_a?(Array)
      out << [0xdc, v.size].pack("Cn")
      v.each { |e| put(out, e) }
    elsif v.is_a?(Hash)
      out << [0xde, v.size].pack("Cn")
      v.each do |k, x|
        put(out, k)
        put(out, x)
      end
    else
      raise ArgumentError, "msgpack (test): cannot pack #{v.class}"
    end
  end

  def self.unpack(b)
    v, pos = take(b, 0)
    raise ArgumentError, "msgpack (test): extra bytes" unless pos == b.bytesize
    v
  end

  def self.str(b, pos, n)
    [b.byteslice(pos, n), pos + n]
  end

  def self.bin(b, pos, n)
    [b.byteslice(pos, n).b, pos + n]
  end

  def self.u(b, pos, n)
    v = 0
    n.times { |i| v = v * 256 + b.getbyte(pos + i) }
    v
  end

  def self.take(b, pos)
    c = b.getbyte(pos)
    raise ArgumentError, "msgpack (test): truncated" if c.nil?
    pos += 1
    return [c, pos] if c < 0x80
    return [c - 256, pos] if c >= 0xe0
    return str(b, pos, c & 0x1f) if c >= 0xa0 && c <= 0xbf
    return seq(b, pos, c & 0x0f, false) if c >= 0x90 && c <= 0x9f
    return seq(b, pos, c & 0x0f, true) if c >= 0x80 && c <= 0x8f
    case c
    when 0xc0 then [nil, pos]
    when 0xc2 then [false, pos]
    when 0xc3 then [true, pos]
    when 0xcc then [u(b, pos, 1), pos + 1]
    when 0xcd then [u(b, pos, 2), pos + 2]
    when 0xce then [u(b, pos, 4), pos + 4]
    # 64 bits in two halves: mruby's Integer is int64 (no Bignum), so the
    # sum must not pass through 2**63.
    when 0xcf
      raise ArgumentError, "msgpack (test): uint64 above int64" if b.getbyte(pos) >= 0x80
      [u(b, pos, 4) * 4_294_967_296 + u(b, pos + 4, 4), pos + 8]
    when 0xd0 then x = u(b, pos, 1); [x >= 128 ? x - 256 : x, pos + 1]
    when 0xd1 then x = u(b, pos, 2); [x >= 32768 ? x - 65536 : x, pos + 2]
    when 0xd2 then x = u(b, pos, 4); [x >= 2**31 ? x - 2**32 : x, pos + 4]
    when 0xd3
      hi = u(b, pos, 4)
      hi -= 4_294_967_296 if hi >= 2_147_483_648
      [hi * 4_294_967_296 + u(b, pos + 4, 4), pos + 8]
    when 0xca then [b.byteslice(pos, 4).unpack("g")[0], pos + 4]
    when 0xcb then [b.byteslice(pos, 8).unpack("G")[0], pos + 8]
    when 0xd9 then str(b, pos + 1, u(b, pos, 1))
    when 0xda then str(b, pos + 2, u(b, pos, 2))
    when 0xdb then str(b, pos + 4, u(b, pos, 4))
    when 0xc4 then bin(b, pos + 1, u(b, pos, 1))
    when 0xc5 then bin(b, pos + 2, u(b, pos, 2))
    when 0xc6 then bin(b, pos + 4, u(b, pos, 4))
    when 0xdc then seq(b, pos + 2, u(b, pos, 2), false)
    when 0xdd then seq(b, pos + 4, u(b, pos, 4), false)
    when 0xde then seq(b, pos + 2, u(b, pos, 2), true)
    when 0xdf then seq(b, pos + 4, u(b, pos, 4), true)
    else raise ArgumentError, "msgpack (test): type 0x#{c.to_s(16)} not handled"
    end
  end

  def self.seq(b, pos, n, map)
    if map
      h = {}
      n.times do
        k, pos = take(b, pos)
        v, pos = take(b, pos)
        h[k] = v
      end
      [h, pos]
    else
      a = []
      n.times do
        v, pos = take(b, pos)
        a << v
      end
      [a, pos]
    end
  end
end
