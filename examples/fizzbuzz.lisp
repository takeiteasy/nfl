; FizzBuzz implementation in nil
; Run with: nil run examples/fizzbuzz.lisp

(define (fizzbuzz n)
  (cond
    ((== (mod n 15) 0) "FizzBuzz")
    ((== (mod n 3) 0) "Fizz")
    ((== (mod n 5) 0) "Buzz")
    (else n)))

(define (print-each lst)
  (if (null? lst)
      nil
      (progn
        (echo (car lst))
        (print-each (cdr lst)))))

(print-each (map fizzbuzz @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]))
(echo "Done!")
