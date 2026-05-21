import std/nilpkg

discard (echo("squares:", (block:
  var r: seq[typeof(@[1, 2, 3, 4, 5][0])] = @[]
  for x in @[1, 2, 3, 4, 5]:
    r.add((    (proc(x: int): auto =
      (x * x)
    ))(x))
  r)); 0)
discard (echo("evens:", (block:
  var r: seq[typeof(@[1, 2, 3, 4, 5, 6, 7, 8, 9, 10][0])] = @[]
  for x in @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]:
    if (    (proc(x: int): auto =
      ((x mod 2) == 0)
    ))(x):
      r.add(x)
  r)); 0)
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
  (echo("counter:", counter); 0))
