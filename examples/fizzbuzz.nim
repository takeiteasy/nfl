import std/nilpkg

proc fizzbuzz(n: auto): auto =
  (if ((n mod 15) == 0): "FizzBuzz" elif ((n mod 3) == 0): "Fizz" elif ((n mod 5) == 0): "Buzz" else: $(n))

proc run_fizzbuzz(n: auto): auto =
  (if (n > 15): 0 else: (block:
    discard (echo(fizzbuzz(n)); 0)
    discard run_fizzbuzz((n + 1))
    0
  ))

discard run_fizzbuzz(1)
discard (echo("Done!"); 0)
