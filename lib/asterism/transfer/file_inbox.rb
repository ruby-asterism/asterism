# Asterism::Transfer::FileInbox (CRuby): the receiver of the kind "file",
# with the rules a Family mruby machine's transfer app keeps for it, under a
# directory the program gives.
#
#   - files of the kind "file" only, from the senders allowed (patterns,
#     * matching any run of characters; or a block);
#   - a name that stays in the directory (Transfer.file_name?: no "/", "\\",
#     "..", not hidden, 1 to 48 bytes);
#   - a name already there: the sender chooses (meta "overwrite" => true
#     replaces it once the new one is whole and its sha256 matches), else
#     it goes beside it as name(1), name(2), ...;
#   - room: max_bytes for the directory in all (nil: no limit of its own);
#     a file that does not fit is refused at begin;
#   - one sender at a time, resending from this receiver's position, the
#     sha256 of the whole (Inbox);
#   - the pieces are written beside where the file goes, hidden
#     ("<dir>.<name>.file.part"), so the commit only renames; the notes of
#     the files coming in go to work (a directory of their own), so a
#     program started again goes on with a file it held (start).
#
# The meta's "inbox" (a Family mruby machine's SD card, "sd") names a place
# this receiver does not have: refused, as on a machine without a card.
#
#   inbox = Asterism::Transfer::FileInbox.new("storage/inbox/", work: "storage/work/", from: ["fmruby-*"])
#   inbox.start                       # takes up a held file, deletes stray pieces
#   endpoint = Asterism::Transfer::Endpoint.new(conn, inbox, node: "mypc").start
#   # ... inbox.tick now and then (endpoint.tick)
module Asterism
  module Transfer
    class FileInbox < Inbox
      KIND = "file"
      # A program has memory for more pieces on their way than a board.
      WINDOW_FILE = 8

      attr_reader :inbox_dir, :max_bytes
      attr_accessor :from, :label

      # dir: where the files go (made when missing; a trailing "/" is
      # added). work: where the notes go (default dir + ".work/"). from: the
      # senders allowed (an Array of node IDs and patterns, "*" for any), or
      # a block |node| -> true / false. max_bytes: the most the directory
      # holds in all. label: this receiver's name in the reasons it gives.
      def initialize(dir, work: nil, from: [], max_bytes: nil, label: "this machine", window: WINDOW_FILE,
                     **opts, &allowed)
        @inbox_dir = dir.end_with?("/") ? dir : "#{dir}/"
        work ||= "#{@inbox_dir}.work/"
        work = "#{work}/" unless work.end_with?("/")
        ::FileUtils.mkdir_p(@inbox_dir)
        ::FileUtils.mkdir_p(work)
        super(work, window: window, **opts)
        @from = from
        @allowed = allowed
        @max_bytes = max_bytes
        @label = label
      end

      # Takes up a file held when the program last ended (its note in work)
      # and deletes the hidden pieces no note speaks for.
      def start
        resume_held
        sweep
        self
      end

      # Whether node may send files here.
      def sender_ok?(node)
        return @allowed.call(node.to_s) ? true : false if @allowed
        Array(@from).any? { |pat| FileInbox.match?(pat.to_s, node.to_s) }
      end

      # pattern with * (any run of characters) against s.
      def self.match?(pattern, s)
        Regexp.new("\\A#{Regexp.escape(pattern).gsub('\\*', '.*')}\\z").match?(s)
      end

      # The files here: [{"name", "size", "mtime"}] (hidden ones left out),
      # newest first.
      def files
        ::Dir.children(@inbox_dir).reject { _1.start_with?(".") }.filter_map do |n|
          path = "#{@inbox_dir}#{n}"
          next unless ::File.file?(path)
          st = ::File.stat(path)
          { "name" => n, "size" => st.size, "mtime" => st.mtime }
        end.sort_by { -_1["mtime"].to_f }
      end

      # The bytes the directory holds (pieces coming in included).
      def used_bytes
        ::Dir.children(@inbox_dir).sum do |n|
          path = "#{@inbox_dir}#{n}"
          ::File.file?(path) ? ::File.size(path) : 0
        end
      end

      # ---- the hooks of Inbox ----

      def refused(kind, from, meta)
        return "#{@label} takes no #{kind}" unless kind == KIND
        return "#{@label} takes no file from #{from}" unless sender_ok?(from)
        place = meta.is_a?(Hash) ? meta["inbox"] : nil
        return nil if place.nil? || place == "home"
        return "#{@label} has no SD card to write to" if place == "sd"
        "#{@label} has no inbox #{place} (home only)"
      end

      def name_ok?(kind, name)
        ::Asterism::Transfer.file_name?(name)
      end

      def room(kind, meta)
        return nil if @max_bytes.nil?
        left = @max_bytes - used_bytes
        left.negative? ? 0 : left
      end

      def part_path(kind, name, meta)
        "#{@inbox_dir}.#{name}.#{kind}.part"
      end

      # The file is whole (its sha256 matches): its hidden piece file is
      # renamed to its name, or to a free name beside it when that one is
      # taken and overwrite was not asked. An overwritten file is replaced
      # only now.
      def received(t)
        over = t["meta"]["overwrite"] == true
        part = t["part"]
        name = over ? t["name"] : ::Asterism::Transfer.free_name(@inbox_dir, t["name"])
        if name.nil?
          remove(part)
          return { "status" => "refused", "reason" => "no free name for #{t['name']} in #{@label}'s inbox" }
        end
        dest = "#{@inbox_dir}#{name}"
        begin
          ::File.delete(dest) if over && ::File.exist?(dest)
          ::File.rename(part, dest)
        rescue SystemCallError => e
          remove(part)
          warn("transfer: #{dest} from #{t['from']}: #{e.message}")
          return { "status" => "refused", "reason" => "cannot place #{name} (#{e.message})" }
        end
        info("transfer: placed #{dest} (#{t['size']} bytes) from #{t['from']}#{over ? ' (overwrite)' : ''}")
        { "status" => "placed", "name" => name, "path" => name }
      end

      private

      def sweep
        keep = current_file && current_file["part"]
        ::Dir.children(@inbox_dir).each do |n|
          next unless n.start_with?(".") && n.end_with?(".part")
          path = "#{@inbox_dir}#{n}"
          next if path == keep
          info("transfer: #{path} left from before; deleted")
          remove(path)
        end
      end
    end
  end
end
