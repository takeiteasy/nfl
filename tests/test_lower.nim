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

  test "allows distinct type declaration":
    discard lowerModule(readAll("(type UserId (distinct int))", "lower-test.nfl"))

  test "rejects distinct with wrong arity":
    expectLowerModuleError("(type UserId (distinct))", "distinct expects a base type")
    expectLowerModuleError("(type UserId (distinct int string))", "distinct expects a base type")

  test "allows tuple type declaration":
    discard lowerModule(readAll("(type Point (tuple (x float) (y float)))", "lower-test.nfl"))

  test "rejects tuple with no fields":
    expectLowerModuleError("(type Empty (tuple))", "tuple type expects at least one field")

  test "rejects tuple with malformed field":
    expectLowerModuleError("(type Bad (tuple x))", "tuple field must be (name type)")
    expectLowerModuleError("(type Bad (tuple (123 int)))", "tuple field name must be a symbol")

  test "rejects duplicate tuple fields":
    expectLowerModuleError("(type Bad (tuple (x int) (x int)))", "duplicate tuple field: x")

  test "allows ref type declaration (ref symbol)":
    discard lowerModule(readAll("(type NodeRef (ref Node))", "lower-test.nfl"))

  test "allows ref type declaration (ref object)":
    discard lowerModule(readAll("(type PersonRef (ref (object (name string))))", "lower-test.nfl"))

  test "rejects ref with wrong arity":
    expectLowerModuleError("(type Bad (ref))", "ref expects a base type")
    expectLowerModuleError("(type Bad (ref int string))", "ref expects a base type")

  test "rejects ref with invalid inner form":
    expectLowerModuleError("(type Bad (ref (enum a b)))", "ref base must be a type symbol")

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

  test "allows pragma on proc":
    discard lowerModule(readAll("(proc add {.inline.} ((x int) (y int)) (+ x y))", "lower-test.nfl"))

  test "allows pragma on proc with return type":
    discard lowerModule(readAll("(proc add {.inline.} ((x int) (y int)) (: int) (+ x y))", "lower-test.nfl"))

  test "allows multi-marker pragma on proc":
    discard lowerModule(readAll("(proc add {.inline, noSideEffect.} ((x int)) x)", "lower-test.nfl"))

  test "allows pragma on exported proc":
    discard lowerModule(readAll("(proc add* {.inline.} ((x int)) x)", "lower-test.nfl"))

  test "allows pragma on type declaration":
    discard lowerModule(readAll("(type Person {.bycopy.} (object (name string)))", "lower-test.nfl"))

  test "allows pragma on object field":
    discard lowerModule(readAll("(type Person (object (name {.exportc.} string)))", "lower-test.nfl"))

  test "allows pragma on defvar":
    discard lowerModule(readAll("(defvar x {.volatile.} 1)", "lower-test.nfl"))

  test "allows pragma on defparameter":
    discard lowerModule(readAll("(defparameter y {.used.} 2)", "lower-test.nfl"))

  test "allows pragma on const":
    discard lowerModule(readAll("(const x {.used.} 1)", "lower-test.nfl"))

  test "allows pragma on typed const":
    discard lowerModule(readAll("(const (x int) {.used.} 1)", "lower-test.nfl"))

  test "rejects pragma in expression position":
    expectLowerError("{.inline.}", "pragma is only allowed as a declaration annotation")

  test "rejects non-symbol pragma entry (via literal list form)":
    # Write (pragma 1) directly — `1` is sxInt, not sxSymbol.
    expectLowerModuleError("(proc add (pragma 1) ((x int)) x)", "pragma entry must be a marker symbol")

  test "rejects export marker in pragma entry":
    # Write (pragma foo*) directly — foo* contains `*`.
    expectLowerModuleError("(proc add (pragma foo*) ((x int)) x)", "pragma entry must be a marker symbol")

  test "allows value pragma on proc":
    discard lowerModule(readAll("(proc cFoo {.importc: \"foo\", cdecl.} () (: int) 0)", "lower-test.nfl"))

  test "allows value pragma on defvar":
    discard lowerModule(readAll("(defvar x {.importc: \"gFoo\".} int)", "lower-test.nfl"))

  test "rejects export marker in value pragma key":
    expectLowerModuleError("(proc add (pragma (: foo* 1)) ((x int)) x)", "pragma key must be a non-empty symbol")

  test "allows pragma on local let binding (untyped)":
    discard lowerExpr(readOne("(let ((x {.volatile.} 1)) x)", "lower-test.nfl"))

  test "allows pragma on local let binding (typed)":
    discard lowerExpr(readOne("(let (((x int) {.volatile.} 5)) x)", "lower-test.nfl"))

  test "allows pragma on local var binding":
    discard lowerExpr(readOne("(var ((x {.volatile.} 1)) x)", "lower-test.nfl"))

  test "rejects non-pragma clause between binding target and value":
    expectLowerError("(let ((x 42 1)) x)", "expected pragma clause between binding target and value")

  test "allows generic proc declaration":
    discard lowerModule(readAll("(proc identity [T] ((x T)) (: T) x)", "lower-test.nfl"))
    discard lowerModule(readAll("(proc pair [T U] ((a T) (b U)) (: T) a)", "lower-test.nfl"))

  test "allows generic type declaration":
    discard lowerModule(readAll("(type Box [T] (object (value T)))", "lower-test.nfl"))
    discard lowerModule(readAll("(type Pair [T U] (object (fst T) (snd U)))", "lower-test.nfl"))

  test "allows generic proc with pragma":
    discard lowerModule(readAll("(proc identity [T] {.inline.} ((x T)) (: T) x)", "lower-test.nfl"))

  test "allows generic type with pragma":
    discard lowerModule(readAll("(type Box [T] {.bycopy.} (object (value T)))", "lower-test.nfl"))

  test "allows generic type reference in param type":
    discard lowerModule(readAll("(proc unbox [T] ((b [Box T])) (: T) b)", "lower-test.nfl"))

  test "allows generic type reference in new":
    discard lowerModule(readAll("""
(type Box [T] (object (value T)))
(defvar b (new [Box int] (value 5)))
""", "lower-test.nfl"))

  test "rejects empty generic parameter list":
    expectLowerModuleError("(proc f [] (()) ())", "generic parameter list must not be empty")
    expectLowerModuleError("(type Box [] (object (value int)))", "generic parameter list must not be empty")

  test "rejects non-symbol generic parameter":
    expectLowerModuleError("(proc f [1] ((x int)) x)", "generic parameter must be a symbol")

  test "rejects exported generic parameter":
    expectLowerModuleError("(proc f [T*] ((x int)) x)", "generic parameter cannot use export markers")

  test "rejects duplicate generic parameters":
    expectLowerModuleError("(proc f [T T] ((x T)) x)", "duplicate generic parameter: T")

  # ---------------------------------------------------------------------------
  # for
  # ---------------------------------------------------------------------------

  test "allows for loop with single binding":
    discard lowerExpr(readOne("(for (x xs) (echo x))", "lower-test.nfl"))

  test "allows for loop with multiple binding vars":
    discard lowerExpr(readOne("(for ((i x) xs) (echo i))", "lower-test.nfl"))

  test "rejects for with non-pair clause":
    expectLowerError("(for xs (echo x))", "for clause must be a")

  test "rejects for clause with wrong item count":
    expectLowerError("(for (x) (echo x))", "for clause must be a")

  test "rejects for with empty binding list":
    expectLowerError("(for (() xs) (echo x))", "for binding list must not be empty")

  test "rejects for with non-symbol binding":
    expectLowerError("(for (1 xs) (echo x))", "for loop variable must be a symbol")

  test "rejects for with non-symbol in multi-binding":
    expectLowerError("(for ((i 1) xs) (echo x))", "for loop variable must be a symbol")

  test "rejects for with missing body":
    expectLowerError("(for (x xs))", "for expects a binding clause and body")

  test "rejects set! on for loop variable":
    expectLowerError("(for (x xs) (set! x 1))", "immutable binding")

  # ---------------------------------------------------------------------------
  # case
  # ---------------------------------------------------------------------------

  test "allows case with of and else branches":
    discard lowerExpr(readOne("(case n (of 0 \"zero\") (else \"other\"))", "lower-test.nfl"))

  test "allows case without else":
    discard lowerExpr(readOne("(case n (of 0 \"zero\") (of 1 \"one\"))", "lower-test.nfl"))

  test "rejects case with no branches":
    expectLowerError("(case n)", "case expects a value and at least one branch")

  test "rejects case with unknown branch head":
    expectLowerError("(case n (when true \"yes\"))", "case branch must be headed by of or else")

  test "rejects case with non-list branch":
    expectLowerError("(case n 42)", "case branch must be a list")

  test "rejects case else not last":
    expectLowerError("(case n (else \"other\") (of 0 \"zero\"))", "case else branch must be last")

  test "rejects case of with missing body":
    expectLowerError("(case n (of 0))", "case of branch expects a value and body")

  test "rejects case else with missing body":
    expectLowerError("(case n (else))", "case else branch expects a body")

  # ---------------------------------------------------------------------------
  # raise
  # ---------------------------------------------------------------------------

  test "allows raise with argument":
    discard lowerExpr(readOne("(raise e)", "lower-test.nfl"))

  test "allows bare raise":
    discard lowerExpr(readOne("(raise)", "lower-test.nfl"))

  test "rejects raise with too many arguments":
    expectLowerError("(raise e1 e2)", "raise expects 0 or 1 arguments, got 2")

  # ---------------------------------------------------------------------------
  # try
  # ---------------------------------------------------------------------------

  test "allows try with typed except":
    discard lowerExpr(readOne("(try (riskyCall) (except ValueError (echo \"bad\")))", "lower-test.nfl"))

  test "allows try with named except binding":
    discard lowerExpr(readOne("(try (riskyCall) (except (e ValueError) (echo (. e msg))))", "lower-test.nfl"))

  test "allows try with bare except catch-all":
    discard lowerExpr(readOne("(try (riskyCall) (except (echo \"oops\")))", "lower-test.nfl"))

  test "allows try with finally only":
    discard lowerExpr(readOne("(try (riskyCall) (finally (cleanup)))", "lower-test.nfl"))

  test "allows try with except and finally":
    discard lowerExpr(readOne("(try (riskyCall) (except ValueError (echo \"bad\")) (finally (cleanup)))", "lower-test.nfl"))

  test "allows try with multiple except branches":
    discard lowerExpr(readOne("(try (riskyCall) (except ValueError (echo \"v\")) (except IOError (echo \"io\")))", "lower-test.nfl"))

  test "rejects try with empty body":
    expectLowerError("(try (except ValueError (echo \"bad\")))", "try body must not be empty")

  test "rejects try with bare except not last":
    expectLowerError("(try (riskyCall) (except (echo \"bare\")) (except ValueError (echo \"typed\")))", "bare except must be the last")

  test "rejects try with empty except branch":
    expectLowerError("(try (riskyCall) (except))", "except branch expects a type or body")

  test "rejects try with typed except missing body":
    expectLowerError("(try (riskyCall) (except ValueError))", "except branch expects a body after the type")

  test "rejects try with named except missing body":
    expectLowerError("(try (riskyCall) (except (e ValueError)))", "except branch expects a body after the binding")

  test "rejects try with empty finally":
    expectLowerError("(try (riskyCall) (finally))", "finally expects a body")

  test "rejects set! on named except binding":
    expectLowerError("(try (riskyCall) (except (e ValueError) (set! e nil)))", "immutable binding")

  # ---------------------------------------------------------------------------
  # template
  # ---------------------------------------------------------------------------

  test "allows basic template":
    discard lowerModule(readAll("(template double ((x int)) (* x 2))", "lower-test.nfl"))

  test "allows template with bare-symbol (untyped) param":
    discard lowerModule(readAll("(template withLog (body) body)", "lower-test.nfl"))

  test "allows exported template":
    discard lowerModule(readAll("(template double* ((x int)) (* x 2))", "lower-test.nfl"))

  test "allows template with pragma":
    discard lowerModule(readAll("(template double {.deprecated.} ((x int)) (* x 2))", "lower-test.nfl"))

  test "allows generic template":
    discard lowerModule(readAll("(template echo2 [T] ((x T)) (block (echo x) (echo x)))", "lower-test.nfl"))

  test "allows template with return type":
    discard lowerModule(readAll("(template double ((x int)) (: int) (* x 2))", "lower-test.nfl"))

  test "rejects template with too few arguments":
    expectLowerModuleError("(template tooShort ())", "template expects name, parameters, and body")

  test "rejects template with non-symbol name":
    expectLowerModuleError("(template 42 () body)", "template name must be a symbol")

  test "rejects template with non-list params":
    expectLowerModuleError("(template t x body)", "template parameters must be a list")

  test "rejects template in expression position":
    expectLowerError("(template t () 1)", "template is only allowed at statement/module scope")

  test "rejects export marker in template name mid-position":
    expectLowerModuleError("(template te*mpl ((x int)) x)", "export marker is only allowed at the end of a name")

  # ---------------------------------------------------------------------------
  # iterator
  # ---------------------------------------------------------------------------

  test "allows basic iterator":
    discard lowerModule(readAll("(iterator upTo ((n int)) (: int) (yield n))", "lower-test.nfl"))

  test "allows exported iterator":
    discard lowerModule(readAll("(iterator upTo* ((n int)) (: int) (yield n))", "lower-test.nfl"))

  test "allows iterator with pragma":
    discard lowerModule(readAll("(iterator upTo {.inline.} ((n int)) (: int) (yield n))", "lower-test.nfl"))

  test "rejects iterator missing return type":
    expectLowerModuleError("(iterator upTo ((n int)) (yield n))", "iterator requires an explicit return type")

  test "rejects iterator with too few arguments":
    expectLowerModuleError("(iterator tooShort ())", "iterator expects name, parameters, and body")

  test "rejects iterator with non-symbol name":
    expectLowerModuleError("(iterator 42 () (yield 1))", "iterator name must be a symbol")

  test "rejects iterator with non-list params":
    # `params` is a symbol, not a list; the params slot must be a list `(...)`.
    expectLowerModuleError("(iterator it params (: int) body)", "iterator parameters must be a list")

  test "rejects iterator in expression position":
    expectLowerError("(iterator it () (: int) (yield 1))", "iterator is only allowed at statement/module scope")

  test "rejects export marker in iterator name mid-position":
    expectLowerModuleError("(iterator up*To ((n int)) (: int) (yield n))", "export marker is only allowed at the end of a name")

  # ---------------------------------------------------------------------------
  # yield
  # ---------------------------------------------------------------------------

  test "allows yield with expression":
    discard lowerExpr(readOne("(yield 42)", "lower-test.nfl"))

  test "rejects yield with no arguments":
    expectLowerError("(yield)", "yield expects exactly one expression")

  test "rejects yield with too many arguments":
    expectLowerError("(yield 1 2)", "yield expects exactly one expression")

  # ---------------------------------------------------------------------------
  # while / break / continue  (#24)
  # ---------------------------------------------------------------------------

  test "allows while loop":
    discard lowerExpr(readOne("(while true (echo \"tick\"))", "lower-test.nfl"))

  test "rejects while with missing body":
    expectLowerError("(while true)", "while expects a condition and body")

  test "rejects while with no arguments":
    expectLowerError("(while)", "while expects a condition and body")

  test "allows break in statement position":
    discard lowerModule(readAll("(while true (break))", "lower-test.nfl"))

  test "rejects break with arguments":
    expectLowerModuleError("(while true (break 1))", "break expects no arguments")

  test "allows continue in statement position":
    discard lowerModule(readAll("(while true (continue))", "lower-test.nfl"))

  test "rejects continue with arguments":
    expectLowerModuleError("(while true (continue 1))", "continue expects no arguments")

  # ---------------------------------------------------------------------------
  # return  (#25)
  # ---------------------------------------------------------------------------

  test "allows return with value":
    discard lowerModule(readAll("(proc f () (: int) (return 42))", "lower-test.nfl"))

  test "allows bare return":
    discard lowerModule(readAll("(proc f () (return))", "lower-test.nfl"))

  test "allows return inside a proc body":
    discard lowerModule(readAll("(proc f () (: int) (if true (return 1) 2))", "lower-test.nfl"))

  test "rejects return with too many arguments":
    expectLowerError("(return 1 2)", "return expects 0 or 1 arguments, got 2")

  # ---------------------------------------------------------------------------
  # discard  (#27)
  # ---------------------------------------------------------------------------

  test "allows discard with expression":
    discard lowerModule(readAll("(discard (someCall))", "lower-test.nfl"))

  test "allows bare discard":
    discard lowerModule(readAll("(discard)", "lower-test.nfl"))

  test "rejects discard with too many arguments":
    expectLowerModuleError("(discard x y)", "discard expects 0 or 1 arguments, got 2")

  # ---------------------------------------------------------------------------
  # method  (#30)
  # ---------------------------------------------------------------------------

  test "allows method definition":
    discard lowerModule(readAll("(method greet ((self string)) (: string) self)", "lower-test.nfl"))

  test "rejects method in expression position":
    expectLowerError("(method m () m)", "method is only allowed at statement/module scope")

  # ---------------------------------------------------------------------------
  # object inheritance  (#33)
  # ---------------------------------------------------------------------------

  test "allows object with inheritance clause":
    discard lowerModule(readAll("(type Animal (ref (object (of RootObj) (name string))))", "lower-test.nfl"))

  test "allows inheritance-only object (no extra fields)":
    discard lowerModule(readAll("(type Base (object (of RootObj)))", "lower-test.nfl"))

  test "rejects malformed inheritance clause (missing base)":
    expectLowerModuleError("(type Bad (object (of) (x int)))", "object inheritance clause must be (of Base)")

  test "rejects object with only the head and no fields or inheritance":
    expectLowerModuleError("(type Bad (object))", "object type expects")
