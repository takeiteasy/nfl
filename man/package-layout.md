# Package Layout

How to organize a real LFN project so it builds with the `lfn` CLI, works
with `nimble test`, and (for libraries) is importable from plain Nim.

## Application layout

A single entry point plus helper `.lfn` files it `(import ...)`s inline (see
[Splitting a project across multiple .lfn
files](nim-interop.md#splitting-a-project-across-multiple-lfn-files)):

```
myapp/
  src/
    app.lfn
    helpers.lfn
  myapp.nimble
```

```lisp
; src/app.lfn
(import ./helpers.lfn)
(echo (greet "world"))
```

Build with the `lfn` CLI directly — there's no Nim frontend hook for `.lfn`
files (`config.nims` rejects `nim c app.lfn` and points here instead):

```sh
lfn compile src/app.lfn   # writes src/app next to the source
lfn run src/app.lfn       # compile and run in one step
```

A `myapp.nimble` `task build`/`task test` wrapping the same `lfn` invocation
keeps `nimble build`/`nimble test` working as the entry points:

```nim
task build, "Build the app":
  exec "lfn compile src/app.lfn"
```

## Library layout

A library exposes some of its `.lfn` files to plain Nim consumers. Each
importable module gets a **shim**: a thin, `lfn shim`-generated `.nim` file
that delegates to the `.lfn` source via the `lfnModule` macro.

```
mylib/
  src/
    mylib/
      util.lfn
      util.nim        ; generated: lfn shim src/mylib/util.lfn
      helpers.lfn      ; imported by util.lfn, no shim needed
  tests/
    consume.nim
  mylib.nimble
```

A worked example of this exact layout lives in
[`examples/package/`](../examples/package/): `src/mylib/util.lfn` inline
`(import)`s `helpers.lfn` and exports `double`/`quad`;
`tests/consume.nim` is plain Nim that `import mylib/util`s it with no `lfn`
CLI involved at import time.

Only give a shim to files you want Nim consumers to `import` directly —
files pulled in solely via `(import ./x.lfn)` from another `.lfn` file (like
`helpers.lfn` above) don't need one of their own.

### Regenerating shims

`lfn shim` operates on one file at a time; there's no project-wide
discovery yet (tracked as a remaining part of the module-system ticket —
see below). Regenerate after editing the `.lfn` source:

```sh
lfn shim src/mylib/util.lfn
```

`lfn shim` refuses to overwrite a file it didn't generate, so it's safe to
run repeatedly. Commit the generated `.nim` files for v1 — this keeps
`nimble install`/`nimble test` working for consumers without requiring them
to run `lfn shim` themselves as a build step. (An alternative is
regenerating them from a nimble `before build` task if you'd rather not
commit generated files; either is fine, but committing is simpler and is
what `examples/package/` does.)

### `lfn shim` vs `--emit nim`

These solve different problems and are easy to colfnate:

- **`lfn shim`** makes an `.lfn` file importable from plain Nim. The
  generated file is a compile-time delegation (`lfnModule(staticRead(...))`)
  — it still requires `lfn` as a build dependency and `--path` to the
  package's `src/`. It is not translated Nim source.
- **`--emit nim`** (see [cli.md](cli.md)) is a debug flag on
  `run`/`compile`/`check` that dumps the `.repr` of the `NimNode` LFN
  produces, for diagnosing compiler errors on generated code. It is
  best-effort output, not guaranteed to be valid, re-compilable Nim: probing
  it across `examples/*.lfn` round-trips 13 of 23 files through `nim c`
  unmodified. Failures are structural to the emitter (e.g. a statement
  nested inside a call argument, which Nim's own renderer can't print back
  as source) — real `.lfn` → readable, standalone `.nim` translation is a
  larger emitter-rework project, tracked separately.

### Macros don't cross the shim boundary

A Nim module importing a shim gets the shimmed file's `proc`/`type`/
`template`/`iterator` declarations, not its `defmacro` definitions — macros
are an LFN-expansion-time concept with no Nim-level representation. Sharing
macros across files still requires `(import ./x.lfn)` from another `.lfn`
file (see [Sharing macros across
files](macros.md#sharing-macros-across-files)).

### Nimble packaging

Set `installExt` to include `"lfn"` as well as `"nim"`, or a library's
`.lfn` sources won't be installed and a consumer's `staticRead` in the
generated shim will fail to find them:

```nim
# mylib.nimble
srcDir        = "src"
installExt    = @["nim", "lfn"]

requires "nim >= 2.2.4"
requires "lfn"
```

(`lfn`'s own `lfn.nimble` gets away with `installExt = @["nim"]` only
because its preamble is baked into the CLI binary via `staticRead` at
`lfn`'s own build time — see below — not read from an installed `.lfn`
file at a consumer's build time.)

## Where `std/core.lfn` lives

There is no search path or override for the preamble — it's compiled
directly into the `lfn` binary:

```nim
# src/lfn/stdlib.nim
const coreSource* = staticRead("preamble.lfn")
```

`run`/`compile`/`check`/`macroexpand` all auto-load it before your file
unless `--no-core` is passed. Nothing about package layout affects this.

## User preludes

There's no dedicated prelude hook. The supported pattern is the same
inline-include mechanism used for any shared code: put common definitions
in a `prelude.lfn` and `(import ./prelude.lfn)` it at the top of each entry
file that needs it. A first-class prelude mechanism (auto-loaded like
`std/core.lfn` but project-defined) would be a separate feature request if
the manual import becomes a real pain point.

## Testing package-shaped projects

`tests/test_cli.nim` covers this layout with CLI-level tests: generating a
shim, compiling a Nim consumer against it (exercising an exported `proc`,
an exported `template`/`iterator`, and a transitively-imported helper), the
overwrite guard, and `--force`. `examples/package/` is compiled as part of
that suite so the documented layout stays verified.
