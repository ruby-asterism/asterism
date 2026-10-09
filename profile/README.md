# Ruby profile probes

A test suite of small Ruby snippets, each checking one language or
core-library feature, run on every Ruby the shared layer (`mrblib/`) has to
work on. The results and what they mean for the shared layer are in
[docs/ruby_profile.md](../docs/ruby_profile.md).

| File | What |
|---|---|
| `probes.txt` | The probes. A probe is a header (`## id:`, `## area:`, `## title:`, `## expect:`, optionally `## mrblib:` and `## kind: measure`) and its code; the format is described at the top of the file |
| `runner.rb` | Parses `probes.txt` and runs each probe with `eval`. Written to run unchanged on CRuby, mruby, PicoRuby and Family mruby's application VM (no Regexp, no `defined?`, `while` loops) |
| `run.rb` | Command-line entry for CRuby and the `mruby` / `picoruby` commands: prints one `RPROF|<id>|<status>|<detail>` line per probe |
| `profile.rb` | The host tool (CRuby): runs the CRuby columns in docker, runs an `mruby` / `picoruby` binary, copies the probes to Family mruby's test app, collects the app's log, and writes the table into `docs/ruby_profile.md` |
| `results/<impl>.txt` | The kept RPROF lines of each column |

Statuses: `ok` (the answer CRuby 3.4 gives), `differs` (another answer, no
exception), `ng` (an exception: missing, or not compiled), `value` (a
measurement).

## Running

```
ruby profile/profile.rb cruby                    # CRuby 3.2, 3.4, 4.0, 4.0 with frozen literals
ruby profile/profile.rb mruby BIN NAME [IMAGE]   # e.g. a host build of mruby or PicoRuby
ruby profile/profile.rb sync ../fmruby-core      # refresh the test app's copies
ruby profile/profile.rb collect sim-standard     # after the app ran in the simulation
ruby profile/profile.rb table                    # regenerate the table
```

The application-VM side is the Family mruby test app
`flash/app/test/ruby_profile.app.rb`, which reads its copies of
`runner.rb` and `probes.txt` from `flash/app/test/ruby_profile/` and logs the
same lines (8 probes per update; `RPROF-BEGIN` / `RPROF-END` frame a run).
Launch it by path (the simulation's `sim_app`, or debugd `spawn`); `collect`
takes the last complete run from `docker logs fmruby_core`.

## Adding a probe

Append a block to `probes.txt`. Keep the code to one feature, and avoid
helpers that may themselves be missing (`odd?`, `sum`, `then`): a probe that
fails on its helper reports the wrong feature. Write `expect` as a plain
literal, the answer CRuby 3.4 gives, and check that the CRuby columns stay
ok. The test app's only top-level local is `rprof_top_error`; a probe must
not assign a local of that name (see the eval caveat in
docs/ruby_profile.md).
