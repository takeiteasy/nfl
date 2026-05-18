; Macros example - demonstrates defmacro, quasiquote, unquote
; Run with: nil run examples/macros.lisp

; Simple macro: double a value at compile time
(defmacro (double x)
  `(+ ,x ,x))

(echo "Double of 5: " (double 5))
(echo "Double of 10: " (double 10))

; when macro: conditional without else branch
(defmacro (when test &rest body)
  `(if ,test (progn ,@body) 0))

(echo "Testing when:")
(when (> 10 5)
  (echo "  10 is greater than 5"))

(when (> 3 5)
  (echo "  This should not print"))

; unless macro: conditional that runs when test is false
(defmacro (unless test &rest body)
  `(if ,test 0 (progn ,@body)))

(echo "Testing unless:")
(unless (> 3 5)
  (echo "  3 is NOT greater than 5"))

; Recursive macro: my-and short-circuits evaluation
(defmacro (my-and &rest terms)
  (if (null? terms)
      true
      (if (null? (cdr terms))
          (car terms)
          `(if ,(car terms) (my-and ,@(cdr terms)) false))))

(echo "Testing my-and:")
(echo "  (my-and true true true): " (my-and true true true))
(echo "  (my-and true false true): " (my-and true false true))

; define-accessor macro: creates simple accessor functions
(defmacro (define-accessor name getter)
  `(define (,name lst) (,getter lst)))

(define-accessor first car)
(define-accessor rest cdr)

(let ((data '(1 2 3 4 5)))
  (echo "First element: " (first data))
  (echo "Rest of list: " (rest data)))

; cond-like macro: multi-branch using nested ifs
(defmacro (my-cond &rest clauses)
  (if (null? clauses)
      0
      (let ((clause (car clauses)))
        (let ((test (car clause)))
          (let ((body (cdr clause)))
            (if (null? (cdr body))
                `(if ,test ,(car body) (my-cond ,@(cdr clauses)))
                `(if ,test (progn ,@body) (my-cond ,@(cdr clauses)))))))))

(echo "Testing my-cond:")
(let ((n 7))
  (echo "  n = " n)
  (my-cond
    ((< n 0) (echo "    negative"))
    ((= n 0) (echo "    zero"))
    ((< n 5) (echo "    small"))
    ((>= n 5) (echo "    big"))))
