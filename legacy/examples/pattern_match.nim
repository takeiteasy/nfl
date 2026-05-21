import std/nilpkg

discard (echo("Dotimes test:"); 0)
discard (block:
  var i = 0
  (block:
    while (i < 5):
      discard (echo("  i = ", i); 0)
      discard (block: i = (i + 1); i)
    nil))
discard (echo("While* test:"); 0)
discard (block:
  var count = 0
  (block:
    while (count < 3):
      discard (block:
        discard (echo("  count = ", count); 0)
        (block: count = (count + 1); count)
      )
    nil))
let pi* = 3.14159
let greeting* = "Hello from macro!"
discard (echo("Constants test:"); 0)
discard (echo("  pi = ", pi); 0)
discard (echo("  greeting = ", greeting); 0)
discard (echo("Repeat test:"); 0)
discard (block:
  var i = 0
  (block:
    while (i < 3):
      discard (echo("  repeating..."); 0)
      discard (block: i = (i + 1); i)
    nil))
discard (echo("Incf test:"); 0)
discard (block:
  var counter = 0
  discard (block: counter = (counter + 1); counter)
  discard (block: counter = (counter + 1); counter)
  discard (block: counter = (counter + 1); counter)
  (echo("  counter = ", counter); 0))
proc square*(x: auto): auto =
  (x * x)

discard (echo("Square function:"); 0)
discard (echo("  square(5) = ", square(5)); 0)
discard (echo("  square(10) = ", square(10)); 0)
