# The mruby test of Asterism::Credentials (rake test:mruby): the board's way
# of reading a console's .tar (plain Ruby: byteslice / getbyte, no Regexp,
# no pack) gives what CRuby gives. The Rakefile writes the .tar and, from
# CRuby, what must come out of it.
#
#   mruby test_credentials.rb TAR EXPECTED
#
# Prints one line per failed check and a summary; exits with 1 on failure.
tar = ARGV[0]
expected = File.open(ARGV[1], "r") { |f| f.read }.split("\n")
$checks = 0
$fails = 0

def check(cond, what)
  $checks += 1
  return if cond
  $fails += 1
  puts "FAIL: #{what}"
end

def raises(klass, what)
  yield
  check(false, "#{what}: nothing raised")
rescue klass
  check(true, what)
rescue => e
  check(false, "#{what}: #{e.class}: #{e.message} instead of #{klass}")
end

c = Asterism::Credentials.load(tar)
check(c.name == expected[0], "name #{c.name.inspect}")
check(c.router == expected[1], "router #{c.router.inspect}")
z = c.zenoh_config
check(z["transport/link/tls/root_ca_certificate_base64"] == expected[2], "CA as base64")
check(z["transport/link/tls/connect_certificate_base64"] == expected[3], "certificate as base64")
check(z["transport/link/tls/connect_private_key_base64"] == expected[4], "key as base64")
check(z["transport/link/tls/enable_mtls"] == true, "enable_mtls")
locator, config, creds = Asterism::Credentials.merge(tar, nil, { "transport/link/tls/verify_name_on_connect" => false })
check(locator == expected[1] && creds.name == expected[0], "merge: the router and the name")
check(config["transport/link/tls/verify_name_on_connect"] == false && config.size == 5, "merge: config laid over")
check(Asterism::Credentials.merge(c, "tls/192.0.2.1:7448", nil)[0] == "tls/192.0.2.1:7448", "merge: the locator given wins")
check(Asterism::Credentials.base64("") == "" && Asterism::Credentials.base64("a") == "YQ==" &&
      Asterism::Credentials.base64("ab") == "YWI=" && Asterism::Credentials.base64("abc") == "YWJj", "base64 padding")
check(Asterism::Credentials.json_strings('{"format": 1, "name": "n", "router":"tls/h:1"}') ==
        { "name" => "n", "router" => "tls/h:1" }, "asterism.json without a JSON library")
raises(Asterism::Credentials::Error, "not a tar") { Asterism::Credentials.untar("x" * 1024) }
raises(Asterism::Credentials::Error, "a missing file") { Asterism::Credentials.load("#{tar}.none") }
raises(ArgumentError, "credentials: with a config String") { Asterism::Credentials.merge(c, nil, "{}") }
check(Asterism::Credentials::Error.superclass == Asterism::Error, "Credentials::Error < Asterism::Error")
puts "#{$checks} checks, #{$fails} failed"
exit($fails == 0 ? 0 : 1)
