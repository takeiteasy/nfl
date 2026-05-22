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

proc writeTempNim(dirName, fileName, source: string): string =
  let dir = getTempDir() / dirName
  createDir(dir)
  result = dir / fileName
  writeFile(result, source)

let cliExe = getCurrentDir() / "src" / "nimp" / "nimp"

suite "nimp cli":
  test "checks example files":
    for file in walkFiles("examples/*.nimp"):
      let (_, exitCode) = runCommand(cliExe, @["check", file])
      check exitCode == 0

  test "runs example files":
    for file in walkFiles("examples/*.nimp"):
      let (output, exitCode) = runCommand(cliExe, @["run", file])
      check exitCode == 0
      check not output.contains("Error:")

  test "simple example produces expected output":
    let (output, exitCode) = runCommand(cliExe, @["run", "examples/simple.nimp"])
    check exitCode == 0
    check output.contains("NIMP")

  test "handles paths with spaces":
    let file = writeTempNimp("nimp cli path with spaces", "hello world.nimp", "(echo \"space path ok\")\n")

    let (output, exitCode) = runCommand(cliExe, @["run", file])
    check exitCode == 0
    check output.contains("space path ok")

  test "compile writes binary next to input":
    let file = writeTempNimp("nimp cli compile output", "compiled.nimp", "(echo \"compiled ok\")\n")
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
    let file = writeTempNimp("nimp cli compile path with spaces", "hello world.nimp", "(echo \"compiled space path ok\")\n")
    let outputExe = changeFileExt(file, ExeExt)
    if fileExists(outputExe):
      removeFile(outputExe)

    let (_, compileExit) = runCommand(cliExe, @["compile", file])
    check compileExit == 0
    check fileExists(outputExe)

  test "can disable core autoload":
    let file = writeTempNimp("nimp cli no core", "no core.nimp", "(when true (echo \"loaded\"))\n")

    let (_, exitCode) = runCommand(cliExe, @["check", "--no-core", file])
    check exitCode != 0

  test "macroexpand expands with core autoload":
    let file = writeTempNimp("nimp cli macroexpand", "expand core.nimp", "(when true (echo \"loaded\"))\n")

    let (output, exitCode) = runCommand(cliExe, @["macroexpand", file])
    check exitCode == 0
    check output.strip() == "(if true (begin (echo \"loaded\")) nil)"

  test "macroexpand can disable core autoload":
    let file = writeTempNimp("nimp cli macroexpand no core", "expand no core.nimp", "(when true (echo \"loaded\"))\n")

    let (output, exitCode) = runCommand(cliExe, @["macroexpand", "--no-core", file])
    check exitCode == 0
    check output.strip() == "(when true (echo \"loaded\"))"

  test "macroexpand omits consumed defmacro forms":
    let file = writeTempNimp("nimp cli macroexpand defmacro", "local macro.nimp", "\n(defmacro id (x) x)\n(id (+ 1 2))\n")

    let (output, exitCode) = runCommand(cliExe, @["macroexpand", file])
    check exitCode == 0
    check output.strip() == "(+ 1 2)"
    check not output.contains("defmacro")

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

  test "unknown symbols point at nimp source":
    let file = writeTempNimp("nimp cli unknown symbol diagnostic", "unknown symbol.nimp", "(define x missingSymbol)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & "(1,")
    check output.contains("undeclared identifier")
    check output.contains("missingSymbol")

  test "unknown call targets point at nimp source":
    let file = writeTempNimp("nimp cli unknown call diagnostic", "unknown call.nimp", "(missingProc 1)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & "(1,")
    check output.contains("undeclared identifier")
    check output.contains("missingProc")

  test "nimp arity errors point at nimp source":
    let file = writeTempNimp("nimp cli nimp arity diagnostic", "if arity.nimp", "(if true 1)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & ":1:1")
    check output.contains("if expects 3 arguments, got 2")

  test "nim call arity errors point at nimp source":
    let file = writeTempNimp("nimp cli nim arity diagnostic", "nim arity.nimp", "(+)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & "(1, 2)")
    check output.contains("type mismatch")
    check output.contains("`+`()")

  test "macro arity errors point at macro call site":
    let file = writeTempNimp("nimp cli macro arity diagnostic", "macro arity.nimp", "\n(defmacro pair (x y) `(list ,x ,y))\n(pair 1)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & ":3:1")
    check output.contains("pair expects 2 arguments, got 1")

  test "multiple embedded modules do not emit helper redefinition warnings":
    let nimExe = findExe("nim")
    check nimExe.len > 0
    if nimExe.len > 0:
      let file = writeTempNim("nimp cli helper warning", "two_modules.nim", """
import nimp/compiler

nimpModule "(define firstValue (first [1 2]))", "first-module.nimp"
nimpModule "(define secondValue (first [3 4]))", "second-module.nimp"
""")

      let (output, exitCode) = runCommand(nimExe, @["check", "--path:src", file])
      check exitCode == 0
      check not output.contains("Warning:")
      check not output.contains("redefinition")
