## End-to-end tests for `lfn repl` (#14), driving the built `src/lfn/lfn`
## binary with piped stdin — unlike `test_cli.nim`'s `runCommand`, these
## need to *write* to the child's stdin and close it, since the REPL reads
## interactively and only exits on EOF.

import std/os
import std/osproc
import std/streams
import std/strutils
import std/unittest

let cliExe = getCurrentDir() / "src" / "lfn" / "lfn"

proc runRepl(lines: seq[string]; extraArgs: seq[string] = @[]; workingDir = ""):
    tuple[output: string; exitCode: int] =
  ## Runs `lfn repl <extraArgs>`, feeding `lines` to stdin (one per line,
  ## newline-joined) and closing stdin — the REPL reads until EOF, which is
  ## also what a real `lfn repl` session sees on Ctrl-D, so this doubles as
  ## the "exits 0 on EOF" check every test here implicitly exercises.
  var options = {poStdErrToStdOut}
  let process =
    if workingDir.len > 0:
      startProcess(cliExe, workingDir = workingDir, args = @["repl"] & extraArgs, options = options)
    else:
      startProcess(cliExe, args = @["repl"] & extraArgs, options = options)
  let inp = process.inputStream()
  for line in lines:
    inp.writeLine(line)
  inp.close()
  result.output = process.outputStream().readAll()
  result.exitCode = process.waitForExit()
  process.close()

proc writeTempLfn(dirName, fileName, source: string): string =
  let dir = getTempDir() / dirName
  createDir(dir)
  result = dir / fileName
  writeFile(result, source)

