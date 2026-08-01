## The `Syntax` s-expression tree produced by the reader and consumed by the
## macro expander, lowering, and backend passes, plus the `Span` source-range
## type attached to every node for diagnostics.

import std/strutils

type
  Span* = object          ## A source range, used to anchor diagnostics.
    file*: string
    line*, col*: int
    endLine*, endCol*: int

  SyntaxKind* = enum        ## The shape of a `Syntax` node.
    sxNil, sxBool, sxInt, sxFloat, sxString, sxSymbol, sxList, sxVector

  Syntax* = ref object     ## A single s-expression node.
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
      escaped*: bool  ## true when read via the reader's `|...|` escaped-symbol
                       ## syntax — marks `sym` as literal, so a trailing `*`
                       ## is never interpreted as an export marker (#46).
    of sxList, sxVector:
      items*: seq[Syntax]

proc span*(file: string; line, col, endLine, endCol: int): Span =
  ## Builds a `Span` from explicit start/end coordinates.
  Span(file: file, line: line, col: col, endLine: endLine, endCol: endCol)

proc withEnd*(start: Span; endLine, endCol: int): Span =
  ## Returns a copy of `start` with its end coordinates replaced — used to
  ## extend a span once a form's closing delimiter has been read.
  Span(file: start.file, line: start.line, col: start.col, endLine: endLine, endCol: endCol)

proc newNil*(span: Span): Syntax =
  ## Constructs an `sxNil` node.
  Syntax(kind: sxNil, span: span)

proc newBool*(value: bool; span: Span): Syntax =
  ## Constructs an `sxBool` node.
  Syntax(kind: sxBool, span: span, boolVal: value)

proc newInt*(value: BiggestInt; span: Span): Syntax =
  ## Constructs an `sxInt` node.
  Syntax(kind: sxInt, span: span, intVal: value)

proc newFloat*(value: BiggestFloat; span: Span): Syntax =
  ## Constructs an `sxFloat` node.
  Syntax(kind: sxFloat, span: span, floatVal: value)

proc newString*(value: string; span: Span): Syntax =
  ## Constructs an `sxString` node.
  Syntax(kind: sxString, span: span, strVal: value)

proc newSymbol*(value: string; span: Span; hygieneId = 0; escaped = false): Syntax =
  ## Constructs an `sxSymbol` node. `hygieneId` is nonzero for gensym'd or
  ## hygiene-renamed symbols; `escaped` marks a symbol read via the reader's
  ## `|...|` syntax.
  Syntax(kind: sxSymbol, span: span, sym: value, hygieneId: hygieneId, escaped: escaped)

proc newList*(items: seq[Syntax]; span: Span): Syntax =
  ## Constructs an `sxList` node.
  Syntax(kind: sxList, span: span, items: items)

proc newVector*(items: seq[Syntax]; span: Span): Syntax =
  ## Constructs an `sxVector` node.
  Syntax(kind: sxVector, span: span, items: items)

proc copySyntax*(sx: Syntax): Syntax =
  ## Deep-copies `sx` and its children, preserving spans.

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
    newSymbol(sx.sym, sx.span, sx.hygieneId, sx.escaped)
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
  ## Returns a deep copy of `sx` with its top-level span replaced.
  result = sx.copySyntax()
  result.span = span

proc isSymbol*(sx: Syntax; name: string): bool =
  ## True when `sx` is a symbol node whose name is exactly `name`.
  sx.kind == sxSymbol and sx.sym == name

const operatorChars = {'=', '+', '-', '*', '/', '<', '>', '@', '$', '~', '&', '%', '|', '!', '?', '^', '.', ':'}

proc isOperatorName*(s: string): bool =
  ## True when `s` is non-empty and every character is a Nim operator
  ## character — the shape Nim requires an accent-quoted proc name for
  ## (e.g. backtick-quoted ``+``), as opposed to a plain identifier.
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

proc isSetterName*(s: string): bool =
  ## `ident=` — Nim's setter-proc name form, callable as `self.foo = v`
  ## when `s` is `foo=`. Requires at least one base character before the
  ## trailing `=` so the base is itself a plain identifier.
  s.len >= 2 and s[^1] == '=' and isPlainIdentifier(s[0 ..< s.high])

