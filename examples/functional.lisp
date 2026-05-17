; Functional programming examples
; Run with: nil run examples/functional.lisp

; map example - apply square to each element
(echo "squares:" (map (lambda ((x int)) (* x x)) @[1, 2, 3, 4, 5]))

; filter example - keep only even numbers
(echo "evens:" (filter (lambda ((x int)) (== (mod x 2) 0)) @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))

; list operations
(echo "car:" (car @[1, 2, 3]))
(echo "cdr:" (cdr @[1, 2, 3]))
(echo "cons:" (cons 0 @[1, 2, 3]))
(echo "append:" (append @[1, 2] @[3, 4]))
(echo "reverse:" (reverse @[1, 2, 3, 4, 5]))
(echo "length:" (length @[1, 2, 3, 4, 5]))

; set! mutation example
(let ((counter 0))
  (set! counter (+ counter 1))
  (echo "counter:" counter))
