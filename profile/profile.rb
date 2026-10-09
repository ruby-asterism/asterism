# The Ruby profile's host tool (CRuby): runs the probes on each Ruby, keeps
# the results in profile/results/<impl>.txt and writes the table into
# docs/ruby_profile.md.
#
#   ruby profile/profile.rb cruby               # CRuby 3.2 / 3.4 / 4.0 and
#                                               # 4.0 with frozen literals (docker)
#   ruby profile/profile.rb mruby BIN [NAME [IMAGE]]
#                                               # an `mruby` or `picoruby` command
#                                               # (NAME: mruby-master, picoruby-master),
#                                               # in docker IMAGE when given (for a
#                                               # binary built in a newer glibc)
#   ruby profile/profile.rb sync CORE_DIR       # copy runner + probes into
#                                               # fmruby-core's flash/app/test/ruby_profile/
#   ruby profile/profile.rb collect NAME [CONTAINER]
#                                               # the last run of the app in the sim's log
#                                               # (docker logs, default fmruby_core)
#   ruby profile/profile.rb table               # regenerate the table in docs/ruby_profile.md
#
# Image names can be changed with RPROF_IMAGE_<version> (e.g.
# RPROF_IMAGE_3_2=ruby:3.2). Each run prints the RPROF lines it kept.
require "open3"
require "fileutils"

