# Package Layout

How to organize a real NFL project so it builds with the `nfl` CLI, works
with `nimble test`, and (for libraries) is importable from plain Nim.

## Application layout

A single entry point plus helper `.nfl` files it `(import ...)`s inline (see
[Splitting a project across multiple .nfl
files](nim-interop.md#splitting-a-project-across-multiple-nfl-files)):

```
myapp/
  src/
    app.nfl
    helpers.nfl
  myapp.nimble
```

```lisp
; src/app.nfl
(import ./helpers.nfl)
(echo (greet "world"))
```

Build with the `nfl` CLI directly — there's no Nim frontend hook for `.nfl`
files (`config.nims` rejects `nim c app.nfl` and points here instead):

```sh
nfl compile src/app.nfl   # writes src/app next to the source
nfl run src/app.nfl       # compile and run in one step
```

A `myapp.nimble` `task build`/`task test` wrapping the same `nfl` invocation
keeps `nimble build`/`nimble test` working as the entry points:

```nim
task build, "Build the app":
  exec "nfl compile src/app.nfl"
```

## Library layout

A library exposes some of its `.nfl` files to plain Nim consumers. Each
importable module gets a **shim**: a thin, `nfl shim`-generated `.nim` file
that delegates to the `.nfl` source via the `nflModule` macro.

```
mylib/
  src/
    mylib/
      util.nfl
      util.nim        ; generated: nfl shim src/mylib/util.nfl
      helpers.nfl      ; imported by util.nfl, no shim needed
  tests/
    consume.nim
  mylib.nimble
```

A worked example of this exact layout lives in
[`examples/package/`](../examples/package/): `src/mylib/util.nfl` inline
`(import)`s `helpers.nfl` and exports `double`/`quad`;
`tests/consume.nim` is plain Nim that `import mylib/util`s it with no `nfl`
CLI involved at import time.

Only give a shim to files you want Nim consumers to `import` directly —
files pulled in solely via `(import ./x.nfl)` from another `.nfl` file (like
`helpers.nfl` above) don't need one of their own.

### Regenerating shims

`nfl shim` operates on one file at a time; there's no project-wide
discovery yet (tracked as a remaining part of the module-system ticket —
see below). Regenerate after editing the `.nfl` source:

```sh
nfl shim src/mylib/util.nfl
```

`nfl shim` refuses to overwrite a file it didn't generate, so it's safe to
run repeatedly. Commit the generated `.nim` files for v1 — this keeps
`nimble install`/`nimble test` working for consumers without requiring them
to run `nfl shim` themselves as a build step. (An alternative is
regenerating them from a nimble `before build` task if you'd rather not
commit generated files; either is fine, but committing is simpler and is
what `examples/package/` does.)

### `nfl shim` vs `--emit nim`

These solve different problems and are easy to conflate:

- **`nfl shim`** makes an `.nfl` file importable from plain Nim. The
  generated file is a compile-time delegation (`nflModule(staticRead(...))`)
  — it still requires `nfl` as a build dependency and `--path` to the
  package's `src/`. It is not translated Nim source.
- **`--emit nim`** (see [cli.md](cli.md)) is a debug flag on
  `run`/`compile`/`check` that dumps the `.repr` of the `NimNode` NFL
  produces, for diagnosing compiler errors on generated code. It is
  best-effort output, not guaranteed to be valid, re-compilable Nim: probing
  it across `examples/*.nfl` round-trips 13 of 23 files through `nim c`
  unmodified. Failures are structural to the emitter (e.g. a statement
  nested inside a call argument, which Nim's own renderer can't print back
  as source) — real `.nfl` → readable, standalone `.nim` translation is a
  larger emitter-rework project, tracked separately.

### Macros don't cross the shim boundary

A Nim module importing a shim gets the shimmed file's `proc`/`type`/
`template`/`iterator` declarations, not its `defmacro` definitions — macros
are an NFL-expansion-time concept with no Nim-level representation. Sharing
macros across files still requires `(import ./x.nfl)` from another `.nfl`
file (see [Sharing macros across
files](macros.md#sharing-macros-across-files)).

### Nimble packaging

Set `installExt` to include `"nfl"` as well as `"nim"`, or a library's
`.nfl` sources won't be installed and a consumer's `staticRead` in the
generated shim will fail to find them:

```nim
# mylib.nimble
srcDir        = "src"
installExt    = @["nim", "nfl"]

requires "nim >= 2.2.4"
requires "nfl"
```

(`nfl`'s own `nfl.nimble` gets away with `installExt = @["nim"]` only
because its preamble is baked into the CLI binary via `staticRead` at
`nfl`'s own build time — see below — not read from an installed `.nfl`
file at a consumer's build time.)

## Where `std/core.nfl` lives

There is no search path or override for the preamble — it's compiled
directly into the `nfl` binary:

```nim
# src/nfl/stdlib.nim
const coreSource* = staticRead("preamble.nfl")
```

`run`/`compile`/`check`/`macroexpand` all auto-load it before your file
unless `--no-core` is passed. Nothing about package layout affects this.

## User preludes

There's no dedicated prelude hook. The supported pattern is the same
inline-include mechanism used for any shared code: put common definitions
in a `prelude.nfl` and `(import ./prelude.nfl)` it at the top of each entry
file that needs it. A first-class prelude mechanism (auto-loaded like
`std/core.nfl` but project-defined) would be a separate feature request if
the manual import becomes a real pain point.

## Testing package-shaped projects

`tests/test_cli.nim` covers this layout with CLI-level tests: generating a
shim, compiling a Nim consumer against it (exercising an exported `proc`,
an exported `template`/`iterator`, and a transitively-imported helper), the
overwrite guard, and `--force`. `examples/package/` is compiled as part of
that suite so the documented layout stays verified.
