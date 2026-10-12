# The conformance samples themselves (rake test:protocol, before the
# driver runs): samples.json is what gen_samples.rb writes, every byte form
# of a value decodes to that value, the first form is what this
# implementation writes, and the matchers do reject what they should.
require "minitest/autorun"
require "json"
require "rbconfig"
require "asterism"
require_relative "tv"

class TestProtocolSamples < Minitest::Test
  S = JSON.parse(File.read(File.join(__dir__, "samples.json")))

  def test_samples_json_is_generated
    assert system(RbConfig.ruby, File.join(__dir__, "gen_samples.rb"), "--check", out: File::NULL),
           "samples.json is stale: run ruby test/protocol/gen_samples.rb"
  end

  def test_every_encoding_decodes_to_the_value
    S["values"].each do |v|
      next unless v["portable"] && !v["expect"]
      v["encodings"].each do |hex|
        got = TV.unpack([hex].pack("H*"))
        assert_nil TV.mismatch(v["value"], got), "#{v['id']} as #{hex[0, 20]}"
      end
    end
  end

  def test_the_first_encoding_is_what_cruby_writes
    S["values"].each do |v|
      next unless v["portable"] && !v["expect"]
      sent = Asterism::Codec.pack(TV.to_ruby(v["value"])).unpack1("H*")
      assert_equal v["encodings"][0], sent, v["id"]
    end
  end

  def test_payloads_are_messagepack_unless_meant_not_to_be
    S["incoming"].each do |q|
      next if q["payload_hex"].nil? || !q["portable"] || q["id"].start_with?("malformed:")
      TV.unpack([q["payload_hex"]].pack("H*")) # raises when not
    end
    S["outgoing"].each do |o|
      o["reply_hex"].each { |h| TV.unpack([h].pack("H*")) unless o["id"].include?("not MessagePack") }
    end
    pass
  end

  # What the protocol does not carry: the CRuby implementation does not
  # read it as a value either.
  def test_values_outside_the_protocol_do_not_decode
    S["values"].select { _1["expect"] }.each do |v|
      v["encodings"].each { |hex| assert_nil Asterism::Codec.unpack([hex].pack("H*")), "#{v['id']} as #{hex}" }
    end
    pass
  end

  def test_the_icon_is_the_one_named
    icon = [S["icon"]["hex"]].pack("H*")
    assert_equal S["icon"]["icon_hash"], Asterism::Profile.png_info(icon)[2]
  end

  def test_matchers_reject
    refute_nil TV.mismatch({ "int" => "1" }, 1.0), "an int is not a float"
    refute_nil TV.mismatch({ "float" => 1.0 }, 1), "a float is not an int"
    refute_nil TV.mismatch("a", "a".b), "str is not bin"
    refute_nil TV.mismatch({ "bin_hex" => "61" }, "a"), "bin is not str"
    refute_nil TV.mismatch(nil, false), "nil is not false"
    refute_nil TV.mismatch([1], [1, 2]), "length"
    refute_nil TV.mismatch({ "map" => [["a", { "int" => "1" }]] }, { "a" => 1, "b" => 2 }), "extra key"
    refute_nil TV.mismatch({ "match" => "\\Aab\\z" }, "abc"), "regex"
    refute_nil TV.mismatch({ "unordered" => [{ "int" => "1" }, { "int" => "2" }] }, [1, 1]), "unordered"
    assert_nil TV.mismatch({ "unordered" => [{ "int" => "1" }, { "int" => "2" }] }, [2, 1])
    assert_nil TV.mismatch({ "map" => [[{ "int" => "1" }, "x"]] }, { 1 => "x" })
    assert_nil TV.mismatch({ "str_hex" => "ff" }, "\xff".dup.force_encoding("UTF-8"))
  end
end