module ProfileTool
  ROOT = File.expand_path("..", __dir__)
  DIR = File.join(ROOT, "profile")
  RESULTS = File.join(DIR, "results")
  DOC = File.join(ROOT, "docs", "ruby_profile.md")

  # Columns of the table, in order: [result name, heading].
  IMPLS = [
    ["cruby-3.2", "CRuby 3.2"],
    ["cruby-3.4", "CRuby 3.4"],
    ["cruby-4.0", "CRuby 4.0"],
    ["cruby-4.0-frozen", "CRuby 4.0 frozen"],
    ["mruby-master", "mruby master"],
    ["picoruby-master", "PicoRuby master"],
    ["sim-standard", "app VM std"],
    ["sim-compat", "app VM compat"],
  ]

  CRUBY = [
    ["cruby-3.2", "ruby:3.2-slim", {}],
    ["cruby-3.4", "ruby:3.4-slim", {}],
    ["cruby-4.0", "ruby:4.0", {}],
    ["cruby-4.0-frozen", "ruby:4.0", {"RUBYOPT" => "--enable-frozen-string-literal"}],
  ]

  module_function

  def run_args(prefix)
    ["#{prefix}profile/run.rb", "#{prefix}profile/runner.rb", "#{prefix}profile/probes.txt"]
  end

  def keep(name, out)
    lines = out.lines.map(&:chomp).select { |l| l.start_with?("RPROF") }
    abort "#{name}: no RPROF lines\n#{out}" if lines.empty?
    FileUtils.mkdir_p(RESULTS)
    File.write(File.join(RESULTS, "#{name}.txt"), lines.join("\n") + "\n")
    puts lines.grep(/\ARPROF-END/)
  end

  def cruby
    CRUBY.each do |name, image, env|
      image = ENV.fetch("RPROF_IMAGE_#{name.delete_prefix('cruby-').tr('.-', '__')}", image)
      envs = env.flat_map { |k, v| ["-e", "#{k}=#{v}"] }
      cmd = ["docker", "run", "--rm", *envs, "-v", "#{ROOT}:/w", "-w", "/w", image,
             "ruby", *run_args(""), name]
      out, st = Open3.capture2e(*cmd)
      abort "#{name}: #{out}" unless st.success?
      keep(name, out)
    end
  end

  def mruby(bin, name = "mruby-master", image = nil)
    bin = File.realpath(bin)
    cmd = if image
            ["docker", "run", "--rm", "-v", "#{ROOT}:/w", "-v", "#{File.dirname(bin)}:/b", "-w", "/w",
             image, "/b/#{File.basename(bin)}", *run_args(""), name]
          else
            [bin, *run_args("#{ROOT}/"), name]
          end
    out, st = Open3.capture2e(*cmd)
    abort "#{name}: #{out}" unless st.success?
    keep(name, out)
  end

  def sync(core)
    dst = File.join(File.expand_path(core), "flash", "app", "test", "ruby_profile")
    FileUtils.mkdir_p(dst)
    %w[runner.rb probes.txt].each { |f| FileUtils.cp(File.join(DIR, f), dst) }
    puts "copied runner.rb, probes.txt -> #{dst}"
  end

  # The app logs through the kernel's logger: keep what follows "RPROF" on
  # each line, from the last RPROF-BEGIN on.
  def collect(name, container = "fmruby_core")
    out, st = Open3.capture2e("docker", "logs", container)
    abort out unless st.success?
    lines = out.lines.map { |l| (i = l.index("RPROF")) ? l[i..].chomp : nil }.compact
    start = lines.rindex { |l| l.start_with?("RPROF-BEGIN") }
    abort "no RPROF-BEGIN in the log of #{container}" unless start
    run = lines[start..]
    stop = run.index { |l| l.start_with?("RPROF-END") }
    abort "the run has not finished (no RPROF-END yet)" unless stop
    keep(name, run[0..stop].map { |l| l.sub(/\e\[[0-9;]*m\z/, "") }.join("\n"))
  end

  Probe = Struct.new(:id, :area, :title, :mrblib, :kind)

  def probes
    list = []
    File.foreach(File.join(DIR, "probes.txt")) do |l|
      next unless l.start_with?("## ")
      key, val = l[3..].chomp.split(": ", 2)
      list << Probe.new(val) if key == "id"
      next if list.empty?
      case key
      when "area" then list.last.area = val
      when "title" then list.last.title = val
      when "mrblib" then list.last.mrblib = val
      when "kind" then list.last.kind = val
      end
    end
    list
  end

  def results
    IMPLS.to_h do |name, _|
      path = File.join(RESULTS, "#{name}.txt")
      rows = {}
      if File.file?(path)
        File.foreach(path) do |l|
          next unless l.start_with?("RPROF|")
          _, id, status, detail = l.chomp.split("|", 4)
          rows[id] = [status, detail.to_s]
        end
      end
      [name, rows]
    end
  end

  def esc(s)
    s.to_s.gsub("|", "\\|").gsub("`", "'")
  end

  def table
    pr = probes
    res = results
    out = []
    out << "| Feature | Area | " + IMPLS.map(&:last).join(" | ") + " | mrblib |"
    out << "|---|---|" + IMPLS.map { "---" }.join("|") + "|---|"
    details = []
    pr.reject { |p| p.kind == "measure" }.each do |p|
      answers = {}  # detail -> the columns that gave it (same answer, one line)
      cells = IMPLS.map do |name, head|
        st, detail = res[name][p.id]
        next "-" unless st
        (answers[detail] ||= []) << head unless st == "ok"
        st == "ok" ? "ok" : "**#{st}**"
      end
      answers.each { |detail, heads| details << "- `#{p.id}` on #{heads.join(', ')}: #{esc(detail)}" }
      out << "| `#{p.id}` #{esc(p.title)} | #{p.area} | #{cells.join(' | ')} | #{esc(p.mrblib)} |"
    end
    meas = ["", "Measurements, not judged (recursion_limit is a depth; the others are microseconds per operation on one x86-64 machine, so compare rows within a column rather than across machines):", "",
            "| Operation | " + IMPLS.map(&:last).join(" | ") + " |",
            "|---|" + IMPLS.map { "---" }.join("|") + "|"]
    pr.select { |p| p.kind == "measure" }.each do |p|
      cells = IMPLS.map { |name, _| (r = res[name][p.id]) ? r[1] : "-" }
      meas << "| `#{p.id}` #{esc(p.title)} | #{cells.join(' | ')} |"
    end
    totals = ["", "| Totals | " + IMPLS.map(&:last).join(" | ") + " |",
              "|---|" + IMPLS.map { "---" }.join("|") + "|"]
    %w[ok differs ng].each do |st|
      totals << "| #{st} | " + IMPLS.map { |name, _| res[name].count { |_, v| v[0] == st } }.join(" | ") + " |"
    end
    body = (out + totals + meas + ["", "What the cells that are not ok answered:", ""] + details).join("\n")
    doc = File.read(DOC)
    b = "<!-- profile:begin -->"
    e = "<!-- profile:end -->"
    i = doc.index(b) or abort "#{DOC}: no #{b}"
    j = doc.index(e) or abort "#{DOC}: no #{e}"
    File.write(DOC, doc[0, i + b.size] + "\n" + body + "\n" + doc[j..])
    puts "wrote the table into #{DOC} (#{pr.size} probes, #{IMPLS.size} columns)"
  end
end

cmd, *args = ARGV
case cmd
when "cruby" then ProfileTool.cruby
when "mruby" then ProfileTool.mruby(*args)
when "sync" then ProfileTool.sync(*args)
when "collect" then ProfileTool.collect(*args)
when "table" then ProfileTool.table
else
  warn File.read(__FILE__).lines.take_while { |l| l.start_with?("#") }.join
  exit 1
end
