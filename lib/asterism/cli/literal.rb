# The arguments of `asterism call` (and of the MCP bridge's tests): each is
# read as JSON, else as a Ruby literal, else taken as the text it is.
#
#   Literal.parse('{"seat": 1}')   # => {"seat" => 1}          (JSON)
#   Literal.parse("[1, :a, nil]")  # => [1, :a, nil]           (Ruby)
#   Literal.parse("{seat: 1}")     # => {seat: 1}              (Ruby)
#   Literal.parse("hello")         # => "hello"                (text)
#
# The Ruby form is read with Ripper and only literals are taken: nil,
# true, false, integers, floats, strings without interpolation, symbols,
# arrays (also %w / %i) and hashes. Nothing is evaluated: anything else (a
# method call, a constant, a variable) makes it not a literal, and the
# argument is then the text as written.
require "json"
require "ripper"

module Asterism
  class CLI
    module Literal
      class NotLiteral < StandardError; end

      module_function

      # The value of one argument (see above).
      def parse(text)
        json(text)
      rescue JSON::ParserError
        begin
          ruby(text)
        rescue NotLiteral
          text
        end
      end

      # JSON: a value of any kind at the top ("1", "\"x\"", "null" too).
      def json(text)
        JSON.parse(text)
      end

      # A Ruby literal, or NotLiteral.
      def ruby(text)
        tree = Ripper.sexp(text)
        raise NotLiteral, "not Ruby" unless tree && tree[0] == :program
        body = tree[1]
        raise NotLiteral, "one value expected" unless body.is_a?(Array) && body.size == 1
        node(body[0])
      end

      def node(n)
        raise NotLiteral, "unexpected #{n.inspect}" unless n.is_a?(Array)
        case n[0]
        when :@int then Integer(n[1].delete("_"), 0)
        when :@float then Float(n[1].delete("_"))
        when :unary
          raise NotLiteral, "only - before a number" unless n[1] == :-@ && %i[@int @float].include?(n[2][0])
          -node(n[2])
        when :var_ref, :@kw then keyword(n[0] == :var_ref ? n[1] : n)
        when :string_literal then string(n[1])
        when :symbol_literal then symbol(n[1])
        when :dyna_symbol then string(n[1]).to_sym
        when :array then array(n[1])
        when :hash then hash(n[1])
        when :bare_assoc_hash then pairs(n[1])
        else raise NotLiteral, "not a literal: #{n[0]}"
        end
      end

      def keyword(kw)
        raise NotLiteral, "not a keyword" unless kw[0] == :@kw
        case kw[1]
        when "nil" then nil
        when "true" then true
        when "false" then false
        else raise NotLiteral, "keyword #{kw[1]}"
        end
      end

      # string_content: plain parts only (no #{...}).
      def string(content)
        return "" if content.nil?
        parts = content[0] == :string_content ? content[1..] : content
        parts.map do |p|
          raise NotLiteral, "interpolation" unless p.is_a?(Array) && p[0] == :@tstring_content
          unescape(p[1])
        end.join
      end

      # The escapes of a double-quoted string (\n, \t, \", \\, \u...).
      def unescape(s)
        return s unless s.include?("\\")
        "\"#{s}\"".undump
      rescue RuntimeError
        s
      end

      def symbol(sym)
        raise NotLiteral, "symbol" unless sym[0] == :symbol
        sym[1][1].to_sym
      end

      def array(items)
        return [] if items.nil?
        items.map do |e|
          if e.is_a?(Array) && e[0] == :@tstring_content # %w[...]
            e[1]
          elsif e.is_a?(Array) && %i[qwords_add words_add qsymbols_add symbols_add].include?(e[0])
            raise NotLiteral, "old Ripper form"
          elsif e.is_a?(Array) && e[0] == :@ident # %i[...]
            e[1].to_sym
          else
            node(e)
          end
        end
      end

      def hash(list)
        return {} if list.nil?
        raise NotLiteral, "hash" unless list[0] == :assoclist_from_args
        pairs(list[1])
      end

      def pairs(assocs)
        assocs.to_h do |a|
          raise NotLiteral, "not a key => value" unless a[0] == :assoc_new
          k = a[1]
          key = k[0] == :@label ? k[1].chomp(":").to_sym : node(k)
          [key, node(a[2])]
        end
      end
    end
  end
end
