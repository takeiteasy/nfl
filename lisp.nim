# Nim Implementation of Lisp

# Copyright (C) 2025 George Watson

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

import macros, strutils

type
  SourceLoc = object
    line: int
    col: int

  SexpKind = enum skList, skSymbol, skString, skInt, skFloat
  Sexp = ref object
    loc: SourceLoc
    isBracket: bool
    isQuoted: bool
    case kind: SexpKind
    of skList: list: seq[Sexp]
    of skSymbol: symbol: string
    of skString: str: string
    of skInt: intVal: int
    of skFloat: floatVal: float

type
  Parser = object
    s: string
    i: int
    line: int
    col: int

proc initParser(s: string): Parser =
  Parser(s: s, i: 0, line: 1, col: 1)

proc skipWhitespace(p: var Parser) =
  while p.i < p.s.len and p.s[p.i] in {' ', '\n', '\t', '\r'}:
    if p.s[p.i] == '\n':
      p.line += 1
      p.col = 1
    else:
      p.col += 1
    p.i += 1

proc currentLoc(p: Parser): SourceLoc =
  SourceLoc(line: p.line, col: p.col)

proc advance(p: var Parser) =
  if p.i < p.s.len:
    if p.s[p.i] == '\n':
      p.line += 1
      p.col = 1
    else:
      p.col += 1
    p.i += 1

proc parseError(loc: SourceLoc, msg: string): ref ValueError =
  var e: ref ValueError
  new(e)
  e.msg = "line " & $loc.line & ":" & $loc.col & ": " & msg
  return e

proc parseSexp(p: var Parser): Sexp =
  p.skipWhitespace()
  if p.i >= p.s.len: return nil

  let loc = p.currentLoc()

  if p.s[p.i] == '(':
    p.advance()
    var list: seq[Sexp] = @[]
    while p.i < p.s.len and p.s[p.i] != ')':
      let child = p.parseSexp()
      if child != nil:
        list.add(child)
      p.skipWhitespace()
    if p.i < p.s.len and p.s[p.i] == ')':
      p.advance()
      return Sexp(kind: skList, list: list, loc: loc)
    else:
      raise parseError(loc, "unbalanced parentheses")
  elif p.s[p.i] == '@' and p.i + 1 < p.s.len and p.s[p.i + 1] == '[':
    p.advance()
    p.advance()
    var list: seq[Sexp] = @[]
    while p.i < p.s.len and p.s[p.i] != ']':
      let child = p.parseSexp()
      if child != nil:
        list.add(child)
      p.skipWhitespace()
      while p.i < p.s.len and p.s[p.i] == ',':
        p.advance()
        p.skipWhitespace()
    if p.i < p.s.len and p.s[p.i] == ']':
      p.advance()
      return Sexp(kind: skList, list: list, loc: loc, isBracket: true)
    else:
      raise parseError(loc, "unbalanced brackets")
  elif p.s[p.i] == '[':
    p.advance()
    var list: seq[Sexp] = @[]
    while p.i < p.s.len and p.s[p.i] != ']':
      let child = p.parseSexp()
      if child != nil:
        list.add(child)
      p.skipWhitespace()
      while p.i < p.s.len and p.s[p.i] == ',':
        p.advance()
        p.skipWhitespace()
    if p.i < p.s.len and p.s[p.i] == ']':
      p.advance()
      return Sexp(kind: skList, list: list, loc: loc)
    else:
      raise parseError(loc, "unbalanced brackets")
  elif p.s[p.i] == '"':
    p.advance()
    var str = ""
    while p.i < p.s.len and p.s[p.i] != '"':
      if p.s[p.i] == '\\':
        p.advance()
        case p.s[p.i]
        of 'n': str.add('\n')
        of 't': str.add('\t')
        of '"': str.add('"')
        of '\\': str.add('\\')
        else: str.add(p.s[p.i])
      else:
        str.add(p.s[p.i])
      p.advance()
    p.advance()
    return Sexp(kind: skString, str: str, loc: loc)
  elif p.s[p.i] == '\'':
    p.advance()
    let quoted = p.parseSexp()
    if quoted == nil:
      raise parseError(loc, "quote requires an expression")
    if quoted.kind == skList:
      quoted.isQuoted = true
    return quoted
  else:
    var token = ""
    while p.i < p.s.len and p.s[p.i] notin {' ', '\n', '\t', '\r', '(', ')', '[', ']', ',', '\''}:
      token.add(p.s[p.i])
      p.advance()
    if token.len > 0:
      try:
        return Sexp(kind: skInt, intVal: parseInt(token), loc: loc)
      except ValueError:
        try:
          return Sexp(kind: skFloat, floatVal: parseFloat(token), loc: loc)
        except ValueError:
          return Sexp(kind: skSymbol, symbol: token, loc: loc)
    else:
      return nil

