# What CRuby needs on top of the pure Ruby layers in mrblib/ (shared with the
# mruby / PicoRuby boards). Kept small: anything that is also right on mruby
# belongs in mrblib/ instead.
module Asterism
  # The message and service types bundled with the gem (the same files the
  # boards keep in /usr/share/asterism/msgs). The application may add its
  # own directories (tools/asterism_msggen.rb -o <dir>).
  MSGS_DIR = File.expand_path("../../data/msgs", __dir__)
  ROS::TYPE_PATH.replace([MSGS_DIR])

  module Codec
    # CRuby's msgpack packs binary (ASCII-8BIT) Strings, such as payloads
    # that came from Zenoh, as the bin type. The mruby MessagePack of the
    # boards reads only the str type, so every String goes as str
    # (compatibility mode), which is what the boards send too.
    def self.pack(v)
      ::MessagePack.pack(check(v), compatibility_mode: true)
    end
  end

  # A monotonic clock (deadlines and node.every must not jump with the
  # wall clock).
  def self.now_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
  end

  # The profile's defaults on CRuby (mrblib/profile.rb): kind "cruby" and
  # the icon bundled with the gem (replace it with Asterism.profile(icon:)).
  ICON_FILE = File.expand_path("../../data/icon.png", __dir__)

  def self.default_profile_kind
    "cruby"
  end

  def self.default_icon_path
    ICON_FILE
  end

  def self.read_icon_file(path)
    File.binread(path)
  rescue SystemCallError
    nil
  end

  module Profile
    # Icons come out of MessagePack as UTF-8 Strings: hand them out as the
    # bytes they are.
    class << self
      alias_method :check_portable, :check

      def check(h)
        out = check_portable(h)
        out["icon"] = out["icon"].b if out&.key?("icon")
        out
      end

      alias_method :icon_portable!, :icon!

      def icon!(v)
        icon_portable!(v).b.freeze
      end
    end
  end

  def self.error_reply(klass, message)
    ::MessagePack.pack(["error", klass.to_s, message.to_s], compatibility_mode: true)
  end
end
