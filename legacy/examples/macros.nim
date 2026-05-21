import std/nilpkg

discard (echo("Double of 5: ", (5 + 5)); 0)
discard (echo("Double of 10: ", (10 + 10)); 0)
discard (echo("Testing when:"); 0)
discard (if (10 > 5): (block:
  (echo("  10 is greater than 5"); 0)
) else: 0)
discard (if (3 > 5): (block:
  (echo("  This should not print"); 0)
) else: 0)
discard (echo("Testing unless:"); 0)
discard (if (3 > 5): 0 else: (block:
  (echo("  3 is NOT greater than 5"); 0)
))
discard (echo("Testing my-and:"); 0)
discard (echo("  (my-and true true true): ", (if true: (if true: true else: false) else: false)); 0)
discard (echo("  (my-and true false true): ", (if true: (if false: true else: false) else: false)); 0)
proc first*(lst: auto): auto =
  lst[0]

proc rest*(lst: auto): auto =
  lst[1..^1]

discard (block:
  var data = @[1, 2, 3, 4, 5]
  discard (echo("First element: ", first(data)); 0)
  (echo("Rest of list: ", rest(data)); 0))
discard (echo("Testing my-cond:"); 0)
discard (block:
  var n = 7
  discard (echo("  n = ", n); 0)
  (if (n < 0): (echo("    negative"); 0) else: (if (n == 0): (echo("    zero"); 0) else: (if (n < 5): (echo("    small"); 0) else: (if (n >= 5): (echo("    big"); 0) else: 0)))))