proc parseAllSexps(s: string): seq[Sexp] =
  var p = initParser(s)
  result = @[]
  while p.i < s.len:
    p.skipWhitespace()
    if p.i >= s.len: break
    let sexp = p.parseSexp()
    if sexp != nil:
      result.add(sexp)

# Quote a string literal safely for emitted Nim source
proc quoteStr(s: string): string = 
  var res = newStringOfCap(s.len * 2 + 2)
  res.add "\""
  for ch in s:
    case ch
    of '"': res.add "\\\""
    of '\\': res.add "\\\\"
    of '\n': res.add "\\n"
    of '\t': res.add "\\t"
    else: res.add ch
  res.add "\""
  result = res

# Detect operator-like identifiers (non-alphanumeric)
proc isOpIdent(s: string): bool = 
  if s.len == 0: return false
  for ch in s:
    if not (ch.isAlphaNumeric or ch == '_'): return true
  return false

proc emitExpr(n: Sexp, quoted: bool = false): string

proc emitIf(n: Sexp): string =
  if n.list.len != 4:
    raise parseError(n.loc, "if requires 3 arguments: condition, then, else")
  let cond = emitExpr(n.list[1])
  let thenB = emitExpr(n.list[2])
  let elseB = emitExpr(n.list[3])
  return "(if " & cond & ": " & thenB & " else: " & elseB & ")"

proc emitLet(n: Sexp): string =
  if n.list.len != 3:
    raise parseError(n.loc, "let requires 2 arguments: bindings and body")
  let bindings = n.list[1]
  if bindings.kind != skList:
    raise parseError(bindings.loc, "let bindings must be a list")
  var binds = ""
  for binding in bindings.list:
    if binding.kind != skList or binding.list.len != 2:
      raise parseError(binding.loc, "each binding must be (name value)")
    if binding.list[0].kind != skSymbol:
      raise parseError(binding.list[0].loc, "binding name must be a symbol")
    let name = binding.list[0].symbol
    let val = emitExpr(binding.list[1])
    binds.add "  let " & name & " = " & val & "\n"
  let body = emitExpr(n.list[2])
  return "((proc(): auto =\n" & binds & "  return " & body & "\n)())"

proc emitLambda(n: Sexp): string =
  if n.list.len != 3:
    raise parseError(n.loc, "lambda requires 2 arguments: params and body")
  let params = n.list[1]
  if params.kind != skList:
    raise parseError(params.loc, "lambda params must be a list")
  var paramList = ""
  var sep = ""
  for p in params.list:
    if p.kind != skList or p.list.len != 2:
      raise parseError(p.loc, "lambda param must be (name type)")
    if p.list[0].kind != skSymbol or p.list[1].kind != skSymbol:
      raise parseError(p.list[0].loc, "lambda param name and type must be symbols")
    let name = p.list[0].symbol
    let typ = p.list[1].symbol
    paramList.add sep & name & ": " & typ
    sep = ", "
  let body = emitExpr(n.list[2])
  return "(proc(" & paramList & "): auto = return " & body & ")"

proc emitProgn(n: Sexp): string =
  if n.list.len == 1: return "nil"
  var sb = ""
  for i in 1..<n.list.len - 1:
    sb.add "  discard " & emitExpr(n.list[i]) & "\n"
  sb.add "  " & emitExpr(n.list[n.list.len - 1]) & "\n"
  return "((proc(): auto =\n" & sb & ")())"

proc emitCar(n: Sexp): string =
  if n.list.len != 2:
    raise parseError(n.loc, "car requires 1 argument: a list")
  let list = emitExpr(n.list[1])
  return list & "[0]"

proc emitCdr(n: Sexp): string =
  if n.list.len != 2:
    raise parseError(n.loc, "cdr requires 1 argument: a list")
  let list = emitExpr(n.list[1])
  return list & "[1..^1]"

proc emitCons(n: Sexp): string =
  if n.list.len != 3:
    raise parseError(n.loc, "cons requires 2 arguments: an element and a list")
  let elem = emitExpr(n.list[1])
  let list = emitExpr(n.list[2])
  return "(@[" & elem & "] & " & list & ")"

proc emitNullPred(n: Sexp): string =
  if n.list.len != 2:
    raise parseError(n.loc, "null? requires 1 argument")
  let list = emitExpr(n.list[1])
  return "(" & list & ".len == 0)"

