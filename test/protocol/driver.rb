# The conformance driver (docs/protocol.md 7): checks an implementation of
# the Asterism wire protocol against test/protocol/samples.json, over Zenoh.
# It uses only the plain Zenoh API (asterism-zenoh) and msgpack, never
# Asterism's object layer, so what it checks is what goes on the wire.
#
#   ruby -I lib -I ../asterism-zenoh/lib test/protocol/driver.rb [options] -- COMMAND...
#
# COMMAND starts the implementation under test; the driver appends three
# arguments: the locator, "peer" or "client", and the path of the sample
# icon (a PNG file). Options:
#   --router LOCATOR   both are clients of this router (else: the driver
#                      listens as a peer on a free local port)
#   --name NAME        how to call the implementation in the output
#   --json FILE        also write the results as JSON
#   --verbose          print every check, not only the failures
# Exits 0 when every portable check passed. The non-portable samples are
# printed as INFO with what the implementation answered.
require "json"
require "socket"
require "tmpdir"
require "asterism/zenoh"
require "asterism"
require_relative "tv"

SAMPLES = JSON.parse(File.read(File.join(__dir__, "samples.json")))

router = nil
name = "implementation"
json_out = nil
verbose = false
args = ARGV.dup
cmd = []
while (a = args.shift)
  case a
  when "--router" then router = args.shift
  when "--name" then name = args.shift
  when "--json" then json_out = args.shift
  when "--verbose" then verbose = true
  when "--" then cmd = args.dup; break
  else abort "unknown option #{a}"
  end
end
abort "usage: driver.rb [--router LOC] [--name NAME] -- COMMAND..." if cmd.empty?

IUT = SAMPLES["names"]["iut"]
APP = SAMPLES["names"]["app"]
DRV = SAMPLES["names"]["driver"]

class Results
  attr_reader :list

  def initialize(verbose)
    @list = []
    @verbose = verbose
  end

  def add(section, id, ok, detail = nil, portable: true)
    status = if portable
               ok ? "pass" : "FAIL"
             else
               "info"
             end
    @list << { "section" => section, "id" => id, "status" => status, "detail" => detail }
    puts "#{status.ljust(4)} #{section}: #{id}#{detail ? " -- #{detail}" : ''}" if status != "pass" || @verbose
  end

  def failed
    @list.count { |r| r["status"] == "FAIL" }
  end
end
R = Results.new(verbose)

def hexbytes(h)
  h.nil? ? nil : [h].pack("H*")
end

def decode(bytes)
  return [:none, nil] if bytes.nil? || bytes.empty?
  [:ok, TV.unpack(bytes)]
rescue StandardError => e
  [:bad, e.class.name]
end

# Compares the replies of one get with the expected list: same number,
# each expected one matched by a different reply (any order).
def replies_mismatch(expected, replies)
  return "error replies: #{replies.select(&:error?).size}" if replies.any?(&:error?)
  if expected.size != replies.size
    got = replies.map { |r| "#{r.key} #{TV.from_ruby(decode(r.payload)[1]).to_json[0, 120]}" }
    return "expected #{expected.size} replies, got #{replies.size}: #{got.join(' | ')}"
  end
  left = replies.dup
  expected.each do |e|
    reasons = []
    i = left.index do |r|
      st, v = decode(r.payload)
      why = if r.key != e["key"]
              "key #{r.key}"
            elsif st != :ok
              "payload not MessagePack (#{v})"
            else
              TV.mismatch(e["payload"], v)
            end
      reasons << why if why
      why.nil?
    end
    return "no reply matches #{e['key']}: #{reasons.join('; ')}" unless i
    left.delete_at(i)
  end
  nil
end

def observed(replies)
  replies.map { |r| [r.key, TV.from_ruby(decode(r.payload)[1])] }.to_json[0, 200]
end

# ------------------------------------------------------------ session
if router
  loc = router
  mode = "client"
  s = Asterism::Zenoh.open(router)
else
  port = TCPServer.new("127.0.0.1", 0).then { |sv| sv.addr[1].tap { sv.close } }
  loc = "tcp/127.0.0.1:#{port}"
  mode = "peer"
  s = Asterism::Zenoh.open(nil, mode: :peer, listen: loc)
end

lock = Mutex.new
alive = {}
seen = []
profile_puts = []
s.liveliness_watch("asterism/**") do |key, up|
  lock.synchronize do
    alive[key] = up
    seen << [key, up]
  end
