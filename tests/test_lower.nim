import std/strutils
import std/unittest

import nfl/diagnostics
import nfl/lower
import nfl/reader

proc expectLowerError(source, messagePart: string) =
  try:
    discard lowerExpr(readOne(source, "lower-test.nfl"))
    fail()
  except CompilerError as err:
    check err.diagnostic.span.file == "lower-test.nfl"
    check err.diagnostic.message.contains(messagePart)

proc expectLowerModuleError(source, messagePart: string) =
  try:
    discard lowerModule(readAll(source, "lower-test.nfl"))
    fail()
  except CompilerError as err:
    check err.diagnostic.span.file == "lower-test.nfl"
    check err.diagnostic.message.contains(messagePart)

suite "lowering validation":
  test "allows set! for var bindings":
    discard lowerExpr(readOne("(var ((x 1)) (set! x 2) x)", "lower-test.nfl"))

  test "allows typed let and var bindings":
    discard lowerExpr(readOne("(let (((x int) 1)) x)", "lower-test.nfl"))
    discard lowerExpr(readOne("(var (((x int) 1)) (set! x 2) x)", "lower-test.nfl"))

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

  test "allows object construction":
    discard lowerExpr(readOne("(new Person (name \"Ada\") (age 36))", "lower-test.nfl"))

  test "rejects malformed object construction":
    expectLowerError("(new)", "new expects a type and field initializers")
    expectLowerError("(new 1 (name \"Ada\"))", "new type must be a type symbol")
    expectLowerError("(new Person name)", "new field initializer must be (name value)")
    expectLowerError("(new Person (name))", "new field initializer must be (name value)")
    expectLowerError("(new Person (1 \"Ada\"))", "new field name must be a symbol")
    expectLowerError("(new Person (name* \"Ada\"))", "new field name cannot use export markers")
    expectLowerError("(new Person (.name \"Ada\"))", "invalid new field name")
    expectLowerError("(new Person (name \"Ada\") (name \"Grace\"))", "duplicate new field: name")

  test "new duplicate field diagnostics use field source location":
    try:
      discard lowerExpr(readOne("""
(new Person
  (name "Ada")
  (name "Grace"))
""", "lower-test.nfl"))
      fail()
    except CompilerError as err:
      check err.diagnostic.span.file == "lower-test.nfl"
      check err.diagnostic.span.line == 3
      check err.diagnostic.message.contains("duplicate new field: name")

  test "allows named arguments in ordinary calls":
    discard lowerExpr(readOne("(makePerson (: name \"Ada\") (: age 36))", "lower-test.nfl"))

  test "rejects malformed named arguments":
    expectLowerError("(: name \"Ada\")", "named argument marker is only allowed in call argument position")
    expectLowerError("(makePerson (: name))", "named argument must be (: name value)")
    expectLowerError("(makePerson (: 1 \"Ada\"))", "named argument name must be a symbol")
    expectLowerError("(makePerson (: name* \"Ada\"))", "named argument name cannot use export markers")
    expectLowerError("(makePerson (: .name \"Ada\"))", "invalid named argument name")
    expectLowerError("(makePerson (: name \"Ada\") (: name \"Grace\"))", "duplicate named argument: name")

  test "named argument duplicate diagnostics use argument source location":
    try:
      discard lowerExpr(readOne("""
(makePerson
  (: name "Ada")
  (: name "Grace"))
""", "lower-test.nfl"))
      fail()
    except CompilerError as err:
      check err.diagnostic.span.file == "lower-test.nfl"
      check err.diagnostic.span.line == 3
      check err.diagnostic.message.contains("duplicate named argument: name")

  test "rejects quote with wrong arity":
    expectLowerError("(quote)", "quote expects 1 arguments, got 0")
    expectLowerError("(quote a b)", "quote expects 1 arguments, got 2")

  test "rejects runtime quasiquote":
    expectLowerError("`(a b)", "runtime quasiquote is not implemented yet")

  test "allows type declarations at statement scope":
    discard lowerModule(readAll("(type Count int)\n(type Person (object (name string)))\n(type Mood (enum happy sad))\n", "lower-test.nfl"))

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

  test "allows exported proc":
    discard lowerModule(readAll("(proc greet* ((name string)) (: string) name)", "lower-test.nfl"))

  test "allows exported defvar":
    discard lowerModule(readAll("(defvar version* \"1.0\")", "lower-test.nfl"))
    discard lowerModule(readAll("(defparameter limit* 100)", "lower-test.nfl"))

  test "exported defvar binding resolves under base name":
    # The binding is registered as `x`, not `x*`, so references without `*` work.
    discard lowerModule(readAll("(defvar x* 1)\n(defvar y (+ x* 0))", "lower-test.nfl"))

  test "allows exported type and object fields":
    discard lowerModule(readAll("(type Person* (object (name* string) (age int)))", "lower-test.nfl"))

  test "rejects export marker in proc name mid-position":
    expectLowerModuleError("(proc gre*et ((name string)) name)", "export marker is only allowed at the end of a name")

  test "rejects bare export marker as proc name":
    expectLowerModuleError("(proc * ((name string)) name)", "exported name must have a base name")

  test "rejects export marker in defvar name mid-position":
    expectLowerModuleError("(defvar x*y 1)", "export marker is only allowed at the end of a name")

  test "rejects bare export marker as defvar name":
    expectLowerModuleError("(defvar * 1)", "exported name must have a base name")

  test "allows const declaration":
    discard lowerModule(readAll("(const answer 42)", "lower-test.nfl"))
    discard lowerModule(readAll("(const greeting \"hello\")", "lower-test.nfl"))

  test "allows typed const declaration":
    discard lowerModule(readAll("(const (limit int) 100)", "lower-test.nfl"))

  test "allows exported const":
    discard lowerModule(readAll("(const maxCoord* 1000)", "lower-test.nfl"))
    discard lowerModule(readAll("(const (scale* int) 2)", "lower-test.nfl"))

  test "allows defconstant alias":
    discard lowerModule(readAll("(defconstant answer 42)", "lower-test.nfl"))

  test "exported const binding resolves under base name":
    discard lowerModule(readAll("(const x* 1)\n(const y (+ x* 0))", "lower-test.nfl"))

  test "rejects const with wrong arity":
    expectLowerModuleError("(const x)", "expects 2")

  test "rejects const with non-symbol name":
    expectLowerModuleError("(const 1 42)", "const name must be a symbol or (name type)")

  test "rejects export marker in const name mid-position":
    expectLowerModuleError("(const a*b 1)", "export marker is only allowed at the end of a name")

  test "rejects bare export marker as const name":
    expectLowerModuleError("(const * 1)", "exported name must have a base name")

  test "rejects set! on const binding":
    expectLowerModuleError("(const c 1)\n(defvar d (block (set! c 2) c))", "immutable binding")

  test "rejects const in expression scope":
    expectLowerError("(let ((x (const a 1))) x)", "const is only allowed at statement/module scope")
