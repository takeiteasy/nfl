import std/macros

import ./diagnostics
import ./lower
import ./nimbackend
import ./reader

macro nimpExpr*(source: static[string]): untyped =
  try:
    result = emitExpr(lowerExpr(readOne(source, "<nimpExpr>")))
  except ReaderError as err:
    error($err.diagnostic)
  except CompilerError as err:
    error($err.diagnostic)

macro nimpModule*(source: static[string]; file: static[string] = "<nimpModule>"): untyped =
  try:
    result = emitModule(lowerModule(readAll(source, file)))
  except ReaderError as err:
    error($err.diagnostic)
  except CompilerError as err:
    error($err.diagnostic)
