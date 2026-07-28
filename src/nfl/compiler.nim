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

proc expandSource*(source, file: string; autoloadCore = true): seq[Syntax] =
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
  expandModule(readAll(source, file), env, parentDir(file), file)

macro nflExpr*(source: static[string]; autoloadCore: static[bool] = true): untyped =
  try:
    let env = newMacroEnv()
    if autoloadCore:
      discard expandModule(readAll(coreSource, "std/core.nfl"), env)
    result = emitExpr(lowerExpr(expandExpr(env, readOne(source, "<nflExpr>"))))
  except ReaderError as err:
    error($err.diagnostic)
  except CompilerError as err:
    error($err.diagnostic)

macro nflModule*(source: static[string]; file: static[string] = "<nflModule>"; autoloadCore: static[bool] = true): untyped =
  try:
    result = emitModule(lowerModule(expandSource(source, file, autoloadCore)))
  except ReaderError as err:
    error($err.diagnostic)
  except CompilerError as err:
    error($err.diagnostic)
