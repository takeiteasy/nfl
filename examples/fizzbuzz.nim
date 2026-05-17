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

proc fizzbuzz(n: auto): auto =
  (if ((n mod 15) == 0): "FizzBuzz" elif ((n mod 3) == 0): "Fizz" elif ((n mod 5) == 0): "Buzz" else: n)

proc print_each(lst: auto): auto =
  (if (lst.len == 0): nil else: (block:
    discard (echo(lst[0]); 0)
    print_each(lst[1..^1])
  ))

print_each(block:
    var r: seq[type(@[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15][0])] = @[]
    for x in @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]:
      r.add((      fizzbuzz)(x))
    r)
echo("Done!")
