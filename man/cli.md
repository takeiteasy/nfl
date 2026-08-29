# CLI Reference

`lfn <command> [flags] file.lfn [-- nim-args...]`

## Commands

### `run`

Compiles `file.lfn` and immediately executes the resulting binary. Under the
hood this generates a temporary `wrapper.nim` that calls the `lfnModule`
macro on `file.lfn` and hands it to `nim c -r`.

```sh
lfn run hello.lfn
```

### `compile`

Compiles `file.lfn` to a binary next to the source file (same name, no
extension — Nim's `ExeExt`, which is empty on Unix). Does not run it.

```sh
lfn compile hello.lfn
./hello
```

### `check`

Type-checks `file.lfn` (and everything it `(import ...)`s) without producing
a binary. Fastest way to validate a file.

```sh
lfn check hello.lfn
```

### Passing arguments straight to `nim`

Anything after a bare `--` on `run`/`compile`/`check` is forwarded verbatim
to the underlying `nim c`/`check` invocation, after `lfn`'s own flags — so
you can reach for any `nim` flag (memory manager, optimization level, panic
mode, etc.) without `lfn` needing to know about it specifically:

```sh
lfn compile hello.lfn -- --mm:orc -d:release
lfn run hello.lfn -- --mm:none        # no GC — see the caveat below
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

Reads and fully macro-expands `file.lfn`, then prints the expanded LFN
s-expressions (one top-level form per line) to stdout. Does not touch the
Nim compiler — this is the reader/expander pipeline running directly in the
`lfn` binary, not inside a `nim c`/`check` subprocess. `defmacro` and
`defmacro-proc` forms are consumed during expansion and never appear in the
output.

```sh
lfn macroexpand hello.lfn
```

`--emit nim` is **not** valid with `macroexpand` — this command already is
the LFN-forms half of "show me what LFN is doing"; `--emit nim` is the
Nim-source half, and only applies to `run`/`compile`/`check` since it needs
an actual `nim` compilation to run inside.

### `shim`

Writes a Nim module that delegates to `file.lfn` via the `lfnModule` macro,
so plain Nim code can `import` it without going through the `lfn` CLI. See
[package-layout.md](package-layout.md) for the package shape this is meant
to fit into, and its limitations (in particular: it's a compile-time
delegation, not translated Nim source, and LFN macros don't cross the
import boundary).

```sh
lfn shim src/mylib/util.lfn        # writes src/mylib/util.nim
```

By default the output path is the input with its extension changed to
`.nim`. `lfn shim` refuses to overwrite a file it didn't generate (detected
by a header comment on the first line), to avoid clobbering hand-written
Nim.

### `repl`

Starts an interactive read/expand/compile/run loop, backed by an actual
`nim c` per accepted input (there is no interpreter). See
[repl.md](repl.md) for the full session model — full-transcript replay,
name-keyed redefinition, `defvar`/`defparameter` semantics, and REPL
commands (`:help`, `:quit`, `:transcript`, `:reset`).

```sh
lfn repl                  # start an empty session
lfn repl mylib.lfn        # preload mylib.lfn as the first transcript entry
```

Unlike every other command, `repl`'s file argument is optional.

## Flags

| Flag | Commands | Effect |
|---|---|---|
| `--no-core` | all | Skip auto-loading the preamble (`std/core.lfn`'s macros — `when`, `unless`, `cond`, threading macros, etc). |
| `--emit nim` | `run`, `compile`, `check` | Echoes the emitted `NimNode`'s `.repr` to stdout, between `# --- lfn: begin/end emitted nim ---` marker lines, once expansion/lowering/emission succeed. **Best-effort debug output** — it is not guaranteed to be valid, re-compilable Nim (see the note in [package-layout.md](package-layout.md#lfn-shim-vs---emit-nim)); use it to see what LFN produced when a `nim` compiler error on generated code is otherwise hard to diagnose. Prints nothing if an LFN-level error is raised first — the error is reported the normal way instead. Not valid with `macroexpand` or `repl`. |
| `--out <path>` | `shim` | Write the generated module to `<path>` instead of the default `<input>.nim`. |
| `--force` | `shim` | Overwrite the output path even if it's not a file `lfn shim` generated. |
| `-h`, `--help` | (as first arg) | Print usage and exit 0. |
| `-- <nim-args...>` | `run`, `compile`, `check` | Forwards everything after `--` straight to the underlying `nim` invocation (e.g. `--mm:orc`, `-d:release`). See [Passing arguments straight to `nim`](#passing-arguments-straight-to-nim) above. |

## Notes

- The input file path is always required (except for `repl`, where it's an
  optional preload) and must be the only positional argument; an
  unrecognized `--`-prefixed flag is an error (exit 2), not silently
  treated as the input path.
- `run`/`compile`/`check` shell out to `nim` on your `PATH`; if it isn't
  found, `lfn` reports that and exits 1 rather than failing inside a
  half-built temp directory.
- On a `nim` failure, the temporary build directory (containing
  `wrapper.nim`) is preserved and its path printed, to help diagnose the
  underlying Nim error; on success it's removed.
