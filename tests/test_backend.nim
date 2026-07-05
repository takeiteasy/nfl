import std/unittest

import nfl/compiler

type ImportedPerson = object
  name: string
  age: int

proc importedPersonAge(p: ImportedPerson): int =
  p.age

proc describePerson(name: string; age: int): string =
  name & ":" & $age

suite "nfl backend":
  test "operator call":
    check nflExpr"(+ 1 2)" == 3

  test "if expression":
    check nflExpr"(if true 1 2)" == 1

  test "let expression":
    check nflExpr"(let ((x 1)) (+ x 2))" == 3

  test "typed let expression":
    check nflExpr"(let (((x int) 1)) (+ x 2))" == 3

  test "var and set expression":
    check nflExpr"(var ((x 1)) (set! x (+ x 2)) x)" == 3

  test "typed var and set expression":
    check nflExpr"(var (((x int) 1)) (set! x (+ x 2)) x)" == 3

  test "do expression":
    let inc = nflExpr"(do ((x int)) (+ x 1))"
    check inc(2) == 3

  test "autoloaded core macros":
    check nflExpr"(and true true)" == true
    check nflExpr"(or false true)" == true

  test "autoload can be disabled for expressions":
    check compiles(nflExpr("(+ 1 2)", autoloadCore = false))

  test "field and indexing interop":
    check nflExpr"(let ((xs [10 20 30])) (. xs len))" == 3
    check nflExpr"(let ((xs [10 20 30])) xs.len)" == 3
    check nflExpr"(let ((xs [10 20 30])) (at xs 1))" == 20
    check nflExpr"(let ((xs [10 20 30])) (|[]| xs 1))" == 20

  test "constructs imported Nim objects":
    check nflExpr("""(let ((p (new ImportedPerson (name "Ada") (age 36)))) (importedPersonAge p))""") == 36

  test "passes Nim named arguments to ordinary calls":
    check nflExpr("""(describePerson (: age 36) (: name "Ada"))""") == "Ada:36"

  test "autoloaded sequence helper macros":
    check nflExpr"(let ((xs [10 20 30])) (first xs))" == 10
    check nflExpr"(let ((xs [10 20 30])) (first (rest xs)))" == 20
    check nflExpr"(let ((xs [10 20 30])) (empty? xs))" == false
    check nflExpr"(let ((xs (@ [10 20])) (ys (@ [30 40]))) (at (append xs ys) 2))" == 30

  test "runtime quote returns public datum scalars":
    let nilDatum = nflExpr"'nil"
    check nilDatum.kind == ndNil

    let boolDatum = nflExpr"'false"
    check boolDatum.kind == ndBool
    check boolDatum.boolVal == false

    let intDatum = nflExpr"'42"
    check intDatum.kind == ndInt
    check intDatum.intVal == 42

    let stringDatum = nflExpr("'\"hello\"")
    check stringDatum.kind == ndString
    check stringDatum.strVal == "hello"

    let symbolDatum = nflExpr"'alpha"
    check symbolDatum.kind == ndSymbol
    check symbolDatum.sym == "alpha"

  test "runtime quote preserves nested list and vector structure":
    let datum = nflExpr"'(alpha [1 beta] (gamma nil))"
    check datum.kind == ndList
    check datum.items.len == 3
    check datum.items[0].kind == ndSymbol
    check datum.items[0].sym == "alpha"
    check datum.items[1].kind == ndVector
    check datum.items[1].items[0].kind == ndInt
    check datum.items[1].items[0].intVal == 1
    check datum.items[1].items[1].kind == ndSymbol
    check datum.items[1].items[1].sym == "beta"
    check datum.items[2].kind == ndList
    check datum.items[2].items[0].sym == "gamma"
    check datum.items[2].items[1].kind == ndNil

