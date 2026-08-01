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
    let file = writeTempNfl("nfl cli reader diagnostic", "reader error.nfl", "\n(var x \"unterminated\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & ":2:8")
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
    let file = writeTempNfl("nfl cli type diagnostic", "type error.nfl", "\n\n(var x (+ 1 \"bad\"))\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & "(3, 9)")
    check output.contains("type mismatch")

  test "unknown symbols point at nfl source":
    let file = writeTempNfl("nfl cli unknown symbol diagnostic", "unknown symbol.nfl", "(var x missingSymbol)\n")

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

nflModule "(var firstValue (first [1 2]))", "first-module.nfl"
nflModule "(var secondValue (first [3 4]))", "second-module.nfl"
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

  # ---------------------------------------------------------------------------
  # multi-file nfl imports (#10)
  # ---------------------------------------------------------------------------

  test "imports another nfl file by relative path":
    discard writeTempNfl("nfl cli multi file", "helpers.nfl", """
(defmacro double (x) `(* 2 ,x))
(proc addOne ((x int)) (: int) (+ x 1))
""")
    let main = writeTempNfl("nfl cli multi file", "main.nfl", """
(import ./helpers.nfl)
(echo (addOne (double 5)))
""")

    let (output, exitCode) = runCommand(cliExe, @["run", main])
    check exitCode == 0
    check output.contains("11")

  test "diamond imports do not duplicate declarations":
    discard writeTempNfl("nfl cli diamond import", "d.nfl", "(var dValue 100)\n")
    discard writeTempNfl("nfl cli diamond import", "b.nfl", "(import ./d.nfl)\n(var bValue (+ dValue 1))\n")
    discard writeTempNfl("nfl cli diamond import", "c.nfl", "(import ./d.nfl)\n(var cValue (+ dValue 2))\n")
    let main = writeTempNfl("nfl cli diamond import", "main.nfl", """
(import ./b.nfl)
(import ./c.nfl)
(echo (+ bValue cValue))
""")

    let (output, exitCode) = runCommand(cliExe, @["run", main])
    check exitCode == 0
    check output.contains("203")

  test "circular nfl imports are reported as a compile error":
    let dir = "nfl cli circular import"
    let main = writeTempNfl(dir, "a.nfl", "(import ./b.nfl)\n(var a 1)\n")
    discard writeTempNfl(dir, "b.nfl", "(import ./a.nfl)\n(var b 1)\n")
    let (output, exitCode) = runCommand(cliExe, @["check", main])
    check exitCode != 0
    check output.contains("circular import")

  test "importing a missing nfl file is a compile error":
    let main = writeTempNfl("nfl cli missing import", "main.nfl", "(import ./does-not-exist.nfl)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", main])
    check exitCode != 0
    check output.contains("cannot find imported file")

  test "nfl file imports are rejected outside top-level module scope":
    let main = writeTempNfl("nfl cli nested import", "main.nfl", """
(proc f () (: int)
  (import ./helpers.nfl)
  1)
""")

    let (output, exitCode) = runCommand(cliExe, @["check", main])
    check exitCode != 0
    check output.contains("nfl file imports are only allowed at the top level of a module")

  test "defmacro-proc helpers imported alongside a macro remain callable (#89)":
    discard writeTempNfl("nfl cli macro-proc import", "helpers.nfl", """
(defmacro-proc dbl (n) (* 2 n))
(defmacro quad (x) `(* ,(dbl 2) ,x))
""")
    let main = writeTempNfl("nfl cli macro-proc import", "main.nfl", """
(import ./helpers.nfl)
(echo (quad 10))
""")

    let (output, exitCode) = runCommand(cliExe, @["run", main])
    check exitCode == 0
    check output.contains("40")

  test "a macro imported transitively still expands correctly (#89)":
    discard writeTempNfl("nfl cli transitive macro import", "b.nfl", """
(defmacro inner (x) `(+ ,x 1))
""")
    discard writeTempNfl("nfl cli transitive macro import", "a.nfl", """
(import ./b.nfl)
(defmacro outer (x) `(* 10 (inner ,x)))
""")
    let main = writeTempNfl("nfl cli transitive macro import", "main.nfl", """
(import ./a.nfl)
(echo (outer 4))
""")

    let (output, exitCode) = runCommand(cliExe, @["run", main])
    check exitCode == 0
    check output.contains("50")

  test "an imported macro's introduced bindings stay hygienic at the call site (#89)":
    discard writeTempNfl("nfl cli imported macro hygiene", "helpers.nfl", """
(defmacro swap-ish (a) `(let ((tmp ,a)) (+ tmp 1)))
""")
    let main = writeTempNfl("nfl cli imported macro hygiene", "main.nfl", """
(import ./helpers.nfl)
(let ((tmp 100)) (echo (swap-ish tmp)))
""")

    let (output, exitCode) = runCommand(cliExe, @["run", main])
    check exitCode == 0
    check output.contains("101")

  test "a macro name colliding across files is a compile error, either import order (#89)":
    discard writeTempNfl("nfl cli macro name collision", "helpers.nfl", """
(defmacro twice (x) `(* 2 ,x))
""")
    let importFirst = writeTempNfl("nfl cli macro name collision", "import-first.nfl", """
(import ./helpers.nfl)
(defmacro twice (x) `(+ ,x ,x))
""")
    let (importFirstOutput, importFirstExitCode) = runCommand(cliExe, @["check", importFirst])
    check importFirstExitCode != 0
    check importFirstOutput.contains("duplicate macro definition: twice")

    let defineFirst = writeTempNfl("nfl cli macro name collision", "define-first.nfl", """
(defmacro twice (x) `(+ ,x ,x))
(import ./helpers.nfl)
""")
    let (defineFirstOutput, defineFirstExitCode) = runCommand(cliExe, @["check", defineFirst])
    check defineFirstExitCode != 0
    check defineFirstOutput.contains("duplicate macro definition: twice")
