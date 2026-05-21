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
    check(nimCode.contains("(1 + 2)"))

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

  test "line comments":
    let result = lisp("(+ 1 2) ; this is a comment\n(* 3 4)")
    check(result == 12)

  test "block comments":
    let result = lisp("(+ 1 2) #| block comment |# (* 3 4)")
    check(result == 12)

  test "multi-line block comments":
    let result = lisp("""(+ 1 2) #| this is
a multi-line
comment |# (* 3 4)""")
    check(result == 12)

  test "inline comments":
    let result = lisp("(+ 1 2) ; comment\n")
    check(result == 3)

  test "cond with single clause":
    let result = lisp("(cond ((> 5 3) 10) (else 0))")
    check(result == 10)

  test "cond with multiple clauses":
    let result = lisp("(cond ((> 5 10) 1) ((> 5 3) 2) (else 3))")
    check(result == 2)

  test "cond with else":
    let result = lisp("(cond ((> 5 10) 1) (else 99))")
    check(result == 99)

  test "and with true values":
    let result = lisp("(and (> 5 3) (< 5 10))")
    check(result == true)

  test "and with false value":
    let result = lisp("(and (> 5 3) (< 5 3))")
    check(result == false)

  test "or with true value":
    let result = lisp("(or (> 5 3) (< 5 3))")
    check(result == true)

  test "or with all false":
    let result = lisp("(or (< 5 3) (> 3 5))")
    check(result == false)

  test "map over list":
    let double = lisp("(lambda ((x int)) (* x 2))")
    let result = lisp("(map double @[1, 2, 3])")
    check(result == @[2, 4, 6])

  test "filter even numbers":
    let isEven = lisp("(lambda ((x int)) (== (mod x 2) 0))")
    let result = lisp("(filter isEven @[1, 2, 3, 4, 5, 6])")
    check(result == @[2, 4, 6])

  test "map with lambda inline":
    let result = lisp("(map (lambda ((x int)) (+ x 1)) @[1, 2, 3])")
    check(result == @[2, 3, 4])

  test "set! mutation in let":
    let result = lisp("(let ((x 10)) (set! x 20) x)")
    check(result == 20)

  test "set! with calculation":
    let result = lisp("(let ((x 5)) (set! x (+ x 10)) x)")
    check(result == 15)

  test "cond transpiles to if/else":
    let nimCode = lispToNim("(cond ((> x 0) 1) (else -1))")
    check(nimCode.contains("if"))
    check(nimCode.contains("else"))

  test "= for equality":
    let t1 = lisp("(= 5 5)")
    check(t1 == true)
    let t2 = lisp("(= 5 3)")
    check(t2 == false)

  test "<= and >= comparisons":
    let t1 = lisp("(<= 1 2 3)")
    check(t1 == true)
    let t2 = lisp("(<= 1 3 2)")
    check(t2 == false)
    let t3 = lisp("(>= 3 2 1)")
    check(t3 == true)
    let t4 = lisp("(>= 3 1 2)")
    check(t4 == false)

  test "$ stringification":
    let result = lisp("($ 42)")
    check(result == "42")

  test "while loop":
    let result = lisp("(let ((i 0) (acc 0)) (while (< i 3) (set! i (+ i 1)) (set! acc (+ acc 1))) acc)")
    check(result == 3)

  test "apply calls function with single list arg":
    let double = lisp("(lambda ((x int)) (* x 2))")
    let result = lisp("(apply double @[10])")
    check(result == 20)

suite "macro and quasiquote tests":
  test "parser handles quasiquote in macro":
    let nimCode = lispToNim("(defmacro (qq) `(foo))")
    check(nimCode.len > 0)

  test "parser handles unquote in macro body":
    let nimCode = lispToNim("(defmacro (qq x) `(foo ,x))")
    check(nimCode.len > 0)

  test "parser handles unquote-splicing in macro body":
    let nimCode = lispToNim("(defmacro (qq x) `(foo ,@x))")
    check(nimCode.len > 0)

  test "simple macro definition and use":
    let result = lisp("""
(defmacro (double x)
  `(+ ,x ,x))
(double 5)
""")
    check(result == 10)

  test "macro with &rest parameter":
    let result = lisp("""
(defmacro (my-and &rest terms)
  (if (null? terms)
      true
      (if (null? (cdr terms))
          (car terms)
          `(if ,(car terms) (my-and ,@(cdr terms)) false))))
(my-and (> 5 3) (< 5 10) (= 5 5))
""")
    check(result == true)

  test "when macro":
    let result = lisp("""
(defmacro (when test &rest body)
  `(if ,test (progn ,@body) 0))
(when (> 5 3)
  (+ 1 2))
""")
    check(result == 3)

  test "macro produces correct Nim code":
    let nimCode = lispToNim("""
(defmacro (double x)
  `(+ ,x ,x))
(double 5)
""")
    check(nimCode.contains("(5 + 5)"))

  test "defmacro does not emit Nim code":
    let nimCode = lispToNim("""
(defmacro (noop) nil)
(+ 1 2)
""")
    check(not nimCode.contains("discard nil"))
    check(nimCode.contains("(1 + 2)"))
