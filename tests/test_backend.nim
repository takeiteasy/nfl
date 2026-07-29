import std/unittest

import nfl/compiler

type ImportedPerson = object
  name: string
  age: int

type MatchColour = enum
  mcRed, mcGreen, mcBlue

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

  test "list/tuple destructuring binding (#12)":
    check nflExpr"(let (([a b] (@ [1 2]))) (+ a b))" == 3
    check nflExpr"(let (([a b] [1 2])) (+ a b))" == 3

  test "rest-capture destructuring":
    check nflExpr"(let (([head & rest] (@ [1 2 3]))) head)" == 1
    check nflExpr"(let (([head & rest] (@ [1 2 3]))) (. rest len))" == 2

  test "nested destructuring":
    check nflExpr"(let (([[a b] [c d]] [[1 2] [3 4]])) (+ (+ a b) (+ c d)))" == 10

  test "destructuring skips _ placeholders":
    check nflExpr"(let (([_ b] [1 2])) b)" == 2

  test "mutable destructuring binding":
    check nflExpr"(var (([a b] [1 2])) (set! a (+ a 10)) (+ a b))" == 13

  test "var and set expression":
    check nflExpr"(var ((x 1)) (set! x (+ x 2)) x)" == 3

  test "typed var and set expression":
    check nflExpr"(var (((x int) 1)) (set! x (+ x 2)) x)" == 3

  test "do expression":
    let inc = nflExpr"(do ((x int)) (+ x 1))"
    check inc(2) == 3

  test "do expression with explicit return type (#40)":
    let doubler = nflExpr"(do ((x int)) (: int) (* x 2))"
    check doubler(21) == 42

  test "do expression with implicit result (#40)":
    let five = nflExpr"(do () (: int) (set! result 5))"
    check five() == 5

  test "do expression accumulating into result then returning explicitly (#40)":
    let sumTo = nflExpr"""(do ((n int)) (: int)
      (set! result 0)
      (set! result (+ result n))
      (return result))"""
    check sumTo(5) == 5

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

suite "nfl backend — for / case / raise / try":
  test "for loop sums elements":
    check nflExpr"(var ((acc 0)) (for (x [1 2 3]) (set! acc (+ acc x))) acc)" == 6

  test "for loop over range":
    check nflExpr"(var ((acc 0)) (for (i (.. 1 5)) (set! acc (+ acc i))) acc)" == 15

  test "case expression returns correct branch":
    check nflExpr"(case 0 (of 0 10) (of 1 20) (else 99))" == 10
    check nflExpr"(case 1 (of 0 10) (of 1 20) (else 99))" == 20
    check nflExpr"(case 2 (of 0 10) (of 1 20) (else 99))" == 99

  test "case expression with multi-value of branch":
    check nflExpr"(case 2 (of (1 2 3) 10) (else 0))" == 10
    check nflExpr"(case 4 (of (1 2 3) 10) (else 0))" == 0

  test "case expression with range of branch":
    check nflExpr"(case 5 (of (.. 1 9) 1) (else 0))" == 1
    check nflExpr"(case 1 (of (.. 1 9) 1) (else 0))" == 1
    check nflExpr"(case 9 (of (.. 1 9) 1) (else 0))" == 1
    check nflExpr"(case 10 (of (.. 1 9) 1) (else 0))" == 0

  test "case expression with mixed value/range of branch":
    check nflExpr"(case 4 (of (1 (.. 3 5) 7) 1) (else 0))" == 1
    check nflExpr"(case 7 (of (1 (.. 3 5) 7) 1) (else 0))" == 1
    check nflExpr"(case 6 (of (1 (.. 3 5) 7) 1) (else 0))" == 0

  test "case expression with wrapped single compound-expression of value":
    # A bare `(of (+ 1 2) …)` reads as the value list `+, 1, 2`; a single
    # computed value must be wrapped: `(of ((+ 1 2)) …)`.
    check nflExpr"(case 3 (of ((+ 1 2)) 10) (else 0))" == 10

  test "match — literal patterns":
    check nflExpr"""(match 0 (0 "zero") (1 "one") (_ "other"))""" == "zero"
    check nflExpr"""(match 1 (0 "zero") (1 "one") (_ "other"))""" == "one"
    check nflExpr"""(match 9 (0 "zero") (1 "one") (_ "other"))""" == "other"

  test "match — bare symbol pattern binds the scrutinee":
    check nflExpr"(match 41 (n (+ n 1)))" == 42

  test "match — quoted symbol pattern compares by equality":
    check nflExpr"""(match mcRed ('mcRed "stop") ('mcGreen "go") (_ "?"))""" == "stop"

  test "match — vector pattern destructures":
    check nflExpr"(match [1 2] ([a b] (+ a b)) (_ 0))" == 3

  test "match — rest-capture vector pattern":
    check nflExpr"(match (@ [1 2 3]) ([h & t] (+ h (. t len))) (_ 0))" == 3

  test "match — vector pattern arity picks the right clause":
    check nflExpr"(match (@ [1]) ([a b] 2) ([a] 1) (_ 0))" == 1
    check nflExpr"(match (@ [1 2]) ([a b] 2) ([a] 1) (_ 0))" == 2

  test "match — guard clause":
    check nflExpr"(match 11 (n :when (> n 10) 100) (n 0))" == 100
    check nflExpr"(match 5 (n :when (> n 10) 100) (n 0))" == 0

  test "match — guard clause references pattern bindings":
    check nflExpr"(match [3 4] ([a b] :when (> (+ a b) 5) (+ a b)) (_ 0))" == 7

  test "match — no branch matched raises":
    expect(ValueError):
      discard nflExpr"(match 9 (0 0) (1 1))"

  test "raise caught by enclosing try":
    check nflExpr("(try (raise (newException ValueError \"boom\")) (except ValueError \"caught\"))") == "caught"

  test "try successful path":
    check nflExpr("(try \"ok\" (except ValueError \"err\"))") == "ok"

  test "try bare catch-all":
    check nflExpr("(try (raise (newException CatchableError \"any\")) (except \"handled\"))") == "handled"

