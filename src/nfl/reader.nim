import std/strutils

import ./diagnostics
import ./syntax

type Reader = object
  source: string
  file: string
  pos: int
  line: int
  col: int

proc currentSpan(r: Reader): Span =
  span(r.file, r.line, r.col, r.line, r.col)

proc atEnd(r: Reader): bool =
  r.pos >= r.source.len

proc peek(r: Reader): char =
  if r.atEnd: '\0' else: r.source[r.pos]

proc peekNext(r: Reader): char =
  if r.pos + 1 >= r.source.len: '\0' else: r.source[r.pos + 1]

proc advance(r: var Reader): char =
  result = r.peek
  if r.atEnd:
    return
  inc r.pos
  if result == '\n':
    inc r.line
    r.col = 1
  else:
    inc r.col

proc isWhitespace(c: char): bool =
  c in {' ', '\t', '\r', '\n'}

proc isDelimiter(c: char): bool =
  c == '\0' or c.isWhitespace or c in {'(', ')', '[', ']', '\'', '`', ',', '"', ';', '|'}

proc skipTrivia(r: var Reader) =
  while not r.atEnd:
    if r.peek.isWhitespace:
      discard r.advance()
    elif r.peek == ';':
      while not r.atEnd and r.peek != '\n':
        discard r.advance()
    elif r.peek == '#' and r.peekNext == '|':
      let start = r.currentSpan
      discard r.advance()
      discard r.advance()
      var closed = false
      while not r.atEnd:
        if r.peek == '|' and r.peekNext == '#':
          discard r.advance()
          discard r.advance()
          closed = true
          break
        discard r.advance()
      if not closed:
        raiseReaderError(start, "unterminated block comment")
    else:
      break

proc readForm(r: var Reader): Syntax

proc readString(r: var Reader): Syntax =
  let start = r.currentSpan
  discard r.advance()
  var value = ""
  while not r.atEnd:
    let c = r.advance()
    case c
    of '"':
      return newString(value, start.withEnd(r.line, r.col))
    of '\\':
      if r.atEnd:
        raiseReaderError(start, "unterminated string literal")
      let escaped = r.advance()
      case escaped
      of 'n': value.add '\n'
      of 'r': value.add '\r'
      of 't': value.add '\t'
      of '"': value.add '"'
      of '\\': value.add '\\'
      else:
        raiseReaderError(r.currentSpan, "invalid string escape: \\" & $escaped)
    else:
      value.add c
  raiseReaderError(start, "unterminated string literal")

proc readEscapedSymbol(r: var Reader): Syntax =
  let start = r.currentSpan
  discard r.advance()
  var value = ""
  while not r.atEnd:
    let c = r.advance()
    case c
    of '|':
      if value.len == 0:
        raiseReaderError(start, "escaped symbol cannot be empty")
      return newSymbol(value, start.withEnd(r.line, r.col))
    of '\\':
      if r.atEnd:
        raiseReaderError(start, "unterminated escaped symbol")
      let escaped = r.advance()
      case escaped
      of '|': value.add '|'
      of '\\': value.add '\\'
      else:
        raiseReaderError(r.currentSpan, "invalid escaped symbol escape: \\" & $escaped)
    else:
      value.add c
  raiseReaderError(start, "unterminated escaped symbol")

proc readDelimited(r: var Reader; closeChar: char; vector: bool; start: Span): Syntax =
  var items: seq[Syntax] = @[]
  while true:
    r.skipTrivia()
    if r.atEnd:
      let kind = if vector: "vector" else: "list"
      raiseReaderError(start, "unterminated " & kind)
    if r.peek == closeChar:
      discard r.advance()
      let fullSpan = start.withEnd(r.line, r.col)
      if vector:
        return newVector(items, fullSpan)
      return newList(items, fullSpan)
    items.add r.readForm()

