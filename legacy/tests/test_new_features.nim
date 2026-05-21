import std/nilpkg

proc test_nil*(): auto =
  discard (echo("nil is null?: ", (@[].len == 0)); 0)
  discard (echo("nil is list?: ", compiles(@[][0])); 0)
  (echo("if nil: ", (if (@[].len != 0): "truthy" else: "falsy")); 0)

discard test_nil()
proc test_letstar*(): auto =
  (block:
    var x = 1
    (block:
      var y = (x + 1)
      (block:
        var z = (y + 1)
        (block:
          (echo("let*: ", z); 0)))))

discard test_letstar()
proc test_swap*(): auto =
  (block:
    var a = 1
    var b = 2
    discard (block:
      var swap_1 = a
      discard (block: a = b; a)
      (block: b = swap_1; b))
    (echo("swap: a=", a, " b=", b); 0))

discard test_swap()
proc test_thread_first*(): auto =
  (echo("->: ", ((5 + 1) * 2)); 0)

discard test_thread_first()
proc test_thread_last*(): auto =
  (echo("->>: ", (block:
    var r: seq[typeof((block:
    var r: seq[typeof(@[1, 2, 3, 4, 5][0])] = @[]
    for x in @[1, 2, 3, 4, 5]:
      if (    (proc(x: int): auto =
        (x > 2)
      ))(x):
        r.add(x)
    r)[0])] = @[]
    for x in (block:
    var r: seq[typeof(@[1, 2, 3, 4, 5][0])] = @[]
    for x in @[1, 2, 3, 4, 5]:
      if (    (proc(x: int): auto =
        (x > 2)
      ))(x):
        r.add(x)
    r):
      r.add((    (proc(x: int): auto =
        (x * 10)
      ))(x))
    r)); 0)

discard test_thread_last()
proc test_case*(n: auto): auto =
  (if (n == 1): (block:
    (echo("small: ", n); 0)
  ) else: (if (n == 2): (block:
    (echo("small: ", n); 0)
  ) else: (if (n == 3): (block:
    (echo("small: ", n); 0)
  ) else: (if (n == 4): (block:
    (echo("medium: ", n); 0)
  ) else: (if (n == 5): (block:
    (echo("medium: ", n); 0)
  ) else: (if (n == 6): (block:
    (echo("medium: ", n); 0)
  ) else: (block:
    (echo("large: ", n); 0)
  )))))))

discard test_case(2)
discard test_case(5)
discard test_case(9)
proc test_match*(lst: auto): auto =
  (block:
    var match_2 = lst
    (if compiles(match_2[0]): (if ((match_2.len) == 2): (block:
      var x = (0[match_2])
      (block:
        var y = ((0 + 1)[match_2])
        (block:
          (echo("two elements: ", x, ", ", y); 0)
        ))) else: (block:
      var match_3 = match_2
      (if compiles(match_3[0]): (if ((match_3.len) == 3): (block:
        var x = (0[match_3])
        (block:
          var y = ((0 + 1)[match_3])
          (block:
            var z = (((0 + 1) + 1)[match_3])
            (block:
              (echo("three elements: ", x, ", ", y, ", ", z); 0)
            )))) else: (block:
        (echo("other length"); 0)
      )) else: (block:
        (echo("other length"); 0)
      )))) else: (block:
      var match_4 = match_2
      (if compiles(match_4[0]): (if ((match_4.len) == 3): (block:
        var x = (0[match_4])
        (block:
          var y = ((0 + 1)[match_4])
          (block:
            var z = (((0 + 1) + 1)[match_4])
            (block:
              (echo("three elements: ", x, ", ", y, ", ", z); 0)
            )))) else: (block:
        (echo("other length"); 0)
      )) else: (block:
        (echo("other length"); 0)
      )))))

discard test_match(@[1, 2])
discard test_match(@[1, 2, 3])
discard test_match(@[1, 2, 3, 4])
