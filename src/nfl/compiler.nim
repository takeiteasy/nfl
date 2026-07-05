import std/macros

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
  expandModule(readAll(source, file), env)

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
