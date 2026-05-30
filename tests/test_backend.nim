import std/unittest

import nimp/compiler

type ImportedPerson = object
  name: string
  age: int

proc importedPersonAge(p: ImportedPerson): int =
  p.age

proc describePerson(name: string; age: int): string =
  name & ":" & $age

suite "nimp backend":
  test "operator call":
    check nimpExpr"(+ 1 2)" == 3

  test "if expression":
    check nimpExpr"(if true 1 2)" == 1

  test "let expression":
    check nimpExpr"(let ((x 1)) (+ x 2))" == 3

  test "typed let expression":
    check nimpExpr"(let (((x int) 1)) (+ x 2))" == 3

  test "var and set expression":
    check nimpExpr"(var ((x 1)) (set! x (+ x 2)) x)" == 3

  test "typed var and set expression":
    check nimpExpr"(var (((x int) 1)) (set! x (+ x 2)) x)" == 3

  test "do expression":
    let inc = nimpExpr"(do ((x int)) (+ x 1))"
    check inc(2) == 3

  test "autoloaded core macros":
    check nimpExpr"(and true true)" == true
    check nimpExpr"(or false true)" == true

  test "autoload can be disabled for expressions":
    check compiles(nimpExpr("(+ 1 2)", autoloadCore = false))

  test "field and indexing interop":
    check nimpExpr"(let ((xs [10 20 30])) (. xs len))" == 3
    check nimpExpr"(let ((xs [10 20 30])) xs.len)" == 3
    check nimpExpr"(let ((xs [10 20 30])) (at xs 1))" == 20
    check nimpExpr"(let ((xs [10 20 30])) (|[]| xs 1))" == 20

  test "constructs imported Nim objects":
    check nimpExpr("""(let ((p (new ImportedPerson (name "Ada") (age 36)))) (importedPersonAge p))""") == 36

  test "passes Nim named arguments to ordinary calls":
    check nimpExpr("""(describePerson (: age 36) (: name "Ada"))""") == "Ada:36"

  test "autoloaded sequence helper macros":
    check nimpExpr"(let ((xs [10 20 30])) (first xs))" == 10
    check nimpExpr"(let ((xs [10 20 30])) (first (rest xs)))" == 20
    check nimpExpr"(let ((xs [10 20 30])) (empty? xs))" == false
    check nimpExpr"(let ((xs (@ [10 20])) (ys (@ [30 40]))) (at (append xs ys) 2))" == 30

  test "runtime quote returns public datum scalars":
    let nilDatum = nimpExpr"'nil"
    check nilDatum.kind == ndNil

    let boolDatum = nimpExpr"'false"
    check boolDatum.kind == ndBool
    check boolDatum.boolVal == false

    let intDatum = nimpExpr"'42"
    check intDatum.kind == ndInt
    check intDatum.intVal == 42

    let stringDatum = nimpExpr("'\"hello\"")
    check stringDatum.kind == ndString
    check stringDatum.strVal == "hello"

    let symbolDatum = nimpExpr"'alpha"
    check symbolDatum.kind == ndSymbol
    check symbolDatum.sym == "alpha"

  test "runtime quote preserves nested list and vector structure":
    let datum = nimpExpr"'(alpha [1 beta] (gamma nil))"
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

nimpModule """
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
(defvar shouted (toUpperAscii "nimp"))
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
""", "module-test.nimp"

suite "nimp module backend":
  test "import and defvar":
    check shouted == "NIMP"

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
