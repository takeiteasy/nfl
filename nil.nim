# Nim Implementation of Lisp

# Copyright (C) 2025 George Watson

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

import os
import lisp
import osproc
import strutils

type
  CompileMode = enum cmNone, cmCompileOnly, cmCompile, cmCompileAndRun

proc transpile(content: string): string =
  lispToNim(content)

proc runNimCompiler(nimFile: string, mode: CompileMode, nimcacheDir: string = "") =
  var cmd = "nim c --path:. "
  case mode
  of cmNone:
    return
  of cmCompileOnly:
    cmd &= "--compileOnly "
    if nimcacheDir.len > 0:
      cmd &= "--nimcache:" & nimcacheDir & " "
  of cmCompile:
    discard
  of cmCompileAndRun:
    cmd &= "-r "
  cmd &= nimFile
  try:
    let output = execCmd(cmd)
    echo output
    if mode == cmCompileOnly and nimcacheDir.len > 0:
      echo "Generated C files in ", nimcacheDir
  except OSError as e:
    echo "Failed to run compiler: ", e.msg
    echo "You can run this yourself: ", cmd

proc processFile(inFilename: string, mode: CompileMode) =
  if not fileExists(inFilename):
    echo "Error: file not found: ", inFilename
    quit(1)
  let content = readFile(inFilename)
  let nimCode = transpile(content)
  let outFilename = changeFileExt(inFilename, ".nim")
  writeFile(outFilename, nimCode)
  echo "Wrote ", outFilename

  if mode == cmCompileOnly:
    let cDir = changeFileExt(inFilename, "_c")
    runNimCompiler(outFilename, mode, cDir)
  else:
    runNimCompiler(outFilename, mode)

proc doRepl() =
  echo "nil repl (type Ctrl-D to exit)"
  var accumulated = ""
  var parenDepth = 0
  var bracketDepth = 0
  var inString = false
  var stringEscape = false

  proc countDelimiters(s: string) =
    parenDepth = 0
    bracketDepth = 0
    inString = false
    stringEscape = false
    for ch in s:
      if stringEscape:
        stringEscape = false
        continue
      if ch == '\\' and inString:
        stringEscape = true
        continue
      if ch == '"':
        inString = not inString
        continue
      if inString:
        continue
      case ch
      of '(': parenDepth += 1
      of ')': parenDepth -= 1
      of '[': bracketDepth += 1
      of ']': bracketDepth -= 1
      else: discard

  proc isComplete(s: string): bool =
    countDelimiters(s)
    return parenDepth == 0 and bracketDepth == 0 and not inString

  let tmpDir = getTempDir()
  let tmpBase = tmpDir / "nil_repl_" & $getCurrentProcessId()

  while true:
    try:
      let prompt = if accumulated.len > 0: "... " else: "> "
      stdout.write prompt
      stdout.flushFile()
      let line = stdin.readLine()

      if accumulated.len > 0:
        accumulated &= "\n" & line
      else:
        accumulated = line

      if not isComplete(accumulated):
        continue

      let nimCode = lispToNim(accumulated)
      accumulated = ""

      if nimCode.len == 0:
        continue

      let tmpNim = tmpBase & ".nim"
      writeFile(tmpNim, nimCode)

      let tmpExe = tmpBase & (if defined(windows): ".exe" else: "")
      let cmd = "nim c --hints:off --warnings:off -o:" & tmpExe & " " & tmpNim
      let exitCode = execCmd(cmd)

      if exitCode == 0:
        let output = execProcess(tmpExe)
        if output.len > 0:
          stdout.write output
      else:
        echo "Compilation error"

      try:
        removeFile(tmpNim)
        if fileExists(tmpExe):
          removeFile(tmpExe)
      except:
        discard

    except EOFError:
      echo ""
      break
    except Exception as e:
      echo "Error: ", e.msg
      accumulated = ""

proc showHelp() =
  echo "nil (Nim Implementation of Lisp)"
  echo "https://github.com/takeiteasy/nil"
  echo ""
  echo "Usage:"
  echo "  nil run <file>       # transpile -> compile -> run a .lisp/.nil file"
  echo "  nil compile <file>   # transpile -> compile to executable"
  echo "  nil transpile <file>     # emit a .nim file from input"
  echo "  nil transpile -c <file>  # emit C source files from input"
  echo "  nil repl             # interactive REPL (prints generated Nim)"
  echo "  nil -h|--help        # show this help"

proc main() =
  if paramCount() == 0:
    showHelp()
    return

  let cmd = paramStr(1)
  case cmd
  of "run":
    if paramCount() < 2:
      echo "run requires a filename"
      quit(1)
    processFile(paramStr(2), cmCompileAndRun)
  of "compile":
    if paramCount() < 2:
      echo "compile requires a filename"
      quit(1)
    processFile(paramStr(2), cmCompile)
  of "transpile":
    if paramCount() < 2:
      echo "transpile requires a filename"
      quit(1)
    if paramStr(2) == "-c":
      if paramCount() < 3:
        echo "transpile -c requires a filename"
        quit(1)
      processFile(paramStr(3), cmCompileOnly)
    else:
      processFile(paramStr(2), cmNone)
  of "repl":
    doRepl()
  of "-h", "--help":
    showHelp()
  else:
    echo "Unknown command: ", cmd
    showHelp()
    quit(1)

when isMainModule:
  main()
