type
  Span* = object
    file*: string
    line*, col*: int
    endLine*, endCol*: int

  SyntaxKind* = enum
    sxNil, sxBool, sxInt, sxFloat, sxString, sxSymbol, sxList, sxVector

  Syntax* = ref object
    span*: Span
    case kind*: SyntaxKind
    of sxNil:
      discard
    of sxBool:
      boolVal*: bool
    of sxInt:
      intVal*: BiggestInt
    of sxFloat:
      floatVal*: BiggestFloat
    of sxString:
      strVal*: string
    of sxSymbol:
      sym*: string
    of sxList, sxVector:
      items*: seq[Syntax]

proc span*(file: string; line, col, endLine, endCol: int): Span =
  Span(file: file, line: line, col: col, endLine: endLine, endCol: endCol)

proc withEnd*(start: Span; endLine, endCol: int): Span =
  Span(file: start.file, line: start.line, col: start.col, endLine: endLine, endCol: endCol)

proc newNil*(span: Span): Syntax =
  Syntax(kind: sxNil, span: span)

proc newBool*(value: bool; span: Span): Syntax =
  Syntax(kind: sxBool, span: span, boolVal: value)

proc newInt*(value: BiggestInt; span: Span): Syntax =
  Syntax(kind: sxInt, span: span, intVal: value)

proc newFloat*(value: BiggestFloat; span: Span): Syntax =
  Syntax(kind: sxFloat, span: span, floatVal: value)

proc newString*(value: string; span: Span): Syntax =
  Syntax(kind: sxString, span: span, strVal: value)

proc newSymbol*(value: string; span: Span): Syntax =
  Syntax(kind: sxSymbol, span: span, sym: value)

proc newList*(items: seq[Syntax]; span: Span): Syntax =
  Syntax(kind: sxList, span: span, items: items)

proc newVector*(items: seq[Syntax]; span: Span): Syntax =
  Syntax(kind: sxVector, span: span, items: items)
