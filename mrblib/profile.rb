# A node's profile: what it runs on, where, a display name and an icon,
# told by the node itself (0.5.0).
#
#   Asterism.profile(name: "Rover", icon: png)   # this node's; returns it
#   Asterism.profile                             # => {"kind" => "picoruby", "name" => "Rover", ...}
#   Asterism.profile_of("fmruby-aaaaaa")         # another node's, or nil
#
# Key: asterism/<node>/@profile (a queryable of every application connected
# as that node). The reply is a MessagePack Hash:
#   "protocol"   the wire protocol the node speaks (Asterism::PROTOCOL, 1);
#                a node without it speaks protocol 0
#   "kind"       what Ruby runs the node: "family_mruby", "picoruby",
#                "cruby", "console" (others are allowed)
#   "host"       where it runs, optional ("atoms3r", "tab5", "sim", ...)
#   "name"       a display name, optional
#   "icon"       PNG bytes as a MessagePack bin, optional (8 KB and
#                256x256 at most)
#   "icon_hash"  the icon's summary (Profile.png_info): a reader that has
#                that icon already asks again with the parameter icon=0 and
#                gets the rest without it
# Each connect, and each change while connected, also puts the profile
# without its icon on the same key, for those who follow it (a console).
#
# Room left for later: an application's own profile would be
# asterism/<node>/<app>/@profile, with the same Hash.
module Asterism
  module Profile
    # The kinds this version knows. Others pass: a kind is any lower-case
    # word (a-z, 0-9, _; up to KIND_MAX bytes) starting with a letter.
    KINDS = ["family_mruby", "picoruby", "cruby", "console"]
    KEY = "@profile"
    ICON_MAX = 8192      # bytes
    ICON_SIDE_MAX = 256  # pixels, each side
    KIND_MAX = 32
    HOST_MAX = 32
    NAME_MAX = 64
    PNG_SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10]

    # [width, height, icon_hash] of a PNG that a profile may carry, or nil.
    # Checks the signature, the size (ICON_MAX bytes), that the chunks tile
    # the bytes from IHDR to IEND, and the image's sides (ICON_SIDE_MAX).
    #
    # icon_hash is the Adler-32 (8 hex digits) of the chunks' CRC-32 fields,
    # in order: each CRC already sums up its chunk, so the summary costs a
    # few bytes of arithmetic instead of a pass over the whole file (small
    # integers only, the same on every Ruby). On CRuby it equals
    # Zlib.adler32 of those fields joined.
    def self.png_info(b)
      return nil unless b.is_a?(String)
      size = b.bytesize
      return nil if size < 8 + 25 + 12 || size > ICON_MAX
      i = 0
      while i < 8
        return nil unless b.getbyte(i) == PNG_SIGNATURE[i]
        i += 1
      end
      pos = 8
      first = true
      w = 0
      h = 0
      a = 1
      s = 0
      while pos + 12 <= size
        # The length is 4 bytes; anything past 16 bits is larger than ICON_MAX.
        return nil unless b.getbyte(pos) == 0 && b.getbyte(pos + 1) == 0
        len = b.getbyte(pos + 2) * 256 + b.getbyte(pos + 3)
        nxt = pos + 12 + len
        return nil if nxt > size
        if first
          return nil unless type?(b, pos, 73, 72, 68, 82) && len == 13 # IHDR
          return nil unless b.getbyte(pos + 8) == 0 && b.getbyte(pos + 9) == 0
          return nil unless b.getbyte(pos + 12) == 0 && b.getbyte(pos + 13) == 0
          w = b.getbyte(pos + 10) * 256 + b.getbyte(pos + 11)
          h = b.getbyte(pos + 14) * 256 + b.getbyte(pos + 15)
          return nil if w < 1 || h < 1 || w > ICON_SIDE_MAX || h > ICON_SIDE_MAX
          first = false
        end
        k = nxt - 4
        while k < nxt
          a = (a + b.getbyte(k)) % 65521
          s = (s + a) % 65521
          k += 1
        end
        if type?(b, pos, 73, 69, 78, 68) # IEND
          return nil unless nxt == size
          return [w, h, hex4(s) + hex4(a)]
        end
        pos = nxt
      end
      nil
    end

    # The bytes as a binary String (String#b), so that they are sent as a
    # MessagePack bin; as they are where String#b is missing.
    # @api private
    def self.binary(s)
      s.respond_to?(:b) ? s.b : s
    end

    # @api private
    def self.type?(b, pos, c0, c1, c2, c3)
      b.getbyte(pos + 4) == c0 && b.getbyte(pos + 5) == c1 && b.getbyte(pos + 6) == c2 && b.getbyte(pos + 7) == c3
    end

    # @api private
    def self.hex4(n)
      t = n.to_s(16)
      t = "0" + t while t.length < 4
      t
    end

    # A received profile, cleaned: the known fields that pass their checks
    # (a field that does not is left out; an icon that is not a valid PNG
    # goes with its hash). nil when it is not a profile (no valid kind).
    def self.check(h)
      return nil unless h.is_a?(Hash)
      kind = h["kind"]
      return nil unless kind.is_a?(String) && kind?(kind)
      out = { "kind" => kind }
      pr = h["protocol"]
      out["protocol"] = pr if pr.is_a?(Integer) && pr >= 0
      host = h["host"]
      out["host"] = host if host.is_a?(String) && !host.empty? && host.bytesize <= HOST_MAX
      name = h["name"]
      out["name"] = name if name.is_a?(String) && !name.empty? && name.bytesize <= NAME_MAX
      icon = h["icon"]
      if icon.is_a?(String)
        info = png_info(icon)
        if info
          out["icon"] = icon
          out["icon_hash"] = info[2]
        end
      elsif hash_text?(h["icon_hash"])
        out["icon_hash"] = h["icon_hash"]
      end
      out
    end

    # @api private
    def self.kind?(s)
      n = s.bytesize
      return false if n < 1 || n > KIND_MAX
      i = 0
      while i < n
        c = s.getbyte(i)
        lower = c >= 97 && c <= 122
        return false unless lower || (i > 0 && ((c >= 48 && c <= 57) || c == 95))
        i += 1
      end
      true
    end

    # @api private
    def self.hash_text?(s)
      return false unless s.is_a?(String) && s.bytesize == 8
      i = 0
      while i < 8
        c = s.getbyte(i)
        return false unless (c >= 48 && c <= 57) || (c >= 97 && c <= 102)
        i += 1
      end
      true
    end

    # The checks of Asterism.profile (ArgumentError, with the reason).
    # @api private
    def self.kind!(v)
      s = v.is_a?(Symbol) ? v.to_s : v
      unless s.is_a?(String) && kind?(s)
        raise ArgumentError, "profile kind: #{v.inspect} is not a lower-case word (a-z, 0-9, _; " \
                             "#{KIND_MAX} bytes at most), e.g. :cruby"
      end
      s
    end

    # @api private
    def self.text!(what, v, max)
      s = v.is_a?(Symbol) ? v.to_s : v
      raise ArgumentError, "profile #{what}: expected a String, got #{v.class}" unless s.is_a?(String)
      raise ArgumentError, "profile #{what}: empty (pass nil to leave it out)" if s.empty?
      raise ArgumentError, "profile #{what}: #{s.bytesize} bytes (#{max} at most)" if s.bytesize > max
      s
    end

    # @api private
    def self.icon!(v)
      raise ArgumentError, "profile icon: expected the bytes of a PNG (a String), got #{v.class}" unless v.is_a?(String)
      if v.bytesize > ICON_MAX
        raise ArgumentError, "profile icon: #{v.bytesize} bytes (#{ICON_MAX} at most)"
      end
      unless png_info(v)
        raise ArgumentError, "profile icon: not a PNG, or not one this accepts (up to " \
                             "#{ICON_SIDE_MAX}x#{ICON_SIDE_MAX}, chunks from IHDR to IEND)"
      end
      v
    end

    # Whether a query's parameters ask for the icon (icon=0 says no).
    # @api private
    def self.wants_icon?(params)
      return true if params.nil? || params.empty?
      params.split(";").each do |pair|
        kv = pair.split("=")
        next unless kv[0] == "icon"
        v = kv[1].to_s
        return false if v == "0" || v == "no" || v == "false"
      end
      true
    end
  end

  # This node's profile. With keywords, sets those fields and returns the
  # profile; without, returns it. The fields: kind: (a Symbol or String;
  # nil goes back to the default), name:, host: (Strings; nil leaves them
  # out), icon: (the bytes of a PNG; nil for no icon). The fields not given
  # stay as they are. Raises ArgumentError for a field it does not accept
  # (see Asterism::Profile).
  #
  # The defaults: kind "picoruby" on mruby / PicoRuby, "cruby" on CRuby; no
  # host, no name; the icon is the file at Asterism.default_icon_path when
  # there is one (the boards: /usr/share/asterism/icon.png; CRuby: the gem's
  # data/icon.png). A board's firmware may set its own defaults with this
  # same call before the application runs (Family mruby does).
  #
  # Kept across connect and close (it belongs to the process, or the VM on
  # a board). While connected, a change is also put on the profile's key.
  def self.profile(**fields)
    return profile_hash(true) if fields.empty?
    changes = {}
    fields.each do |k, v|
      key = k.to_s
      if key == "kind"
        changes[key] = v.nil? ? nil : Profile.kind!(v)
      elsif key == "name"
        changes[key] = v.nil? ? nil : Profile.text!("name", v, Profile::NAME_MAX)
      elsif key == "host"
        changes[key] = v.nil? ? nil : Profile.text!("host", v, Profile::HOST_MAX)
      elsif key == "icon"
        changes[key] = v.nil? ? nil : Profile.icon!(v)
      else
        raise ArgumentError, "unknown profile field #{key} (kind, name, host, icon)"
      end
    end
    set = (@profile_set ||= {})
    changes.each do |k, v|
      if v.nil? && k != "icon"
        set.delete(k)
      else
        set[k] = v # icon: nil stays, so the default file is not used
      end
    end
    @profile_icon = nil if changes.key?("icon")
    tell_profile
    profile_hash(true)
  end

  # Another node's profile (Asterism::Profile.check has cleaned it), or nil
  # when it does not answer in time (an older version of Asterism, a ROS 2
  # node, a node that is gone). icon: false asks for it without the icon
  # bytes (icon_hash still says which icon it is). timeout: in seconds (or
  # timeout_ms:), 2.0 by default. Waits like a call (polling, answering
  # calls meanwhile); raises Disconnected when not connected. This node's
  # own profile comes without the network.
  def self.profile_of(node, icon: true, timeout: nil, timeout_ms: nil)
    f = profile_async(node, icon, timeout, timeout_ms)
    begin
      raw = f.raw_value
    rescue Disconnected
      raise
    rescue Error
      return nil # no answer in time, or not MessagePack
    end
    Profile.check(raw)
  end

  # @api private
  def self.profile_async(node, icon, timeout, timeout_ms)
    node = check_name("node", node)
    ms = time_ms("Asterism.profile_of", timeout, timeout_ms, nil, DEFAULT_TIMEOUT_MS)
    path = "#{node}/#{Profile::KEY}"
    return Future.answered(path, "profile", Codec.pack(profile_hash(icon))) if @session && node == @node
    begin
      g = session!.get("#{ROOT}/#{path}", timeout_ms: ms, params: icon ? nil : "icon=0")
    rescue Asterism::Zenoh::Error => e
      lost(e.message)
      raise Disconnected, e.message
    end
    Future.new(path, "profile", g, now_ms + ms, ms)
  end

  # The kind when the application did not set one.
  # @api private
  def self.default_profile_kind
    "picoruby"
  end

  # Where the default icon is read from (when the application gave none);
  # nil for none. CRuby: the gem's data/icon.png.
  def self.default_icon_path
    "/usr/share/asterism/icon.png"
  end

  # The bytes of a file, nil when it cannot be read.
  # @api private
  def self.read_icon_file(path)
    return nil unless Object.const_defined?(:File) && File.exist?(path)
    File.open(path, "r") { |f| f.read }
  rescue
    nil
  end

  # The profile as sent: String keys, the icon only when with_icon.
  # @api private
  def self.profile_hash(with_icon)
    set = @profile_set || {}
    h = { "protocol" => PROTOCOL, "kind" => set["kind"] || default_profile_kind }
    h["host"] = set["host"] if set["host"]
    h["name"] = set["name"] if set["name"]
    icon = profile_icon
    if icon
      h["icon"] = icon[0] if with_icon
      h["icon_hash"] = icon[1]
    end
    h
  end

  # [bytes, icon_hash] of this node's icon, or nil. The default file is
  # read once, when the profile is first needed.
  # @api private
  def self.profile_icon
    if @profile_icon.nil?
      set = @profile_set || {}
      bytes = set.key?("icon") ? set["icon"] : nil
      unless set.key?("icon")
        path = default_icon_path
        bytes = path ? read_icon_file(path) : nil
      end
      info = bytes ? Profile.png_info(bytes) : nil
      # A binary String: it goes as a MessagePack bin.
      @profile_icon = info ? [Profile.binary(bytes), info[2]] : false
    end
    @profile_icon ? @profile_icon : nil
  end

  # Puts the profile without its icon on its key (while connected).
  # @api private
  def self.tell_profile
    s = @session
    return unless s
    s.put("#{ROOT}/#{@node}/#{Profile::KEY}", Codec.pack(profile_hash(false)))
  rescue Asterism::Zenoh::Error
    nil # the next poll notices a lost connection
  end

  # @api private
  def self.answer_profile
    qa = @profile_queryable
    return unless qa && qa.pending > 0
    queries = qa.each_pending
    i = 0
    while i < queries.size
      q = queries[i]
      i += 1
      begin
        q.reply("#{ROOT}/#{@node}/#{Profile::KEY}", Codec.pack(profile_hash(Profile.wants_icon?(q.params))))
      ensure
        begin
          q.finish
        rescue Asterism::Zenoh::Error
          # the session went away meanwhile
        end
      end
    end
  end
end
