import std/os
import std/osproc
import std/streams
import std/strutils
import std/unittest

proc runCommand(exe: string; args: seq[string]): tuple[output: string; exitCode: int] =
  let process = startProcess(exe, args = args, options = {poStdErrToStdOut})
  result.output = process.outputStream().readAll()
  result.exitCode = process.waitForExit()
  process.close()

proc writeTempNimp(dirName, fileName, source: string): string =
  let dir = getTempDir() / dirName
  createDir(dir)
  result = dir / fileName
  writeFile(result, source)

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
    let file = writeTempNimp("nimp cli path with spaces", "hello world.nimp", "(echo \"space path ok\")\n")

    let (output, exitCode) = runCommand(cliExe, @["run", file])
    check exitCode == 0
    check output.contains("space path ok")

  test "can disable core autoload":
    let file = writeTempNimp("nimp cli no core", "no core.nimp", "(when true (echo \"loaded\"))\n")

    let (_, exitCode) = runCommand(cliExe, @["check", "--no-core", file])
    check exitCode != 0

  test "reader errors point at nimp source":
    let file = writeTempNimp("nimp cli reader diagnostic", "reader error.nimp", "\n(define x \"unterminated\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & ":2:11")
    check output.contains("unterminated string literal")

  test "lowering errors point at nimp source":
    let file = writeTempNimp("nimp cli lower diagnostic", "lower error.nimp", "\n(let ((x 1))\n  (set! x 2)\n  x)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & ":3:9")
    check output.contains("immutable binding")

  test "macro errors point at macro call site":
    let file = writeTempNimp("nimp cli macro diagnostic", "macro error.nimp", "\n(defmacro fail () (macro-error \"boom\"))\n(fail)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & ":3:1")
    check output.contains("error expanding macro fail")
    check output.contains("boom")

  test "nim type errors point at nimp source":
    let file = writeTempNimp("nimp cli type diagnostic", "type error.nimp", "\n\n(define x (+ 1 \"bad\"))\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & "(3, 12)")
    check output.contains("type mismatch")