proc emitListPred(n: Sexp): string =
  if n.list.len != 2:
    raise parseError(n.loc, "list? requires 1 argument")
  let expr = emitExpr(n.list[1])
  return "compiles(" & expr & "[0])"

proc emitLength(n: Sexp): string =
  if n.list.len != 2:
    raise parseError(n.loc, "length requires 1 argument")
  let list = emitExpr(n.list[1])
  return "(" & list & ".len)"

proc emitAppend(n: Sexp): string =
  if n.list.len < 2:
    raise parseError(n.loc, "append requires at least 1 argument")
  var output = emitExpr(n.list[1])
  for i in 2..<n.list.len:
    let next = emitExpr(n.list[i])
    output = "(" & output & " & " & next & ")"
  return output

proc emitList(n: Sexp): string =
  var args = ""
  var sep = ""
  for i in 1..<n.list.len:
    args.add sep & emitExpr(n.list[i])
    sep = ", "
  return "@[" & args & "]"

proc emitReverse(n: Sexp): string =
  if n.list.len != 2:
    raise parseError(n.loc, "reverse requires 1 argument")
  let list = emitExpr(n.list[1])
  return "block:\n  var revtmp = " & list & "\n  for i in 0 .. revtmp.len div 2 - 1:\n    let j = revtmp.len - 1 - i\n    let tmp = revtmp[i]\n    revtmp[i] = revtmp[j]\n    revtmp[j] = tmp\n  revtmp"

proc emitExpr(n: Sexp, quoted: bool = false): string =
  if n == nil: return "nil"
  case n.kind
  of skSymbol:
    if quoted:
      return quoteStr(n.symbol)
    return n.symbol
  of skString:
    return quoteStr(n.str)
  of skInt:
    return $n.intVal
  of skFloat:
    return $n.floatVal
  of skList:
    if n.list.len == 0:
      return "@[]"
    if n.isQuoted or quoted:
      var args = ""
      var sep = ""
      for item in n.list:
        args.add sep & emitExpr(item, true)
        sep = ", "
      return "@[" & args & "]"
    if n.isBracket:
      var args = ""
      var sep = ""
      for item in n.list:
        args.add sep & emitExpr(item)
        sep = ", "
      return "@[" & args & "]"
    let opNode = n.list[0]
    if opNode.kind != skSymbol:
      raise parseError(opNode.loc, "operator must be a symbol")
    let op = opNode.symbol

    case op
    of "if": return emitIf(n)
    of "let": return emitLet(n)
    of "lambda": return emitLambda(n)
    of "progn": return emitProgn(n)
    of "car": return emitCar(n)
    of "cdr": return emitCdr(n)
    of "cons": return emitCons(n)
    of "null?": return emitNullPred(n)
    of "list?": return emitListPred(n)
    of "length": return emitLength(n)
    of "append": return emitAppend(n)
    of "list": return emitList(n)
    of "reverse": return emitReverse(n)
    else:
      if isOpIdent(op) and n.list.len == 3:
        return "(" & emitExpr(n.list[1]) & " " & op & " " & emitExpr(n.list[2]) & ")"
      elif isOpIdent(op) and n.list.len > 3:
        var folded = emitExpr(n.list[1])
        for i in 2..<n.list.len:
          folded = "(" & folded & " " & op & " " & emitExpr(n.list[i]) & ")"
        return folded
      else:
        var opStr = op
        if isOpIdent(op):
          opStr = "(" & op & ")"
        var args = ""
        var sep = ""
        for i in 1..<n.list.len:
          args.add sep & emitExpr(n.list[i])
          sep = ", "
        return opStr & "(" & args & ")"

proc lispToNim*(code: string): string =
  let sexps = parseAllSexps(code)
  if sexps.len == 0:
    return ""
  elif sexps.len == 1:
    return emitExpr(sexps[0])
  else:
    var output = ""
    for sexp in sexps:
      output.add emitExpr(sexp) & "\n"
    return output

macro lisp*(body: string): untyped =
  try:
    let sexps = parseAllSexps(body.strVal)
    if sexps.len == 0:
      result = newStmtList()
    elif sexps.len == 1:
      let src = emitExpr(sexps[0])
      result = parseStmt(src)
    else:
      var stmts = newStmtList()
      for j in 0..<sexps.len - 1:
        let src = emitExpr(sexps[j])
        stmts.add parseStmt("discard " & src)
      let lastSrc = emitExpr(sexps[sexps.len - 1])
      stmts.add parseStmt(lastSrc)
      result = stmts
  except ValueError as e:
    error(e.msg)

