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

discard (echo("squares:", block:
    var r: seq[type(@[1, 2, 3, 4, 5][0])] = @[]
    for x in @[1, 2, 3, 4, 5]:
      r.add((      (proc(x: int): auto =
        (x * x)
      ))(x))
    r); 0)
discard (echo("evens:", block:
    var r: seq[type(@[1, 2, 3, 4, 5, 6, 7, 8, 9, 10][0])] = @[]
    for x in @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]:
      if (      (proc(x: int): auto =
        ((x mod 2) == 0)
      ))(x):
        r.add(x)
    r); 0)
discard (echo("car:", @[1, 2, 3][0]); 0)
discard (echo("cdr:", @[1, 2, 3][1..^1]); 0)
discard (echo("cons:", (@[0] & @[1, 2, 3])); 0)
discard (echo("append:", (@[1, 2] & @[3, 4])); 0)
discard (echo("reverse:", block:
  var revtmp = @[1, 2, 3, 4, 5]
  for i in 0 .. revtmp.len div 2 - 1:
    let j = revtmp.len - 1 - i
    let tmp = revtmp[i]
    revtmp[i] = revtmp[j]
    revtmp[j] = tmp
  revtmp); 0)
discard (echo("length:", (@[1, 2, 3, 4, 5].len)); 0)
discard (block:
  var counter = 0
  discard (block: counter = (counter + 1); counter)
  echo("counter:", counter)
)
