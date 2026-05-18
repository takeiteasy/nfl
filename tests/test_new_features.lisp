; Test new features

; 1. nil as distinct type
(define (test-nil)
  (echo "nil is null?: " (null? nil))
  (echo "nil is list?: " (list? nil))
  (echo "if nil: " (if nil "truthy" "falsy")))

(test-nil)

; 2. let*
(define (test-letstar)
  (let* ((x 1)
         (y (+ x 1))
         (z (+ y 1)))
    (echo "let*: " z)))

(test-letstar)

; 3. swap
(define (test-swap)
  (let ((a 1) (b 2))
    (swap a b)
    (echo "swap: a=" a " b=" b)))

(test-swap)

; 4. thread-first ->
(define (test-thread-first)
  (echo "->: " (-> 5 (+ 1) (* 2))))

(test-thread-first)

; 5. thread-last ->>
(define (test-thread-last)
  (echo "->>: " (->> (list 1 2 3 4 5)
                     (filter (lambda ((x int)) (> x 2)))
                     (map (lambda ((x int)) (* x 10))))))

(test-thread-last)

; 6. case
(define (test-case n)
  (case n
    ((1 2 3) (echo "small: " n))
    ((4 5 6) (echo "medium: " n))
    (else (echo "large: " n))))

(test-case 2)
(test-case 5)
(test-case 9)

; 7. match
(define (test-match lst)
  (match lst
    ((list x y) (echo "two elements: " x ", " y))
    ((list x y z) (echo "three elements: " x ", " y ", " z))
    (else (echo "other length"))))

(test-match (list 1 2))
(test-match (list 1 2 3))
(test-match (list 1 2 3 4))
