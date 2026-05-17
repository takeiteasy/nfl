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

echo("Comments work!")
stdout.write("Before ")
echo("after")
