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

nimpModule """
(import std/strutils)
(define shouted (toUpperAscii "nimp"))
""", "module-test.nimp"

suite "nimp module backend":
  test "import and define":
    check shouted == "NIMP"