nflModule """
(import std/strutils)
(defmacro hygienic ()
  (let ((tmp (gensym "tmp")))
    `(let ((,tmp 1) (tmp__gensym1 2))
       (+ ,tmp tmp__gensym1))))
; --- Automatic template hygiene (#11) ---
; The macro's own literal `tmp` binding no longer captures — or is captured
; by — a caller-supplied `,a` that happens to also be named `tmp`.
(defmacro badplus (a)
  `(let ((tmp 1)) (+ tmp ,a)))
; Nested lets in one template shadow correctly: the inner `tmp` gets its
; own hygieneId, distinct from (but still referencing, via `,a`) the outer.
(defmacro nestedShadow (a)
  `(let ((tmp ,a)) (let ((tmp (+ tmp tmp))) tmp)))
; (unhygienic sym) is the intentional-capture escape hatch — an anaphoric
; macro binding `it` for the body to see.
(defmacro with-it (test &body body)
  `(let (((unhygienic it) ,test))
     (block ,@body)))
(proc greet ((name string))
  (toUpperAscii name))
(proc shout ((name string)) (: string)
  (name.toUpperAscii))
(when true nil)
(var shouted (toUpperAscii "nfl"))
(var shoutedAgain (greet "macro"))
(var shoutedByMethod (shout "method"))
(var hygienicResult (hygienic))
(var autoHygieneResult (let ((tmp 100)) (badplus tmp)))
(var nestedShadowResult (nestedShadow 5))
(var withItResult (with-it 41 (+ it 1)))
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
(var counted (incCount 2))
(var defaultPerson (default Person))
(var defaultAge (personAge defaultPerson))
(var ada (new Person (name "Ada") (age 36)))
(var adaName (. ada name))
(var adaAge (personAge ada))
(var adaHasExpectedAge (personNamedAge ada 36))
(var adaHasExpectedNamedAge (personNamedAge (: expected 36) (: p ada)))
(var favoriteMood happy)
(+ 1)
(block (+ 1 2) nil)
; Export marker tests — public proc, exported var declaration, exported type with mixed fields.
(proc publicGreet* ((name string)) (: string)
  (name.toUpperAscii))
(var publicVersion* "2.0")
(type PublicPoint*
  (object
    (x* int)
    (y int)))
(var testPoint (new PublicPoint (x 3) (y 4)))
; Const tests — plain, typed, exported.
(const privateConst 7)
(const (typedConst int) 11)
(const publicSize* 3)
; Typed var declaration tests — with value, without value (zero-initialized), exported.
(var (typedVar int) 11)
(var (typedBlank int))
(var (typedExported* int) 22)
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
; Pragma on var declaration.
(var pragmaVar {.used.} 77)
; Pragma on const.
(const pragmaConst {.used.} 13)
; Typed var declaration with pragma — value-less and with a value.
(var (typedPragmaBlank int) {.volatile.})
(var (typedPragmaValue int) {.volatile.} 42)
; Multi-binding var/const sections.
(var (((multiA int) 1) ((multiB int) 2)))
(const ((multiConstA 3) (multiConstB 4)))
; Value-less typed bindings within a var section (zero-initialized), mixed
; with a valued binding and a pragma-annotated value-less binding.
(var (((sectionBlank int)) ((sectionValued int) 5)))
(var (((sectionPragmaBlank int) {.volatile.})))
; Pragma on a valued binding within a var section (#39 follow-up coverage).
(var (((sectionPragmaValued int) {.volatile.} 9) (sectionPlain 3)))
; Value pragma: {.deprecated: "msg".} is usable without external linkage.
(proc oldHelper {.deprecated: "use newHelper instead".} () (: int)
  99)
; Value pragma: {.raises: [].} declares proc raises nothing.
(proc noRaises {.raises: [].} () (: int)
  42)
; Local let binding pragma.
(var localPragmaResult
  (let ((x {.used.} 7)) x))
; Local let binding with type and pragma.
(var localTypedPragmaResult
  (let (((x int) {.used.} 12)) x))
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
(var intBox (new [Box int] (value 42)))
; Call via inference.
(var identResult (identity 99))
; Two-param call via inference.
(var firstResult (pickFst 7 "ignored"))
; Unbox round-trip.
(var unboxResult (unbox intBox))
; Generic proc with pragma.
(proc inlinedId [T] {.inline.} ((x T)) (: T)
  x)
; Generic type with pragma.
(type BoxPure [T] {.pure.}
  (object
    (val T)))
; Generic template — inference-based call (#21).
(template genericIdent [T] ((x T)) (: T)
  x)
; Exported generic template — callable under base name.
(template genericIdent2* [T] ((x T)) (: T)
  x)
; Generic template consuming a generic type — [Box T] in parameter position.
(template genericUnbox [T] ((b [Box T])) (: T)
  (. b value))
(var genericTemplateResult (genericIdent 77))
(var genericTemplateResult2 (genericIdent2 88))
(var genericUnboxResult (genericUnbox intBox))
; Generic iterator — single type param (#21).
(iterator genericTwice [T] ((x T)) (: T)
  (yield x)
  (yield x))
; Generic iterator — two type params.
(iterator genericFirstTwice [T U] ((a T) (b U)) (: T)
  (yield a)
  (yield a))
(var genericIterSum
  (block
    (var ((acc 0))
      (for (x (genericTwice 5))
        (set! acc (+ acc x)))
      acc)))
(var genericIterSum2
  (block
    (var ((acc 0))
      (for (x (genericFirstTwice 3 "ignored"))
        (set! acc (+ acc x)))
      acc)))
; --- func / converter tests (#21 follow-on) ---
(func doublePure ((x int)) (: int)
  (* x 2))
(func genericSquare* [T] ((x T)) (: T)
  (* x x))
(converter toFloatConv ((x int)) (: float)
  (float x))
(var funcResult (doublePure 21))
(var genericSquareResult (genericSquare 6))
(var converterResult (+ (toFloatConv 3) 0.5))
; The converter also applies implicitly at a call site expecting `float` —
; no explicit call needed (#45).
(proc takesFloatArg ((f float)) (: float) f)
(var implicitConverterResult (takesFloatArg 3))
; Mixed int/float arithmetic relies on the same untyped-literal fix (#45).
(var mixedArithResult (+ 3 0.5))
; Sequence literals infer plain `int`, not `int64` (#45).
(var seqLiteral (@ [1 2 3]))
; --- For loop tests ---
; Sum elements of an array literal with a for loop.
(var forSeqSum
  (block
    (var ((acc 0))
      (for (x [1 2 3 4 5])
        (set! acc (+ acc x)))
      acc)))
; Sum of range 1..5 using the `..` range operator.
(var forRangeSum
  (block
    (var ((acc 0))
      (for (i (.. 1 5))
        (set! acc (+ acc i)))
      acc)))
; Multi-var iteration over array pairs.
(var forPairsSum
  (block
    (var ((acc 0))
      (for ((i x) (. [10 20 30] pairs))
        (set! acc (+ acc i)))
      acc)))
; --- Case tests ---
(proc caseLabel ((n int)) (: string)
  (case n
    (of 0 "zero")
    (of 1 "one")
    (else "many")))
; Case as statement — side effect via mutable var.
(var caseStmtRan
  (block
    (var ((x "unset"))
      (case 1
        (of 0 (set! x "zero"))
        (of 1 (set! x "one"))
        (else (set! x "other")))
      x)))
; Case as statement — range of-branch dispatch.
(var caseStmtRange
  (block
    (var ((x "unset"))
      (case 5
        (of (.. 1 9) (set! x "low"))
        (else (set! x "other")))
      x)))
; --- Error handling tests ---
; try: successful path — no exception raised.
(proc trySafe ((x int)) (: string)
  (try
    (if (< x 0)
        (raise (newException ValueError "negative"))
        "ok")
    (except ValueError
      "caught")))
; try: named except binding lets us read the exception message.
(proc tryNamed () (: string)
  (try
    (raise (newException ValueError "oops"))
    (except (e ValueError)
      (. e msg))))
; try: finally block runs even on the success path.
(var finallyRan
  (block
    (var ((ran false))
      (try
        nil
        (finally (set! ran true)))
      ran)))
; try: bare catch-all.
(proc tryBare () (: string)
  (try
    (raise (newException CatchableError "any"))
    (except "handled")))
; --- defer tests (#26) ---
; defer: runs at scope exit on the success path — the proc's own scope, not
; before the caller observes the mutation.
(var deferRan false)
(proc triggerDefer () (: void)
  (defer (set! deferRan true)))
(triggerDefer)
; defer: still runs when an exception propagates out of its scope.
(proc deferRanOnException () (: bool)
  (var ((ran false))
    (try
      (block
        (defer (set! ran true))
        (raise (newException ValueError "boom")))
      (except ValueError nil))
    ran))
; defer: may be the last form in a body (routed through emitBodyExpr).
(proc deferTrailingResult () (: int)
  (set! result 42)
  (defer (set! result result)))
; --- Template tests ---
; Unexported template: squares an int.
(template square ((x int))
  (* x x))
; Exported template with explicit return type — callable under base name from Nim/NFL.
(template double* ((x int)) (: int)
  (* x 2))
; Template with bare-symbol (untyped) param — e.g. used for code injection.
(template inject (body)
  body)
; Use templates via var declaration.
(var templateResult (square 7))
(var injectResult (inject 99))
; --- Iterator tests ---
; Unexported iterator yielding 0..n-1 used for the var declaration sum.
(iterator upTo ((n int)) (: int)
  (for (i (.. 0 (- n 1)))
    (yield i)))
; Exported iterator — callable from NFL for and from Nim.
(iterator range2* ((n int)) (: int)
  (for (i (.. 0 (- n 1)))
    (yield i)))
; Sum all values produced by the unexported iterator.
(var iterSum
  (block
    (var ((acc 0))
      (for (x (upTo 5))
        (set! acc (+ acc x)))
      acc)))
; --- Operator proc tests (#29) ---
(type OpInt (distinct int))
; Unexported operator proc, called infix from Nim.
(proc |+| ((a OpInt) (b OpInt)) (: OpInt)
  (OpInt (+ (int a) (int b))))
; Exported operator proc — `-*` strips to exported `-`.
(proc -* ((a OpInt) (b OpInt)) (: OpInt)
  (OpInt (- (int a) (int b))))
; Multi-char exported operator — `**` strips to exported `*`.
(proc ** ((a OpInt) (b OpInt)) (: OpInt)
  (OpInt (* (int a) (int b))))
; Escaped multi-char operator — `|**|` is the unexported `**` operator,
; distinct from unescaped `**` above (#46 follow-up to #29).
(proc |**| ((a OpInt) (b OpInt)) (: OpInt)
  (OpInt (* (* (int a) (int b)) 2)))
(var opSum (int (+ (OpInt 3) (OpInt 4))))
(var opProduct (int (* (OpInt 3) (OpInt 4))))
(var opDoubleProduct (int (|**| (OpInt 3) (OpInt 4))))
; --- Selective imports (#31) ---
(from std/math import sqrt)
(from std/os import (except getEnv))
(var fromImportResult (sqrt 16.0))
(var fromImportExceptResult (. (getCurrentDir) len))
""", "module-test.nfl"

