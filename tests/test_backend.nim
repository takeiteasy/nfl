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

suite "nfl backend — for / case / raise / try":
  test "for loop sums elements":
    check nflExpr"(var ((acc 0)) (for (x [1 2 3]) (set! acc (+ acc x))) acc)" == 6

  test "for loop over range":
    check nflExpr"(var ((acc 0)) (for (i (.. 1 5)) (set! acc (+ acc i))) acc)" == 15

  test "case expression returns correct branch":
    check nflExpr"(case 0 (of 0 10) (of 1 20) (else 99))" == 10
    check nflExpr"(case 1 (of 0 10) (of 1 20) (else 99))" == 20
    check nflExpr"(case 2 (of 0 10) (of 1 20) (else 99))" == 99

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
; Typed defvar tests — with value, without value (zero-initialized), exported.
(defvar (typedVar int) 11)
(defvar (typedBlank int))
(defvar (typedExported* int) 22)
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
; Value pragma: {.deprecated: "msg".} is usable without external linkage.
(proc oldHelper {.deprecated: "use newHelper instead".} () (: int)
  99)
; Value pragma: {.raises: [].} declares proc raises nothing.
(proc noRaises {.raises: [].} () (: int)
  42)
; Local let binding pragma.
(defvar localPragmaResult
  (let ((x {.used.} 7)) x))
; Local let binding with type and pragma.
(defvar localTypedPragmaResult
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
; --- For loop tests ---
; Sum elements of an array literal with a for loop.
(defvar forSeqSum
  (block
    (var ((acc 0))
      (for (x [1 2 3 4 5])
        (set! acc (+ acc x)))
      acc)))
; Sum of range 1..5 using the `..` range operator.
(defvar forRangeSum
  (block
    (var ((acc 0))
      (for (i (.. 1 5))
        (set! acc (+ acc i)))
      acc)))
; Multi-var iteration over array pairs.
(defvar forPairsSum
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
(defvar caseStmtRan
  (block
    (var ((x "unset"))
      (case 1
        (of 0 (set! x "zero"))
        (of 1 (set! x "one"))
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
(defvar finallyRan
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
; Use templates via defvar.
(defvar templateResult (square 7))
(defvar injectResult (inject 99))
; --- Iterator tests ---
; Unexported iterator yielding 0..n-1 used for the defvar sum.
(iterator upTo ((n int)) (: int)
  (for (i (.. 0 (- n 1)))
    (yield i)))
; Exported iterator — callable from NFL for and from Nim.
(iterator range2* ((n int)) (: int)
  (for (i (.. 0 (- n 1)))
    (yield i)))
; Sum all values produced by the unexported iterator.
(defvar iterSum
  (block
    (var ((acc 0))
      (for (x (upTo 5))
        (set! acc (+ acc x)))
      acc)))
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

  test "typed defvar declaration":
    check typedVar == 11

  test "typed defvar without value is zero-initialized":
    check typedBlank == 0

  test "typed exported defvar is accessible under its base name":
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

  test "pragma on defvar compiles":
    check pragmaVar == 77

  test "pragma on const compiles":
    check pragmaConst == 13

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

# ---------------------------------------------------------------------------
# Behavioral tests for while/break/continue (#24), return (#25),
# discard (#27), distinct/tuple/ref (#28), and method (#30 foundation).
# ---------------------------------------------------------------------------

nflModule """
; --- while loop sums 0+1+2+3+4 = 10 (#24) ---
(defvar whileSum
  (block
    (var ((i 0) (acc 0))
      (while (< i 5)
        (set! acc (+ acc i))
        (set! i (+ i 1)))
      acc)))

; --- break exits early when i reaches 3 (#24) ---
(defvar breakAt
  (block
    (var ((i 0))
      (while true
        (if (>= i 3) (break) nil)
        (set! i (+ i 1)))
      i)))

; --- continue skips even increments; sums odd i: 1+3+5 = 9 (#24) ---
(defvar continueSkips
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
(defvar discardRan
  (block
    (discard (sideEffect))
    true))

; --- distinct type wraps a base type (#28) ---
(type Metres (distinct float))
(proc toMetres ((x float)) (: Metres) (Metres x))
(defvar metreDist (toMetres 5.0))

; --- tuple structural type (#28) ---
; Construction of named tuples uses Nim-side syntax (no (new ...) form for tuples).
; We declare the type and procs in NFL; the test constructs the value in Nim.
(type Point2D (tuple (x float) (y float)))
(proc getPtX ((pt Point2D)) (: float) (. pt x))
(proc getPtY ((pt Point2D)) (: float) (. pt y))

; --- ref object heap allocation (#28) ---
(type TreeNode (ref (object (val int))))
(proc mkNode ((v int)) (: TreeNode)
  (new TreeNode (val v)))
(defvar aNode (mkNode 7))
(defvar nodeVal (. aNode val))
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

(defvar circ (mkCircle 2.0 "red"))
(defvar circColor (. circ color))
""", "method-test.nfl"

suite "nfl backend — method / object inheritance (#30, #33)":
  test "object inheritance compiles and base field is accessible":
    check circColor == "red"

  test "method dynamic dispatch via base ref":
    let s: Shape = circ
    check s.area() > 12.0 and s.area() < 13.0   # π×2² ≈ 12.566

  test "method dispatches on concrete type":
    check circ.area() > 12.0 and circ.area() < 13.0
