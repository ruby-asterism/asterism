# The two forms of the gem read the same files: lib/asterism.rb loads mrblib/
# (the mrbgem's sources) and the message types from data/msgs.
require "minitest/autorun"

class TestLayout < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_mrblib_is_what_cruby_loads
    files = Dir.glob(File.join(ROOT, "mrblib/*.rb")).map { |f| File.basename(f, ".rb") }.sort
    assert_equal %w[asterism cdr future proxy ros], files
    loader = File.read(File.join(ROOT, "lib/asterism.rb"))
    assert_includes loader, '%w[asterism cdr future proxy ros].each do |f|'
    assert_includes loader, 'require_relative "../mrblib/#{f}"'
    assert_empty Dir.glob(File.join(ROOT, "lib/**/shared")), "no copies of mrblib under lib/"
  end

  def test_bundled_types
    assert_equal 84, Dir.glob(File.join(ROOT, "data/msgs/**/*.rb")).size
    assert File.file?(File.join(ROOT, "data/msgs/NOTICE"))
    assert File.file?(File.join(ROOT, "data/msgs/LICENSE-Apache-2.0.txt"))
    assert File.file?(File.join(ROOT, "data/msgs/LICENSE-BSD-3-Clause-tf2_msgs.txt"))
  end

  # Every bundled type states its package and license at its top (taken from
  # the package.xml kept in tools/ros2_jazzy), and the license is one whose
  # text ships in data/msgs and that the NOTICE files name.
  LICENSES = { "tf2_msgs" => "BSD" }.freeze

  def test_bundled_types_state_their_license
    Dir.glob(File.join(ROOT, "data/msgs/**/*.rb")).each do |f|
      pkg = f.delete_prefix(File.join(ROOT, "data/msgs/")).split("/").first
      head = File.foreach(f).first(4).join
      lic = LICENSES.fetch(pkg, "Apache License 2.0")
      assert_includes head, "of the package #{pkg}.", f
      assert_includes head, "# License: #{lic}, as the definition (package.xml of #{pkg}).", f
      xml = File.read(File.join(ROOT, "tools/ros2_jazzy", pkg, "package.xml"))
      assert_includes xml, "<license>#{lic}</license>", pkg
      %w[NOTICE data/msgs/NOTICE].each { |n| assert_includes File.read(File.join(ROOT, n)).gsub(/\s+/, " "), pkg, n }
    end
  end

  def test_gemspec_licenses
    spec = File.read(File.join(ROOT, "asterism.gemspec"))
    assert_includes spec, 's.licenses = ["MIT", "Apache-2.0", "BSD-3-Clause"]'
  end

  def test_mrbgem_definition
    rake = File.read(File.join(ROOT, "mrbgem.rake"))
    assert_includes rake, "MRuby::Gem::Specification.new('picoruby-asterism')"
    assert_includes rake, "spec.add_dependency 'picoruby-asterism-zenoh'"
  end
end