suite "nfl module backend":
  test "import and var declaration":
    check shouted == "NFL"

  test "proc definition":
    check shoutedAgain == "MACRO"

  test "typed proc and dotted method call":
    check shout("nim") == "NIM"
    check shoutedByMethod == "METHOD"

  test "from-import brings only the named symbol into scope (#31)":
    check fromImportResult == 4.0

  test "from-import-except imports everything but the excepted symbol (#31)":
    check fromImportExceptResult > 0

  test "gensym bindings do not collide with matching source names":
    check hygienicResult == 3

  test "automatic template hygiene — macro-local binding doesn't capture caller argument (#11)":
    # (badplus tmp) called with the caller's own `tmp` (== 100): the macro's
    # literal `(let ((tmp 1)) (+ tmp ,a))` must bind its own hygienic `tmp`
    # (== 1) without shadowing the substituted `,a` reference to the
    # caller's `tmp`. Result is 1 + 100 = 101 — a 2 would mean capture.
    check autoHygieneResult == 101

  test "automatic template hygiene — nested lets in one template shadow correctly":
    check nestedShadowResult == 10   # (5 + 5)

  test "unhygienic escape hatch — anaphoric macro binds it for the caller's body":
    check withItResult == 42

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

  test "exported var declaration is accessible under its base name":
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

  test "typed var declaration":
    check typedVar == 11

  test "typed var declaration without value is zero-initialized":
    check typedBlank == 0

  test "typed exported var declaration is accessible under its base name":
    check typedExported == 22

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

  test "pragma on var declaration compiles":
    check pragmaVar == 77

  test "pragma on const compiles":
    check pragmaConst == 13

  test "typed var declaration with pragma and no value is zero-initialized":
    check typedPragmaBlank == 0

  test "typed var declaration with pragma and value":
    check typedPragmaValue == 42

  test "multi-binding var section":
    check multiA == 1
    check multiB == 2

  test "multi-binding const section":
    check multiConstA == 3
    check multiConstB == 4

  test "value-less typed binding in var section is zero-initialized":
    check sectionBlank == 0
    check sectionValued == 5

  test "value-less typed binding with pragma in var section is zero-initialized":
    check sectionPragmaBlank == 0

  test "pragma on a valued binding within a var section":
    check sectionPragmaValued == 9
    check sectionPlain == 3

  test "value pragma {.deprecated: msg.} compiles and proc is callable":
    {.push warnings: off.}
    check oldHelper() == 99
    {.pop.}

  test "value pragma {.raises: [].} compiles and proc is callable":
    check noRaises() == 42

  test "local let binding with pragma compiles and evaluates":
    check localPragmaResult == 7

  test "typed local let binding with pragma compiles and evaluates":
    check localTypedPragmaResult == 12

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

  test "generic template — inference-based call":
    check genericIdent(55) == 55
    check genericTemplateResult == 77

  test "exported generic template callable under base name":
    check genericIdent2(11) == 11
    check genericTemplateResult2 == 88

  test "generic template with generic type in param position":
    check genericUnbox(intBox) == 42
    check genericUnboxResult == 42

  test "generic iterator — single type param":
    check genericIterSum == 10   # 5 + 5

  test "generic iterator — two type params":
    check genericIterSum2 == 6   # 3 + 3