suite "lfn repl":
  test "exits 0 on EOF with no input":
    let (output, exitCode) = runRepl(@[])
    check exitCode == 0
    check output.len == 0

  test "prints an int value":
    let (output, exitCode) = runRepl(@["42"])
    check exitCode == 0
    check output.strip() == "42"

  test "quotes a string value distinctly from an int":
    let (output, exitCode) = runRepl(@["\"1\"", "1"])
    check exitCode == 0
    let lines = output.strip().splitLines()
    check lines == @["\"1\"", "1"]

  test "a declaration produces no printed output":
    let (output, exitCode) = runRepl(@["(var x 1)"])
    check exitCode == 0
    check output.strip().len == 0

  test "a void form (set!) prints nothing but still runs":
    let (output, exitCode) = runRepl(@["(var x 1)", "(set! x 2)", "x"])
    check exitCode == 0
    check output.strip() == "2"

  test "mutation persists across inputs (full replay)":
    let (output, exitCode) = runRepl(@["(var x 1)", "x", "(set! x 5)", "x"])
    check exitCode == 0
    check output.strip().splitLines() == @["1", "5"]

  test "a proc definition persists and is callable in a later input":
    let (output, exitCode) = runRepl(@["(proc f () (: int) 41)", "(+ (f) 1)"])
    check exitCode == 0
    check output.strip() == "42"

  test "a macro defined in one input expands in the next":
    let (output, exitCode) = runRepl(@["(defmacro dbl (x) `(* 2 ,x))", "(dbl 21)"])
    check exitCode == 0
    check output.strip() == "42"

  test "earlier echo output is not repeated on a later input":
    let (output, exitCode) = runRepl(@["(echo \"one\")", "(echo \"two\")"])
    check exitCode == 0
    check output.strip().splitLines() == @["one", "two"]

  test "a failed input leaves the session usable":
    let (output, exitCode) = runRepl(@["(var x 10)", "(missingProc 1)", "x"])
    check exitCode == 0
    check output.contains("undeclared identifier")
    check output.strip().splitLines()[^1] == "10"

  test "multi-line continuation of an unterminated list":
    let (output, exitCode) = runRepl(@["(var y", "  (+ 1", "     2))", "y"])
    check exitCode == 0
    check output.strip() == "3"

  test "defvar is idempotent; a second defvar for a bound name is a no-op":
    let (output, exitCode) = runRepl(@["(defvar x 1)", "(defvar x 999)", "x"])
    check exitCode == 0
    check output.strip() == "1"

  test "defparameter always resets, unlike defvar":
    let (output, exitCode) = runRepl(@["(defvar x 1)", "(defparameter x 999)", "x"])
    check exitCode == 0
    check output.strip() == "999"

  test "a plain var redefinition also resets (like defparameter)":
    let (output, exitCode) = runRepl(@["(var x 1)", "(var x 999)", "x"])
    check exitCode == 0
    check output.strip() == "999"

  test "a proc redefinition replaces the earlier one":
    let (output, exitCode) = runRepl(@[
      "(proc f () (: int) 1)", "(f)", "(proc f () (: int) 2)", "(f)"])
    check exitCode == 0
    let lines = output.strip().splitLines()
    check lines[0] == "1"
    check lines[^1] == "2"

  test "defclass (a preamble macro expanding to a multi-decl block) works and redefines cleanly":
    let (output, exitCode) = runRepl(@[
      "(defclass Animal () ((name string :accessor animalName)))",
      "(animalName (make-instance Animal (name \"Rex\")))",
      "(defclass Animal () ((name string :accessor animalName) (age int :initform 3)))",
      "(animalName (make-instance Animal (name \"Rex\")))"])
    check exitCode == 0
    check output.strip().splitLines() == @["\"Rex\"", "\"Rex\""]

  test "a defmacro redefinition replaces the earlier one, even after a use":
    let (output, exitCode) = runRepl(@[
      "(defmacro id (x) x)", "(id 5)",
      "(defmacro id (x) `(+ ,x 100))", "(id 5)"])
    check exitCode == 0
    check output.strip().splitLines()[^1] == "105"

  test "a static-when carrying a proc (#32) is a declaration and redefines cleanly":
    # Matches the "a proc redefinition replaces the earlier one" test above:
    # checks only the first and last printed values, not exact line-for-line
    # equality — a redefinition can cause an earlier entry's now-changed
    # output to reprint too (known limitation #93), independent of #32.
    let (output, exitCode) = runRepl(@[
      "(static-when ((defined this_symbol_is_never_defined_32) " &
        "(proc f () (: int) 1)) (else (proc f () (: int) 2)))",
      "(f)",
      "(static-when ((defined this_symbol_is_never_defined_32) " &
        "(proc f () (: int) 10)) (else (proc f () (: int) 20)))",
      "(f)"])
    check exitCode == 0
    let lines = output.strip().splitLines()
    check lines[0] == "2"
    check lines[^1] == "20"

  test "a relative import resolves against the launch directory, not the temp session dir":
    # `lfn repl` itself must keep running with its cwd at the repo root (not
    # some other `workingDir`) so `nim`'s own `--path:src` resolution
    # (`repoSrcPath`, cli.nim) still finds `lfn/compiler` — a pre-existing
    # dev-checkout constraint shared by every other `lfn` subcommand, not
    # something particular to `repl`. The fix under test (`importDir` on
    # `lfnModule`, compiler.nim) is exercised regardless: absent it, this
    # relative import would resolve against the session's temp dir instead
    # of the repo root and fail to find the file at all.
    let helper = getCurrentDir() / "test_repl_relative_import_helper.lfn"
    writeFile(helper, "(proc bump* ((n int)) (: int) (+ n 1))\n")
    defer: removeFile(helper)
    let (output, exitCode) = runRepl(
      @["(import ./test_repl_relative_import_helper.lfn)", "(bump 41)"])
    check exitCode == 0
    check output.strip() == "42"

  test "a type error reports <repl:N> at the input-relative line, not the temp file":
    let (output, exitCode) = runRepl(@["(echo \"ok\")", "(var z (+ 1 \"bad\"))"])
    check exitCode == 0
    check output.contains("<repl:2>(1,")
    # The primary error location is rewritten away from the on-disk
    # session file entirely; a secondary Nim instantiation-trace line (from
    # `wrapper.nim`, the tiny generated entry point, not `session.lfn`) may
    # still reference the temp dir directly — see `repl.nim`'s
    # `rewriteDiagnostics` doc comment.
    check not output.contains("session.lfn")

  test ":quit stops the loop without waiting for EOF":
    let (output, exitCode) = runRepl(@["1", ":quit", "2"])
    check exitCode == 0
    check output.strip() == "1"

  test ":transcript prints the accumulated session source":
    let (output, exitCode) = runRepl(@["(var x 1)", ":transcript"])
    check exitCode == 0
    check output.contains("(var x 1)")

  test ":reset clears the session":
    let (output, exitCode) = runRepl(@["(var x 1)", ":reset", ":transcript"])
    check exitCode == 0
    check not output.contains("(var x 1)")

  test "--no-core disables the preamble macros in the repl":
    let (output, exitCode) = runRepl(@["(when true 1)"], extraArgs = @["--no-core"])
    check exitCode == 0
    check output.contains("undeclared")

  test "an optional preload file is loaded as the first transcript entry":
    let file = writeTempLfn("lfn repl preload", "preload.lfn", "(var x 41)\n")
    let (output, exitCode) = runRepl(@["(+ x 1)"], extraArgs = @[file])
    check exitCode == 0
    check output.strip() == "42"

  test "--emit is rejected on repl":
    let (output, exitCode) = runRepl(@[], extraArgs = @["--emit", "nim"])
    check exitCode == 2
    check output.contains("--emit is not valid with repl")
