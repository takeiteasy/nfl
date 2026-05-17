let t = true
proc pairp(x: auto): auto =
  (if (x.len == 0): false else: t)

proc atomp(x: auto): auto =
  (if pairp(x): false else: t)

proc caar(x: auto): auto =
  x[0][0]

proc cadr(x: auto): auto =
  x[1..^1][0]

proc cdar(x: auto): auto =
  x[0][1..^1]

proc cddr(x: auto): auto =
  x[1..^1][1..^1]

proc caaar(x: auto): auto =
  x[0][0][0]

proc caadr(x: auto): auto =
  x[1..^1][0][0]

proc cadar(x: auto): auto =
  x[0][1..^1][0]

proc caddr(x: auto): auto =
  x[1..^1][1..^1][0]

proc cdaar(x: auto): auto =
  x[0][0][1..^1]

proc cdadr(x: auto): auto =
  x[1..^1][0][1..^1]

proc cddar(x: auto): auto =
  x[0][1..^1][1..^1]

proc cdddr(x: auto): auto =
  x[1..^1][1..^1][1..^1]

proc identity(x: auto): auto =
  x

(block:
  var score = 85
  (if (score >= 90): echo("Grade: A") elif (score >= 80): echo("Grade: B") elif (score >= 70): echo("Grade: C") elif (score >= 60): echo("Grade: D") else: echo("Grade: F"))
)
(block:
  var x = 10
  discard (echo("and test:", (if (x > 5): (x < 20) else: false)); 0)
  echo("or test:", (if (x < 5): (x < 5) else: (x > 20)))
)
(block:
  var n = 7
  (if (n == 0): echo("zero") elif (n == 1): echo("one") elif (n == 2): echo("two") else: echo("many"))
)
