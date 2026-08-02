## The compiler orchestration layer: ties the reader, macro expander, and
## lowering/backend passes together, and exposes the two Nim macros
## (`nflExpr`, `nflModule`) that the `nfl` CLI's generated wrapper calls to
## turn `.nfl` source into Nim AST at compile time.

import std/macros
import std/os

import ./diagnostics
import ./expand
import ./lower
import ./macros
import ./backend
import ./reader
import ./runtime
import ./stdlib
import ./syntax

export runtime

proc expandSource*(source, file: string; autoloadCore = true; importDir = ""): seq[Syntax] =
  ## Reads `source` (labelled `file` for diagnostics) and fully macro-expands
  ## it, optionally auto-loading `std/core.nfl` first. Returns the expanded
  ## top-level forms; does not lower or emit Nim code.
  let env = newMacroEnv()
  if autoloadCore:
    discard expandModule(readAll(coreSource, "std/core.nfl"), env)
  # `file` is used as-is (never resolved via `getCurrentDir()`) since this
  # also runs inside the `nflModule` macro at Nim compile time during `nfl
  # run`/`compile`/`check`, where the compiler's VM refuses `getCurrentDir`
  # (compile-time FFI). The CLI already passes an absolute path, so relative
  # `.nfl` imports resolve correctly there; callers that hand in a synthetic,
  # non-file-backed label (as tests do) simply can't relatively import
  # anything from it, which is fine since no such file exists to import from.
  #
  # `importDir`, when non-empty, overrides `parentDir(file)` as the root a
  # relative `(import ./x.nfl)` resolves against — used by `nfl repl`
  # (repl.nim), whose `file` is a synthetic on-disk path inside a session
  # temp dir (needed so Nim diagnostics can attach real line info to it),
  # not the directory the user actually launched `nfl repl` from.
  let root = if importDir.len > 0: importDir else: parentDir(file)
  expandModule(readAll(source, file), env, root, file)

macro nflExpr*(source: static[string]; autoloadCore: static[bool] = true): untyped =
  ## Expands, lowers, and emits a single NFL expression as a Nim expression,
  ## for embedding NFL snippets directly in Nim code.
  try:
    let env = newMacroEnv()
    if autoloadCore:
      discard expandModule(readAll(coreSource, "std/core.nfl"), env)
    result = emitExpr(lowerExpr(expandExpr(env, readOne(source, "<nflExpr>"))))
  except ReaderError as err:
    error($err.diagnostic)
  except CompilerError as err:
    error($err.diagnostic)

macro nflModule*(source: static[string]; file: static[string] = "<nflModule>"; autoloadCore: static[bool] = true; emitNim: static[bool] = false; importDir: static[string] = ""): untyped =
  ## Expands, lowers, and emits an entire NFL source file as top-level Nim
  ## declarations. This is what the `nfl` CLI's generated wrapper calls to
  ## compile a `.nfl` file via `nim c`/`check`. When `emitNim` is set, the
  ## resulting `NimNode`'s `.repr` is echoed (between marker lines) once
  ## emission succeeds -- this is what `nfl`'s `--emit nim` flag turns on;
  ## it is a best-effort debug dump, not guaranteed to be re-compilable Nim.
  ## `importDir` overrides where a relative `(import ./x.nfl)` resolves from
  ## — see `expandSource`'s own doc comment; every caller but `nfl repl`
  ## leaves it empty and gets the existing `parentDir(file)` behavior.
  try:
    result = emitModule(lowerModule(expandSource(source, file, autoloadCore, importDir)))
    if emitNim:
      echo "# --- nfl: begin emitted nim (" & file & ") ---"
      echo result.repr
      echo "# --- nfl: end emitted nim ---"
  except ReaderError as err:
    error($err.diagnostic)
  except CompilerError as err:
    error($err.diagnostic)
