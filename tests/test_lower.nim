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

proc expectLowerModuleError(source, messagePart: string) =
  try:
    discard lowerModule(readAll(source, "lower-test.nimp"))
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

  test "rejects set! for do parameters":
    expectLowerError("(do ((x int)) (set! x 2))", "immutable binding")

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

  test "allows type declarations at statement scope":
    discard lowerModule(readAll("(type Count int)\n(type Person (object (name string)))\n(type Mood (enum happy sad))\n", "lower-test.nimp"))

  test "rejects type declarations in expression position":
    expectLowerError("(let ((x (type Count int))) x)", "type is only allowed at statement/module scope")

  test "rejects malformed type declarations":
    expectLowerModuleError("(type)", "type expects 2 arguments, got 0")
    expectLowerModuleError("(type 1 int)", "type name must be a symbol")
    expectLowerModuleError("(type Count 1)", "type body must be an alias target or type form")
    expectLowerModuleError("(type Count int*)", "type references cannot use export markers")
    expectLowerModuleError("(type Count int)\n(type Count* int)", "duplicate binding: Count")

  test "rejects malformed object type declarations":
    expectLowerModuleError("(type Person (object))", "object type expects fields")
    expectLowerModuleError("(type Person (object name))", "object field must be (name Type)")
    expectLowerModuleError("(type Person (object (name)))", "object field must be (name Type)")
    expectLowerModuleError("(type Person (object (1 string)))", "object field name must be a symbol")
    expectLowerModuleError("(type Person (object (name 1)))", "object field type must be a type symbol")
    expectLowerModuleError("(type Person (object (name string) (name int)))", "duplicate object field: name")

  test "rejects malformed enum type declarations":
    expectLowerModuleError("(type Mood (enum))", "enum type expects values")
    expectLowerModuleError("(type Mood (enum 1))", "enum value must be a symbol")
    expectLowerModuleError("(type Mood (enum happy happy))", "duplicate enum value: happy")
    expectLowerModuleError("(type Mood (enum happy*))", "enum values cannot use export markers")

  test "rejects reserved type forms until implemented":
    expectLowerModuleError("(type Pair (tuple (left int)))", "tuple type declarations are not implemented yet")
    expectLowerModuleError("(type UserId (distinct int))", "distinct type declarations are not implemented yet")
    expectLowerModuleError("(type PersonRef (ref object (name string)))", "ref object type declarations are not implemented yet")
