import std/os
import std/osproc
import std/streams
import std/strutils
import std/unittest

proc runCommand(exe: string; args: seq[string]): tuple[output: string; exitCode: int] =
  let process = startProcess(exe, args = args, options = {})
  result.output = process.outputStream().readAll()
  result.exitCode = process.waitForExit()
  process.close()

let cliExe = getCurrentDir() / "src" / "nimp" / "cli"

suite "nimp cli":
  test "checks example file":
    let (_, exitCode) = runCommand(cliExe, @["check", "examples/simple.nimp"])
    check exitCode == 0

  test "runs example file":
    let (output, exitCode) = runCommand(cliExe, @["run", "examples/simple.nimp"])
    check exitCode == 0
    check output.contains("NIMP")

  test "handles paths with spaces":
    let dir = getTempDir() / "nimp cli path with spaces"
    createDir(dir)
    let file = dir / "hello world.nimp"
    writeFile(file, "(echo \"space path ok\")\n")

    let (output, exitCode) = runCommand(cliExe, @["run", file])
    check exitCode == 0
    check output.contains("space path ok")