nflModule """
(import std/strutils)
(defmacro hygienic ()
  (let ((tmp (gensym "tmp")))
    `(let ((,tmp 1) (tmp__gensym1 2))
       (+ ,tmp tmp__gensym1))))
(proc greet ((name string))
  (toUpperAscii name))
(proc shout ((name string)) (: string)
  (name.toUpperAscii))
(when true nil)
(defvar shouted (toUpperAscii "nfl"))
(defvar shoutedAgain (greet "macro"))
(defvar shoutedByMethod (shout "method"))
(defvar hygienicResult (hygienic))
(type Count int)
(type Person
  (object
    (name string)
    (age int)))
(type Mood
  (enum happy sad))
(proc incCount ((x Count)) (: Count)
  (+ x 1))
(proc personAge ((p Person)) (: int)
  (. p age))
(proc personNamedAge ((p Person) (expected int)) (: bool)
  (== (. p age) expected))
(defvar counted (incCount 2))
(defvar defaultPerson (default Person))
(defvar defaultAge (personAge defaultPerson))
(defvar ada (new Person (name "Ada") (age 36)))
(defvar adaName (. ada name))
(defvar adaAge (personAge ada))
(defvar adaHasExpectedAge (personNamedAge ada 36))
(defvar adaHasExpectedNamedAge (personNamedAge (: expected 36) (: p ada)))
(defvar favoriteMood happy)
(+ 1)
(block (+ 1 2) nil)
; Export marker tests — public proc, exported defvar, exported type with mixed fields.
(proc publicGreet* ((name string)) (: string)
  (name.toUpperAscii))
(defvar publicVersion* "2.0")
(type PublicPoint*
  (object
    (x* int)
    (y int)))
(defvar testPoint (new PublicPoint (x 3) (y 4)))
; Const tests — plain, typed, exported.
(const privateConst 7)
(const (typedConst int) 11)
(const publicSize* 3)
(defconstant defconstantAlias 99)
; Pragma tests.
; {.discardable.} lets us call the proc as a statement without `discard`.
(proc makeValue {.discardable.} () (: int)
  42)
; {.pure.} on enum requires fully-qualified access when ambiguous; used here
; to prove the pragma reached the generated nnkTypeDef.
(type Flavor {.pure.}
  (enum vanilla chocolate))
; Pragma composes with the `*` export marker.
(proc doubled* {.inline.} ((x int)) (: int)
  (* x 2))
; Pragma on object field.
(type Tagged
  (object
    (value int)
    (tag {.used.} string)))
; Pragma on defvar.
(defvar pragmaVar {.used.} 77)
; Pragma on const.
(const pragmaConst {.used.} 13)
; Generic declarations.
; Simple generic proc — inference-based call.
(proc identity [T] ((x T)) (: T)
  x)
; Two-parameter generic proc.
(proc pickFst [T U] ((a T) (b U)) (: T)
  a)
; Generic type.
(type Box [T]
  (object
    (value T)))
; Generic proc consuming a generic type — uses [Box T] in parameter position.
(proc unbox [T] ((b [Box T])) (: T)
  (. b value))
; Instantiate the generic type with explicit [Box int].
(defvar intBox (new [Box int] (value 42)))
; Call via inference.
(defvar identResult (identity 99))
; Two-param call via inference.
(defvar firstResult (pickFst 7 "ignored"))
; Unbox round-trip.
(defvar unboxResult (unbox intBox))
; Generic proc with pragma.
(proc inlinedId [T] {.inline.} ((x T)) (: T)
  x)
; Generic type with pragma.
(type BoxPure [T] {.pure.}
  (object
    (val T)))
""", "module-test.nfl"

suite "nfl module backend":
  test "import and defvar":
    check shouted == "NFL"

  test "proc definition":
    check shoutedAgain == "MACRO"

  test "typed proc and dotted method call":
    check shout("nim") == "NIM"
    check shoutedByMethod == "METHOD"

  test "gensym bindings do not collide with matching source names":
    check hygienicResult == 3

  test "type alias definition":
    check counted == 3

  test "object type definition":
    check defaultAge == 0
    check adaName == "Ada"
    check adaAge == 36
    check adaHasExpectedAge == true
    check adaHasExpectedNamedAge == true

  test "enum type definition":
    check favoriteMood == happy

  test "exported proc is callable under its base name":
    check publicGreet("world") == "WORLD"

  test "exported defvar is accessible under its base name":
    check publicVersion == "2.0"

  test "exported type and mixed-export fields work":
    check testPoint.x == 3
    check testPoint.y == 4

  test "private proc has no export postfix (regression)":
    # greet and shout were defined without `*` and must remain private-nameable.
    check greet("nim") == "NIM"
    check shout("nim") == "NIM"

  test "const declaration produces a compile-time constant":
    check privateConst == 7
    # Using publicSize* as an array length proves nnkConstSection was emitted —
    # a var would cause a compile error here.
    var arr: array[publicSize, int]
    check arr.len == 3
    static: doAssert publicSize == 3

  test "typed const declaration":
    check typedConst == 11

  test "exported const is accessible under its base name":
    check publicSize == 3

  test "discardable pragma allows result to be discarded at statement scope":
    makeValue()  # would require `discard` without {.discardable.}

  test "pragma on type compiles and type is usable":
    check Flavor.vanilla != Flavor.chocolate

  test "pragma composes with export marker on proc":
    check doubled(5) == 10

  test "pragma on object field compiles":
    let t = Tagged(value: 3, tag: "hi")
    check t.value == 3

  test "pragma on defvar compiles":
    check pragmaVar == 77

  test "pragma on const compiles":
    check pragmaConst == 13

  test "generic proc — inference-based call":
    check identity(42) == 42
    check identity("hi") == "hi"
    check identResult == 99

  test "two-parameter generic proc":
    check pickFst(7, "x") == 7
    check firstResult == 7

  test "generic type — explicit instantiation":
    check intBox.value == 42

  test "generic proc with generic type in param type":
    check unbox(intBox) == 42
    check unboxResult == 42

  test "generic proc with pragma compiles and works":
    check inlinedId(5) == 5
    check inlinedId("nfl") == "nfl"

  test "generic type with pragma compiles":
    let b = BoxPure[int](val: 3)
    check b.val == 3
