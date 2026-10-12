# mruby build for the mruby test of the shared layer (rake test:mruby): a
# plain host build with picoruby-asterism-zenoh, this gem and the core gems
# the test scripts use. MRB_UTF8_STRING as on Family mruby's boards, so the
# byte-level code (the PNG checks) runs as it does there. The build name
# "host" selects zenoh-pico's POSIX platform.
MRuby::Build.new("host") do |conf|
  conf.toolchain :gcc
  conf.enable_debug
  conf.cc.flags << "-O1"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.gem core: "mruby-bin-mruby"
  conf.gem core: "mruby-sleep"
  conf.gem core: "mruby-time"
  conf.gem core: "mruby-string-ext"
  conf.gem core: "mruby-encoding"  # String#encoding: the test MessagePack tells a binary String (bin)
  conf.gem core: "mruby-array-ext"
  conf.gem core: "mruby-hash-ext"
  conf.gem core: "mruby-kernel-ext"
  conf.gem core: "mruby-sprintf"
  conf.gem core: "mruby-pack"
  conf.gem core: "mruby-exit"
  conf.gem core: "mruby-io"
  conf.gem core: "mruby-enum-ext"
  conf.gem core: "mruby-metaprog" # public_send and the rest, as on the boards
  conf.gem core: "mruby-eval"     # Asterism::ROS.require_type evaluates the type files
  conf.gem ENV.fetch("PICORUBY_ASTERISM_ZENOH_DIR")
  conf.gem File.expand_path("..", __dir__)
end
