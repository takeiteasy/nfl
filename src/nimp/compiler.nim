import std/macros

import ./diagnostics
import ./expand
import ./lower
import ./macroenv
import ./nimbackend
import ./reader
import ./runtime
import ./stdlib
import ./syntax

export runtime

proc expandSource*(source, file: string; autoloadCore = true): seq[Syntax] =
  let env = newMacroEnv()
  if autoloadCore:
    discard expandModule(readAll(coreSource, "std/core.nimp"), env)
  expandModule(readAll(source, file), env)

macro nimpExpr*(source: static[string]; autoloadCore: static[bool] = true): untyped =
  try:
    let env = newMacroEnv()
    if autoloadCore:
      discard expandModule(readAll(coreSource, "std/core.nimp"), env)
    result = emitExpr(lowerExpr(expandExpr(env, readOne(source, "<nimpExpr>"))))
  except ReaderError as err:
    error($err.diagnostic)
  except CompilerError as err:
    error($err.diagnostic)

macro nimpModule*(source: static[string]; file: static[string] = "<nimpModule>"; autoloadCore: static[bool] = true): untyped =
  try:
    result = emitModule(lowerModule(expandSource(source, file, autoloadCore)))
  except ReaderError as err:
    error($err.diagnostic)
  except CompilerError as err:
    error($err.diagnostic)
