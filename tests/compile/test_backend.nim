import std/unittest

import nimp/compiler

suite "nimp backend":
  test "operator call":
    check nimpExpr"(+ 1 2)" == 3

  test "if expression":
    check nimpExpr"(if true 1 2)" == 1

  test "let expression":
    check nimpExpr"(let ((x 1)) (+ x 2))" == 3

  test "var and set expression":
    check nimpExpr"(var ((x 1)) (set! x (+ x 2)) x)" == 3

  test "lambda expression":
    let inc = nimpExpr"(lambda ((x int)) (+ x 1))"
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

  test "autoloaded sequence helper macros":
    check nimpExpr"(let ((xs [10 20 30])) (first xs))" == 10
    check nimpExpr"(let ((xs [10 20 30])) (first (rest xs)))" == 20
    check nimpExpr"(let ((xs [10 20 30])) (empty? xs))" == false
    check nimpExpr"(let ((xs (@ [10 20])) (ys (@ [30 40]))) (at (append xs ys) 2))" == 30

nimpModule """
(import std/strutils)
(defmacro hygienic ()
  (let ((tmp (gensym "tmp")))
    `(let ((,tmp 1) (tmp__gensym1 2))
       (+ ,tmp tmp__gensym1))))
(define-proc greet ((name string))
  (toUpperAscii name))
(define-proc shout ((name string)) (: string)
  (name.toUpperAscii))
(when true nil)
(define shouted (toUpperAscii "nimp"))
(define shoutedAgain (greet "macro"))
(define shoutedByMethod (shout "method"))
(define hygienicResult (hygienic))
(+ 1)
(begin (+ 1 2) nil)
""", "module-test.nimp"

suite "nimp module backend":
  test "import and define":
    check shouted == "NIMP"

  test "define-proc macro":
    check shoutedAgain == "MACRO"

  test "typed define-proc and dotted method call":
    check shout("nim") == "NIM"
    check shoutedByMethod == "METHOD"

  test "gensym bindings do not collide with matching source names":
    check hygienicResult == 3
