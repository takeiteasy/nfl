# Package

version       = "0.2.0"
author        = "George Watson"
description   = "Nimp: a small Lisp-inspired processor for Nim"
license       = "GPL-3.0-or-later"
srcDir        = "src"
installExt    = @["nim"]

# Dependencies

requires "nim >= 2.2.4"

task test, "Run tests":
  exec "nim c --path:src -r tests/reader/test_reader.nim"
