import std/cmdline
import std/os
import std/osproc
import std/times

proc nimStringLit(s: string): string =
  result = "\""
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else: result.add c
  result.add '"'

proc usage() =
  stderr.writeLine "usage: nimp <run|compile|check> file.nimp"

proc repoSrcPath(): string =
  let candidate = getCurrentDir() / "src"
  if dirExists(candidate / "nimp"):
    absolutePath(candidate)
  else:
    ""

proc runNim(args: seq[string]): int =
  let nimExe = findExe("nim")
  if nimExe.len == 0:
    stderr.writeLine "nimp: nim executable not found in PATH"
    return 1
  let process = startProcess(nimExe, args = args, options = {poParentStreams})
  result = process.waitForExit()
  process.close()

proc main(): int =
  let args = commandLineParams()
  if args.len != 2:
    usage()
    return 2

  let command = args[0]
  if command notin ["run", "compile", "check"]:
    usage()
    return 2

  let input = absolutePath(args[1])
  if not fileExists(input):
    stderr.writeLine "nimp: file not found: " & args[1]
    return 1

  let tempDir = getTempDir() / ("nimp-" & $getCurrentProcessId() & "-" & $epochTime())
  createDir(tempDir)
  let wrapper = tempDir / "wrapper.nim"
  writeFile(wrapper,
    "import nimp/compiler\n" &
    "nimpModule(staticRead(" & nimStringLit(input) & "), " & nimStringLit(input) & ")\n")

  var nimArgs: seq[string] = @[]
  case command
  of "run": nimArgs.add @["c", "-r"]
  of "compile": nimArgs.add "c"
  of "check": nimArgs.add "check"
  else: discard

  let srcPath = repoSrcPath()
  if srcPath.len > 0:
    nimArgs.add "--path:" & srcPath
  nimArgs.add wrapper

  result = runNim(nimArgs)

when isMainModule:
  quit main()
