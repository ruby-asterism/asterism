# Plain Zenoh with the Ruby-like API: subscribes with a block, answers a
# queryable, puts, asks every status with a get, and watches who is there.
# Run two of them with different --name to see each other.
#
#   ruby examples/zenoh.rb --router tcp/192.0.2.2:7447 --name pc1 [--seconds 10]
#
# A board running fmruby-core's zenoh_echo puts fmrb/test/out every second;
# --key fmrb/test/** prints those too.
# This repository's lib, and asterism-zenoh's next to it (ASTERISM_ZENOH_DIR
# overrides; an installed asterism-zenoh gem works too).
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__),
                   File.join(ENV["ASTERISM_ZENOH_DIR"] || File.expand_path("../../asterism-zenoh", __dir__), "lib"))
require "asterism"
require "optparse"

opt = { router: "tcp/127.0.0.1:7447", name: "pc", seconds: 10, key: nil }
OptionParser.new do |o|
  o.on("--router LOC") { |v| opt[:router] = v }
  o.on("--name NAME") { |v| opt[:name] = v }
  o.on("--seconds S", Float) { |v| opt[:seconds] = v }
  o.on("--key KEY", "also print the samples of KEY") { |v| opt[:key] = v }
end.parse!

def log(text)
  puts "#{Time.now.strftime('%H:%M:%S.%L')} #{text}"
  $stdout.flush
end

me = opt[:name]
Asterism::Zenoh.open(opt[:router]) do |s|
  s.on_error { |e, where| log("#{where}: #{e.message}") }
  s.subscribe("demo/*/hello") { |sample| log("heard #{sample.key}: #{sample.text}") }
  s.subscribe(opt[:key]) { |sample| log("#{sample.key} = #{sample.payload}") } if opt[:key]
  s.queryable("demo/#{me}/status") { |q| q.reply("#{me} up, ruby #{RUBY_VERSION}") }
  token = s.liveliness("demo/#{me}")
  s.liveliness_watch("demo/*") do |key, alive|
    log("#{key} #{alive ? 'is here' : 'left'}") unless key == "demo/#{me}"
  end
  s.start

  sleep 0.3
  s.put("demo/#{me}/hello", "hi from #{me}")
  s.get("demo/*/status").each { |reply| log("status #{reply.key}: #{reply.text}") }

  # Pattern matching on samples.
  watcher = Thread.new do
    s.subscribe("demo/*/temp").each(timeout: opt[:seconds]).each do |sample|
      case sample
      in { key: %r{\Ademo/(\w+)/temp\z}, payload: }
        log("temperature from #{Regexp.last_match(1)}: #{payload.to_f}")
      end
    end
  end
  3.times do |i|
    s.put("demo/#{me}/temp", (20.5 + i).to_s)
    sleep 0.2
  end

  s.stop
  log("receiving on the main thread for #{opt[:seconds]} s (Ctrl-C ends)")
  Thread.new do
    sleep opt[:seconds]
    s.stop
  end
  s.run
  watcher.kill
  token.close
end
