# Package

import std/os
import std/tables
import std/json

version       = "1.0.1"
author        = "George Watson"
description   = "NFL: Nim Flavoured Lisp"
license       = "GPL-3.0-or-later"
srcDir        = "src"
installExt    = @["nim"]
binDir        = "bin"
namedBin      = {"nfl/cli": "nfl"}.toTable

# Dependencies

requires "nim >= 2.2.4"

# --- dochack.js bootstrap ---------------------------------------------------
# `nim doc --index:on` builds a full-text search index but needs to copy
# tools/dochack/dochack.js into the output, compiling it from source if
# missing. Some Nim distributions (notably Homebrew's) don't ship `tools/`,
# so docgen crashes with an AssertionDefect. We precompile the matching
# version's dochack.js into the compiler prefix, which makes docgen skip the
# compile step entirely.

proc compilerInfo(): tuple[nimr, version: string] =
  ## Resolve the Nim compiler prefix dir and version via `nim dump`.
  let tmp = getTempDir() / "nfl-dochack"
  exec "mkdir -p " & quoteShell(tmp)
  let src = tmp / "nimdump.nim"
  let json = tmp / "nimdump.json"
  writeFile(src, "echo 0\n")
  exec "nim dump --dump.format:json --hints:off " & quoteShell(src) & " > " &
    quoteShell(json)
  let d = parseJson(readFile(json))
  result = (d["prefixdir"].getStr(), d["version"].getStr())

proc ensureDochack(force = false) =
  ## Install a compiled dochack.js into the Nim compiler prefix if missing.
  let (nimr, version) = compilerInfo()
  let js = nimr / "tools" / "dochack" / "dochack.js"
  if fileExists(js) and not force:
    echo "  dochack.js already present at " & js
    return
  let tmp = getTempDir() / "nfl-dochack"
  exec "mkdir -p " & quoteShell(tmp)
  let base = "https://raw.githubusercontent.com/nim-lang/Nim/v" & version
  echo "  fetching dochack sources for Nim " & version
  exec "curl -fsSL -o " & quoteShell(tmp / "dochack.nim") & " " & base &
    "/tools/dochack/dochack.nim"
  exec "curl -fsSL -o " & quoteShell(tmp / "fuzzysearch.nim") & " " & base &
    "/tools/dochack/fuzzysearch.nim"
  echo "  compiling dochack.js"
  exec "nim js -d:release --outdir:" & quoteShell(tmp) & " " &
    quoteShell(tmp / "dochack.nim")
  exec "mkdir -p " & quoteShell(js.parentDir)
  exec "cp " & quoteShell(tmp / "dochack.js") & " " & quoteShell(js)
  echo "  installed " & js

task test, "Run tests":
  exec "nim c --path:src -r tests/test_reader.nim"
  exec "nim c --path:src -r tests/test_expand.nim"
  exec "nim c --path:src -r tests/test_lower.nim"
  exec "nim c --path:src -r tests/test_backend.nim"
  exec "nim c --path:src -r tests/test_stdlib.nim"
  exec "nim c --path:src --out:src/nfl/nfl src/nfl/cli.nim"
  exec "nim c --path:src -r tests/test_cli.nim"
  exec "nim c --path:src -r tests/test_repl.nim"

task dochack, "Ensure a compiled dochack.js exists in the Nim compiler prefix (for `nim doc --index:on`)":
  ensureDochack()

task docs, "Generate HTML API documentation into docs/ (served via GitHub Pages)":
  # `--index:on` generates the search index (theindex.html, *.idx and
  # dochack.js) and adds a search box to every module page; ensureDochack
  # makes that work on distributions that omit tools/ (e.g. Homebrew).
  #
  # Output goes straight to docs/ (not docs/api/) since GitHub Pages serves
  # a repo's /docs directory directly; prose guides live under /man instead.
  ensureDochack()
  exec "nim doc --project --index:on --path:src --out:docs src/nfl/cli.nim"
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
  <p>Each module page has a full-text search box; you can also browse the
    <a href="theindex.html">complete symbol index</a>.</p>
  <ul>
""" & links & """
  </ul>
</body>
</html>
""")
