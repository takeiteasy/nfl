import std/unittest
import std/strutils

import nfl/diagnostics
import nfl/reader
import nfl/syntax

proc checkSpans(node: Syntax) =
  check node.span.line > 0
  check node.span.col > 0
  check node.span.endLine > 0
  check node.span.endCol > 0
  if node.kind in {sxList, sxVector}:
    for item in node.items:
      checkSpans(item)

proc expectReaderError(source, messagePart: string) =
  try:
    discard readAll(source, "bad.nfl")
    fail()
  except ReaderError as err:
    check err.diagnostic.span.file == "bad.nfl"
    check err.diagnostic.message.contains(messagePart)

suite "reader valid syntax":
  test "reads scalar literals":
    let forms = readAll("nil true false 42 -7 3.5 \"hi\\nthere\" symbol-name", "scalars.nfl")
    check forms.len == 8
    check forms[0].kind == sxNil
    check forms[1].kind == sxBool
    check forms[1].boolVal == true
    check forms[2].kind == sxBool
    check forms[2].boolVal == false
    check forms[3].kind == sxInt
    check forms[3].intVal == 42
    check forms[4].kind == sxInt
    check forms[4].intVal == -7
    check forms[5].kind == sxFloat
    check forms[5].floatVal == 3.5
    check forms[6].kind == sxString
    check forms[6].strVal == "hi\nthere"
    check forms[7].kind == sxSymbol
    check forms[7].sym == "symbol-name"
    for form in forms:
      checkSpans(form)

  test "reads lists and vectors":
    let form = readOne("(defvar xs [1 2 (do (x) x)])", "forms.nfl")
    check form.kind == sxList
    check form.items.len == 3
    check form.items[0].sym == "defvar"
    check form.items[2].kind == sxVector
    check form.items[2].items.len == 3
    check form.items[2].items[2].kind == sxList
    checkSpans(form)

  test "reads escaped symbols":
    let forms = readAll("|[]| |has space| |has\\|pipe| |has\\\\slash|", "escaped-symbols.nfl")
    check forms.len == 4
    check forms[0].kind == sxSymbol
    check forms[0].sym == "[]"
    check forms[0].renderSyntax() == "|[]|"
    check forms[1].sym == "has space"
    check forms[1].renderSyntax() == "|has space|"
    check forms[2].sym == "has|pipe"
    check forms[2].renderSyntax() == "|has\\|pipe|"
    check forms[3].sym == "has\\slash"
    check forms[3].renderSyntax() == "has\\slash"
    for form in forms:
      checkSpans(form)

  test "skips line and block comments":
    let forms = readAll("; ignore me\n1 #| ignore\nme |# 2", "comments.nfl")
    check forms.len == 2
    check forms[0].intVal == 1
    check forms[1].intVal == 2
    checkSpans(forms[0])
    checkSpans(forms[1])

  test "expands quote forms to syntax lists":
    let forms = readAll("'x `(a ,b ,@c)", "quote.nfl")
    check forms.len == 2
    check forms[0].kind == sxList
    check forms[0].items[0].sym == "quote"
    check forms[0].items[1].sym == "x"
    check forms[1].items[0].sym == "quasiquote"
    let inner = forms[1].items[1]
    check inner.kind == sxList
    check inner.items[1].items[0].sym == "unquote"
    check inner.items[2].items[0].sym == "unquote-splicing"
    for form in forms:
      checkSpans(form)

suite "reader pragma syntax":
  test "reads single-marker pragma clause":
    let sx = readOne("{.inline.}", "pragma.nfl")
    check sx.kind == sxList
    check sx.items.len == 2
    check sx.items[0].kind == sxSymbol
    check sx.items[0].sym == "pragma"
    check sx.items[1].kind == sxSymbol
    check sx.items[1].sym == "inline"
    checkSpans(sx)

  test "reads multi-marker pragma with comma separator":
    let sx = readOne("{.inline, cdecl.}", "pragma.nfl")
    check sx.kind == sxList
    check sx.items.len == 3
    check sx.items[1].sym == "inline"
    check sx.items[2].sym == "cdecl"

  test "reads multi-marker pragma with whitespace separator":
    let sx = readOne("{.inline cdecl.}", "pragma.nfl")
    check sx.kind == sxList
    check sx.items.len == 3
    check sx.items[1].sym == "inline"
    check sx.items[2].sym == "cdecl"

  test "reads empty pragma clause":
    let sx = readOne("{..}", "pragma.nfl")
    check sx.kind == sxList
    check sx.items.len == 1
    check sx.items[0].sym == "pragma"

  test "pragma clause appears inside larger form":
    let forms = readAll("(proc foo {.inline.} () 1)", "pragma.nfl")
    check forms.len == 1
    let sx = forms[0]
    check sx.kind == sxList
    check sx.items[2].kind == sxList
    check sx.items[2].items[0].sym == "pragma"
    check sx.items[2].items[1].sym == "inline"

  test "bare { without . falls through to atom reader":
    let forms = readAll("{myvar}", "pragma.nfl")
    check forms.len == 1
    check forms[0].kind == sxSymbol
    check forms[0].sym == "{myvar}"

suite "reader malformed syntax":
  test "reports unterminated string":
    expectReaderError("\"no end", "unterminated string")

  test "reports unterminated list":
    expectReaderError("(defvar x 1", "unterminated list")

  test "reports unterminated vector":
    expectReaderError("[1 2", "unterminated vector")

  test "reports unexpected closing delimiter":
    expectReaderError(")", "unexpected closing delimiter")

  test "reports invalid quote form":
    expectReaderError("' )", "expected expression after quote")

  test "reports unterminated block comment":
    expectReaderError("#| missing end", "unterminated block comment")

  test "reports malformed escaped symbols":
    expectReaderError("|", "unterminated escaped symbol")
    expectReaderError("||", "escaped symbol cannot be empty")
    expectReaderError("|bad\\n|", "invalid escaped symbol escape")

  test "reports unterminated pragma":
    expectReaderError("{.inline", "unterminated pragma")
    expectReaderError("{.", "unterminated pragma")