suite "nfl module backend — for / case / raise / try":
  test "for loop sums sequence elements":
    check forSeqSum == 15

  test "for loop sums range":
    check forRangeSum == 15

  test "for multi-var pairs iteration":
    # Indices 0 + 1 + 2 = 3.
    check forPairsSum == 3

  test "case expression dispatches correctly":
    check caseLabel(0) == "zero"
    check caseLabel(1) == "one"
    check caseLabel(99) == "many"

  test "case as statement — side effect executes correct branch":
    check caseStmtRan == "one"

  test "case as statement — range of-branch executes correct branch":
    check caseStmtRange == "low"

  test "try — successful path returns body value":
    check trySafe(1) == "ok"

  test "try — exception caught returns handler value":
    check trySafe(-1) == "caught"

  test "try — named except binding reads exception message":
    check tryNamed() == "oops"

  test "try — finally block runs on success path":
    check finallyRan == true

  test "try — bare catch-all catches any exception":
    check tryBare() == "handled"

  test "defer — runs at scope exit on success":
    check deferRan == true

  test "defer — runs even when an exception propagates out of its scope":
    check deferRanOnException() == true

  test "defer — trailing defer in a body still returns the implicit result":
    check deferTrailingResult() == 42

suite "nfl module backend — template / iterator":
  test "template definition produces correct value":
    check templateResult == 49   # square(7) = 7 * 7 = 49

  test "exported template callable under base name":
    check double(4) == 8

  test "template with untyped param":
    check injectResult == 99

  test "iterator sum via for loop":
    check iterSum == 10   # 0 + 1 + 2 + 3 + 4 = 10

  test "exported iterator callable from NFL for":
    var s = 0
    for x in range2(4):
      s += x
    check s == 6   # 0 + 1 + 2 + 3 = 6

