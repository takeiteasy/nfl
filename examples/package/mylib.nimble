# Example nimble file for a library package built on NFL. See
# ../../man/package-layout.md for why `installExt` must list "nfl".

version       = "0.1.0"
author        = "example"
description   = "Worked example: an NFL library importable from plain Nim"
license       = "GPL-3.0-or-later"
srcDir        = "src"
installExt    = @["nim", "nfl"]

requires "nim >= 2.2.4"
requires "nfl"

task test, "Run the consumer example":
  exec "nim c --path:src -r tests/consume.nim"
