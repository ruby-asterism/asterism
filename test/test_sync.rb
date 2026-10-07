# The pure Ruby layers are copies of fmruby-core's (rake sync): they must
# match byte for byte. Skipped when fmruby-core is not next to this
# repository (FMRUBY_CORE overrides the place).
require "minitest/autorun"

class TestSync < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_copies_match_fmruby_core
    core = ENV["FMRUBY_CORE"] || File.expand_path("../fmruby-core", ROOT)
    skip "fmruby-core not found at #{core}" unless File.directory?(core)
    out = `cd #{ROOT} && #{RbConfig.ruby} -S rake sync:check 2>&1`
    assert $?.success?, out
  end

  def test_shared_files_are_loaded_unchanged
    shared = Dir.glob(File.join(ROOT, "asterism/lib/asterism/shared/*.rb")).map { |f| File.basename(f) }.sort
    assert_equal %w[asterism.rb cdr.rb future.rb proxy.rb ros.rb], shared
    assert_equal 62, Dir.glob(File.join(ROOT, "asterism/data/msgs/**/*.rb")).size
  end
end
