## Embeds the NFL prelude source so it's available at compile time without
## a runtime file read — needed since `compiler.nim` auto-loads it inside
## Nim macros, where the compiler VM's file access is restricted.

const coreSource* = staticRead("preamble.nfl")
  ## The full source of `preamble.nfl`, auto-expanded before user code
  ## unless `expandSource`/`expandModule` is called with `autoloadCore =
  ## false` (e.g. the REPL's `--no-core`).
