template apply(f: untyped, args: untyped): untyped =
  f(args[0])

let t* = true
proc pairp*(x: auto): auto =
  (if (x.len == 0): false else: t)

proc atomp*(x: auto): auto =
  (if pairp(x): false else: t)

proc caar*(x: auto): auto =
  x[0][0]

proc cadr*(x: auto): auto =
  x[1..^1][0]

proc cdar*(x: auto): auto =
  x[0][1..^1]

proc cddr*(x: auto): auto =
  x[1..^1][1..^1]

proc caaar*(x: auto): auto =
  x[0][0][0]

proc caadr*(x: auto): auto =
  x[1..^1][0][0]

proc cadar*(x: auto): auto =
  x[0][1..^1][0]

proc caddr*(x: auto): auto =
  x[1..^1][1..^1][0]

proc cdaar*(x: auto): auto =
  x[0][0][1..^1]

proc cdadr*(x: auto): auto =
  x[1..^1][0][1..^1]

proc cddar*(x: auto): auto =
  x[0][1..^1][1..^1]

proc cdddr*(x: auto): auto =
  x[1..^1][1..^1][1..^1]

proc identity*(x: auto): auto =
  x

proc zerop*(x: auto): auto =
  (x == 0)

proc positivep*(x: auto): auto =
  (x > 0)

proc negativep*(x: auto): auto =
  (x < 0)

proc evenp*(x: auto): auto =
  ((x mod 2) == 0)

proc oddp*(x: auto): auto =
  ((x mod 2) != 0)

proc foldl*(f: auto, init: auto, lst: auto): auto =
  (if (lst.len == 0): init else: foldl(f, f(init, lst[0]), lst[1..^1]))

proc foldr*(f: auto, init: auto, lst: auto): auto =
  (if (lst.len == 0): init else: f(lst[0], foldr(f, init, lst[1..^1])))

proc reduce*(f: auto, lst: auto): auto =
  (if (lst.len == 0): @[] else: foldl(f, lst[0], lst[1..^1]))

proc some*(pred: auto, lst: auto): auto =
  (if (lst.len == 0): false else: (if pred(lst[0]): true else: some(pred, lst[1..^1])))

proc every*(pred: auto, lst: auto): auto =
  (if (lst.len == 0): true else: (if pred(lst[0]): every(pred, lst[1..^1]) else: false))

proc range*(n: auto): auto =
  (if (n == 0): @[] else: (range((n - 1)) & @[(n - 1)]))

proc repeat*(x: auto, n: auto): auto =
  (if (n == 0): @[] else: (@[x] & repeat(x, (n - 1))))

proc take*(n: auto, lst: auto): auto =
  (if (n == 0): @[] else: (if (lst.len == 0): @[] else: (@[lst[0]] & take((n - 1), lst[1..^1]))))

proc drop*(n: auto, lst: auto): auto =
  (if (n == 0): lst else: (if (lst.len == 0): lst else: drop((n - 1), lst[1..^1])))

proc nth*(n: auto, lst: auto): auto =
  drop(n, lst)[0]

proc member*(x: auto, lst: auto): auto =
  (if (lst.len == 0): @[] else: (if (x == lst[0]): lst else: member(x, lst[1..^1])))

proc assoc*(key: auto, alist: auto): auto =
  (if (alist.len == 0): @[] else: (if (key == caar(alist)): alist[0] else: assoc(key, alist[1..^1])))

proc last*(lst: auto): auto =
  (if (lst[1..^1].len == 0): lst[0] else: last(lst[1..^1]))

proc butlast*(lst: auto): auto =
  (if (lst[1..^1].len == 0): @[] else: (@[lst[0]] & butlast(lst[1..^1])))

proc str*(x: auto): auto =
  (if (x.len == 0): "" else: $(x))

