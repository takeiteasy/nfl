template apply(f: untyped, args: untyped): untyped =
  f(args[0])

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

proc zerop(x: auto): auto =
  (x == 0)

proc positivep(x: auto): auto =
  (x > 0)

proc negativep(x: auto): auto =
  (x < 0)

proc evenp(x: auto): auto =
  ((x mod 2) == 0)

proc oddp(x: auto): auto =
  ((x mod 2) != 0)

