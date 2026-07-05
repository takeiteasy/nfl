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

proc writeTempNfl(dirName, fileName, source: string): string =
  let dir = getTempDir() / dirName
  createDir(dir)
  result = dir / fileName
  writeFile(result, source)

proc writeTempNim(dirName, fileName, source: string): string =
  let dir = getTempDir() / dirName
  createDir(dir)
  result = dir / fileName
  writeFile(result, source)

let cliExe = getCurrentDir() / "src" / "nfl" / "nfl"

suite "nfl cli":
  test "checks example files":
    for file in walkFiles("examples/*.nfl"):
      let (_, exitCode) = runCommand(cliExe, @["check", file])
      check exitCode == 0

  test "runs example files":
    for file in walkFiles("examples/*.nfl"):
      let (output, exitCode) = runCommand(cliExe, @["run", file])
      check exitCode == 0
      check not output.contains("Error:")

  test "simple example produces expected output":
    let (output, exitCode) = runCommand(cliExe, @["run", "examples/simple.nfl"])
    check exitCode == 0
    check output.contains("NFL")

  test "handles paths with spaces":
    let file = writeTempNfl("nfl cli path with spaces", "hello world.nfl", "(echo \"space path ok\")\n")

    let (output, exitCode) = runCommand(cliExe, @["run", file])
    check exitCode == 0
    check output.contains("space path ok")

  test "compile writes binary next to input":
    let file = writeTempNfl("nfl cli compile output", "compiled.nfl", "(echo \"compiled ok\")\n")
    let outputExe = changeFileExt(file, ExeExt)
    if fileExists(outputExe):
      removeFile(outputExe)

    let (_, compileExit) = runCommand(cliExe, @["compile", file])
    check compileExit == 0
    check fileExists(outputExe)

    let (output, runExit) = runCommand(outputExe, @[])
    check runExit == 0
    check output.contains("compiled ok")

  test "compile handles output paths with spaces":
    let file = writeTempNfl("nfl cli compile path with spaces", "hello world.nfl", "(echo \"compiled space path ok\")\n")
    let outputExe = changeFileExt(file, ExeExt)
    if fileExists(outputExe):
      removeFile(outputExe)

    let (_, compileExit) = runCommand(cliExe, @["compile", file])
    check compileExit == 0
    check fileExists(outputExe)

  test "can disable core autoload":
    let file = writeTempNfl("nfl cli no core", "no core.nfl", "(when true (echo \"loaded\"))\n")

    let (_, exitCode) = runCommand(cliExe, @["check", "--no-core", file])
    check exitCode != 0

  test "macroexpand expands with core autoload":
    let file = writeTempNfl("nfl cli macroexpand", "expand core.nfl", "(when true (echo \"loaded\"))\n")

    let (output, exitCode) = runCommand(cliExe, @["macroexpand", file])
    check exitCode == 0
    check output.strip() == "(if true (block (echo \"loaded\")) nil)"

  test "macroexpand can disable core autoload":
    let file = writeTempNfl("nfl cli macroexpand no core", "expand no core.nfl", "(when true (echo \"loaded\"))\n")

    let (output, exitCode) = runCommand(cliExe, @["macroexpand", "--no-core", file])
    check exitCode == 0
    check output.strip() == "(when true (echo \"loaded\"))"

  test "macroexpand omits consumed defmacro forms":
    let file = writeTempNfl("nfl cli macroexpand defmacro", "local macro.nfl", "\n(defmacro id (x) x)\n(id (+ 1 2))\n")

    let (output, exitCode) = runCommand(cliExe, @["macroexpand", file])
    check exitCode == 0
    check output.strip() == "(+ 1 2)"
    check not output.contains("defmacro")

  test "reader errors point at nfl source":
    let file = writeTempNfl("nfl cli reader diagnostic", "reader error.nfl", "\n(defvar x \"unterminated\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & ":2:11")
    check output.contains("unterminated string literal")

  test "lowering errors point at nfl source":
    let file = writeTempNfl("nfl cli lower diagnostic", "lower error.nfl", "\n(let ((x 1))\n  (set! x 2)\n  x)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & ":3:9")
    check output.contains("immutable binding")

  test "macro errors point at macro call site":
    let file = writeTempNfl("nfl cli macro diagnostic", "macro error.nfl", "\n(defmacro fail () (macro-error \"boom\"))\n(fail)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & ":3:1")
    check output.contains("error expanding macro fail")
    check output.contains("boom")

  test "nim type errors point at nfl source":
    let file = writeTempNfl("nfl cli type diagnostic", "type error.nfl", "\n\n(defvar x (+ 1 \"bad\"))\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & "(3, 12)")
    check output.contains("type mismatch")

  test "unknown symbols point at nfl source":
    let file = writeTempNfl("nfl cli unknown symbol diagnostic", "unknown symbol.nfl", "(defvar x missingSymbol)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & "(1,")
    check output.contains("undeclared identifier")
    check output.contains("missingSymbol")

  test "unknown call targets point at nfl source":
    let file = writeTempNfl("nfl cli unknown call diagnostic", "unknown call.nfl", "(missingProc 1)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & "(1,")
    check output.contains("undeclared identifier")
    check output.contains("missingProc")

  test "nfl arity errors point at nfl source":
    let file = writeTempNfl("nfl cli nfl arity diagnostic", "if arity.nfl", "(if true 1)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & ":1:1")
    check output.contains("if expects 3 arguments, got 2")

  test "nim call arity errors point at nfl source":
    let file = writeTempNfl("nfl cli nim arity diagnostic", "nim arity.nfl", "(+)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & "(1, 2)")
    check output.contains("type mismatch")
    check output.contains("`+`()")

  test "macro arity errors point at macro call site":
    let file = writeTempNfl("nfl cli macro arity diagnostic", "macro arity.nfl", "\n(defmacro pair (x y) `(list ,x ,y))\n(pair 1)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & ":3:1")
    check output.contains("pair expects 2 arguments, got 1")

  test "multiple embedded modules do not emit helper redefinition warnings":
    let nimExe = findExe("nim")
    check nimExe.len > 0
    if nimExe.len > 0:
      let file = writeTempNim("nfl cli helper warning", "two_modules.nim", """
import nfl/compiler

nflModule "(defvar firstValue (first [1 2]))", "first-module.nfl"
nflModule "(defvar secondValue (first [3 4]))", "second-module.nfl"
""")

      let (output, exitCode) = runCommand(nimExe, @["check", "--path:src", file])
      check exitCode == 0
      check not output.contains("Warning:")
      check not output.contains("redefinition")

  test "nim module can import exported nfl types":
    let nimExe = findExe("nim")
    check nimExe.len > 0
    if nimExe.len > 0:
      let dir = getTempDir() / "nfl cli imported types"
      createDir(dir)
      let nflFile = dir / "types.nfl"
      let producer = dir / "producer.nim"
      let consumer = dir / "consumer.nim"

      writeFile(nflFile, """
(type PublicPerson*
  (object
    (name* string)
    (age* int)))
(type PublicMood*
  (enum publicHappy publicSad))
""")
      writeFile(producer, """
import nfl/compiler

nflModule(staticRead("types.nfl"), "types.nfl")
""")
      writeFile(consumer, """
import producer

let p = PublicPerson(name: "Ada", age: 36)
doAssert p.name == "Ada"
doAssert p.age == 36
doAssert publicHappy != publicSad
""")

      let (output, exitCode) = runCommand(nimExe, @["check", "--path:src", consumer])
      check exitCode == 0
      check not output.contains("Error:")