suite "nfl module backend — operator procs (#29)":
  test "unexported operator proc — dispatches via NFL prefix call":
    check opSum == 7

  test "exported multi-char operator proc — ** strips to exported *":
    check opProduct == 12

  test "exported operator proc callable infix from plain Nim":
    check int(OpInt(9) - OpInt(4)) == 5

  test "unexported |**| operator proc is a distinct name from exported ** (#46)":
    check opDoubleProduct == 24
    check opProduct == 12

suite "nfl module backend — func / converter (#21 follow-on)":
  test "func compiles and is callable":
    check doublePure(21) == 42
    check funcResult == 42

  test "generic exported func callable under base name":
    check genericSquare(6) == 36
    check genericSquareResult == 36

  test "converter is callable via an explicit call":
    check converterResult == 3.5

  test "converter applies implicitly at a call site (#45)":
    check implicitConverterResult == 3.0

  test "mixed int/float arithmetic on untyped literals (#45)":
    check mixedArithResult == 3.5

  test "sequence literals infer plain int, not int64 (#45)":
    check seqLiteral is seq[int]
    check seqLiteral == @[1, 2, 3]

# ---------------------------------------------------------------------------
# Behavioral tests for while/break/continue (#24), return (#25),
# discard (#27), distinct/tuple/ref (#28), and method (#30 foundation).
# ---------------------------------------------------------------------------

