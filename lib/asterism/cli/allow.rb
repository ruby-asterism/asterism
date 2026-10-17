# The --allow patterns of `asterism mcp` (lib/asterism/cli/mcp.rb): which
# methods an MCP client may call.
module Asterism
  class CLI
    # The --allow patterns: [node/][app/]object.method, each part a glob
    # (* any text within the part). A pattern with fewer parts matches the
    # last parts of the path ("games/othello1.*" is "*/games/othello1.*";
    # "othello1" alone is "*/*/othello1.*": a pattern without .method
    # allows every method).
    class Allow
      def initialize(patterns)
        @list = patterns.map { parse(_1) }
      end

      def empty? = @list.empty?

      # Whether some pattern names this object (any of its methods).
      def object?(path)
        parts = path.split("/")
        @list.any? { |chunks, _| chunks_match?(chunks, parts) }
      end

      def method?(path, method)
        parts = path.split("/")
        @list.any? { |chunks, m| chunks_match?(chunks, parts) && glob?(m, method.to_s) }
      end

      private

      def parse(pat)
        slash = pat.rindex("/") || -1
        dot = pat.index(".", slash + 1)
        path = dot ? pat[0...dot] : pat
        meth = dot ? pat[(dot + 1)..] : "*"
        chunks = path.split("/", -1)
        if chunks.empty? || chunks.size > 3 || chunks.any?(&:empty?) || meth.empty?
          raise ArgumentError, "--allow #{pat.inspect}: expected [node/][app/]object.method (globs allowed)"
        end
        [Array.new(3 - chunks.size, "*") + chunks, meth]
      end

      def chunks_match?(chunks, parts)
        parts.size == 3 && chunks.each_with_index.all? { |c, i| glob?(c, parts[i]) }
      end

      # Only * is a wildcard (any text); ? and the rest are themselves (a
      # method may be called ok?).
      def glob?(pat, text)
        Regexp.new("\\A#{pat.split('*', -1).map { Regexp.escape(_1) }.join('.*')}\\z").match?(text)
      end
    end
  end
end
