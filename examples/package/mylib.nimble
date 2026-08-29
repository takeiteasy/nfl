# Example nimble file for a library package built on LFN. See
# ../../man/package-layout.md for why `installExt` must list "lfn".

version       = "0.1.0"
author        = "example"
description   = "Worked example: an LFN library importable from plain Nim"
license       = "GPL-3.0-or-later"
srcDir        = "src"
installExt    = @["nim", "lfn"]

requires "nim >= 2.2.4"
requires "lfn"

task test, "Run the consumer example":
  exec "nim c --path:src -r tests/consume.nim"
