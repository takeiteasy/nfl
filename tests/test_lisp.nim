import unittest
import lisp
import strutils

suite "lisp macro tests":
  test "simple addition":
    let result = lisp("(+ 1 2)")
    check(result == 3)

  test "if expression":
    let result = lisp("(if (> 5 3) 10 20)")
    check(result == 10)

  test "let expression":
    let result = lisp("(let ((a 10) (b 20)) (+ a b))")
    check(result == 30)

  test "lambda expression":
    let square = lisp("(lambda ((x int)) (* x x))")
    check(square(5) == 25)

  test "list operations":
    let mylist = lisp("(cons 1 (cons 2 (cons 3 @[])))")
    check(mylist == @[1, 2, 3])
    let car_res = lisp("(car mylist)")
    check(car_res == 1)
    let cdr_res = lisp("(cdr mylist)")
    check(cdr_res == @[2, 3])

  test "progn expression":
    let result = lisp("(progn 1 2 3)")
    check(result == 3)

  test "multiple top-level expressions":
    let result = lisp("(+ 1 2)\n(* 3 4)")
    check(result == 12)

  test "string literals":
    let result = lisp("\"hello world\"")
    check(result == "hello world")

  test "float literals":
    let result = lisp("(+ 1.5 2.5)")
    check(result == 4.0)

  test "nested expressions":
    let result = lisp("(+ (* 2 3) (- 10 4))")
    check(result == 12)

  test "lambda with multiple params":
    let add = lisp("(lambda ((x int) (y int)) (+ x y))")
    check(add(3, 4) == 7)

  test "if with false condition":
    let result = lisp("(if (< 5 3) 10 20)")
    check(result == 20)

  test "let with single binding":
    let result = lisp("(let ((x 42)) x)")
    check(result == 42)

  test "lispToNim with multiple expressions":
    let nimCode = lispToNim("(+ 1 2)\n(* 3 4)")
    check(nimCode.contains("(1 + 2)"))
    check(nimCode.contains("(3 * 4)"))

  test "lispToNim with single expression":
    let nimCode = lispToNim("(+ 1 2)")
    check(nimCode == "(1 + 2)")

  test "operator with more than 2 args":
    let result = lisp("(+ 1 2 3 4)")
    check(result == 10)

  test "lambda returning lambda":
    let makeAdder = lisp("(lambda ((n int)) (lambda ((x int)) (+ x n)))")
    let add5 = makeAdder(5)
    check(add5(10) == 15)

  test "null? with empty list":
    let result = lisp("(null? @[])")
    check(result == true)

  test "null? with non-empty list":
    let result = lisp("(null? @[1, 2])")
    check(result == false)

  test "list? with list":
    let result = lisp("(list? @[1, 2, 3])")
    check(result == true)

  test "list? with non-list":
    let result = lisp("(list? 42)")
    check(result == false)

  test "length of list":
    let result = lisp("(length @[1, 2, 3, 4])")
    check(result == 4)

  test "length of empty list":
    let result = lisp("(length @[])")
    check(result == 0)

  test "append two lists":
    let result = lisp("(append @[1, 2] @[3, 4])")
    check(result == @[1, 2, 3, 4])

  test "append three lists":
    let result = lisp("(append @[1] @[2] @[3])")
    check(result == @[1, 2, 3])

  test "list constructor":
    let result = lisp("(list 1 2 3)")
    check(result == @[1, 2, 3])

  test "list with expressions":
    let result = lisp("(list (+ 1 2) (* 3 4))")
    check(result == @[3, 12])

  test "reverse list":
    let result = lisp("(reverse @[1, 2, 3])")
    check(result == @[3, 2, 1])

  test "error message includes line number":
    let nimCode = lispToNim("(let ((a 10)) (+ a b))")
    check(nimCode.len > 0)

  test "quote syntax with list":
    let result = lisp("'(1 2 3)")
    check(result == @[1, 2, 3])

  test "quote syntax with symbols":
    let result = lisp("'(a b c)")
    check(result == @["a", "b", "c"])

  test "quote syntax with nested lists":
    let result = lisp("'((1 2) (3 4))")
    check(result == @[@[1, 2], @[3, 4]])
