import std/cmdline
import std/os
import std/osproc
import std/times

import ./compiler
import ./diagnostics
import ./syntax

type
  Command = enum
    cmdRun = "run"
    cmdCompile = "compile"
    cmdCheck = "check"
    cmdMacroexpand = "macroexpand"

  CliOptions = object
    command: Command
    autoloadCore: bool
    input: string
    inputDisplay: string

  ParseResult = object
    ok: bool
    exitCode: int
    showUsage: bool
    options: CliOptions

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
  stderr.writeLine "usage: nfl <run|compile|check|macroexpand> [--no-core] file.nfl"

proc parseCommand(value: string): Command =
  case value
  of "run": cmdRun
  of "compile": cmdCompile
  of "check": cmdCheck
  of "macroexpand": cmdMacroexpand
  else:
    raise newException(ValueError, "unknown command: " & value)

proc parseOptions(args: seq[string]): ParseResult =
  if args.len == 0:
    return ParseResult(ok: false, exitCode: 2, showUsage: true)
  if args[0] in ["-h", "--help"]:
    return ParseResult(ok: false, exitCode: 0, showUsage: true)

  try:
    result.options.command = parseCommand(args[0])
  except ValueError:
    return ParseResult(ok: false, exitCode: 2, showUsage: true)

  result.options.autoloadCore = true
  var inputArg = ""
  if args.len > 1:
    for arg in args[1..^1]:
      case arg
      of "--no-core":
        result.options.autoloadCore = false
      else:
        if inputArg.len != 0:
          return ParseResult(ok: false, exitCode: 2, showUsage: true)
        inputArg = arg

  if inputArg.len == 0:
    return ParseResult(ok: false, exitCode: 2, showUsage: true)

  result.ok = true
  result.options.inputDisplay = inputArg
  result.options.input = absolutePath(inputArg)

proc repoSrcPath(): string =
  let candidate = getCurrentDir() / "src"
  if dirExists(candidate / "nfl"):
    absolutePath(candidate)
  else:
    ""

proc defaultOutputPath(input: string): string =
  changeFileExt(input, ExeExt)

proc tempBuildDir(): string =
  getTempDir() / ("nfl-" & $getCurrentProcessId() & "-" & $epochTime())

proc wrapperSource(input: string; autoloadCore: bool): string =
  "import nfl/compiler\n" &
    "nflModule(staticRead(" & nimStringLit(input) & "), " &
    nimStringLit(input) & ", autoloadCore = " & $autoloadCore & ")\n"

proc runNim(args: seq[string]): int =
  let nimExe = findExe("nim")
  if nimExe.len == 0:
    stderr.writeLine "nfl: nim executable not found in PATH"
    return 1
  let process = startProcess(nimExe, args = args, options = {poParentStreams})
  result = process.waitForExit()
  process.close()

proc nimArgsFor(options: CliOptions; wrapper: string): seq[string] =
  case options.command
  of cmdRun:
    result.add @["c", "-r"]
  of cmdCompile:
    result.add "c"
    result.add "--out:" & defaultOutputPath(options.input)
  of cmdCheck:
    result.add "check"
  of cmdMacroexpand:
    discard

  let srcPath = repoSrcPath()
  if srcPath.len > 0:
    result.add "--path:" & srcPath
  result.add wrapper

proc macroexpand(options: CliOptions): int =
  try:
    for form in expandSource(readFile(options.input), options.input, options.autoloadCore):
      stdout.writeLine form.renderSyntax()
    0
  except ReaderError as err:
    stderr.writeLine $err.diagnostic
    1
  except CompilerError as err:
    stderr.writeLine $err.diagnostic
    1

proc compileViaNim(options: CliOptions): int =
  let tempDir = tempBuildDir()
  createDir(tempDir)
  let wrapper = tempDir / "wrapper.nim"
  writeFile(wrapper, wrapperSource(options.input, options.autoloadCore))

  result = runNim(nimArgsFor(options, wrapper))
  if result == 0:
    removeDir(tempDir)
  else:
    stderr.writeLine "nfl: preserved temporary build directory: " & tempDir

proc main(): int =
  let parsed = parseOptions(commandLineParams())
  if not parsed.ok:
    if parsed.showUsage:
      usage()
    return parsed.exitCode

  let options = parsed.options

  if not fileExists(options.input):
    stderr.writeLine "nfl: file not found: " & options.inputDisplay
    return 1

  case options.command
  of cmdMacroexpand:
    macroexpand(options)
  of cmdRun, cmdCompile, cmdCheck:
    compileViaNim(options)

when isMainModule:
  quit main()
