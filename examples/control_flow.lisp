; Control flow examples
; Run with: nil run examples/control_flow.lisp

; cond example
(let ((score 85))
  (cond
    ((>= score 90) (echo "Grade: A"))
    ((>= score 80) (echo "Grade: B"))
    ((>= score 70) (echo "Grade: C"))
    ((>= score 60) (echo "Grade: D"))
    (else (echo "Grade: F"))))

; and/or with short-circuit evaluation
(let ((x 10))
  (echo "and test:" (and (> x 5) (< x 20)))
  (echo "or test:" (or (< x 5) (> x 20))))

; nested cond
(let ((n 7))
  (cond
    ((== n 0) (echo "zero"))
    ((== n 1) (echo "one"))
    ((== n 2) (echo "two"))
    (else (echo "many"))))
