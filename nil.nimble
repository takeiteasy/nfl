# Package

version       = "0.1.0"
author        = "George Watson"
description   = "Lisp interpreter in Nim"
license       = "GPL-3.0-or-later"
srcDir        = "."
installExt    = @["nim"]
bin           = @["nil"]

# Dependencies

requires "nim >= 2.2.4"

task test, "Run tests":
  exec "nim c --path:. -r tests/test_lisp.nim"

task build, "Build lisp interpreter":
  exec "nim c --path:. lisp.nim -o:nil"

task buildStd, "Build std/std.nim from std/std.nil":
  exec "nim c --path:. -r build_std.nim"