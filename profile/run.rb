# Runs the probes on this Ruby and prints RPROF lines (CRuby or the `mruby`
# command; both read the files through File.open, which mruby-io provides):
#
#   ruby  profile/run.rb profile/runner.rb profile/probes.txt cruby-3.4
#   mruby profile/run.rb profile/runner.rb profile/probes.txt mruby-master
#
# profile/profile.rb runs this in docker images and keeps the results.
rp_runner_path = ARGV[0]
rp_probes_path = ARGV[1]
rp_impl = ARGV[2] || "unknown"
eval(File.open(rp_runner_path, "r") { |f| f.read })
rp_probes = RubyProfile.parse(File.open(rp_probes_path, "r") { |f| f.read })
rp = RubyProfile::Runner.new(rp_probes)
puts RubyProfile.header(rp_impl, rp.size)
i = 0
while i < rp.size
  puts rp.line(i)
  i += 1
end
puts RubyProfile.footer(rp_impl, rp.counts)
