# How the command line's text looks (not --json, which stays as it is):
# colours and the terminal's width when the output is a terminal, plain
# text 80 columns wide (or COLUMNS) otherwise; NO_COLOR turns the colours
# off. Statuses are laid out as indented key=value lines, the methods and
# the descriptions are wrapped to the width, and watch tells what changed
# in a status. The standard library only (io/console for the width).
require "json"

module Asterism
  class CLI
    # Colours and width for one output.
    class Style
      CODES = { bold: 1, dim: 2, red: 31, green: 32, yellow: 33, blue: 34, magenta: 35, cyan: 36 }.freeze
      # What each kind of thing is painted with.
      ROLES = {
        node: %i[bold blue], app: [:cyan], object: [:green], method: [:bold], note: [:dim], time: [:dim],
        join: [:green], leave: [:red], status: [:yellow], profile: [:magenta]
      }.freeze
      MIN_WIDTH = 20

      attr_reader :width

      def initialize(io, env = ENV)
        tty = io.respond_to?(:tty?) && io.tty?
        @color = tty && env["NO_COLOR"].to_s.empty?
        w = (tty && terminal_width(io)) || env["COLUMNS"].to_i
        @width = w.positive? ? [w, MIN_WIDTH].max : 80
      end

      def color?
        @color
      end

      # text painted as role (a ROLES key) or with the CODES given.
      def paint(text, *styles)
        text = text.to_s
        return text unless @color
        codes = styles.flat_map { ROLES.fetch(_1, [_1]) }.map { CODES.fetch(_1) }
        codes.empty? ? text : "\e[#{codes.join(';')}m#{text}\e[0m"
      end

      private

      def terminal_width(io)
        require "io/console"
        w = io.winsize[1]
        w.positive? ? w : nil
      rescue StandardError, LoadError
        nil
      end
    end

    # Laying text out: display widths (East Asian wide characters take two
    # columns), word wrapping, statuses and their differences.
    module Text
      module_function

      ANSI = /\e\[[0-9;]*m/
      # Code points that take two columns on a terminal (East Asian Wide and
      # Fullwidth, roughly).
      WIDE = /[ᄀ-ᅟ⺀-〾ぁ-㏿㐀-䶿一-鿿ꀀ-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦\u{1F300}-\u{1F64F}\u{1F900}-\u{1F9FF}\u{20000}-\u{3FFFD}]/
      # A string value longer than this (columns) is cut, and so is an
      # array written on one line; --json has them whole.
      LONG = 60
      ARROW = "→"
      ELLIPSIS = "…"

      # The columns text takes on a terminal (colour codes take none).
      def width(text)
        s = text.to_s.gsub(ANSI, "")
        s = s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace) unless s.encoding == Encoding::UTF_8
        s.scrub.each_char.sum { _1.match?(WIDE) ? 2 : 1 }
      end

      # The tokens joined with sep in lines at most cols columns wide: the
      # first starts with first, the others with rest (spaces as wide as
      # first by default). A plain token wider than a line is broken between
      # characters (break_long: false keeps it whole, on a line of its own);
      # a painted one (a method's signature) is kept whole. Returns the
      # lines (at least one).
      def wrap(tokens, cols, first: "", rest: nil, sep: " ", break_long: true)
        rest ||= " " * width(first)
        lines = []
        line = first
        lw = width(first)
        empty = true
        tokens.each do |tok|
          tok = tok.to_s
          tw = width(tok)
          if !empty && lw + sep.size + tw > cols
            lines << line
            line = rest
            lw = width(rest)
            empty = true
          end
          while break_long && lw + tw > cols && !tok.match?(ANSI) && tok.size > 1
            head, tail = split_width(tok, [cols - lw, 1].max)
            break if tail.empty?
            lines << (empty ? line : line + sep) + head
            line = rest
            lw = width(rest)
            empty = true
            tok = tail
            tw = width(tok)
          end
          line += (empty ? "" : sep) + tok
          lw += (empty ? 0 : sep.size) + tw
          empty = false
        end
        lines << line
        lines
      end

      # text's words wrapped (wrap), each paragraph (blank lines between)
      # starting a new line with rest.
      def wrap_text(text, cols, first: "", rest: nil)
        rest ||= " " * width(first)
        paras = text.to_s.strip.split(/\n\s*\n/).map(&:split).reject(&:empty?)
        return [first.rstrip] if paras.empty?
        paras.each_with_index.flat_map { |words, i| wrap(words, cols, first: i.zero? ? first : rest, rest: rest) }
      end

      # [the start of text no wider than cols (one character at least), the rest]
      def split_width(text, cols)
        w = 0
        n = 0
        text.each_char do |c|
          cw = width(c)
          break if n.positive? && w + cw > cols
          w += cw
          n += 1
        end
        [text[0, n], text[n..]]
      end

      # ------------------------------------------------------------ statuses

      # A status (a Hash) as lines indented by indent spaces: the plain
      # values of a level as key=value on one line (wrapped), a Hash of
      # plain values as "key: k=v k=v", deeper ones as "key:" and their
      # lines two spaces further in, an array with a Hash in it as "key:"
      # and its elements as "- " lines. A key=value is never broken: one
      # wider than the line has a line of its own (the terminal folds it).
      def status_lines(h, cols, indent = 0)
        pad = " " * indent
        lines = []
        flat = []
        flush = lambda do
          lines.concat(wrap(flat, cols, first: pad, break_long: false)) unless flat.empty?
          flat = []
        end
        h.each do |k, v|
          if plain?(v)
            flat << pair(k, v)
            next
          end
          flush.call
          if v.is_a?(Hash) && v.empty?
            lines << "#{pad}#{k}: {}"
          elsif v.is_a?(Hash) && v.values.all? { plain?(_1) }
            # The lines after the first under the first value (two spaces in
            # when the key is long).
            hang = width(k) + 2 > cols / 3 ? 2 : width(k) + 2
            lines.concat(wrap(v.map { |kk, vv| pair(kk, vv) }, cols, first: "#{pad}#{k}: ", rest: pad + (" " * hang),
                                                                    break_long: false))
          elsif v.is_a?(Hash)
            lines << "#{pad}#{k}:"
            lines.concat(status_lines(v, cols, indent + 2))
          else
            lines << "#{pad}#{k}:"
            v.each { |e| lines.concat(element_lines(e, cols, indent + 2)) }
          end
        end
        flush.call
        lines.empty? ? ["#{pad}{}"] : lines
      end

      # One element of an array that holds a Hash: "- " and the element.
      def element_lines(e, cols, indent)
        pad = " " * indent
        if e.is_a?(Hash) && !e.empty? && e.values.all? { plain?(_1) }
          wrap(e.map { |k, v| pair(k, v) }, cols, first: "#{pad}- ", rest: "#{pad}  ", break_long: false)
        elsif e.is_a?(Hash) && !e.empty?
          sub = status_lines(e, cols, indent + 2)
          sub[0] = "#{pad}- #{sub[0].lstrip}"
          sub
        else
          ["#{pad}- #{inline(e)}"]
        end
      end

      # No Hash anywhere in v (it goes on one line).
      def plain?(v)
        case v
        when Hash then false
        when Array then v.all? { plain?(_1) }
        else true
        end
      end

      def pair(k, v)
        "#{k}=#{inline(v)}"
      end

      # A value on one line: a word as it is, other text quoted (JSON), a
      # long one cut; [a, b] (a long array cut, with the count left out);
      # {k=v k=v}; nil as nil.
      def inline(v)
        case v
        when Hash then "{#{v.map { |k, x| pair(k, x) }.join(' ')}}"
        when Array then inline_array(v)
        when String then inline_string(v)
        when nil then "nil"
        else v.to_s
        end
      end

      def inline_string(s)
        s = s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace) unless s.encoding == Encoding::UTF_8
        s = "#{split_width(s, LONG - 1)[0]}#{ELLIPSIS}" if width(s) > LONG
        s.match?(/\A[^\s="'{}\[\],]+\z/) ? s : JSON.generate(s)
      end

      def inline_array(a)
        parts = a.map { inline(_1) }
        text = "[#{parts.join(', ')}]"
        return text if width(text) <= LONG || parts.size < 2
        kept = []
        parts.each do |p|
          break if width("[#{(kept + [p]).join(', ')}, #{ELLIPSIS}+#{parts.size}]") > LONG && kept.any?
          kept << p
        end
        "[#{kept.join(', ')}, #{ELLIPSIS}+#{parts.size - kept.size}]"
      end

      # What changed from the status old to new, one String a change:
      # "a.b 0→1" (a value changed), "+a.b=1" (a key came; a Hash on one
      # line), "-a.b" (a key went). Hashes in both are compared key by key.
      def status_diff(old, new, prefix = nil)
        out = []
        at = ->(k) { prefix ? "#{prefix}.#{k}" : k.to_s }
        new.each do |k, v|
          if !old.key?(k)
            out << "+#{pair(at.(k), v)}"
          elsif old[k].is_a?(Hash) && v.is_a?(Hash)
            out.concat(status_diff(old[k], v, at.(k)))
          elsif old[k] != v
            out << "#{at.(k)} #{inline(old[k])}#{ARROW}#{inline(v)}"
          end
        end
        old.each_key { |k| out << "-#{at.(k)}" unless new.key?(k) }
        out
      end
    end
  end
end
