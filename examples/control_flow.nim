import std/nilpkg

discard (block:
  var score = 85
  (if (score >= 90): (echo("Grade: A"); 0) elif (score >= 80): (echo("Grade: B"); 0) elif (score >= 70): (echo("Grade: C"); 0) elif (score >= 60): (echo("Grade: D"); 0) else: (echo("Grade: F"); 0)))
discard (block:
  var x = 10
  discard (echo("and test:", (if (x > 5): (x < 20) else: false)); 0)
  (echo("or test:", (if (x < 5): (x < 5) else: (x > 20))); 0))
discard (block:
  var n = 7
  (if (n == 0): (echo("zero"); 0) elif (n == 1): (echo("one"); 0) elif (n == 2): (echo("two"); 0) else: (echo("many"); 0)))
