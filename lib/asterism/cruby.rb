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
    INT_MIN = -(2**63)
    INT_MAX = 2**63 - 1

    # msgpack-ruby packs a binary (ASCII-8BIT) String, such as a payload
    # that came from Zenoh or File.binread, as a bin and any other String
    # as a str (docs/protocol.md 3.1): no compatibility mode.
    def self.pack(v)
      ::MessagePack.pack(check(v))
    end

    class << self
      alias_method :check_portable, :check

      # An Integer outside the signed 64-bit range cannot be sent (the
      # other implementations cannot hold it): EncodeError, before sending.
      def check(v, depth = 0)
        if v.is_a?(Integer) && (v < INT_MIN || v > INT_MAX)
          raise ::Asterism::EncodeError, "Integer #{v} is outside the signed 64-bit range"
        end
        return v if v.is_a?(Integer)
        check_portable(v, depth)
      end

      alias_method :unpack_portable, :unpack

      # Also nil for an integer above 2^63-1 (msgpack-ruby reads a uint64;
      # the protocol carries signed 64-bit integers only).
      def unpack(bytes)
        v = unpack_portable(bytes)
        return v unless bytes&.b&.include?("\xcf".b)
        int64_only?(v) ? v : nil
      end

      def int64_only?(v)
        case v
        when Integer then v <= INT_MAX
        when Array then v.all? { int64_only?(_1) }
        when Hash then v.all? { |k, x| int64_only?(k) && int64_only?(x) }
        else true
        end
      end

      # A text field of the protocol is a str, whatever the String's
      # encoding was.
      def text(s)
        s.to_s.dup.force_encoding(Encoding::UTF_8)
      end
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

  # The calls being answered, per thread: an exposed method runs on the
  # thread that answers (the receiving thread, or whatever polls), and
  # Asterism.current_call on another thread is not inside that call.
  def self.call_stack
    Thread.current[:asterism_call_stack] ||= []
  end
end
