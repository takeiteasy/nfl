; FizzBuzz implementation in nil
; Run with: nil run examples/fizzbuzz.lisp

(define (fizzbuzz n)
  (cond
    ((== (mod n 15) 0) "FizzBuzz")
    ((== (mod n 3) 0) "Fizz")
    ((== (mod n 5) 0) "Buzz")
    (else ($ n))))

; Use a simple counted loop instead of map (avoids type-changing map issue)
(define (run-fizzbuzz n)
  (if (> n 15)
      0
      (progn
        (echo (fizzbuzz n))
        (run-fizzbuzz (+ n 1))
        0)))

(run-fizzbuzz 1)
(echo "Done!")