end
s.subscribe("asterism/#{IUT}/@profile") { |sm| lock.synchronize { profile_puts << sm.payload.b } }

icon_file = File.join(Dir.mktmpdir("asterism-protocol"), "icon.png")
File.binwrite(icon_file, hexbytes(SAMPLES["icon"]["hex"]))

out_r, out_w = IO.pipe
pid = Process.spawn(*cmd, loc, mode, icon_file, out: out_w, err: out_w)
out_w.close
iut_out = +""
reader = Thread.new { out_r.each_line { |l| lock.synchronize { iut_out << l } } }

def wait(timeout)
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  until yield
    return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) - t > timeout
    sleep 0.01
  end
  true
end

s.start
begin
  # ---------------------------------------------------------- liveliness
  want = SAMPLES["liveliness"]["alive"]
  up = wait(20) { lock.synchronize { want.all? { |k| alive[k] } } }
  R.add("liveliness", "tokens alive", up, up ? nil : "alive: #{alive.select { |_, v| v }.keys.inspect}")
  abort "the implementation did not come up:\n#{iut_out}" unless up
  sleep 0.3
  extra = lock.synchronize { alive.select { |k, v| v && k.start_with?("asterism/#{IUT}") && !want.include?(k) }.keys }
  R.add("liveliness", "no other tokens of the node", extra.empty?, extra.empty? ? nil : extra.inspect)

  # The profile put at connect may come just after the tokens.
  wait(3) { lock.synchronize { profile_puts.size >= 1 } }

  # ---------------------------------------------------------- values (through subject.echo)
  echo_key = "asterism/#{IUT}/#{APP}/subject/call"
  SAMPLES["values"].each do |v|
    v["encodings"].each_with_index do |enc, n|
      payload = hexbytes("93a46563686f91#{enc}80")
      replies = s.get(echo_key, timeout: 2.0, payload: payload, errors: true).to_a
      expected = v["expect"] || [{ "key" => echo_key, "payload" => ["ok", v["value"]] }]
      why = replies_mismatch(expected, replies)
      id = n.zero? ? v["id"] : "#{v['id']} (as #{enc[0, 12]}#{enc.size > 12 ? '...' : ''})"
      if v["portable"]
        R.add("values", id, why.nil?, why)
      else
        R.add("values", id, true, "answered #{observed(replies)}", portable: false)
      end
    end
  end

  # ---------------------------------------------------------- incoming
  SAMPLES["incoming"].each do |q|
    replies = s.get(q["key"], timeout: 2.0, params: q["params"], payload: hexbytes(q["payload_hex"]), errors: true).to_a
    # The driver's own queryables are not declared yet, so every reply is the implementation's.
    if q["portable"]
      why = replies_mismatch(q["replies"], replies)
      R.add("incoming", q["id"], why.nil?, why)
    else
      R.add("incoming", q["id"], true, "answered #{observed(replies)}", portable: false)
    end
  end

  # ---------------------------------------------------------- outgoing
  outs = SAMPLES["outgoing"]
  by_call = outs.select { |o| o["do"].key?("call") }.to_h { |o| [o["do"]["call"], o] }
  meta = outs.find { |o| o["do"].key?("respond_to") }
  profile_steps = outs.select { |o| o["do"].key?("profile_of") }
  requests = {} # id => [ok, detail]
  reports = []
  done = false
  meta_count = 0
  check_request = lambda do |o, q|
    exp = o["request"]
    why = nil
    why = "key #{q.key}, expected #{exp['key']}" if q.key != exp["key"]
    why ||= "params #{q.params.inspect}, expected #{exp['params'].inspect}" if q.params.to_s != exp["params"].to_s
    if why.nil?
      if exp["payload"].nil?
        why = "a payload where none was expected" unless q.payload.nil? || q.payload.empty?
      else
        st, v = decode(q.payload)
        why = st == :ok ? TV.mismatch(exp["payload"], v) : "payload #{st} #{v}"
      end
    end
    why
  end
  answer = lambda do |o, q|
    o["reply_hex"].each { |h| q.reply(q.key, hexbytes(h)) }
  end
  rec_key = "asterism/#{DRV}/#{APP}/rec"
  s.queryable("asterism/#{DRV}/#{APP}/**") do |q|
    parts = q.key.split("/")
    if q.key == "#{rec_key}/meta"
      meta_count += 1
      lock.synchronize { requests[meta["id"]] = check_request.(meta, q) } if meta_count == 1
      answer.(meta, q)
    elsif q.key == "#{rec_key}/call"
      st, req = decode(q.payload)
      method = st == :ok && req.is_a?(Array) ? req[0] : nil
      if method == "report"
        lock.synchronize { reports << req[1] }
        q.reply(q.key, MessagePack.pack(["ok", nil], compatibility_mode: true))
      elsif method == "done"
        lock.synchronize { done = true }
        q.reply(q.key, MessagePack.pack(["ok", nil], compatibility_mode: true))
      elsif (o = by_call[method])
        lock.synchronize { requests[o["id"]] = check_request.(o, q) }
        answer.(o, q)
      else
        lock.synchronize { requests["unexpected #{method.inspect}"] = "unexpected call #{q.key} #{TV.from_ruby(req).to_json[0, 120]}" }
      end
    else
      lock.synchronize { requests["unexpected #{q.key}"] = "unexpected query #{q.key} (#{parts.size} chunks)" }
    end
  end
  profile_n = 0
  s.queryable("asterism/#{DRV}/@profile") do |q|
    o = profile_steps[profile_n]
    profile_n += 1
    if o
      lock.synchronize { requests[o["id"]] = check_request.(o, q) }
      answer.(o, q)
    end
  end
  tokens = [s.liveliness("asterism/#{DRV}"), s.liveliness(rec_key)]
  finished = wait(90) { lock.synchronize { done } }
  R.add("outgoing", "all steps reported", finished, finished ? nil : "#{reports.size} of #{outs.size} reported")
  outs.each_with_index do |o, n|
    if o["request"]
      if lock.synchronize { requests.key?(o["id"]) }
        why = requests[o["id"]]
        R.add("outgoing", "#{o['id']}: request", why.nil?, why)
      else
        R.add("outgoing", "#{o['id']}: request", false, "no request came")
      end
    end
    rep = reports[n]
    if rep.nil?
      R.add("outgoing", "#{o['id']}: outcome", false, "not reported")
    elsif rep[0] != o["id"]
      R.add("outgoing", "#{o['id']}: outcome", false, "report #{n} is for #{rep[0].inspect}")
    else
      why = TV.mismatch(o["outcome"], rep[1])
      R.add("outgoing", "#{o['id']}: outcome", why.nil?, why ? "#{why} (#{TV.from_ruby(rep[1]).to_json[0, 160]})" : nil)
    end
  end
  requests.each_key do |k|
    R.add("outgoing", k, false, requests[k]) if k.start_with?("unexpected")
  end
  R.add("outgoing", "meta fetched once", meta_count == 1, "#{meta_count} meta queries")

  # ---------------------------------------------------------- after close
  gone = SAMPLES["liveliness"]["gone_after_close"]
  down = wait(10) { lock.synchronize { gone.none? { |k| alive[k] } } }
  R.add("liveliness", "tokens gone after close", down, down ? nil : "still alive: #{gone.select { |k| alive[k] }.inspect}")
  tokens.each(&:close)

  # ---------------------------------------------------------- profile puts
  puts_now = lock.synchronize { profile_puts.dup }
  SAMPLES["profile_puts"].each_with_index do |p, n|
    b = puts_now[n]
    if b.nil?
      R.add("profile puts", p["when"], false, "#{puts_now.size} puts came")
    else
      st, v = decode(b)
      why = st == :ok ? TV.mismatch(p["payload"], v) : "not MessagePack"
      R.add("profile puts", p["when"], why.nil?, why)
    end
  end
  R.add("profile puts", "no other puts", puts_now.size == SAMPLES["profile_puts"].size, "#{puts_now.size} puts")
ensure
  begin
    exited = wait(5) { Process.waitpid(pid, Process::WNOHANG) }
    unless exited
      Process.kill("TERM", pid)
      Process.waitpid(pid)
    end
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  end
  reader.join(2)
  s.close
end

lines = iut_out.lines.map(&:chomp)
iut_fails = lines.grep(/\AFAIL/)
R.add("implementation", "its own output", iut_fails.empty? && lines.include?("done"),
      iut_fails.empty? && lines.include?("done") ? nil : lines.last(5).join(" / "))

counts = R.list.group_by { |r| r["status"] }.transform_values(&:size)
puts "#{name}: #{counts['pass'] || 0} passed, #{counts['FAIL'] || 0} failed, #{counts['info'] || 0} informational"
if json_out
  File.write(json_out, JSON.pretty_generate({ "implementation" => name, "results" => R.list }) + "\n")
end
exit(R.failed.zero? ? 0 : 1)
