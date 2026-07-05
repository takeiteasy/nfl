# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

import std/strutils

# Nim currently rejects `nim c file.nfl` before config.nims can redirect the
# project to a generated wrapper. Revisit this if Nim exposes a frontend hook
# for non-Nim project source files.
let nflProjectPath = projectPath()
if nflProjectPath.endsWith(".nfl"):
  hint("QuitCalled", false)
  quit("NFL source files are compiled through the nfl CLI, not by passing them directly to Nim.\n" &
    "Use: nfl check " & nflProjectPath & "\n" &
    "Or:  nfl compile " & nflProjectPath, 1)
