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

proc writeTempLfn(dirName, fileName, source: string): string =
  let dir = getTempDir() / dirName
  createDir(dir)
  result = dir / fileName
  writeFile(result, source)

proc writeTempNim(dirName, fileName, source: string): string =
  let dir = getTempDir() / dirName
  createDir(dir)
  result = dir / fileName
  writeFile(result, source)

let cliExe = getCurrentDir() / "src" / "lfn" / "lfn"

suite "lfn cli":
  test "checks example files":
    for file in walkFiles("examples/*.lfn"):
      let (_, exitCode) = runCommand(cliExe, @["check", file])
      check exitCode == 0

  test "runs example files":
    for file in walkFiles("examples/*.lfn"):
      let (output, exitCode) = runCommand(cliExe, @["run", file])
      check exitCode == 0
      check not output.contains("Error:")

  test "simple example produces expected output":
    let (output, exitCode) = runCommand(cliExe, @["run", "examples/simple.lfn"])
    check exitCode == 0
    check output.contains("LFN")

  test "handles paths with spaces":
    let file = writeTempLfn("lfn cli path with spaces", "hello world.lfn", "(echo \"space path ok\")\n")

    let (output, exitCode) = runCommand(cliExe, @["run", file])
    check exitCode == 0
    check output.contains("space path ok")

  test "compile writes binary next to input":
    let file = writeTempLfn("lfn cli compile output", "compiled.lfn", "(echo \"compiled ok\")\n")
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
    let file = writeTempLfn("lfn cli compile path with spaces", "hello world.lfn", "(echo \"compiled space path ok\")\n")
    let outputExe = changeFileExt(file, ExeExt)
    if fileExists(outputExe):
      removeFile(outputExe)

    let (_, compileExit) = runCommand(cliExe, @["compile", file])
    check compileExit == 0
    check fileExists(outputExe)

  test "can disable core autoload":
    let file = writeTempLfn("lfn cli no core", "no core.lfn", "(when true (echo \"loaded\"))\n")

    let (_, exitCode) = runCommand(cliExe, @["check", "--no-core", file])
    check exitCode != 0

  test "macroexpand expands with core autoload":
    let file = writeTempLfn("lfn cli macroexpand", "expand core.lfn", "(when true (echo \"loaded\"))\n")

    let (output, exitCode) = runCommand(cliExe, @["macroexpand", file])
    check exitCode == 0
    check output.strip() == "(if true (block (echo \"loaded\")) nil)"

  test "macroexpand can disable core autoload":
    let file = writeTempLfn("lfn cli macroexpand no core", "expand no core.lfn", "(when true (echo \"loaded\"))\n")

    let (output, exitCode) = runCommand(cliExe, @["macroexpand", "--no-core", file])
    check exitCode == 0
    check output.strip() == "(when true (echo \"loaded\"))"

  test "macroexpand omits consumed defmacro forms":
    let file = writeTempLfn("lfn cli macroexpand defmacro", "local macro.lfn", "\n(defmacro id (x) x)\n(id (+ 1 2))\n")

    let (output, exitCode) = runCommand(cliExe, @["macroexpand", file])
    check exitCode == 0
    check output.strip() == "(+ 1 2)"
    check not output.contains("defmacro")

  test "reader errors point at lfn source":
    let file = writeTempLfn("lfn cli reader diagnostic", "reader error.lfn", "\n(var x \"unterminated\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & ":2:8")
    check output.contains("unterminated string literal")

  test "lowering errors point at lfn source":
    let file = writeTempLfn("lfn cli lower diagnostic", "lower error.lfn", "\n(let ((x 1))\n  (set! x 2)\n  x)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & ":3:9")
    check output.contains("immutable binding")

  test "macro errors point at macro call site":
    let file = writeTempLfn("lfn cli macro diagnostic", "macro error.lfn", "\n(defmacro fail () (macro-error \"boom\"))\n(fail)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & ":3:1")
    check output.contains("error expanding macro fail")
    check output.contains("boom")

  test "nim type errors point at lfn source":
    let file = writeTempLfn("lfn cli type diagnostic", "type error.lfn", "\n\n(var x (+ 1 \"bad\"))\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & "(3, 9)")
    check output.contains("type mismatch")

  test "unknown symbols point at lfn source":
    let file = writeTempLfn("lfn cli unknown symbol diagnostic", "unknown symbol.lfn", "(var x missingSymbol)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & "(1,")
    check output.contains("undeclared identifier")
    check output.contains("missingSymbol")

  test "unknown call targets point at lfn source":
    let file = writeTempLfn("lfn cli unknown call diagnostic", "unknown call.lfn", "(missingProc 1)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & "(1,")
    check output.contains("undeclared identifier")
    check output.contains("missingProc")

  test "lfn arity errors point at lfn source":
    let file = writeTempLfn("lfn cli lfn arity diagnostic", "if arity.lfn", "(if true 1)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & ":1:1")
    check output.contains("if expects 3 arguments, got 2")

  test "nim call arity errors point at lfn source":
    let file = writeTempLfn("lfn cli nim arity diagnostic", "nim arity.lfn", "(+)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & "(1, 2)")
    check output.contains("type mismatch")
    check output.contains("`+`()")

  test "macro arity errors point at macro call site":
    let file = writeTempLfn("lfn cli macro arity diagnostic", "macro arity.lfn", "\n(defmacro pair (x y) `(list ,x ,y))\n(pair 1)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", file])
    check exitCode != 0
    check output.contains(file & ":3:1")
    check output.contains("pair expects 2 arguments, got 1")

  test "multiple embedded modules do not emit helper redefinition warnings":
    let nimExe = findExe("nim")
    check nimExe.len > 0
    if nimExe.len > 0:
      let file = writeTempNim("lfn cli helper warning", "two_modules.nim", """
import lfn/compiler

lfnModule "(var firstValue (first [1 2]))", "first-module.lfn"
lfnModule "(var secondValue (first [3 4]))", "second-module.lfn"
""")

      let (output, exitCode) = runCommand(nimExe, @["check", "--path:src", file])
      check exitCode == 0
      check not output.contains("Warning:")
      check not output.contains("redefinition")

  test "nim module can import exported lfn types":
    let nimExe = findExe("nim")
    check nimExe.len > 0
    if nimExe.len > 0:
      let dir = getTempDir() / "lfn cli imported types"
      createDir(dir)
      let lfnFile = dir / "types.lfn"
      let producer = dir / "producer.nim"
      let consumer = dir / "consumer.nim"

      writeFile(lfnFile, """
(type PublicPerson*
  (object
    (name* string)
    (age* int)))
(type PublicMood*
  (enum publicHappy publicSad))
""")
      writeFile(producer, """
import lfn/compiler

lfnModule(staticRead("types.lfn"), "types.lfn")
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
  # multi-file lfn imports (#10)
  # ---------------------------------------------------------------------------

  test "imports another lfn file by relative path":
    discard writeTempLfn("lfn cli multi file", "helpers.lfn", """
(defmacro double (x) `(* 2 ,x))
(proc addOne ((x int)) (: int) (+ x 1))
""")
    let main = writeTempLfn("lfn cli multi file", "main.lfn", """
(import ./helpers.lfn)
(echo (addOne (double 5)))
""")

    let (output, exitCode) = runCommand(cliExe, @["run", main])
    check exitCode == 0
    check output.contains("11")

  test "diamond imports do not duplicate declarations":
    discard writeTempLfn("lfn cli diamond import", "d.lfn", "(var dValue 100)\n")
    discard writeTempLfn("lfn cli diamond import", "b.lfn", "(import ./d.lfn)\n(var bValue (+ dValue 1))\n")
    discard writeTempLfn("lfn cli diamond import", "c.lfn", "(import ./d.lfn)\n(var cValue (+ dValue 2))\n")
    let main = writeTempLfn("lfn cli diamond import", "main.lfn", """
(import ./b.lfn)
(import ./c.lfn)
(echo (+ bValue cValue))
""")

    let (output, exitCode) = runCommand(cliExe, @["run", main])
    check exitCode == 0
    check output.contains("203")

  test "circular lfn imports are reported as a compile error":
    let dir = "lfn cli circular import"
    let main = writeTempLfn(dir, "a.lfn", "(import ./b.lfn)\n(var a 1)\n")
    discard writeTempLfn(dir, "b.lfn", "(import ./a.lfn)\n(var b 1)\n")
    let (output, exitCode) = runCommand(cliExe, @["check", main])
    check exitCode != 0
    check output.contains("circular import")

  test "importing a missing lfn file is a compile error":
    let main = writeTempLfn("lfn cli missing import", "main.lfn", "(import ./does-not-exist.lfn)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", main])
    check exitCode != 0
    check output.contains("cannot find imported file")

  test "lfn file imports are rejected outside top-level module scope":
    let main = writeTempLfn("lfn cli nested import", "main.lfn", """
(proc f () (: int)
  (import ./helpers.lfn)
  1)
""")

    let (output, exitCode) = runCommand(cliExe, @["check", main])
    check exitCode != 0
    check output.contains("lfn file imports are only allowed at the top level of a module")

  test "defmacro-proc helpers imported alongside a macro remain callable (#89)":
    discard writeTempLfn("lfn cli macro-proc import", "helpers.lfn", """
(defmacro-proc dbl (n) (* 2 n))
(defmacro quad (x) `(* ,(dbl 2) ,x))
""")
    let main = writeTempLfn("lfn cli macro-proc import", "main.lfn", """
(import ./helpers.lfn)
(echo (quad 10))
""")

    let (output, exitCode) = runCommand(cliExe, @["run", main])
    check exitCode == 0
    check output.contains("40")

  test "a macro imported transitively still expands correctly (#89)":
    discard writeTempLfn("lfn cli transitive macro import", "b.lfn", """
(defmacro inner (x) `(+ ,x 1))
""")
    discard writeTempLfn("lfn cli transitive macro import", "a.lfn", """
(import ./b.lfn)
(defmacro outer (x) `(* 10 (inner ,x)))
""")
    let main = writeTempLfn("lfn cli transitive macro import", "main.lfn", """
(import ./a.lfn)
(echo (outer 4))
""")

    let (output, exitCode) = runCommand(cliExe, @["run", main])
    check exitCode == 0
    check output.contains("50")

  test "an imported macro's introduced bindings stay hygienic at the call site (#89)":
    discard writeTempLfn("lfn cli imported macro hygiene", "helpers.lfn", """
(defmacro swap-ish (a) `(let ((tmp ,a)) (+ tmp 1)))
""")
    let main = writeTempLfn("lfn cli imported macro hygiene", "main.lfn", """
(import ./helpers.lfn)
(let ((tmp 100)) (echo (swap-ish tmp)))
""")

    let (output, exitCode) = runCommand(cliExe, @["run", main])
    check exitCode == 0
    check output.contains("101")

  test "a macro name colliding across files is a compile error, either import order (#89)":
    discard writeTempLfn("lfn cli macro name collision", "helpers.lfn", """
(defmacro twice (x) `(* 2 ,x))
""")
    let importFirst = writeTempLfn("lfn cli macro name collision", "import-first.lfn", """
(import ./helpers.lfn)
(defmacro twice (x) `(+ ,x ,x))
""")
    let (importFirstOutput, importFirstExitCode) = runCommand(cliExe, @["check", importFirst])
    check importFirstExitCode != 0
    check importFirstOutput.contains("duplicate macro definition: twice")

    let defineFirst = writeTempLfn("lfn cli macro name collision", "define-first.lfn", """
(defmacro twice (x) `(+ ,x ,x))
(import ./helpers.lfn)
""")
    let (defineFirstOutput, defineFirstExitCode) = runCommand(cliExe, @["check", defineFirst])
    check defineFirstExitCode != 0
    check defineFirstOutput.contains("duplicate macro definition: twice")

  # ---------------------------------------------------------------------------
  # --emit nim (#69)
  # ---------------------------------------------------------------------------

  test "check --emit nim prints the emitted nim source between markers":
    let file = writeTempLfn("lfn cli emit nim check", "emit.lfn", "(echo \"hi\")\n")

    let (output, exitCode) = runCommand(cliExe, @["check", "--emit", "nim", file])
    check exitCode == 0
    check output.contains("# --- lfn: begin emitted nim (" & file & ") ---")
    check output.contains("# --- lfn: end emitted nim ---")
    check output.contains("lfnStmt")

  test "compile --emit nim prints the emitted nim source between markers":
    let file = writeTempLfn("lfn cli emit nim compile", "emit.lfn", "(echo \"hi\")\n")
    let outputExe = changeFileExt(file, ExeExt)
    if fileExists(outputExe):
      removeFile(outputExe)

    let (output, exitCode) = runCommand(cliExe, @["compile", "--emit", "nim", file])
    check exitCode == 0
    check output.contains("# --- lfn: begin emitted nim (" & file & ") ---")
    check output.contains("# --- lfn: end emitted nim ---")

  test "--emit nim= (equals form) also works":
    let file = writeTempLfn("lfn cli emit nim equals", "emit.lfn", "(echo \"hi\")\n")

    let (output, exitCode) = runCommand(cliExe, @["check", "--emit=nim", file])
    check exitCode == 0
    check output.contains("# --- lfn: begin emitted nim")

  test "--emit rejects an unknown value":
    let file = writeTempLfn("lfn cli emit unknown", "emit.lfn", "(echo \"hi\")\n")

    let (output, exitCode) = runCommand(cliExe, @["check", "--emit", "bogus", file])
    check exitCode == 2
    check output.contains("--emit")

  test "--emit with no value is a usage error":
    let file = writeTempLfn("lfn cli emit no value", "emit.lfn", "(echo \"hi\")\n")

    let (output, exitCode) = runCommand(cliExe, @["check", "--emit"])
    check exitCode == 2
    check output.contains("--emit requires a value")
    discard file

  test "--emit nim is rejected on macroexpand":
    let file = writeTempLfn("lfn cli emit macroexpand", "emit.lfn", "(echo \"hi\")\n")

    let (output, exitCode) = runCommand(cliExe, @["macroexpand", "--emit", "nim", file])
    check exitCode == 2
    check output.contains("--emit is not valid with macroexpand")

  test "an lfn-level error suppresses --emit nim output":
    # `(if true 1)` fails arity checking during expansion, before lfnModule
    # ever reaches emitModule -- distinct from a nim-level type/undeclared
    # error, which happens after emission (and so still prints).
    let file = writeTempLfn("lfn cli emit error", "emit error.lfn", "(if true 1)\n")

    let (output, exitCode) = runCommand(cliExe, @["check", "--emit", "nim", file])
    check exitCode != 0
    check not output.contains("# --- lfn: begin emitted nim")

  test "an unrecognised flag is a usage error, not a second positional":
    let file = writeTempLfn("lfn cli unknown flag", "unknown flag.lfn", "(echo \"hi\")\n")

    let (output, exitCode) = runCommand(cliExe, @["check", "--bogus-flag", file])
    check exitCode == 2
    check output.contains("unknown flag: --bogus-flag")

  # ---------------------------------------------------------------------------
  # -- nim arg passthrough
  # ---------------------------------------------------------------------------

  test "run passes args after -- straight through to nim":
    let file = writeTempLfn("lfn cli nim passthrough", "passthrough.lfn", "(echo \"passthrough ok\")\n")

    let (output, exitCode) = runCommand(cliExe, @["run", file, "--", "--mm:orc"])
    check exitCode == 0
    check output.contains("passthrough ok")
    check output.contains("mm: orc")

  test "compile passes args after -- straight through to nim":
    let file = writeTempLfn("lfn cli nim passthrough compile", "passthrough compile.lfn", "(echo \"compiled passthrough ok\")\n")
    let outputExe = changeFileExt(file, ExeExt)
    if fileExists(outputExe):
      removeFile(outputExe)

    let (output, compileExit) = runCommand(cliExe, @["compile", file, "--", "--mm:orc"])
    check compileExit == 0
    check output.contains("mm: orc")
    check fileExists(outputExe)

  test "-- passthrough is rejected for macroexpand/shim/repl":
    let file = writeTempLfn("lfn cli nim passthrough invalid", "passthrough invalid.lfn", "(echo \"hi\")\n")

    let (output, exitCode) = runCommand(cliExe, @["macroexpand", file, "--", "--mm:orc"])
    check exitCode == 2
    check output.contains("-- (nim arg passthrough) is only valid with run/compile/check")

  # ---------------------------------------------------------------------------
  # shim (#53 partial): nim-importable modules
  # ---------------------------------------------------------------------------

  test "shim writes a nim module that plain nim can import":
    let dir = getTempDir() / "lfn cli shim basic"
    createDir(dir)
    let lfnFile = dir / "util.lfn"
    let consumer = dir / "consumer.nim"

    writeFile(lfnFile, """
(proc double* ((n int)) (: int) (* n 2))
""")

    let (shimOutput, shimExit) = runCommand(cliExe, @["shim", lfnFile])
    check shimExit == 0
    check shimOutput.len == 0
    let shimPath = changeFileExt(lfnFile, ".nim")
    check fileExists(shimPath)
    check readFile(shimPath).contains("Generated by `lfn shim`")

    writeFile(consumer, """
import util
doAssert double(21) == 42
echo "shim ok"
""")

    let nimExe = findExe("nim")
    check nimExe.len > 0
    if nimExe.len > 0:
      let (output, exitCode) = runCommand(nimExe, @["c", "-r", "--hints:off", "--path:src", "--path:" & dir, consumer])
      check exitCode == 0
      check output.contains("shim ok")

  test "shim resolves a transitively imported lfn file":
    let dir = getTempDir() / "lfn cli shim transitive"
    createDir(dir)
    writeFile(dir / "helpers.lfn", """
(proc bump* ((n int)) (: int) (+ n 1))
""")
    let lfnFile = dir / "util.lfn"
    writeFile(lfnFile, """
(import ./helpers.lfn)
(proc quad* ((n int)) (: int) (* 2 (bump n)))
""")
    let consumer = dir / "consumer.nim"
    writeFile(consumer, """
import util
doAssert quad(5) == 12
echo "transitive shim ok"
""")

    let (_, shimExit) = runCommand(cliExe, @["shim", lfnFile])
    check shimExit == 0

    let nimExe = findExe("nim")
    check nimExe.len > 0
    if nimExe.len > 0:
      let (output, exitCode) = runCommand(nimExe, @["c", "-r", "--hints:off", "--path:src", "--path:" & dir, consumer])
      check exitCode == 0
      check output.contains("transitive shim ok")

  test "shim-exported template is usable from the importing nim module":
    let dir = getTempDir() / "lfn cli shim template"
    createDir(dir)
    let lfnFile = dir / "util.lfn"
    writeFile(lfnFile, """
(template twice* (body) (block body body))
""")
    let consumer = dir / "consumer.nim"
    writeFile(consumer, """
import util
var count = 0
twice:
  inc count
doAssert count == 2
echo "template shim ok"
""")

    let (_, shimExit) = runCommand(cliExe, @["shim", lfnFile])
    check shimExit == 0

    let nimExe = findExe("nim")
    check nimExe.len > 0
    if nimExe.len > 0:
      let (output, exitCode) = runCommand(nimExe, @["c", "-r", "--hints:off", "--path:src", "--path:" & dir, consumer])
      check exitCode == 0
      check output.contains("template shim ok")

  test "shim refuses to overwrite a non-generated file":
    let dir = getTempDir() / "lfn cli shim overwrite guard"
    createDir(dir)
    let lfnFile = dir / "util.lfn"
    writeFile(lfnFile, "(proc double* ((n int)) (: int) (* n 2))\n")
    let manual = dir / "manual.nim"
    writeFile(manual, "# hand written, do not clobber\n")

    let (output, exitCode) = runCommand(cliExe, @["shim", lfnFile, "--out", manual])
    check exitCode != 0
    check output.contains("refusing to overwrite")
    check readFile(manual) == "# hand written, do not clobber\n"

  test "shim --force overwrites an existing file":
    let dir = getTempDir() / "lfn cli shim force"
    createDir(dir)
    let lfnFile = dir / "util.lfn"
    writeFile(lfnFile, "(proc double* ((n int)) (: int) (* n 2))\n")
    let manual = dir / "manual.nim"
    writeFile(manual, "# hand written, do not clobber\n")

    let (_, exitCode) = runCommand(cliExe, @["shim", lfnFile, "--out", manual, "--force"])
    check exitCode == 0
    check readFile(manual).contains("Generated by `lfn shim`")

  test "shim run twice regenerates its own output without --force":
    let dir = getTempDir() / "lfn cli shim regenerate"
    createDir(dir)
    let lfnFile = dir / "util.lfn"
    writeFile(lfnFile, "(proc double* ((n int)) (: int) (* n 2))\n")

    let (_, firstExit) = runCommand(cliExe, @["shim", lfnFile])
    check firstExit == 0
    let (_, secondExit) = runCommand(cliExe, @["shim", lfnFile])
    check secondExit == 0

  test "--out is rejected on commands other than shim":
    let file = writeTempLfn("lfn cli out wrong command", "out.lfn", "(echo \"hi\")\n")

    let (output, exitCode) = runCommand(cliExe, @["check", "--out", "/tmp/whatever.nim", file])
    check exitCode == 2
    check output.contains("--out is only valid with shim")

  test "--force is rejected on commands other than shim":
    let file = writeTempLfn("lfn cli force wrong command", "force.lfn", "(echo \"hi\")\n")

    let (output, exitCode) = runCommand(cliExe, @["check", "--force", file])
    check exitCode == 2
    check output.contains("--force is only valid with shim")

  test "the shipped package example: plain nim consumes a shimmed lfn library":
    let nimExe = findExe("nim")
    check nimExe.len > 0
    if nimExe.len > 0:
      let (output, exitCode) = runCommand(nimExe, @["c", "-r", "--hints:off",
        "--path:src", "--path:examples/package/src", "examples/package/tests/consume.nim"])
      check exitCode == 0
      check output.contains("package example ok")
