# CLI Reference

`nfl <command> [flags] file.nfl [-- nim-args...]`

## Commands

### `run`

Compiles `file.nfl` and immediately executes the resulting binary. Under the
hood this generates a temporary `wrapper.nim` that calls the `nflModule`
macro on `file.nfl` and hands it to `nim c -r`.

```sh
nfl run hello.nfl
```

### `compile`

Compiles `file.nfl` to a binary next to the source file (same name, no
extension — Nim's `ExeExt`, which is empty on Unix). Does not run it.

```sh
nfl compile hello.nfl
./hello
```

### `check`

Type-checks `file.nfl` (and everything it `(import ...)`s) without producing
a binary. Fastest way to validate a file.

```sh
nfl check hello.nfl
```

### Passing arguments straight to `nim`

Anything after a bare `--` on `run`/`compile`/`check` is forwarded verbatim
to the underlying `nim c`/`check` invocation, after `nfl`'s own flags — so
you can reach for any `nim` flag (memory manager, optimization level, panic
mode, etc.) without `nfl` needing to know about it specifically:

```sh
nfl compile hello.nfl -- --mm:orc -d:release
nfl run hello.nfl -- --mm:none        # no GC — see the caveat below
```

`--mm:none` disables the memory manager entirely: allocations are never
freed, not garbage-collected less eagerly. It's appropriate for short-lived
scripts or freestanding/embedded targets where the process exits before
memory pressure matters, not as a general "GC optional" mode for long-running
programs — a loop appending a few thousand items to a sequence for a couple
of seconds visibly balloons to hundreds of MB of RSS under `--mm:none`
versus single-digit MB under `--mm:orc` for the same program. `--mm:arc`
(deterministic reference counting, no cycle collector, still frees memory)
is the middle ground if you want lower GC overhead without leaking.

`--` is only valid with `run`/`compile`/`check` — `macroexpand`, `shim`, and
`repl` don't shell out to `nim` per invocation the same way, so there's
nothing to forward the arguments to.

### `macroexpand`

Reads and fully macro-expands `file.nfl`, then prints the expanded NFL
s-expressions (one top-level form per line) to stdout. Does not touch the
Nim compiler — this is the reader/expander pipeline running directly in the
`nfl` binary, not inside a `nim c`/`check` subprocess. `defmacro` and
`defmacro-proc` forms are consumed during expansion and never appear in the
output.

```sh
nfl macroexpand hello.nfl
```

`--emit nim` is **not** valid with `macroexpand` — this command already is
the NFL-forms half of "show me what NFL is doing"; `--emit nim` is the
Nim-source half, and only applies to `run`/`compile`/`check` since it needs
an actual `nim` compilation to run inside.

### `shim`

Writes a Nim module that delegates to `file.nfl` via the `nflModule` macro,
so plain Nim code can `import` it without going through the `nfl` CLI. See
[package-layout.md](package-layout.md) for the package shape this is meant
to fit into, and its limitations (in particular: it's a compile-time
delegation, not translated Nim source, and NFL macros don't cross the
import boundary).

```sh
nfl shim src/mylib/util.nfl        # writes src/mylib/util.nim
```

By default the output path is the input with its extension changed to
`.nim`. `nfl shim` refuses to overwrite a file it didn't generate (detected
by a header comment on the first line), to avoid clobbering hand-written
Nim.

### `repl`

Starts an interactive read/expand/compile/run loop, backed by an actual
`nim c` per accepted input (there is no interpreter). See
[repl.md](repl.md) for the full session model — full-transcript replay,
name-keyed redefinition, `defvar`/`defparameter` semantics, and REPL
commands (`:help`, `:quit`, `:transcript`, `:reset`).

```sh
nfl repl                  # start an empty session
nfl repl mylib.nfl        # preload mylib.nfl as the first transcript entry
```

Unlike every other command, `repl`'s file argument is optional.

## Flags

| Flag | Commands | Effect |
|---|---|---|
| `--no-core` | all | Skip auto-loading the preamble (`std/core.nfl`'s macros — `when`, `unless`, `cond`, threading macros, etc). |
| `--emit nim` | `run`, `compile`, `check` | Echoes the emitted `NimNode`'s `.repr` to stdout, between `# --- nfl: begin/end emitted nim ---` marker lines, once expansion/lowering/emission succeed. **Best-effort debug output** — it is not guaranteed to be valid, re-compilable Nim (see the note in [package-layout.md](package-layout.md#nfl-shim-vs---emit-nim)); use it to see what NFL produced when a `nim` compiler error on generated code is otherwise hard to diagnose. Prints nothing if an NFL-level error is raised first — the error is reported the normal way instead. Not valid with `macroexpand` or `repl`. |
| `--out <path>` | `shim` | Write the generated module to `<path>` instead of the default `<input>.nim`. |
| `--force` | `shim` | Overwrite the output path even if it's not a file `nfl shim` generated. |
| `-h`, `--help` | (as first arg) | Print usage and exit 0. |
| `-- <nim-args...>` | `run`, `compile`, `check` | Forwards everything after `--` straight to the underlying `nim` invocation (e.g. `--mm:orc`, `-d:release`). See [Passing arguments straight to `nim`](#passing-arguments-straight-to-nim) above. |

## Notes

- The input file path is always required (except for `repl`, where it's an
  optional preload) and must be the only positional argument; an
  unrecognized `--`-prefixed flag is an error (exit 2), not silently
  treated as the input path.
- `run`/`compile`/`check` shell out to `nim` on your `PATH`; if it isn't
  found, `nfl` reports that and exits 1 rather than failing inside a
  half-built temp directory.
- On a `nim` failure, the temporary build directory (containing
  `wrapper.nim`) is preserved and its path printed, to help diagnose the
  underlying Nim error; on success it's removed.