proc isValidRoutineName*(s: string): bool =
  ## A routine (proc/method/func/…) name must be a plain identifier
  ## (optionally with a trailing `*` export marker), a setter name
  ## (`ident=`, see #75), or entirely operator characters (see #29) — not a
  ## mix of plain-identifier and operator characters otherwise, which Nim
  ## cannot express as an `ident`, an `nnkAccQuoted` operator, or a setter.
  if isOperatorName(s):
    return true
  if isSetterName(s):
    return true
  if s.len > 0 and s[^1] == '*':
    isPlainIdentifier(s[0 ..< s.high])
  else:
    isPlainIdentifier(s)

proc splitExportMarker*(sym: string; escaped, allowOperator: bool):
    tuple[base: string, exported: bool, err: string] =
  ## Determines whether `sym`'s trailing `*` is an export marker or part of
  ## the name itself, and splits accordingly. `err` is non-empty when the
  ## name is malformed; callers attach a span and raise.
  ## (Named `err`, not `error` — `error` collides with `diagnostics.error`,
  ## the proc that builds a `Diagnostic`, imported into every caller.)
  ##
  ## `escaped` is true for a name read via the reader's `|...|` syntax
  ## (#46) — inside `|...|` a trailing `*` is never an export marker, so
  ## `|**|` is the unexported two-char operator `**` rather than exported
  ## `*`. An escaped non-operator name ending in `*` (e.g. `|foo*|`) is
  ## rejected: there is no way to apply an export marker inside `|...|`.
  ##
  ## `allowOperator` (routine names only — see #29) additionally accepts
  ## operator names (`+`, `+*`, `**`, …) when unescaped, which are made
  ## entirely of operator characters, so a trailing `*` is ambiguous between
  ## "the operator itself" and "export marker". The marker only applies when
  ## stripping it leaves a nonempty operator name — `+*` is exported `+`,
  ## `**` is exported `*`, but a bare `*` is the unexported `*` operator.
  if escaped:
    if allowOperator and sym.isOperatorName:
      return (sym, false, "")
    if sym.endsWith("*"):
      return ("", false, "export marker is not applied inside |...|")
    return (sym, false, "")
  if allowOperator and sym.isOperatorName:
    if sym.len > 1 and sym.endsWith("*"):
      return (sym[0 ..< sym.high], true, "")
    return (sym, false, "")
  if sym.endsWith("*"):
    let base = sym[0 ..< sym.high]
    if base.len == 0:
      return ("", false, "exported name must have a base name")
    if base.contains("*"):
      return ("", false, "export marker is only allowed at the end of a name")
    return (base, true, "")
  if sym.contains("*"):
    return ("", false, "export marker is only allowed at the end of a name")
  return (sym, false, "")

proc isBlockLabel*(sx: Syntax): bool =
  ## True for a `:name` symbol used as a `block`/`break-from` label — e.g.
  ## the `:search` in `(block :search …)` or `(break-from :search expr)`.
  ## Requires a symbol strictly longer than the bare `:` (which is reserved
  ## as the named-argument marker, see `isNamedArg`) whose first character
  ## is `:` and whose remainder contains no further `:` or `*`.
  sx.kind == sxSymbol and sx.sym.len > 1 and sx.sym[0] == ':' and
    not sx.sym[1 .. ^1].contains(':') and not sx.sym[1 .. ^1].contains('*')

proc blockLabelName*(sx: Syntax): string =
  ## The label name with its leading `:` stripped. Only valid to call when
  ## `isBlockLabel(sx)` holds.
  sx.sym[1 .. ^1]

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
  ## Structural equality: same kind and same value(s), recursively for
  ## lists/vectors. Symbols must also share a `hygieneId`.
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

proc renderSymbol(value: string; escaped = false): string =
  var needsEscape = escaped or value.len == 0 or value in ["nil", "true", "false"] or
    value.isNumberLikeSymbol()
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
  ## Renders `sx` back to NFL source text, escaping symbols and strings as
  ## needed so the result reads back to an equivalent `Syntax` tree.
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
    result = renderSymbol(sx.sym, sx.escaped)
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
