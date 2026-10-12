# Typed values (docs/protocol.md, "Conformance samples"): the JSON form the
# samples use for MessagePack values, and the matchers of their expected
# values. CRuby only (the driver and the sample checks); an implementation
# in another language reads the same JSON with its own code.
#
#   null / true / false        nil, true, false
#   "text"                     str (UTF-8)
#   {"int": "-12"}             int (decimal text: every 64-bit value fits)
#   {"float": 1.5}             float; also "inf", "-inf", "nan"
#   {"str": "text"}            str, the same as a bare JSON string
#   {"str_hex": "ff00"}        str carrying these bytes (not UTF-8)
#   {"bin_hex": "ff00"}        bin
#   [v, ...]                   array
#   {"map": [[k, v], ...]}     map (the pairs in order; order is not significant)
#
# Matchers, only in expected values:
#   {"any": "str" | "int" | "float" | "value"}
#   {"match": "regex"}         a str matching the regular expression
#   {"unordered": [v, ...]}    an array with these elements, in any order
require "msgpack"

module TV
  module_function

  # The Ruby value of a typed value. str is a UTF-8 String, bin a binary
  # (ASCII-8BIT) String: that is how msgpack-ruby tells them apart.
  def to_ruby(t)
    case t
    when nil, true, false then t
    when String then t.dup.force_encoding(Encoding::UTF_8)
    when Array then t.map { |e| to_ruby(e) }
    when Hash
      raise ArgumentError, "a matcher is not a value: #{t.inspect}" if t.key?("any") || t.key?("match") || t.key?("unordered")
      raise ArgumentError, "one tag per typed value: #{t.inspect}" unless t.size == 1
      tag, v = t.first
      case tag
      when "int" then Integer(v, 10)
      when "float" then float(v)
      when "str" then v.dup.force_encoding(Encoding::UTF_8)
      when "str_hex" then [v].pack("H*").force_encoding(Encoding::UTF_8)
      when "bin_hex" then [v].pack("H*")
      when "map" then v.to_h { |k, x| [to_ruby(k), to_ruby(x)] }
      else raise ArgumentError, "unknown tag #{tag}"
      end
    else raise ArgumentError, "not a typed value: #{t.inspect}"
    end
  end

  def float(v)
    case v
    when "inf" then Float::INFINITY
    when "-inf" then -Float::INFINITY
    when "nan" then Float::NAN
    else Float(v)
    end
  end

  # The typed value of a Ruby value as msgpack-ruby decodes it.
  def from_ruby(v)
    case v
    when nil, true, false then v
    when Integer then { "int" => v.to_s }
    when Float
      return { "float" => "nan" } if v.nan?
      return { "float" => v.positive? ? "inf" : "-inf" } if v.infinite?
      { "float" => v }
    when String
      if v.encoding == Encoding::BINARY
        { "bin_hex" => v.unpack1("H*") }
      elsif v.valid_encoding?
        v
      else
        { "str_hex" => v.b.unpack1("H*") }
      end
    when Symbol then v.to_s
    when Array then v.map { |e| from_ruby(e) }
    when Hash then { "map" => v.map { |k, x| [from_ruby(k), from_ruby(x)] } }
    else raise ArgumentError, "no typed value for #{v.class}"
    end
  end

  # Decodes MessagePack bytes the way the driver reads the wire: str as
  # UTF-8 Strings (possibly not valid UTF-8), bin as binary Strings.
  def unpack(bytes)
    MessagePack.unpack(bytes.b)
  end

  # Whether the Ruby value v (as decoded) matches the expected typed value.
  # Returns nil when it does, else a short reason.
  def mismatch(expected, v, path = "$")
    case expected
    when nil, true, false
      return nil if v.equal?(expected)
      "#{path}: expected #{expected.inspect}, got #{v.inspect}"
    when Array
      return "#{path}: expected an array, got #{v.inspect[0, 80]}" unless v.is_a?(Array)
      return "#{path}: expected #{expected.size} elements, got #{v.size}" unless v.size == expected.size
      expected.each_with_index do |e, i|
        r = mismatch(e, v[i], "#{path}[#{i}]")
        return r if r
      end
      nil
    when String then str_mismatch(expected.b, v, path)
    when Hash
      if expected.key?("any")
        ok = case expected["any"]
             when "str" then v.is_a?(String) && v.encoding != Encoding::BINARY
             when "int" then v.is_a?(Integer)
             when "float" then v.is_a?(Float)
             else true
             end
        return ok ? nil : "#{path}: expected any #{expected['any']}, got #{v.inspect[0, 80]}"
      end
      if expected.key?("match")
        ok = v.is_a?(String) && v.encoding != Encoding::BINARY && v.match?(Regexp.new(expected["match"]))
        return ok ? nil : "#{path}: expected a str matching /#{expected['match']}/, got #{v.inspect[0, 80]}"
      end
      if expected.key?("unordered")
        return "#{path}: expected an array, got #{v.inspect[0, 80]}" unless v.is_a?(Array)
        left = v.dup
        expected["unordered"].each do |e|
          i = left.index { |x| mismatch(e, x).nil? }
          return "#{path}: no element matches #{e.inspect} in #{v.inspect[0, 120]}" unless i
          left.delete_at(i)
        end
        return left.empty? ? nil : "#{path}: extra elements #{left.inspect[0, 80]}"
      end
      tag, x = expected.first
      case tag
      when "int"
        v.is_a?(Integer) && v == Integer(x, 10) ? nil : "#{path}: expected int #{x}, got #{v.inspect[0, 80]}"
      when "float"
        f = float(x)
        ok = v.is_a?(Float) && (f.nan? ? v.nan? : v == f)
        ok ? nil : "#{path}: expected float #{x}, got #{v.inspect[0, 80]}"
      when "str" then str_mismatch(x.b, v, path)
      when "str_hex" then str_mismatch([x].pack("H*"), v, path)
      when "bin_hex"
        v.is_a?(String) && v.encoding == Encoding::BINARY && v == [x].pack("H*") ? nil : "#{path}: expected bin #{x}, got #{v.inspect[0, 80]}"
      when "map"
        return "#{path}: expected a map, got #{v.inspect[0, 80]}" unless v.is_a?(Hash)
        return "#{path}: expected #{x.size} keys, got #{v.keys.inspect[0, 120]}" unless v.size == x.size
        x.each do |k, e|
          rk = to_ruby(k)
          key = v.keys.find { |kk| mismatch(k, kk).nil? }
          return "#{path}: missing key #{rk.inspect}" if key.nil?
          r = mismatch(e, v[key], "#{path}[#{rk.inspect}]")
          return r if r
        end
        nil
      else "#{path}: unknown tag #{tag}"
      end
    else "#{path}: bad expected value #{expected.inspect}"
    end
  end

  def str_mismatch(bytes, v, path)
    ok = v.is_a?(String) && v.encoding != Encoding::BINARY && v.b == bytes
    ok ? nil : "#{path}: expected str #{bytes.inspect[0, 60]}, got #{v.inspect[0, 80]}"
  end
end
