import std/strutils
import std/unittest

import nimp/diagnostics
import nimp/lower
import nimp/reader

proc expectLowerError(source, messagePart: string) =
  try:
    discard lowerExpr(readOne(source, "lower-test.nimp"))
    fail()
  except CompilerError as err:
    check err.diagnostic.span.file == "lower-test.nimp"
    check err.diagnostic.message.contains(messagePart)

suite "lowering validation":
  test "allows set! for var bindings":
    discard lowerExpr(readOne("(var ((x 1)) (set! x 2) x)", "lower-test.nimp"))

  test "rejects set! for let bindings":
    expectLowerError("(let ((x 1)) (set! x 2) x)", "immutable binding")

  test "rejects set! for unknown bindings":
    expectLowerError("(set! x 2)", "not a mutable local")

  test "rejects duplicate bindings":
    expectLowerError("(let ((x 1) (x 2)) x)", "duplicate binding")

  test "rejects set! for lambda parameters":
    expectLowerError("(lambda ((x int)) (set! x 2))", "immutable binding")
