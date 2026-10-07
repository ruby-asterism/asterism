# What CRuby needs on top of the shared pure Ruby layers (lib/asterism/shared,
# copied unchanged from fmruby-core; rake sync). Kept small: anything that
# is also right on mruby belongs in the shared files instead.
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

  def self.error_reply(klass, message)
    ::MessagePack.pack(["error", klass.to_s, message.to_s], compatibility_mode: true)
  end
end