nflModule """
; --- while loop sums 0+1+2+3+4 = 10 (#24) ---
(var whileSum
  (block
    (var ((i 0) (acc 0))
      (while (< i 5)
        (set! acc (+ acc i))
        (set! i (+ i 1)))
      acc)))

; --- break exits early when i reaches 3 (#24) ---
(var breakAt
  (block
    (var ((i 0))
      (while true
        (if (>= i 3) (break) nil)
        (set! i (+ i 1)))
      i)))

; --- continue skips even increments; sums odd i: 1+3+5 = 9 (#24) ---
(var continueSkips
  (block
    (var ((i 0) (acc 0))
      (while (< i 5)
        (set! i (+ i 1))
        (if (== 0 (mod i 2))
            (continue)
            (set! acc (+ acc i))))
      acc)))

; --- return exits proc early (#25) ---
(proc clamp ((n int) (lo int) (hi int)) (: int)
  (if (< n lo) (return lo) nil)
  (if (> n hi) (return hi) nil)
  n)

; --- discard suppresses unused-result warning (#27) ---
(proc sideEffect () (: int) 42)
(var discardRan
  (block
    (discard (sideEffect))
    true))

; --- distinct type wraps a base type (#28) ---
(type Metres (distinct float))
(proc toMetres ((x float)) (: Metres) (Metres x))
(var metreDist (toMetres 5.0))

; --- tuple structural type (#28) ---
(type Point2D (tuple (x float) (y float)))
(proc getPtX ((pt Point2D)) (: float) (. pt x))
(proc getPtY ((pt Point2D)) (: float) (. pt y))
; Named tuple construction (#35) — no Nim-side syntax required.
(var namedPoint (tuple-new Point2D (x 3.0) (y 4.0)))

; --- ref object heap allocation (#28) ---
(type TreeNode (ref (object (val int))))
(proc mkNode ((v int)) (: TreeNode)
  (new TreeNode (val v)))
(var aNode (mkNode 7))
(var nodeVal (. aNode val))
""", "new-forms-test.nfl"

suite "nfl backend — while / break / continue / return / discard (#24-#27)":
  test "while loop accumulates sum":
    check whileSum == 10   # 0+1+2+3+4 = 10

  test "while sums inline via nflExpr":
    check nflExpr"(var ((i 0)(s 0)) (while (< i 5) (set! s (+ s i)) (set! i (+ i 1))) s)" == 10

  test "break exits loop at target":
    check breakAt == 3

  test "continue skips even iterations":
    check continueSkips == 9  # 1+3+5 = 9

  test "bare break inside an expression-position block still exits the loop (#60)":
    # An anonymous `(block ...)` used in expression position (e.g. as an
    # `if` branch assigned via `set!`) emits a real Nim `block:` around its
    # non-tail statements. A bare `break` there must still exit the
    # enclosing `while`, not the intervening anonymous block. Bounded at
    # 100 so a regression fails on the wrong value instead of hanging the
    # test suite.
    check nflExpr"""
      (var ((i 0) (y 0))
        (while (< i 100)
          (set! y (if (>= i 3) (block (break) 1) 0))
          (set! i (+ i 1)))
        i)
    """ == 3

  test "return exits proc early — clamp low":
    check clamp(-1, 0, 10) == 0

  test "return exits proc early — clamp high":
    check clamp(20, 0, 10) == 10

  test "return falls through — clamp in range":
    check clamp(5, 0, 10) == 5

  test "discard suppresses unused-result warning":
    check discardRan == true

suite "nfl backend — distinct / tuple / ref types (#28)":
  test "distinct type wraps base":
    check float(metreDist) == 5.0

  test "tuple type fields are accessible from NFL proc":
    let pt: Point2D = (x: 3.0, y: 4.0)
    check getPtX(pt) == 3.0
    check getPtY(pt) == 4.0

  test "tuple-new constructs a named tuple by field (#35)":
    check namedPoint == (x: 3.0, y: 4.0)
    check getPtX(namedPoint) == 3.0
    check getPtY(namedPoint) == 4.0

  test "ref object allocates on heap and field is readable":
    check nodeVal == 7

# ---------------------------------------------------------------------------
# method + object inheritance (#30, #33)
# ---------------------------------------------------------------------------

nflModule """
; Define a base ref type using object inheritance (#33).
(type Shape (ref (object (of RootObj) (color string))))
(type Circle (ref (object (of Shape) (radius float))))

; method dispatches dynamically via vtable (#30).
(method area ((s Shape)) (: float) 0.0)
(method area ((c Circle)) (: float)
  (* 3.14159 (* (. c radius) (. c radius))))

(proc mkCircle ((r float) (col string)) (: Circle)
  (new Circle (radius r) (color col)))

(var circ (mkCircle 2.0 "red"))
(var circColor (. circ color))
""", "method-test.nfl"

suite "nfl backend — method / object inheritance (#30, #33)":
  test "object inheritance compiles and base field is accessible":
    check circColor == "red"

  test "method dynamic dispatch via base ref":
    let s: Shape = circ
    check s.area() > 12.0 and s.area() < 13.0   # π×2² ≈ 12.566

  test "method dispatches on concrete type":
    check circ.area() > 12.0 and circ.area() < 13.0

# ---------------------------------------------------------------------------
# implicit result variable  (#36)
# ---------------------------------------------------------------------------

