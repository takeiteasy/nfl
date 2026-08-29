# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

import std/strutils

# Nim currently rejects `nim c file.lfn` before config.nims can redirect the
# project to a generated wrapper. Revisit this if Nim exposes a frontend hook
# for non-Nim project source files.
let lfnProjectPath = projectPath()
if lfnProjectPath.endsWith(".lfn"):
  hint("QuitCalled", false)
  quit("LFN source files are compiled through the lfn CLI, not by passing them directly to Nim.\n" &
    "Use: lfn check " & lfnProjectPath & "\n" &
    "Or:  lfn compile " & lfnProjectPath, 1)
