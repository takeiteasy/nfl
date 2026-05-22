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

  test "allows typed let and var bindings":
    discard lowerExpr(readOne("(let (((x int) 1)) x)", "lower-test.nimp"))
    discard lowerExpr(readOne("(var (((x int) 1)) (set! x 2) x)", "lower-test.nimp"))

  test "rejects set! for let bindings":
    expectLowerError("(let ((x 1)) (set! x 2) x)", "immutable binding")

  test "rejects set! for unknown bindings":
    expectLowerError("(set! x 2)", "not a mutable local")

  test "rejects duplicate bindings":
    expectLowerError("(let ((x 1) (x 2)) x)", "duplicate binding")

  test "rejects malformed typed bindings":
    expectLowerError("(let (((x 1) 2)) x)", "binding name must be a symbol or (name type)")

  test "rejects set! for lambda parameters":
    expectLowerError("(lambda ((x int)) (set! x 2))", "immutable binding")

  test "rejects if with too few arguments":
    expectLowerError("(if true 1)", "if expects 3 arguments, got 2")

  test "rejects set! with too few arguments":
    expectLowerError("(set! x)", "set! expects 2 arguments, got 1")

  test "rejects at with too few arguments":
    expectLowerError("(at xs)", "at expects 2 arguments, got 1")

  test "rejects slice with too few arguments":
    expectLowerError("(slice xs 0)", "slice expects 3 arguments, got 2")

  test "rejects quote with wrong arity":
    expectLowerError("(quote)", "quote expects 1 arguments, got 0")
    expectLowerError("(quote a b)", "quote expects 1 arguments, got 2")

  test "rejects runtime quasiquote":
    expectLowerError("`(a b)", "runtime quasiquote is not implemented yet")
