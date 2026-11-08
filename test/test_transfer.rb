# Asterism::Transfer (data/transfer/transfer.rb) between a Sender and an
# Inbox in one process, over a stand-in for the calls that can lose, repeat
# and reorder pieces, go down for a while, and lose answers; the receiver's
# application started again on the same directory; a file whose sha256
# does not match; a file kept too long; another sender while one is coming
# in. No Zenoh: the calls are the stand-in's (rake test:transfer).
require "minitest/autorun"
require "tmpdir"
require "fileutils"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "asterism"
require "asterism/transfer"

module Asterism
  module Transfer
    # the test's clock
    @clock = 0
    class << self
      attr_accessor :clock

      def now_ms
        @clock
      end
    end
  end
end

class TestTransfer < Minitest::Test
  T = Asterism::Transfer

  # An answer already there, or an error.
  class Answer
    def initialize(value = nil, error = nil)
      @value = value
      @error = error
    end

    def done?
      true
    end

    def value
      raise @error if @error
      @value
    end
  end

  # The calls: each goes to the inbox at once (as the receiver would answer
  # it), unless the network is down; lose: the call is done there but its
  # answer does not come back.
  class Net
    attr_accessor :inbox, :down, :lose, :log, :from

    def initialize(inbox)
      @inbox = inbox
      @down = false
      @lose = nil
      @log = []
      @from = "node-a"
    end

    def call(method, args)
      @log << [method, args[0..1]]
      return Answer.new(nil, Asterism::TimeoutError.new("no answer (nobody answers)")) if @down
      begin
        v = @inbox.public_send(method, *args, from: @from)
      rescue StandardError => e
        return Answer.new(nil, Asterism::RemoteError.new(e.class.name, e.message, "raised"))
      end
      return Answer.new(nil, Asterism::TimeoutError.new("no answer within 10 s")) if @lose&.call(method, args)
      Answer.new(v)
    end
  end

  class Proxy
    def initialize(net)
      @net = net
    end

    def async
      self
    end

    def asterism_call(method, *args)
      @net.call(method.to_s, args)
    end
  end

  # A Sender whose calls go to the stand-in and whose pieces meet faults.
  class TestSender < T::Sender
    attr_accessor :net, :faults

    def proxy
      Proxy.new(@net)
    end

    def fault(pos, n)
      @seen ||= {}
      return nil if @seen[pos]
      @seen[pos] = true
      @faults&.call(pos / @piece)
    end
  end

  # An inbox that places the whole file beside the piece file.
  class TestInbox < T::Inbox
    attr_accessor :space
    attr_writer :window, :parts, :parts_b

    attr_accessor :kinds

    def room(_kind, _meta)
      @space
    end

    def refused(kind, _from, _meta)
      return nil if @kinds.nil? || @kinds.include?(kind)
      "takes no #{kind}"
    end

    # parts: a directory of its own for the piece files (the kind "file"
    # of Family mruby writes them beside where they go)
    def part_path(kind, name, meta)
      return super unless @parts
      return "#{@parts_b}.#{name}.#{kind}.part" if meta["inbox"] == "b"
      "#{@parts}.#{name}.#{kind}.part"
    end

    def received(t)
      dest = "#{dir}#{t['name']}.#{t['kind']}"
      File.rename(t["part"], dest)
      { "status" => "placed", "path" => dest }
    end
  end

  def setup
    T.clock = 1_000_000
    @dir = Dir.mktmpdir("asterism-transfer")
    @src = File.join(@dir, "src.bin")
    @bytes = Random.new(7).bytes(100_000)
    File.binwrite(@src, @bytes)
    @rx = "#{File.join(@dir, 'rx')}/"
    FileUtils.mkdir_p(@rx)
    # one piece at a time (the counts below are of that); the window's own
    # tests say otherwise
    @inbox = TestInbox.new(@rx, piece: 1000, window: 1)
    @inbox.logger = nil
    @net = Net.new(@inbox)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def sender(**opts)
    s = TestSender.new("node-b/transfer/inbox", "file", @src, **{ name: "src" }.merge(opts))
    s.logger = nil
    s.net = @net
    s
  end

  # Steps until done, the clock going on 10 ms a step; a block runs before
  # each step (to break things on the way).
  def run_to_end(s, max: 100_000)
    n = 0
    until s.done?
      yield n if block_given?
      s.step
      T.clock += 10
      n += 1
      flunk "not done in #{max} steps" if n > max
    end
    s
  end

  def placed
    File.binread("#{@rx}src.file")
  end

  def chunk_positions
    @net.log.select { |m, _| m == "chunk" }.map { |_, a| a[1] }
  end

  def test_straight
    s = run_to_end(sender)
    assert s.ok?, s.reason
    assert_equal "placed", s.answer["status"]
    assert_equal @bytes, placed
    assert_equal 100, s.stats["pieces"]
    assert_equal 0, s.stats["again"]
    assert_empty Dir.glob("#{@rx}*.part") + Dir.glob("#{@rx}*.xfer")
  end

  def test_a_tenth_of_the_pieces_lost
    s = sender
    s.faults = ->(i) { i % 10 == 3 ? :drop : nil }
    run_to_end(s)
    assert s.ok?, s.reason
    assert_equal @bytes, placed
    assert_equal 10, s.stats["again"]
    # each lost piece is sent again from where the receiver stood
    pos = chunk_positions
    (0...10).each do |k|
      assert_equal 1, pos.count((k * 10 + 3) * 1000), "the lost piece #{k * 10 + 3} sent once, when asked for"
      assert_equal 2, pos.count((k * 10 + 4) * 1000), "the piece after it sent before and after"
    end
  end

  def test_every_piece_twice
    s = sender
    s.faults = ->(_i) { :twice }
    run_to_end(s)
    assert s.ok?, s.reason
    assert_equal @bytes, placed
    assert_equal 200, s.stats["pieces"]
  end

  def test_pieces_swapped
    s = sender
    s.faults = ->(i) { i % 7 == 2 ? :swap : nil }
    run_to_end(s)
    assert s.ok?, s.reason
    assert_equal @bytes, placed
    assert_operator s.stats["again"], :>, 0
  end

  def test_window_of_four
    @inbox.window = 4
    s = sender
    s.faults = ->(i) { i % 10 == 5 ? :drop : nil }
    run_to_end(s)
    assert s.ok?, s.reason
    assert_equal @bytes, placed
  end

  def test_down_twice_goes_on_from_where_it_stood
    s = sender
    downs = []
    run_to_end(s) do |n|
      if n == 20 || n == 60
        @net.down = true
        downs << @inbox.current_file["got"]
      end
      @net.down = false if n == 30 || n == 75
    end
    assert s.ok?, s.reason
    assert_equal @bytes, placed
    assert_equal 2, downs.size
    # it began again twice and went on from where the receiver stood
    assert_equal downs, s.stats["resumed_at"]
    assert_operator downs[0], :>, 0
  end

  def test_answers_lost
    k = 0
    @net.lose = ->(m, _a) { m == "chunk" && (k += 1) % 9 == 0 }
    s = run_to_end(sender)
    assert s.ok?, s.reason
    assert_equal @bytes, placed
    assert_operator s.stats["retries"], :>, 5
  end

  def test_commit_answer_lost_is_asked_again
    lost = false
    @net.lose = ->(m, _a) { m == "commit" && !lost && (lost = true) }
    s = run_to_end(sender)
    assert s.ok?, s.reason
    assert_equal "placed", s.answer["status"]
    assert_equal @bytes, placed
  end

  def test_receiver_started_again
    s = sender
    held = nil
    run_to_end(s) do |n|
      next unless n == 40
      held = @inbox.current_file["got"]
      @inbox.close
      @inbox = TestInbox.new(@rx, piece: 1000, window: 1)
      @inbox.logger = nil
      @inbox.resume_held
      @net.inbox = @inbox
    end
    assert s.ok?, s.reason
    assert_equal @bytes, placed
    assert_equal [held], s.stats["resumed_at"]
    assert_operator held, :>, 0
  end

  def test_sha256_mismatch_is_not_placed
    s = sender(sha256: "0" * 64)
    run_to_end(s)
    assert s.ok?
    assert_equal "refused", s.answer["status"]
    assert_includes s.answer["reason"], "does not match"
    refute File.exist?("#{@rx}src.file")
    assert_empty Dir.glob("#{@rx}*.part") + Dir.glob("#{@rx}*.xfer")
  end

  def test_kept_too_long_is_deleted
    s = sender
    run_to_end(s) do |n|
      next unless n == 30
      @net.down = true
    end
    # (the sender gives up while down)
    refute s.ok?
    assert_includes s.reason, "gave up"
    assert File.exist?("#{@rx}src.file.part")
    T.clock += T::Inbox::KEEP_MS + 1
    @inbox.tick
    refute File.exist?("#{@rx}src.file.part")
    refute File.exist?("#{@rx}src.file.xfer")
  end

  def test_too_big_for_the_room
    @inbox.space = 50_000
    s = run_to_end(sender)
    refute s.ok?
    assert_includes s.reason, "do not fit"
  end

  def test_another_sender_is_busy_until_stale
    s = sender
    run_to_end(s) { |n| break if n == 10 }
    @net.from = "node-c"
    other = sender(tries: 1)
    run_to_end(other)
    refute other.ok?
    assert_includes other.reason, "busy"
    T.clock += T::Inbox::STALE_MS + 1
    other = sender
    run_to_end(other)
    assert other.ok?, other.reason
  end

  def test_cancel_drops_what_the_receiver_holds
    s = sender
    run_to_end(s) { |n| break if n == 30 }
    assert_operator @inbox.current_file["got"], :>, 0
    assert File.exist?("#{@rx}src.file.part")
    assert s.cancel
    assert s.done?
    refute s.ok?
    assert s.cancelled?
    assert_equal "cancelled", s.reason
    assert_nil @inbox.current_file
    assert_empty Dir.glob("#{@rx}*.part") + Dir.glob("#{@rx}*.xfer")
    refute s.cancel
  end

  def test_a_kind_not_taken_is_refused_at_begin
    @inbox.kinds = ["other"]
    s = run_to_end(sender)
    refute s.ok?
    assert_equal "takes no file", s.reason
    assert_equal [["begin", ["file", { "name" => "src", "size" => 100_000, "sha256" => Digest::SHA256.hexdigest(@bytes) }]]],
                 @net.log
    assert_empty Dir.glob("#{@rx}*")
  end

  # The receiver names the piece and the window; the sender keeps within
  # them and within its own most.
  def test_the_receiver_names_piece_and_window
    @inbox.window = 8
    most = 0
    s = sender
    s.define_singleton_method(:pump) do
      super()
      most = @inflight.size if @inflight.size > most
    end
    run_to_end(s)
    assert s.ok?, s.reason
    assert_equal @bytes, placed
    assert_equal 1000, s.piece
    assert_equal 8, s.window
    assert_equal 8, most
    assert_equal 100, s.stats["pieces"]
    # its own most
    s = run_to_end(sender(piece: 700, window: 2))
    assert s.ok?, s.reason
    assert_equal [700, 2], [s.piece, s.window]
  end

  # A receiver that names no window (before T3) is sent one piece at a time.
  def test_an_older_receiver_one_at_a_time
    @inbox.define_singleton_method(:begin) do |kind, meta, from: nil|
      r = super(kind, meta, from: from)
      r.delete("window")
      r
    end
    s = run_to_end(sender)
    assert s.ok?, s.reason
    assert_equal 1, s.window
  end

  # The piece is what a call to this inbox carries: its key counts.
  def test_piece_from_the_key
    assert_equal 3840, T.piece_for_key(50)
    assert_equal 3584, T.piece_for_key(200)
    assert_equal 512, T.piece_for_key(5000)
    ib = T::Inbox.new(@rx)
    ib.logger = nil
    ib.path = "node-b/transfer/inbox"
    assert_equal 3840, ib.begin("file", meta, from: "node-a")["piece"]
    ib.cancel(ib.current_file["id"], from: "node-a")
    ib.path = "n" * 200
    assert_equal 3584, ib.begin("file", meta, from: "node-a")["piece"]
    ib.cancel(ib.current_file["id"], from: "node-a")
    assert_equal T::WINDOW, ib.begin("file", meta, from: "node-a")["window"]
  end

  # Piece files written elsewhere than the notes (part_path): placed from
  # there, kept there across the application started again, deleted from
  # there when kept too long; the notes stay in dir.
  def test_pieces_beside_where_they_go
    parts = "#{File.join(@dir, 'inbox')}/"
    FileUtils.mkdir_p(parts)
    @inbox.parts = parts
    s = sender
    held = nil
    run_to_end(s) do |n|
      if n == 20
        assert File.exist?("#{parts}.src.file.part")
        refute File.exist?("#{@rx}src.file.part")
        assert File.exist?("#{@rx}src.file.xfer")
      end
      next unless n == 40
      held = @inbox.current_file["got"]
      @inbox.close
      @inbox = TestInbox.new(@rx, piece: 1000, window: 1)
      @inbox.logger = nil
      @inbox.parts = parts
      @inbox.resume_held
      @net.inbox = @inbox
    end
    assert s.ok?, s.reason
    assert_equal @bytes, placed
    assert_equal [held], s.stats["resumed_at"]
    assert_empty Dir.children(parts) + Dir.glob("#{@rx}*.xfer")
    # kept too long: deleted where it was written
    s = sender(name: "again")
    run_to_end(s) { |n| @net.down = true if n == 30 }
    assert File.exist?("#{parts}.again.file.part")
    T.clock += T::Inbox::KEEP_MS + 1
    @inbox.tick
    assert_empty Dir.children(parts) + Dir.glob("#{@rx}*.xfer")
    # a note left by an application that ended, with another one held: both
    # files of the one not taken up go
    @net.down = false
    s = sender(name: "third")
    run_to_end(s) { |n| break if n == 10 }
    @inbox.close
    File.write("#{@rx}stray.file.xfer", JSON.generate({ "from" => "node-x", "kind" => "file", "name" => "stray",
                                                         "size" => 10, "sha256" => "0" * 64 }))
    File.write("#{parts}.stray.file.part", "x")
    ib = TestInbox.new(@rx, piece: 1000, window: 1)
    ib.logger = nil
    ib.parts = parts
    ib.resume_held
    # one is taken up (whichever the directory lists first), the other's two
    # files are gone
    other = ib.current_file["name"] == "third" ? "stray" : "third"
    refute File.exist?("#{parts}.#{other}.file.part")
    refute File.exist?("#{@rx}#{other}.file.xfer")
  end

  # The meta chooses where the pieces go (the sender's choice of a place);
  # the same file begun again for the other place begins anew there.
  def test_the_meta_chooses_the_place
    a = "#{File.join(@dir, 'a')}/"
    b = "#{File.join(@dir, 'b')}/"
    FileUtils.mkdir_p([a, b])
    @inbox.parts = a
    @inbox.parts_b = b
    s = sender(meta: { "inbox" => "b" })
    run_to_end(s) do |n|
      next unless n == 20
      assert File.exist?("#{b}.src.file.part")
      refute File.exist?("#{a}.src.file.part")
      @net.down = true
    end
    refute s.ok?
    @net.down = false
    T.clock += T::Inbox::STALE_MS + 1
    s = run_to_end(sender)
    assert s.ok?, s.reason
    assert_equal [], s.stats["resumed_at"]
    refute File.exist?("#{b}.src.file.part")
    assert_equal @bytes, placed
  end

  def meta
    { "name" => "src", "size" => @bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(@bytes) }
  end

  def test_file_names
    %w[a.txt foo.tar.gz 日本語.txt a-b_c(1).bin x].each { |n| assert T.file_name?(n), n }
    ["", ".hidden", "a/b", "../x", "a..b", "a\\b", "a\nb", "x" * 49, nil, 3].each { |n| refute T.file_name?(n), n.inspect }
    assert_equal "foo(1).txt", T.numbered("foo.txt", 1)
    assert_equal "foo.tar(2).gz", T.numbered("foo.tar.gz", 2)
    assert_equal "foo(3)", T.numbered("foo", 3)
    File.write("#{@rx}foo.txt", "1")
    File.write("#{@rx}foo(1).txt", "2")
    assert_equal "foo(2).txt", T.free_name(@rx, "foo.txt")
    assert_equal "bar.txt", T.free_name(@rx, "bar.txt")
  end

  # The plain Ruby SHA-256 (the boards without mbedTLS) gives CRuby's digest.
  def test_plain_sha256
    require_relative "../data/transfer/sha256"
    [0, 1, 55, 56, 64, 1000, 100_000].each do |n|
      b = @bytes.byteslice(0, n)
      d = T::SHA256.new(:ruby)
      i = 0
      while i < n
        d.update(b.byteslice(i, 777))
        i += 777
      end
      assert_equal Digest::SHA256.hexdigest(b), d.hexdigest, "#{n} bytes"
    end
  end
end