nflModule """
; Body is only a set! of result — Nim auto-returns result, no explicit return.
(proc justResult () (: int)
  (set! result 5))

; Assign result, run further statements, then bail early with a bare return.
(proc sumTo ((n int)) (: int)
  (set! result 0)
  (for (i (.. 1 n))
    (set! result (+ result i)))
  (if (> n 100)
      (return)
      (return result)))

; method also gets an implicit result.
(type Doubler (object (factor int)))
(method resultDouble ((d Doubler) (n int)) (: int)
  (set! result n)
  (set! result (* result (. d factor))))
""", "result-test.nfl"

suite "nfl backend — implicit result variable (#36)":
  test "set! result as the only body form returns it":
    check justResult() == 5

  test "result accumulates across statements":
    check sumTo(5) == 15

  test "bare return exits early, returning result already accumulated":
    check sumTo(200) == 20100  # 200*201/2, returned via bare `return`

  test "method gets an implicit result too":
    check resultDouble(Doubler(factor: 2), 3) == 6

nflModule """
; A typed do nested inside a typed proc each get their own independent
; `result` binding — the inner do's `result` legitimately shadows the
; outer proc's `result` rather than colliding with it (#40).
(proc nestedResult () (: int)
  (var g (do () (: int) (set! result 1)))
  (set! result (g)))
""", "nested-result-test.nfl"

suite "nfl backend — do/lambda implicit result variable (#40)":
  test "a typed do nested in a typed proc gets its own independent result":
    check nestedResult() == 1

# ---------------------------------------------------------------------------
# named block / break-from (#41)
# ---------------------------------------------------------------------------

nflModule """
; --- fall-through value: no break-from taken ---
(proc firstOver ((xs [seq int]) (limit int)) (: int)
  (block :search
    (for (x xs)
      (if (> x limit) (break-from :search x) nil))
    -1))

; --- valueless break-from out of a void-tailed block, from inside a for ---
(var (voidBreakLog [seq int]) (@ []))
(proc logFirstOver ((xs [seq int]) (limit int)) (: void)
  (block :search
    (for (x xs)
      (if (> x limit)
          (break-from :search)
          nil))
    (. voidBreakLog add 0)))

; --- break-from reachable from inside a while loop ---
(proc firstOverWhile ((xs [seq int]) (limit int)) (: int)
  (block :search
    (var ((i 0))
      (while (< i (. xs len))
        (if (> (at xs i) limit)
            (break-from :search (at xs i))
            nil)
        (set! i (+ i 1))))
    -1))

; --- nested named blocks: inner block exits the outer one ---
(proc nestedExit ((x int)) (: string)
  (block :outer
    (let ((inner (block :inner
                   (if (> x 0)
                       (break-from :outer "early")
                       5))))
      (& "inner=" ($ inner)))))

; --- bare tail break-from with a value, no other fallthrough at all ---
(proc bareBreak () (: int)
  (block :search
    (break-from :search 5)))

; --- named block in non-tail statement position (not a proc's own tail,
; so it emits via emitStmt's labelled branch, a real nnkBlockStmt, unlike
; the anonymous-block statement path which just flattens) ---
(var (stmtPositionLog [seq int]) (@ []))
(proc stmtPositionExit ((doBreak bool)) (: void)
  (block :early
    (if doBreak (break-from :early) nil)
    (. stmtPositionLog add 1))
  (. stmtPositionLog add 2))
""", "named-block-test.nfl"

suite "nfl backend — named block / break-from (#41)":
  test "fall-through value when break-from is never taken":
    check firstOver(@[1, 2, 3], 100) == -1

  test "break-from short-circuits with a value":
    check firstOver(@[1, 2, 3, 9, 4], 3) == 9

  test "valueless break-from exits a void-tailed block early":
    logFirstOver(@[1, 2, 9], 3)
    check voidBreakLog.len == 0
    logFirstOver(@[1, 2, 3], 100)
    check voidBreakLog.len == 1

  test "break-from reachable from inside a while loop":
    check firstOverWhile(@[1, 2, 3], 100) == -1
    check firstOverWhile(@[1, 2, 3, 9, 4], 3) == 9

  test "nested named blocks — inner block's break-from exits the outer one":
    check nestedExit(1) == "early"
    check nestedExit(-1) == "inner=5"

  test "bare tail break-from with a value and no other fallthrough":
    check bareBreak() == 5

  test "named block in non-tail statement position still runs code after it":
    stmtPositionLog = @[]
    stmtPositionExit(true)
    check stmtPositionLog == @[2]   # break-from skips the `add 1`
    stmtPositionLog = @[]
    stmtPositionExit(false)
    check stmtPositionLog == @[1, 2]

# ---------------------------------------------------------------------------
# labelled break / continue (#54)
# ---------------------------------------------------------------------------

