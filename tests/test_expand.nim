import std/os
import std/strutils
import std/unittest

import nimp/compiler
import nimp/diagnostics
import nimp/expand
import nimp/macros
import nimp/reader
import nimp/syntax

proc expandOne(source: string): Syntax =
  let env = newMacroEnv()
  let forms = expandModule(readAll(source, "expand-test.nimp"), env)
  check forms.len == 1
  forms[0]

proc expectExpandError(source, messagePart: string) =
  try:
    discard expandOne(source)
    fail()
  except CompilerError as err:
    check err.diagnostic.span.file == "expand-test.nimp"
    check err.diagnostic.message.contains(messagePart)

proc renderForms(forms: seq[Syntax]): string =
  for form in forms:
    if result.len > 0:
      result.add "\n"
    result.add form.renderSyntax()

suite "macro expansion":
  test "expands fixed parameter macro":
    let sx = expandOne """
(defmacro id (x) x)
(id (+ 1 2))
"""
    check sx.renderSyntax() == "(+ 1 2)"

  test "expands rest parameter macro with quasiquote splicing":
    let sx = expandOne """
(defmacro when (test . body)
  `(if ,test (block ,@body) nil))
(when true (echo "yes") 3)
"""
    check sx.renderSyntax() == "(if true (block (echo \"yes\") 3) nil)"

  test "gensym generates distinct symbols":
    let sx = expandOne """
(defmacro twice (x)
  (let ((a (gensym "tmp"))
        (b (gensym "tmp")))
    `(let ((,a ,x) (,b ,x)) (+ ,a ,b))))
(twice 1)
"""
    let rendered = sx.renderSyntax()
    check rendered.contains("tmp__gensym1")
    check rendered.contains("tmp__gensym2")

  test "gensym identity cannot be forged by matching printed name":
    let sx = expandOne """
(defmacro collision ()
  (let ((a (gensym "tmp")))
    `(list ,a tmp__gensym1)))
(collision)
"""
    check sx.renderSyntax() == "(list tmp__gensym1 tmp__gensym1)"
    check sx.items[1].kind == sxSymbol
    check sx.items[2].kind == sxSymbol
    check sx.items[1].sym == sx.items[2].sym
    check sx.items[1].hygieneId != 0
    check sx.items[2].hygieneId == 0
    check not sx.items[1].sameSyntax(sx.items[2])

  test "macro-time truthiness matches runtime truthiness":
    let sx = expandOne """
(defmacro truthy-empty-values ()
  (list
    (if nil 'nil-false 'nil-true)
    (if false 'false-true 'false-false)
    (if '() 'empty-list-true 'empty-list-false)
    (if '[] 'empty-vector-true 'empty-vector-false)))
(truthy-empty-values)
"""
    check sx.renderSyntax() == "(nil-true false-false empty-list-true empty-vector-true)"

  test "macro errors include call site context":
    try:
      discard expandOne """
(defmacro nope () (macro-error "bad macro"))
(nope)
"""
      fail()
    except CompilerError as err:
      check err.diagnostic.span.file == "expand-test.nimp"
      check err.diagnostic.message.contains("error expanding macro nope")
      check err.diagnostic.message.contains("bad macro")

  test "rejects fixed parameter macro with too few arguments":
    expectExpandError("""
(defmacro pair (x y) `(list ,x ,y))
(pair 1)
""", "pair expects 2 arguments, got 1")

  test "rejects fixed parameter macro with too many arguments":
    expectExpandError("""
(defmacro pair (x y) `(list ,x ,y))
(pair 1 2 3)
""", "pair expects 2 arguments, got 3")

  test "rejects rest parameter macro with too few required arguments":
    expectExpandError("""
(defmacro when (test . body) `(if ,test (block ,@body) nil))
(when)
""", "when expects at least 1 arguments, got 0")

  test "rejects macro-time builtin with bad arity":
    expectExpandError("""
(defmacro bad () (first))
(bad)
""", "first expects 1 arguments, got 0")

  test "rejects unquote outside quasiquote":
    expectExpandError(",x", "unquote is only valid inside quasiquote")

  test "rejects unquote-splicing outside quasiquote":
    expectExpandError(",@xs", "unquote-splicing is only valid inside quasiquote")

  test "rejects malformed unquote":
    expectExpandError("""
(defmacro bad () `(unquote a b))
(bad)
""", "unquote expects 1 arguments, got 2")

  test "rejects malformed unquote-splicing":
    expectExpandError("""
(defmacro bad () `(a (unquote-splicing (list 'x) (list 'y))))
(bad)
""", "unquote-splicing expects 1 arguments, got 2")

  test "rejects duplicate macro parameters":
    expectExpandError("""
(defmacro bad (x x) x)
(bad 1 2)
""", "duplicate macro parameter: x")

  test "rejects duplicate macro rest parameter":
    expectExpandError("""
(defmacro bad (x . x) x)
(bad 1 2)
""", "duplicate macro parameter: x")

  test "rejects expansion recursion limit":
    expectExpandError("""
(defmacro loop () `(loop))
(loop)
""", "macro expansion depth exceeded")

suite "golden macro expansion":
  test "core macro fixtures":
    for sourcePath in ["tests/golden/core_macros.nimp",
                       "tests/golden/escaped_symbols.nimp"]:
      let expectedPath = sourcePath.changeFileExt("out")
      let actual = expandSource(readFile(sourcePath), sourcePath).renderForms()
      check actual.strip() == readFile(expectedPath).strip()