proc readPragma(r: var Reader; start: Span): Syntax =
  ## Reads a Nim pragma clause `{.p1 p2.}` or `{.p1, p2.}` and returns it as a
  ## list headed by the symbol `pragma`, e.g. `(pragma inline cdecl)`.
  ## `r` must still be pointing at `{` when called; both `{` and `.` are consumed
  ## inside this proc.
  discard r.advance()  # consume `{`
  discard r.advance()  # consume `.`
  var markers: seq[Syntax] = @[]
  while true:
    r.skipTrivia()
    if r.atEnd:
      raiseReaderError(start, "unterminated pragma")
    if r.peek == '.' and r.peekNext == '}':
      discard r.advance()  # `.`
      discard r.advance()  # `}`
      break
    if r.peek == ',':
      discard r.advance()  # skip `,` separator
      continue
    # Read one marker identifier, stopping before whitespace, `,`, `.`, or `}`.
    let mStart = r.currentSpan
    var token = ""
    while not r.atEnd and r.peek notin {' ', '\t', '\r', '\n', ',', '.', '}', '\0'}:
      token.add r.advance()
    if token.len == 0:
      raiseReaderError(r.currentSpan, "expected pragma marker")
    markers.add newSymbol(token, mStart.withEnd(r.line, r.col))
  let fullSpan = start.withEnd(r.line, r.col)
  var items: seq[Syntax] = @[newSymbol("pragma", start)]
  for m in markers:
    items.add m
  newList(items, fullSpan)

proc readQuote(r: var Reader; name: string; start: Span): Syntax =
  r.skipTrivia()
  if r.atEnd or r.peek in {')', ']'}:
    raiseReaderError(start, "expected expression after " & name)
  let expr = r.readForm()
  let fullSpan = start.withEnd(expr.span.endLine, expr.span.endCol)
  newList(@[newSymbol(name, start), expr], fullSpan)

proc isNumberToken(token: string): bool =
  if token.len == 0:
    return false
  if token[0] in {'+', '-'}:
    return token.len > 1 and token[1].isDigit
  token[0].isDigit

proc readAtom(r: var Reader): Syntax =
  let start = r.currentSpan
  var token = ""
  while not r.atEnd and not r.peek.isDelimiter:
    token.add r.advance()
  let fullSpan = start.withEnd(r.line, r.col)

  case token
  of "nil": return newNil(fullSpan)
  of "true": return newBool(true, fullSpan)
  of "false": return newBool(false, fullSpan)
  else: discard

  if token.isNumberToken:
    if token.contains('.'):
      try:
        return newFloat(BiggestFloat(parseFloat(token)), fullSpan)
      except ValueError:
        discard
    else:
      try:
        return newInt(parseBiggestInt(token), fullSpan)
      except ValueError:
        discard

  newSymbol(token, fullSpan)

proc readForm(r: var Reader): Syntax =
  r.skipTrivia()
  if r.atEnd:
    raiseReaderError(r.currentSpan, "expected expression")

  let start = r.currentSpan
  case r.peek
  of '(':
    discard r.advance()
    readDelimited(r, ')', false, start)
  of '[':
    discard r.advance()
    readDelimited(r, ']', true, start)
  of ')', ']':
    raiseReaderError(start, "unexpected closing delimiter")
  of '"':
    readString(r)
  of '|':
    readEscapedSymbol(r)
  of '{':
    if r.peekNext == '.':
      readPragma(r, start)
    else:
      readAtom(r)
  of '\'':
    discard r.advance()
    readQuote(r, "quote", start)
  of '`':
    discard r.advance()
    readQuote(r, "quasiquote", start)
  of ',':
    discard r.advance()
    if r.peek == '@':
      discard r.advance()
      readQuote(r, "unquote-splicing", start)
    else:
      readQuote(r, "unquote", start)
  else:
    readAtom(r)

proc readAll*(source: string; file = "<input>"): seq[Syntax] =
  var reader = Reader(source: source, file: file, line: 1, col: 1)
  while true:
    reader.skipTrivia()
    if reader.atEnd:
      break
    result.add reader.readForm()

proc readOne*(source: string; file = "<input>"): Syntax =
  let forms = readAll(source, file)
  if forms.len == 0:
    raiseReaderError(span(file, 1, 1, 1, 1), "expected expression")
  if forms.len > 1:
    raiseReaderError(forms[1].span, "expected exactly one expression")
  forms[0]