nflModule """
; --- labelled break from a nested loop exits the outer loop ---
(var (labelledBreakLog [seq int]) (@ []))
(proc labelledBreakOuter ((n int)) (: int)
  (var ((i 0))
    (while :outer (< i n)
      (var ((j 0))
        (while (< j n)
          (if (and (== i 1) (== j 1)) (break :outer) nil)
          (. labelledBreakLog add (+ (* i 100) j))
          (set! j (+ j 1))))
      (set! i (+ i 1)))
    i))

; --- labelled continue from a nested loop restarts the outer loop,
; skipping both the rest of the inner loop and the rest of the outer
; loop's own body ---
(proc labelledContinueOuter ((n int)) (: int)
  (var ((i 0) (acc 0))
    (while :outer (< i n)
      (set! i (+ i 1))
      (var ((j 0))
        (while (< j n)
          (if (== j 1) (continue :outer) nil)
          (set! acc (+ acc 1))
          (set! j (+ j 1))))
      (set! acc (+ acc 100)))
    acc))

; --- unlabelled break/continue inside a labelled loop still bind to the
; innermost loop, not the labelled outer one ---
(proc innerBreakStaysInner ((n int)) (: int)
  (var ((i 0) (count 0))
    (while :outer (< i n)
      (var ((j 0))
        (while (< j n)
          (if (== j 1) (break) nil)
          (set! count (+ count 1))
          (set! j (+ j 1))))
      (set! i (+ i 1)))
    count))

; --- a labelled loop with no labelled break/continue behaves identically
; to an unlabelled one ---
(proc labelledSum ((n int)) (: int)
  (var ((i 0) (acc 0))
    (while :outer (< i n)
      (set! acc (+ acc i))
      (set! i (+ i 1)))
    acc))

; --- break-from out of a labelled loop into an enclosing named block
; still works (#41 interop) ---
(proc labelledLoopBreakFrom ((n int)) (: int)
  (block :outerBlock
    (var ((i 0))
      (while :innerLoop (< i n)
        (if (== i 2) (break-from :outerBlock 99) nil)
        (set! i (+ i 1))))
    -1))

; --- behaviour change (#60): a bare `break` inside a *named* block now
; exits the enclosing loop, not just the block — Nim's unlabelled `break`
; previously captured by the block's own (named or anonymous) `block:`.
; Bounded at 100 so a regression shows as a wrong value, not a hang. ---
(proc bareBreakThroughNamedBlock () (: int)
  (var ((i 0))
    (while (< i 100)
      (block :name (break))
      (set! i (+ i 1)))
    i))

; --- labelled break/continue on a `for` loop (not just `while`) ---
(var (labelledForBreakLog [seq int]) (@ []))
(proc labelledForBreakOuter () (: int)
  (var ((lastI 0))
    (for :outer (i (.. 0 2))
      (set! lastI i)
      (for (j (.. 0 2))
        (if (and (== i 1) (== j 1)) (break :outer) nil)
        (. labelledForBreakLog add (+ (* i 100) j))))
    lastI))

(proc labelledForContinueOuter () (: int)
  (var ((acc 0))
    (for :outer (i (.. 0 2))
      (for (j (.. 0 2))
        (if (== j 1) (continue :outer) nil)
        (set! acc (+ acc 1)))
      (set! acc (+ acc 100)))
    acc))

; --- shadowing at the Nim codegen level: an inner loop reusing the outer
; loop's label binds break/continue to the inner loop, and the outer
; loop's own label is still usable afterwards (#54) ---
(proc shadowedLabelBreak () (: int)
  (var ((count 0))
    (while :outer true
      (while :outer true
        (set! count (+ count 1))
        (break :outer))
      (break :outer))
    count))
""", "labelled-loop-test.nfl"

suite "nfl backend — labelled break / continue (#54)":
  test "labelled break from a nested loop exits the outer loop":
    labelledBreakLog = @[]
    check labelledBreakOuter(3) == 1
    check labelledBreakLog == @[0, 1, 2, 100]

  test "labelled continue from a nested loop restarts the outer loop":
    check labelledContinueOuter(3) == 3

  test "unlabelled break/continue inside a labelled loop bind to the innermost loop":
    check innerBreakStaysInner(3) == 3

  test "a labelled loop with no labelled break/continue behaves like an unlabelled one":
    check labelledSum(5) == 10   # 0+1+2+3+4

  test "break-from escapes a labelled loop into an enclosing named block (#41 interop)":
    check labelledLoopBreakFrom(5) == 99

  test "a bare break inside a named block now exits the loop, not the block (#60)":
    check bareBreakThroughNamedBlock() == 0

  test "labelled break from a nested loop exits an outer for loop":
    labelledForBreakLog = @[]
    check labelledForBreakOuter() == 1
    check labelledForBreakLog == @[0, 1, 2, 100]

  test "labelled continue from a nested loop restarts an outer for loop":
    check labelledForContinueOuter() == 3

  test "an inner loop reusing the outer label shadows it at the Nim codegen level":
    check shadowedLabelBreak() == 1
