# Package

import std/tables

version       = "0.2.0"
author        = "George Watson"
description   = "Nimp: a small Lisp-inspired processor for Nim"
license       = "GPL-3.0-or-later"
srcDir        = "src"
installExt    = @["nim"]
binDir        = "bin"
namedBin      = {"nimp/cli": "nimp"}.toTable

# Dependencies

requires "nim >= 2.2.4"

task test, "Run tests":
  exec "nim c --path:src -r tests/test_reader.nim"
  exec "nim c --path:src -r tests/test_expand.nim"
  exec "nim c --path:src -r tests/test_lower.nim"
  exec "nim c --path:src -r tests/test_backend.nim"
  exec "nim c --path:src -r tests/test_stdlib.nim"
  exec "nim c --path:src --out:src/nimp/nimp src/nimp/cli.nim"
  exec "nim c --path:src -r tests/test_cli.nim"
