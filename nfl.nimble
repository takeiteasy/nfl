# Package

import std/os
import std/tables

version       = "0.2.0"
author        = "George Watson"
description   = "NFL: Nim Flavoured Lisp"
license       = "GPL-3.0-or-later"
srcDir        = "src"
installExt    = @["nim"]
binDir        = "bin"
namedBin      = {"nfl/cli": "nfl"}.toTable

# Dependencies

requires "nim >= 2.2.4"

task test, "Run tests":
  exec "nim c --path:src -r tests/test_reader.nim"
  exec "nim c --path:src -r tests/test_expand.nim"
  exec "nim c --path:src -r tests/test_lower.nim"
  exec "nim c --path:src -r tests/test_backend.nim"
  exec "nim c --path:src -r tests/test_stdlib.nim"
  exec "nim c --path:src --out:src/nfl/nfl src/nfl/cli.nim"
  exec "nim c --path:src -r tests/test_cli.nim"

task docs, "Generate HTML API documentation into docs/ (served via GitHub Pages)":
  # --index:off: nim doc's search index requires compiling
  # tools/dochack.nim to JS, which some Nim distributions (e.g. Homebrew's)
  # don't ship, crashing docgen. We skip it and write a plain module-list
  # index below instead.
  #
  # Output goes straight to docs/ (not docs/api/) since GitHub Pages serves
  # a repo's /docs directory directly; prose guides live under /man instead.
  exec "nim doc --project --index:off --path:src --out:docs src/nfl/cli.nim"
  var links = ""
  for f in listFiles("src/nfl"):
    if f.splitFile.ext == ".nim":
      let name = f.splitFile.name
      links.add "    <li><a href=\"" & name & ".html\">" & name & "</a></li>\n"
  writeFile("docs/index.html", """
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>NFL API documentation</title>
  <link rel="stylesheet" href="nimdoc.out.css">
</head>
<body>
  <h1>NFL API documentation</h1>
  <ul>
""" & links & """
  </ul>
</body>
</html>
""")
