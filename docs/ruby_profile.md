# The Ruby profile of Asterism's shared layer

Asterism's shared layer (`mrblib/`) is one set of Ruby files that runs on
CRuby (the gem `asterism`) and on the boards (the mrbgem
`picoruby-asterism`, compiled by PicoRuby's compiler and run by the mruby VM
in Family mruby's application VM). This page records, by test rather than
by reading, which Ruby language and core-library features each of those
Rubies has: the subset the shared layer can be written in.

The table below is generated. The probes, the runner and the tool are in
[`profile/`](../profile/README.md); how to run them again is at the end.

## The implementations

| Column | What ran | How |
|---|---|---|
| CRuby 3.2 / 3.4 / 4.0 | `ruby:3.2-slim`, `ruby:3.4-slim`, `ruby:4.0` docker images (3.2.x, 3.4.x, 4.0.7) | `profile/run.rb` |
| CRuby 4.0 frozen | the same 4.0 with `RUBYOPT=--enable-frozen-string-literal` (the CI leg that checks frozen literals) | `profile/run.rb` |
| mruby master | `mruby/mruby` master `09dbc5f3` (2026-10-08), default gembox, host build. Uses the same Prism-based compiler as PicoRuby, at a newer commit | `profile/run.rb` |
| PicoRuby master | `picoruby/picoruby` master `a90afd12` (2026-10-05), default build (mruby VM), host build | `profile/run.rb` |
| app VM std | Family mruby's application VM in the Linux simulation, standard build (Spinel kernel and editor; the applications are mruby). PicoRuby `c932f70b` with its compiler `mruby-compiler2` `10408c3` (both 2026-07-11), plus the two upstream case/in fixes (mruby `0e6bac0e5a7e`, `680084ac1275`) that Family mruby carries since its C8 | the test app `/app/test/ruby_profile.app.rb`, read from the log |
| app VM compat | the same, compatibility build (`FMRB_KERNEL_ENGINE=mruby FMRB_APP_ENGINE_DESKTOP=mruby FMRB_APP_ENGINE_EDITOR=mruby`) | the same |

The two application-VM columns are the boards' Ruby: the ESP32-S3 and
ESP32-P4 firmwares build the application VM from the same PicoRuby, the same
compiler and the same core gems (their gem lists differ only in device
drivers). What the simulation cannot show is a board's word size and
memory: the integer and recursion rows are for a 64-bit host.

## How a probe is judged

Each probe checks one feature with a few lines of Ruby and states the answer
CRuby 3.4 gives. The runner compiles each probe on its own with `eval`, so a
probe that does not compile fails alone.

- **ok**: the answer is the stated one.
- **differs**: the code ran and gave another answer. These are the dangerous
  ones: nothing is raised.
- **ng**: an exception: the method or class is missing, or the code did not
  compile.

The last column says how the shared layer relates to the feature: *uses* it,
*avoids* it, or *guards* it (looks for it at load time and has a fallback).

## What it means for the shared layer

The two application-VM builds gave the same answer on every probe, so they
are one column for what follows.

**Safe on every Ruby measured** (what `mrblib/` is written in):

- The dynamic object model the proxies need: `method_missing` with
  positional, keyword and block arguments, `respond_to_missing?`,
  `define_method`, `send` / `public_send` / `__send__`,
  `instance_variable_get` / `set`, `public_instance_methods(false)`, `eval`
  of a string.
- Keyword arguments (required, optional, unknown-keyword `ArgumentError`),
  `*args, **kw, &blk` forwarding, `...`, endless `def`, `_1`, hash
  shorthand `{x:}`, `&.`, `<<~` heredocs.
- `defined?` works in the application VM now (it returned the CRuby answers
  for a constant, a missing constant and an instance variable). Older notes
  in Family mruby said it did not; the shared layer still uses
  `Object.const_defined?`, which also works everywhere.
- Constant lookup from a method of a class reaches top-level and built-in
  constants, and a constant of the enclosing module. A bare constant of the
  including class from a module method is a `NameError` on CRuby too, so
  `self.class::CONST` is the way on every Ruby. (Older Family mruby notes
  reported bare-constant lookup failures in classes; none reproduced here.)
- Exceptions: custom classes, `retry`, `ensure`, `rescue` modifiers,
  `backtrace` as an Array, `FrozenError`, `NoMatchingPatternError`.
- Blocks stored and called later keep their locals; `block_given?`,
  `yield`, `&:sym`, `Proc.new`'s lenient arity, lambdas' strict arity,
  `return` from a block leaves the method.
- Strings at the byte level (`getbyte`, `setbyte`, `byteslice`, `bytesize`),
  `format` / `String#%`, `start_with?`, `delete_prefix`, `tr`, `split`
  with a limit, `sub` / `gsub` with a String pattern, `chr` / `ord`.
- `Array#pack` / `String#unpack` and `Math.ldexp` / `frexp` are present in
  the application VM (mruby-pack and mruby-math are in the build); the
  shared layer still guards them, because a smaller build may leave them out.
- 64-bit Integers on a 64-bit host, floor division and modulo of negatives,
  `Integer()` / `Float()`, Float formatting (`1.0e+20`,
  `0.30000000000000004`), `Infinity`, `NaN`, `-0.0`.
- Hash insertion order, `Hash.new` with a default block, `Hash#to_a`,
  `any?`; `Array#include?`, `index`, `uniq`, `rotate`, `partition`,
  `bsearch`, `dig`, `product`; `Range#include?`; `Comparable`, a custom
  `Enumerable` (`select`, `map`, `include?`), `prepend`, `class << self`.

**Missing in the application VM** (ng), so not usable in the shared layer:

- Regexp (literal, `Regexp.new`, `scan` with a regexp). PicoRuby master and
  mruby master have it.
- `Struct`, `Data`, `Set`. The ROS 2 message types are plain classes for this
  reason. PicoRuby master has a `Data` that answers a Hash (differs).
- `Module#name` (use `to_s`, as the error replies do), `Kernel#proc`,
  `Kernel#method`, `catch` / `throw`, `instance_exec`, `class_eval` with a
  string, `Proc#curry`, `Exception#cause`.
- `nil.to_i`, `nil.to_a`, `Integer#digits`, `pow(b, mod)`, `bit_length`,
  `clamp`, Rational, Complex, Integers beyond 64 bits (`2**64` is a
  `RangeError`).
- Much of Enumerable on Array, Hash and Range: `sum`, `minmax`, `tally`,
  `filter_map`, `each_slice`, `each_cons`, `zip`, `flat_map`, `group_by`,
  `sort_by`, `cycle`, `count` / `min_by` / `sum` on a Hash,
  `transform_values`, `Hash#dig`, `compare_by_identity`, `Range#sum`,
  `(5..).first(2)`.
- External enumerators and anything that needs one (`e.next`,
  `step(...).to_a`, `lazy`, `Enumerator.new`), `Fiber`, `Thread`, `Mutex`.
- `Integer#odd?` / `even?` (seen while writing the probes, which now use
  `% 2`), `Process.clock_gettime`, `Random`, `then` / `tap` / `itself`. The shared
  layer reads the clock through `Asterism.now_ms` (PicoRuby's `Machine` on
  the boards).
- String encodings: `encoding`, `force_encoding`, `String#b`. The CDR code
  guards these (`ENCODINGS`).
- Ruby recursion deeper than about 500 (`SystemStackError` at 501 calls;
  mruby and PicoRuby master stop at 506, CRuby at about 10,000).

**Different answers in the application VM** (differs: no exception):

- `^x` of a local of the enclosing method inside a block does not match,
  `^(expr)` never matches, `Const[...]` ignores the constant, and
  `in {a:, **rest} then [a, rest]` answers `rest` alone.
- The `# frozen_string_literal: true` comment is ignored (literals stay
  mutable, as on mruby and PicoRuby master); `"\u0001".inspect` is
  `"\x01"`.

Fixed in the application VM since the first run of this table (2026-10-09,
Family mruby C8): a hash pattern's value was compared the wrong way round
(`in {x: Integer}`, `in {x: 0..2}` never matched, a literal value matched
anything) and a pattern inside a block did not bind a local of the
enclosing method. Seven probes went from differs to ok. Both fixes are
upstream (mruby `0e6bac0e5a7e`, `680084ac1275`; in PicoRuby master), and
Family mruby carries them on its older PicoRuby.

Also wrong there, though they raise rather than answer differently (ng in
the table): `protected` methods cannot be called from another instance of
the same class (`NoMethodError`), and `$!` is nil in a `rescue` modifier
(both fixed in PicoRuby master).

All of these remaining differences are compiler or VM bugs of the vendored
PicoRuby that PicoRuby master no longer has (PicoRuby master passes every
pattern probe). They and their upstream fixes are written up in Family
mruby's `doc/ruby_asterism/upstream/picoruby_case_in.md`. Until the vendored
PicoRuby moves, the shared layer and the boards' applications avoid them
(the README's Limits).

**Ruby 4 and frozen literals.** CRuby 4.0 still lets a literal be appended
to (it warns under `-W:deprecated`), but with
`--enable-frozen-string-literal` appending raises `FrozenError`. Strings
that are built up start from `"".dup` in the shared layer (all three Rubies
accept it).

**Block calls.** On the mruby-family columns a call with a literal block
costs 2.1 to 2.6 times a plain method call (CRuby: 1.2 to 1.4 times), and an
`Array#each` iteration about 1.5 times a method call. The shared layer uses
`while` loops on its hot paths and leaves blocks to the application's
callbacks. On a board the absolute numbers are much larger (Family mruby
measured about 0.4 ms for creating a block on the ESP32-P4), but the ratios
are the point here.

**C stack per callback.** Not probed (a host has a large C stack). On a
board, every C function that calls back into Ruby (a block called from C,
`respond_to?` calling `respond_to_missing?`, an event handed in from C)
nests the interpreter on the task's C stack: Family mruby measured a 16 KB
application stack using 8.1 KB at rest and 12.4 KB when a call waited inside
an event handler, against 10.7 KB inside the update callback. Hence the
shared layer takes replies as Arrays rather than blocks from C, defines
`Proxy#respond_to?` in Ruby, and tells applications to wait only from
their update callback or with `async`.

## The table

<!-- profile:begin -->
| Feature | Area | CRuby 3.2 | CRuby 3.4 | CRuby 4.0 | CRuby 4.0 frozen | mruby master | PicoRuby master | app VM std | app VM compat | mrblib |
|---|---|---|---|---|---|---|---|---|---|---|
| `regexp_literal` Regexp literal and =~ | syntax | ok | ok | ok | ok | ok | ok | **ng** | **ng** | avoids |
| `regexp_class` Regexp.new / match? | core | ok | ok | ok | ok | ok | ok | **ng** | **ng** | avoids |
| `defined_const` defined?(Const) | syntax | ok | ok | ok | ok | ok | ok | ok | ok | avoids (uses Object.const_defined?) |
| `defined_missing` defined?(UnknownConst) is nil | syntax | ok | ok | ok | ok | ok | ok | ok | ok | avoids |
| `defined_ivar` defined?(@ivar) | syntax | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `const_defined` Object.const_defined? | core | ok | ok | ok | ok | ok | ok | ok | ok | uses |
| `safe_navigation` &. on nil | syntax | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `endless_def` endless method definition | syntax | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `numbered_param` numbered block parameter _1 | syntax | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `it_param` it block parameter (Ruby 3.4) | syntax | **ng** | ok | ok | ok | ok | ok | ok | ok |  |
| `hash_shorthand` hash shorthand {x:} | syntax | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `kwargs` required and optional keywords | syntax | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `kwargs_unknown` unknown keyword raises ArgumentError | syntax | ok | ok | ok | ok | ok | ok | ok | ok | uses |
| `kwargs_forward` *args, **kw, &blk forwarding | syntax | ok | ok | ok | ok | ok | ok | ok | ok | uses (Proxy#method_missing) |
| `args_forward_dots` ... argument forwarding | syntax | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `multi_assign` a, *b = list | syntax | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `multi_assign_index` a[0], a[1] = a[1], a[0] | syntax | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `heredoc_squiggly` <<~ heredoc | syntax | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `string_interp` interpolation of non-strings | syntax | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `begin_end_while` begin ... end while (runs once) | syntax | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `flip_case_when` case/when with ranges, classes, splat | syntax | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `pattern_hash_bind` in {x:} binds x | pattern | ok | ok | ok | ok | ok | ok | ok | ok | uses (deconstruct_keys) |
| `pattern_hash_literal` in {x: 3} with a literal value | pattern | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `pattern_hash_class` in {x: Integer} | pattern | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `pattern_hash_class_capture` in {x: Integer => a} | pattern | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `pattern_hash_range` in {x: 0..2} | pattern | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `pattern_hash_nested` in {a: {b:}} | pattern | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `pattern_hash_rest` in {a:, **rest} | pattern | ok | ok | ok | ok | ok | ok | **differs** | **differs** |  |
| `pattern_second_clause` the second in clause after a missing key | pattern | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `pattern_deconstruct_keys` an object with deconstruct_keys | pattern | ok | ok | ok | ok | ok | ok | ok | ok | uses (Message, Attachment) |
| `pattern_array_class` in [Integer => a, String] | pattern | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `pattern_find` find pattern [*, 42 => x, *] | pattern | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `pattern_guard_alt` guard and alternative | pattern | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `pattern_pin_local` ^pin of a local in the same scope | pattern | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `pattern_pin_block` ^pin of an outer local inside a block | pattern | ok | ok | ok | ok | ok | ok | **differs** | **differs** |  |
| `pattern_pin_expr` ^(expression) | pattern | ok | ok | ok | ok | ok | ok | **differs** | **differs** |  |
| `pattern_bind_in_block` binding an outer local inside a block | pattern | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `pattern_rightward_in_block` x => [a] inside a block, a outer | pattern | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `pattern_block_local` binding a new name inside a block | pattern | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `pattern_const_pattern` Const[...] checks the constant | pattern | ok | ok | ok | ok | ok | ok | **differs** | **differs** |  |
| `pattern_no_match` NoMatchingPatternError | pattern | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `pattern_one_line_in` expr in pattern (boolean) | pattern | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `const_top_from_class` a top-level constant from a method of a class | const | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `const_builtin_from_class` a built-in class (Hash) from a method of a class | const | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `const_lexical_nested` a constant of the enclosing module | const | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `const_mixin_host` a constant of the including class, bare, from a module (NameError in CRuby) | const | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `const_self_class` self.class::CONST from a module | const | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `const_get_path` Object.const_get("A::B") | const | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `const_get_module` Module#const_get(sym) | const | ok | ok | ok | ok | ok | ok | ok | ok | uses (ROS.type_constant) |
| `module_name` Module#name | object | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** | avoids (uses to_s) |
| `module_to_s` Module#to_s and interpolation of a class | object | ok | ok | ok | ok | ok | ok | ok | ok | uses (error replies) |
| `struct` Struct.new | core | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** | avoids (plain classes) |
| `data_define` Data.define | core | ok | ok | ok | ok | ok | **differs** | **ng** | **ng** | avoids (plain classes) |
| `set` Set without require | core | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `comparable` include Comparable with <=> | object | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `enumerable_custom` include Enumerable with each | object | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `prepend` Module#prepend and super | object | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `singleton_class_block` class << self | object | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `protected_method` protected method callable from same class | object | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `equal_eql_hash` custom eql?/hash as Hash keys | object | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `object_id_equal` equal? and object_id | object | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `freeze` freeze and FrozenError | object | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `method_missing` method_missing with args and kwargs | meta | ok | ok | ok | ok | ok | ok | ok | ok | uses (Proxy) |
| `respond_to_missing` respond_to? consults respond_to_missing? | meta | ok | ok | ok | ok | ok | ok | ok | ok | uses (Proxy defines respond_to? in Ruby) |
| `define_method` define_method (public) with args | meta | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `send_public_send` send reaches private, public_send does not | meta | ok | ok | ok | ok | ok | ok | ok | ok | uses (__send__) |
| `instance_variable_get_set` instance_variable_get / set | meta | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `method_object` method(:x).call and arity | meta | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `instance_methods_false` public_instance_methods(false) | meta | ok | ok | ok | ok | ok | ok | ok | ok | uses (meta replies) |
| `class_eval_string` class_eval with a string | meta | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `instance_exec` instance_exec with an argument | meta | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `kernel_eval` eval of a string | meta | ok | ok | ok | ok | ok | ok | ok | ok | uses (ROS types on mruby) |
| `lambda_strict` a lambda checks its arity | proc | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `proc_new_lenient` Proc.new fills missing args with nil | proc | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `kernel_proc` Kernel#proc | proc | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `proc_auto_splat` proc auto-splats an array argument | proc | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `proc_return` return inside a proc leaves the method | proc | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `block_given` block_given? and yield | proc | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `stored_block_capture` a stored block keeps its locals | proc | ok | ok | ok | ok | ok | ok | ok | ok | uses (subscribe/every blocks) |
| `symbol_to_proc` &:sym | proc | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `curry` Proc#curry | proc | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `exception_custom` custom exception class and message | exception | ok | ok | ok | ok | ok | ok | ok | ok | uses (Asterism::RemoteError etc.) |
| `exception_retry_ensure` retry and ensure | exception | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `exception_backtrace` backtrace is an Array | exception | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `exception_cause` Exception#cause | exception | ok | ok | ok | ok | **ng** | **ng** | **ng** | **ng** |  |
| `catch_throw` catch / throw | exception | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `rescue_modifier` rescue modifier | exception | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `rescue_modifier_bang` $! in a rescue modifier | exception | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `string_literal_mutable` appending to a string literal | string | ok | ok | ok | **ng** | ok | ok | ok | ok | avoids (uses "".dup) |
| `string_literal_frozen_p` "".frozen? | string | ok | ok | ok | **differs** | ok | ok | ok | ok |  |
| `string_literal_magic_frozen` frozen_string_literal magic comment | string | ok | ok | ok | ok | **differs** | **differs** | **differs** | **differs** |  |
| `string_dup_append` "".dup << "a" | string | ok | ok | ok | ok | ok | ok | ok | ok | uses |
| `string_length_utf8` length counts characters, bytesize bytes | string | ok | ok | ok | ok | **differs** | ok | ok | ok |  |
| `string_byte_ops` getbyte / setbyte / byteslice | string | ok | ok | ok | ok | ok | ok | ok | ok | uses |
| `string_b` String#b and encoding | string | ok | ok | ok | ok | **ng** | **ng** | **ng** | **ng** |  |
| `string_force_encoding` force_encoding | string | ok | ok | ok | ok | **ng** | **ng** | **ng** | **ng** | guards (respond_to?) |
| `string_unpack` String#unpack / unpack1 | string | ok | ok | ok | ok | ok | ok | ok | ok | guards (respond_to?) |
| `array_pack` Array#pack | collection | ok | ok | ok | ok | ok | ok | ok | ok | guards (respond_to?) |
| `pack_float` pack("e") float32 little-endian | collection | ok | ok | ok | ok | ok | ok | ok | ok | guards (CDR float) |
| `string_format` format / String#% | string | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `string_methods` start_with?, delete_prefix, center, tr | string | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `string_split_join` split with limit, join | string | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `string_sub_string` sub / gsub with a String pattern | string | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `string_scan_regexp` scan with a regexp | string | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `string_inspect_escape` inspect of control and non-ASCII | string | ok | ok | ok | ok | **differs** | **differs** | **differs** | **differs** |  |
| `symbol_string` to_sym / to_s / inspect of symbols | string | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `chr_ord` Integer#chr and String#ord | string | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `integer_division` floor division and modulo of negatives | numeric | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `integer_64bit` 1 << 40 and 2**62 (64-bit Integer) | numeric | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `integer_bignum` 2**64 (arbitrary precision) | numeric | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `nil_to_i` nil.to_i | numeric | ok | ok | ok | ok | ok | ok | **ng** | **ng** | avoids |
| `nil_to_a` nil.to_a | numeric | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `nil_to_s` nil.to_s | numeric | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `kernel_integer_float` Integer("12") / Float("1.5") / "12x".to_i | numeric | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `float_to_s` Float#to_s formatting | numeric | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `float_round` round(2), floor, ceil, truncate | numeric | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `float_special` Infinity, NaN, -0.0 | numeric | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `math_functions` Math.sqrt, ldexp, frexp | numeric | ok | ok | ok | ok | ok | ok | ok | ok | guards (CDR float) |
| `rational` Rational literal 1r / 3 | numeric | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `complex` Complex literal 1 + 2i | numeric | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `integer_digits` Integer#digits | numeric | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `integer_pow_mod` Integer#pow(b, mod) | numeric | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `integer_bit_length` Integer#bit_length | numeric | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `integer_clamp` Comparable#clamp on Integer | numeric | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `hash_insertion_order` Hash keeps insertion order | collection | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `hash_transform_values` Hash#transform_values | collection | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `hash_dig` Hash#dig | collection | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `hash_to_a` Hash#to_a | collection | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `hash_default_proc` Hash.new with a block | collection | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `hash_compare_by_identity` compare_by_identity | collection | ok | ok | ok | ok | **ng** | **ng** | **ng** | **ng** |  |
| `hash_any` Hash#any? with a block | collection | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `hash_count` Hash#count with a block | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `hash_min_by` Hash#min_by | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `hash_sum` Hash#sum with a block | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `array_each_slice` each_slice | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `array_each_cons` each_cons | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `array_tally` tally | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `array_filter_map` filter_map | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `array_sum` Array#sum | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `array_minmax` minmax | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `array_zip` zip | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `array_flat_map` flat_map | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `array_group_by` group_by | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `array_partition` partition | collection | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `array_sort_by` sort_by | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `array_uniq` uniq | collection | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `array_rotate` rotate | collection | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `array_include_index` include? and index | collection | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `array_bsearch` bsearch | collection | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `array_dig` Array#dig | collection | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `array_cycle` cycle.first(n) | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `array_product` product | collection | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `range_step` Integer#step(to, by).to_a | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `range_endless` endless range (5..).first(2) | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `range_sum` Range#sum | collection | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `range_include` Range#include? | collection | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `enumerator_next` external enumerator next / StopIteration | core | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `enumerator_lazy` lazy.map.select.first | core | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `enumerator_new` Enumerator.new with a yielder | core | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `fiber` Fiber.new / resume / yield | core | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `thread` Thread.new.value | core | ok | ok | ok | ok | **ng** | **ng** | **ng** | **ng** |  |
| `mutex` Mutex#synchronize | core | ok | ok | ok | ok | **ng** | **ng** | **ng** | **ng** |  |
| `object_space_gc` GC.start and ObjectSpace.count_objects | core | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `time_now` Time.now and Time#to_f | core | ok | ok | ok | ok | ok | ok | ok | ok | avoids (Machine / Process clock) |
| `process_clock` Process.clock_gettime(MONOTONIC) | core | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** | guards (CRuby clock, Machine on boards) |
| `kernel_rand` rand(10) and Random.new(1) | core | ok | ok | ok | ok | ok | **ng** | **ng** | **ng** |  |
| `object_then` then | core | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `object_tap` tap | core | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `object_itself` itself | core | ok | ok | ok | ok | ok | ok | **ng** | **ng** |  |
| `method_name` __method__ | core | ok | ok | ok | ok | ok | ok | ok | ok |  |
| `recursion_1000` Ruby recursion 1000 deep | runtime | ok | ok | ok | ok | **ng** | **ng** | **ng** | **ng** |  |
| `recursion_via_block_100` recursion through a block called from C, 100 deep | runtime | ok | ok | ok | ok | ok | ok | ok | ok |  |

| Totals | CRuby 3.2 | CRuby 3.4 | CRuby 4.0 | CRuby 4.0 frozen | mruby master | PicoRuby master | app VM std | app VM compat |
|---|---|---|---|---|---|---|---|---|
| ok | 171 | 172 | 172 | 170 | 162 | 131 | 107 | 107 |
| differs | 0 | 0 | 0 | 1 | 3 | 3 | 6 | 6 |
| ng | 1 | 0 | 0 | 1 | 7 | 38 | 59 | 59 |

Measurements, not judged (recursion_limit is a depth; the others are microseconds per operation on one x86-64 machine, so compare rows within a column rather than across machines):

| Operation | CRuby 3.2 | CRuby 3.4 | CRuby 4.0 | CRuby 4.0 frozen | mruby master | PicoRuby master | app VM std | app VM compat |
|---|---|---|---|---|---|---|---|---|
| `recursion_limit` Ruby recursion depth before SystemStackError (capped at 100000) | 10073.0 | 10913.0 | 10913.0 | 10913.0 | 506.0 | 506.0 | 501.0 | 501.0 |
| `measure_while` one while iteration (us) | 0.0039 | 0.01 | 0.0044 | 0.0076 | 0.021 | 0.0283 | 0.0249 | 0.0266 |
| `measure_method_call` one method call (us) | 0.0138 | 0.0192 | 0.0147 | 0.0148 | 0.032 | 0.0464 | 0.0425 | 0.0413 |
| `measure_block_call` one call with a literal block that yields once (us) | 0.0196 | 0.023 | 0.0202 | 0.0212 | 0.0748 | 0.0996 | 0.1074 | 0.1123 |
| `measure_each` one Array#each iteration (us) | 0.016 | 0.018 | 0.0183 | 0.0196 | 0.0463 | 0.0601 | 0.0601 | 0.0623 |

What the cells that are not ok answered:

- `regexp_literal` on app VM std, app VM compat: NameError: uninitialized constant Regexp
- `regexp_class` on app VM std, app VM compat: NameError: uninitialized constant RubyProfile::Runner::Regexp
- `it_param` on CRuby 3.2: NameError: undefined local variable or method 'it' for #<RubyProfile::Ru...
- `pattern_hash_rest` on app VM std, app VM compat: {b: 2}
- `pattern_pin_block` on app VM std, app VM compat: [false]
- `pattern_pin_expr` on app VM std, app VM compat: false
- `pattern_const_pattern` on app VM std, app VM compat: true
- `module_name` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'name' for Class
- `struct` on PicoRuby master, app VM std, app VM compat: NameError: uninitialized constant RubyProfile::Runner::Struct
- `data_define` on PicoRuby master: {a: 1}
- `data_define` on app VM std, app VM compat: NameError: uninitialized constant RubyProfile::Runner::Data
- `set` on PicoRuby master, app VM std, app VM compat: NameError: uninitialized constant RubyProfile::Runner::Set
- `protected_method` on app VM std, app VM compat: NoMethodError: protected method 'v' called for RubyProfile::Runner::RpPr...
- `method_object` on app VM std, app VM compat: NoMethodError: undefined method 'method' for RubyProfile::Runner
- `class_eval_string` on app VM std, app VM compat: NotImplementedError: module_eval/class_eval with string not implemented
- `instance_exec` on app VM std, app VM compat: NoMethodError: undefined method 'instance_exec' for Object
- `kernel_proc` on app VM std, app VM compat: NoMethodError: undefined method 'proc' for RubyProfile::Runner
- `curry` on app VM std, app VM compat: NoMethodError: undefined method 'curry' for Proc
- `exception_cause` on mruby master, PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'cause' for RuntimeError
- `catch_throw` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'catch' for RubyProfile::Runner
- `rescue_modifier_bang` on app VM std, app VM compat: NoMethodError: undefined method 'message' for NilClass
- `string_literal_mutable` on CRuby 4.0 frozen: FrozenError: can't modify frozen String: "a"
- `string_literal_frozen_p` on CRuby 4.0 frozen: true
- `string_literal_magic_frozen` on mruby master, PicoRuby master, app VM std, app VM compat: false
- `string_length_utf8` on mruby master: [3, 3]
- `string_b` on mruby master, PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'encoding' for String
- `string_force_encoding` on mruby master, PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'force_encoding' for String
- `string_scan_regexp` on app VM std, app VM compat: NameError: uninitialized constant Regexp
- `string_inspect_escape` on mruby master, PicoRuby master, app VM std, app VM compat: "\"a\\n\\x01\""
- `integer_bignum` on PicoRuby master, app VM std, app VM compat: RangeError: integer overflow in power
- `nil_to_i` on app VM std, app VM compat: NoMethodError: undefined method 'to_i' for NilClass
- `nil_to_a` on app VM std, app VM compat: NoMethodError: undefined method 'to_a' for NilClass
- `rational` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'Rational' for RubyProfile::Runner
- `complex` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'Complex' for RubyProfile::Runner
- `integer_digits` on app VM std, app VM compat: NoMethodError: undefined method 'digits' for Integer
- `integer_pow_mod` on app VM std, app VM compat: NoMethodError: undefined method 'pow' for Integer
- `integer_bit_length` on app VM std, app VM compat: NoMethodError: undefined method 'bit_length' for Integer
- `integer_clamp` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'clamp' for Integer
- `hash_transform_values` on app VM std, app VM compat: NoMethodError: undefined method 'transform_values' for Hash
- `hash_dig` on app VM std, app VM compat: NoMethodError: undefined method 'dig' for Hash
- `hash_compare_by_identity` on mruby master, PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'compare_by_identity' for Hash
- `hash_count` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'count' for Hash
- `hash_min_by` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'min_by' for Hash
- `hash_sum` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'sum' for Hash
- `array_each_slice` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'each_slice' for Array
- `array_each_cons` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'each_cons' for Array
- `array_tally` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'tally' for Array
- `array_filter_map` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'filter_map' for Array
- `array_sum` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'sum' for Array
- `array_minmax` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'minmax' for Array
- `array_zip` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'zip' for Array
- `array_flat_map` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'flat_map' for Array
- `array_group_by` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'group_by' for Array
- `array_sort_by` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'sort_by' for Array
- `array_cycle` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'cycle' for Array
- `range_step` on PicoRuby master, app VM std, app VM compat: NotImplementedError: fiber required for enumerator
- `range_endless` on PicoRuby master, app VM std, app VM compat: ArgumentError: wrong number of arguments (given 1, expected 0)
- `range_sum` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'sum' for Range
- `enumerator_next` on PicoRuby master, app VM std, app VM compat: NotImplementedError: fiber required for enumerator
- `enumerator_lazy` on PicoRuby master, app VM std, app VM compat: NoMethodError: undefined method 'lazy' for Range
- `enumerator_new` on PicoRuby master, app VM std, app VM compat: NameError: uninitialized constant RubyProfile::Runner::Enumerator
- `fiber` on PicoRuby master, app VM std, app VM compat: NameError: uninitialized constant RubyProfile::Runner::Fiber
- `thread` on mruby master, PicoRuby master, app VM std, app VM compat: NameError: uninitialized constant RubyProfile::Runner::Thread
- `mutex` on mruby master, PicoRuby master, app VM std, app VM compat: NameError: uninitialized constant RubyProfile::Runner::Mutex
- `process_clock` on PicoRuby master, app VM std, app VM compat: NameError: uninitialized constant RubyProfile::Runner::Process
- `kernel_rand` on PicoRuby master, app VM std, app VM compat: NameError: uninitialized constant RubyProfile::Runner::Random
- `object_then` on app VM std, app VM compat: NoMethodError: undefined method 'then' for Integer
- `object_tap` on app VM std, app VM compat: NoMethodError: undefined method 'tap' for Integer
- `object_itself` on app VM std, app VM compat: NoMethodError: undefined method 'itself' for Integer
- `recursion_1000` on mruby master, PicoRuby master, app VM std, app VM compat: SystemStackError: SystemStackError
<!-- profile:end -->

## Running it again

```
ruby profile/profile.rb cruby                         # the four CRuby columns (docker)
ruby profile/profile.rb mruby path/to/mruby/bin/mruby mruby-master
ruby profile/profile.rb mruby path/to/picoruby/bin/picoruby picoruby-master ruby:3.4
ruby profile/profile.rb sync ../fmruby-core           # copy the probes into the test app
#   start the simulation, launch /app/test/ruby_profile.app.rb (MCP sim_app,
#   or debugd spawn), wait for "ok N differs N ng N" in its window
ruby profile/profile.rb collect sim-standard          # (sim-compat for the compat build)
ruby profile/profile.rb table                         # rewrite the table above
```

One caveat of running probes through `eval` in the application VM: `eval`
of code that assigns a new local with the name of a local of the
application file's top level fails with `SyntaxError` ("Can't find local
variables"). The test app keeps its top level free of common names, and
PicoRuby master no longer has the problem.
