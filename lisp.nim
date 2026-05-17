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
  SexpKind = enum skList, skSymbol, skString, skInt, skFloat
  Sexp = ref object
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

proc initParser(s: string): Parser =
  Parser(s: s, i: 0)

proc skipWhitespace(p: var Parser) =
  while p.i < p.s.len and p.s[p.i] in {' ', '\n', '\t', '\r'}:
    p.i += 1

proc parseSexp(p: var Parser): Sexp =
  p.skipWhitespace()
  if p.i >= p.s.len: return nil

  if p.s[p.i] == '(':
    p.i += 1
    var list: seq[Sexp] = @[]
    while p.i < p.s.len and p.s[p.i] != ')':
      let child = p.parseSexp()
      if child != nil:
        list.add(child)
      p.skipWhitespace()
    if p.i < p.s.len and p.s[p.i] == ')':
      p.i += 1
      return Sexp(kind: skList, list: list)
    else:
      raise newException(ValueError, "unbalanced parentheses")
  elif p.s[p.i] == '"':
    p.i += 1
    var str = ""
    while p.i < p.s.len and p.s[p.i] != '"':
      if p.s[p.i] == '\\':
        p.i += 1
        case p.s[p.i]
        of 'n': str.add('\n')
        of 't': str.add('\t')
        of '"': str.add('"')
        of '\\': str.add('\\')
        else: str.add(p.s[p.i])
      else:
        str.add(p.s[p.i])
      p.i += 1
    p.i += 1
    return Sexp(kind: skString, str: str)
  else:
    var token = ""
    while p.i < p.s.len and p.s[p.i] notin {' ', '\n', '\t', '\r', '(', ')'}:
      token.add(p.s[p.i])
      p.i += 1
    if token.len > 0:
      try:
        return Sexp(kind: skInt, intVal: parseInt(token))
      except ValueError:
        try:
          return Sexp(kind: skFloat, floatVal: parseFloat(token))
        except ValueError:
          return Sexp(kind: skSymbol, symbol: token)
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

proc emitExpr(n: Sexp): string

proc emitIf(n: Sexp): string =
  if n.list.len != 4:
    raise newException(ValueError, "if requires 3 arguments: condition, then, else")
  let cond = emitExpr(n.list[1])
  let thenB = emitExpr(n.list[2])
  let elseB = emitExpr(n.list[3])
  return "(if " & cond & ": " & thenB & " else: " & elseB & ")"

proc emitLet(n: Sexp): string =
  if n.list.len != 3:
    raise newException(ValueError, "let requires 2 arguments: bindings and body")
  let bindings = n.list[1]
  if bindings.kind != skList:
    raise newException(ValueError, "let bindings must be a list")
  var binds = ""
  for binding in bindings.list:
    if binding.kind != skList or binding.list.len != 2:
      raise newException(ValueError, "each binding must be (name value)")
    if binding.list[0].kind != skSymbol:
      raise newException(ValueError, "binding name must be a symbol")
    let name = binding.list[0].symbol
    let val = emitExpr(binding.list[1])
    binds.add "  let " & name & " = " & val & "\n"
  let body = emitExpr(n.list[2])
  return "((proc(): auto =\n" & binds & "  return " & body & "\n)())"

proc emitLambda(n: Sexp): string =
  if n.list.len != 3:
    raise newException(ValueError, "lambda requires 2 arguments: params and body")
  let params = n.list[1]
  if params.kind != skList:
    raise newException(ValueError, "lambda params must be a list")
  var paramList = ""
  var sep = ""
  for p in params.list:
    if p.kind != skList or p.list.len != 2:
      raise newException(ValueError, "lambda param must be (name type)")
    if p.list[0].kind != skSymbol or p.list[1].kind != skSymbol:
      raise newException(ValueError, "lambda param name and type must be symbols")
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
    raise newException(ValueError, "car requires 1 argument: a list")
  let list = emitExpr(n.list[1])
  return list & "[0]"

proc emitCdr(n: Sexp): string =
  if n.list.len != 2:
    raise newException(ValueError, "cdr requires 1 argument: a list")
  let list = emitExpr(n.list[1])
  return list & "[1..^1]"

proc emitCons(n: Sexp): string =
  if n.list.len != 3:
    raise newException(ValueError, "cons requires 2 arguments: an element and a list")
  let elem = emitExpr(n.list[1])
  let list = emitExpr(n.list[2])
  return "(@[" & elem & "] & " & list & ")"

proc emitExpr(n: Sexp): string =
  if n == nil: return "nil"
  case n.kind
  of skSymbol:
    return n.symbol
  of skString:
    return quoteStr(n.str)
  of skInt:
    return $n.intVal
  of skFloat:
    return $n.floatVal
  of skList:
    if n.list.len == 0:
      return "nil"
    let opNode = n.list[0]
    if opNode.kind != skSymbol:
      raise newException(ValueError, "operator must be a symbol")
    let op = opNode.symbol

    case op
    of "if": return emitIf(n)
    of "let": return emitLet(n)
    of "lambda": return emitLambda(n)
    of "progn": return emitProgn(n)
    of "car": return emitCar(n)
    of "cdr": return emitCdr(n)
    of "cons": return emitCons(n)
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
      result = parseExpr(src)
    else:
      var stmts = newStmtList()
      for j in 0..<sexps.len - 1:
        let src = emitExpr(sexps[j])
        stmts.add parseStmt("discard " & src)
      let lastSrc = emitExpr(sexps[sexps.len - 1])
      stmts.add parseExpr(lastSrc)
      result = stmts
  except ValueError as e:
    error(e.msg)

