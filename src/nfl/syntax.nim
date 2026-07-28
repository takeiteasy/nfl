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
      hygieneId*: int
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

proc newSymbol*(value: string; span: Span; hygieneId = 0): Syntax =
  Syntax(kind: sxSymbol, span: span, sym: value, hygieneId: hygieneId)

proc newList*(items: seq[Syntax]; span: Span): Syntax =
  Syntax(kind: sxList, span: span, items: items)

proc newVector*(items: seq[Syntax]; span: Span): Syntax =
  Syntax(kind: sxVector, span: span, items: items)

proc copySyntax*(sx: Syntax): Syntax =
  case sx.kind
  of sxNil:
    newNil(sx.span)
  of sxBool:
    newBool(sx.boolVal, sx.span)
  of sxInt:
    newInt(sx.intVal, sx.span)
  of sxFloat:
    newFloat(sx.floatVal, sx.span)
  of sxString:
    newString(sx.strVal, sx.span)
  of sxSymbol:
    newSymbol(sx.sym, sx.span, sx.hygieneId)
  of sxList:
    var items: seq[Syntax] = @[]
    for item in sx.items:
      items.add item.copySyntax()
    newList(items, sx.span)
  of sxVector:
    var items: seq[Syntax] = @[]
    for item in sx.items:
      items.add item.copySyntax()
    newVector(items, sx.span)

proc withSpan*(sx: Syntax; span: Span): Syntax =
  result = sx.copySyntax()
  result.span = span

proc isSymbol*(sx: Syntax; name: string): bool =
  sx.kind == sxSymbol and sx.sym == name

const operatorChars = {'=', '+', '-', '*', '/', '<', '>', '@', '$', '~', '&', '%', '|', '!', '?', '^', '.', ':'}

proc isOperatorName*(s: string): bool =
  ## True when `s` is non-empty and every character is a Nim operator
  ## character — the shape Nim requires an accent-quoted proc name
  ## (`` `+` ``) for, as opposed to a plain identifier.
  if s.len == 0:
    return false
  for c in s:
    if c notin operatorChars:
      return false
  true

proc isPlainIdentifierChar(c: char; first: bool): bool =
  if first: c in {'a' .. 'z', 'A' .. 'Z', '_'}
  else: c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}

proc isPlainIdentifier*(s: string): bool =
  ## True for an ordinary Nim-style identifier: starts with a letter or
  ## underscore, followed by letters/digits/underscores.
  if s.len == 0 or not isPlainIdentifierChar(s[0], first = true):
    return false
  for i in 1 ..< s.len:
    if not isPlainIdentifierChar(s[i], first = false):
      return false
  true

proc isValidRoutineName*(s: string): bool =
  ## A routine (proc/method/func/…) name must be a plain identifier
  ## (optionally with a trailing `*` export marker) or entirely operator
  ## characters (see #29) — not a mix of the two, which Nim cannot express
  ## as either an `ident` or an `nnkAccQuoted` operator.
  if isOperatorName(s):
    return true
  if s.len > 0 and s[^1] == '*':
    isPlainIdentifier(s[0 ..< s.high])
  else:
    isPlainIdentifier(s)

proc isRangeShaped*(sx: Syntax): bool =
  ## True for any list headed by the `..` symbol, regardless of arity. Used
  ## to recognize (and validate the arity of) an intended range form —
  ## distinct from `isRangeForm`, which also checks the arity is exactly 2.
  sx.kind == sxList and sx.items.len > 0 and sx.items[0].isSymbol("..")

proc isRangeForm*(sx: Syntax): bool =
  ## True for `(.. lo hi)` — the range form used by `for` loops and, per
  ## ticket #22, `case` of-branches (`(of (.. lo hi) body…)`).
  sx.isRangeShaped and sx.items.len == 3

proc isCaseValueList*(sx: Syntax): bool =
  ## True when a parenthesized form after `of` should be read as a
  ## multi-value / mixed value-and-range list (`(of (1 (.. 3 5) 7) body…)`)
  ## rather than a range (`(of (.. lo hi) body…)`).
  ##
  ## There is no syntactic way to distinguish a value list from a compound
  ## call expression — `(+ 1 2)` and `(1 2)` have the same shape, and a
  ## value list of symbols (e.g. `(Red Green)` enum labels) looks exactly
  ## like a call. Per the ticket, any non-empty, non-range-shaped list after
  ## `of` is read as a value list; a single computed value must be wrapped,
  ## e.g. `(of ((+ 1 2)) body…)`.
  sx.kind == sxList and sx.items.len > 0 and not sx.isRangeShaped

proc sameSyntax*(a, b: Syntax): bool =
  if a.kind != b.kind:
    return false
  case a.kind
  of sxNil:
    true
  of sxBool:
    a.boolVal == b.boolVal
  of sxInt:
    a.intVal == b.intVal
  of sxFloat:
    a.floatVal == b.floatVal
  of sxString:
    a.strVal == b.strVal
  of sxSymbol:
    a.sym == b.sym and a.hygieneId == b.hygieneId
  of sxList, sxVector:
    if a.items.len != b.items.len:
      return false
    for i in 0 ..< a.items.len:
      if not sameSyntax(a.items[i], b.items[i]):
        return false
    true

proc isRenderDelimiter(c: char): bool =
  c == '\0' or c in {' ', '\t', '\r', '\n', '(', ')', '[', ']', '\'', '`', ',', '"', ';', '|'}

proc isNumberLikeSymbol(value: string): bool =
  if value.len == 0:
    return false
  if value[0] in {'+', '-'}:
    return value.len > 1 and value[1] in {'0' .. '9'}
  value[0] in {'0' .. '9'}

proc renderSymbol(value: string): string =
  var needsEscape = value.len == 0 or value in ["nil", "true", "false"] or value.isNumberLikeSymbol()
  for c in value:
    if c.isRenderDelimiter:
      needsEscape = true
      break

  if not needsEscape:
    return value

  result = "|"
  for c in value:
    case c
    of '|': result.add "\\|"
    of '\\': result.add "\\\\"
    else: result.add c
  result.add "|"

proc renderSyntax*(sx: Syntax): string =
  case sx.kind
  of sxNil:
    result = "nil"
  of sxBool:
    result = if sx.boolVal: "true" else: "false"
  of sxInt:
    result = $sx.intVal
  of sxFloat:
    result = $sx.floatVal
  of sxString:
    result = "\""
    for c in sx.strVal:
      case c
      of '\\': result.add "\\\\"
      of '"': result.add "\\\""
      of '\n': result.add "\\n"
      of '\r': result.add "\\r"
      of '\t': result.add "\\t"
      else: result.add c
    result.add '"'
  of sxSymbol:
    result = renderSymbol(sx.sym)
  of sxList:
    result = "("
    for i, item in sx.items:
      if i > 0: result.add " "
      result.add item.renderSyntax()
    result.add ")"
  of sxVector:
    result = "["
    for i, item in sx.items:
      if i > 0: result.add " "
      result.add item.renderSyntax()
    result.add "]"
