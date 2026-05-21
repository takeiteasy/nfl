import std/strutils
import std/unittest

import nimp/diagnostics
import nimp/expand
import nimp/macroenv
import nimp/reader
import nimp/syntax

proc expandOne(source: string): Syntax =
  let env = newMacroEnv()
  let forms = expandModule(readAll(source, "expand-test.nimp"), env)
  check forms.len == 1
  forms[0]

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
  `(if ,test (begin ,@body) nil))
(when true (echo "yes") 3)
"""
    check sx.renderSyntax() == "(if true (begin (echo \"yes\") 3) nil)"

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
