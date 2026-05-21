# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

import std/strutils

let nimpProjectPath = projectPath()
if nimpProjectPath.endsWith(".nimp"):
  hint("QuitCalled", false)
  quit("Nimp source files are compiled through the nimp CLI, not by passing them directly to Nim.\n" &
    "Use: nimp check " & nimpProjectPath & "\n" &
    "Or:  nimp compile " & nimpProjectPath, 1)
