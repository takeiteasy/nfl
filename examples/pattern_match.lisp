; Advanced macros example
; Run with: nil run examples/pattern_match.lisp

; dotimes macro: loop n times
(defmacro (dotimes var count &rest body)
  `(let ((,var 0))
     (while (< ,var ,count)
       ,@body
       (set! ,var (+ ,var 1)))))

(echo "Dotimes test:")
(dotimes i 5
  (echo "  i = " i))

; while* macro: while with implicit progn
(defmacro (while* test &rest body)
  `(while ,test (progn ,@body)))

(echo "While* test:")
(let ((count 0))
  (while* (< count 3)
    (echo "  count = " count)
    (set! count (+ count 1))))

; define-constant macro
(defmacro (define-constant name value)
  `(define ,name ,value))

(define-constant pi 3.14159)
(define-constant greeting "Hello from macro!")

(echo "Constants test:")
(echo "  pi = " pi)
(echo "  greeting = " greeting)

; repeat macro: run body n times
(defmacro (repeat n &rest body)
  `(let ((i 0))
     (while (< i ,n)
       ,@body
       (set! i (+ i 1)))))

(echo "Repeat test:")
(repeat 3
  (echo "  repeating..."))

; incf macro: increment place
(defmacro (incf place)
  `(set! ,place (+ ,place 1)))

(echo "Incf test:")
(let ((counter 0))
  (incf counter)
  (incf counter)
  (incf counter)
  (echo "  counter = " counter))

; Simple function definition
(define (square x)
  (* x x))

(echo "Square function:")
(echo "  square(5) = " (square 5))
(echo "  square(10) = " (square 10))
