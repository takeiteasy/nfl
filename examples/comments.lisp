; Comments example
; Run with: nil run examples/comments.lisp

; This is a line comment

#| This is a
   block comment
   spanning multiple lines |#

(echo "Comments work!") ; inline comment

; Block comment in the middle of code
(stdout.write "Before ") #| ignored |# (echo "after")
