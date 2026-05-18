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

const runtimeHelpers* = """
template apply(f: untyped, args: untyped): untyped =
  f(args[0])
"""

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

proc currentLoc(p: Parser): SourceLoc

proc parseError(loc: SourceLoc, msg: string): ref ValueError

proc skipWhitespace(p: var Parser) =
  while p.i < p.s.len:
    if p.s[p.i] in {' ', '\n', '\t', '\r'}:
      if p.s[p.i] == '\n':
        p.line += 1
        p.col = 1
      else:
        p.col += 1
      p.i += 1
    elif p.s[p.i] == ';':
      while p.i < p.s.len and p.s[p.i] != '\n':
        p.i += 1
    elif p.i + 1 < p.s.len and p.s[p.i] == '#' and p.s[p.i + 1] == '|':
      p.i += 2
      while p.i + 1 < p.s.len and not (p.s[p.i] == '|' and p.s[p.i + 1] == '#'):
        if p.s[p.i] == '\n':
          p.line += 1
          p.col = 1
        else:
          p.col += 1
        p.i += 1
      if p.i + 1 < p.s.len:
        p.i += 2
      else:
        raise parseError(p.currentLoc(), "unterminated block comment")
    else:
      break

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
    while p.i < p.s.len and p.s[p.i] notin {' ', '\n', '\t', '\r', '(', ')', '[', ']', ',', '\'', ';', '#'}:
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

proc isOpIdent(s: string): bool =
  if s.len == 0: return false
  for ch in s:
    if ch.isAlphaNumeric or ch == '_': return false
  return true

proc sanitizeName(s: string): string =
  result = newStringOfCap(s.len)
  for ch in s:
    case ch
    of '-': result.add '_'
    of '?': result.add 'p'
    of '!': discard
    else: result.add ch

proc isDefine(n: Sexp): bool

proc opName(n: Sexp): string =
  if n.kind == skList and n.list.len > 0 and n.list[0].kind == skSymbol:
    return n.list[0].symbol
  return ""

proc emitExpr(n: Sexp, quoted: bool = false): string
proc emitBody(exprs: seq[Sexp]): string
proc emitDefine(n: Sexp, topLevel: bool): string
proc indentLines(s: string, spaces: int): string

proc forceValue(n: Sexp): string =
  result = emitExpr(n)
  if opName(n) in ["echo", "stdout.write", "stderr.write"]:
    result = "(" & result & "; 0)"

proc emitIf(n: Sexp): string =
  if n.list.len != 4:
    raise parseError(n.loc, "if requires 3 arguments: condition, then, else")
  let cond = emitExpr(n.list[1])
  let thenB = forceValue(n.list[2])
  let elseB = forceValue(n.list[3])
  return "(if " & cond & ": " & thenB & " else: " & elseB & ")"

proc emitLet(n: Sexp): string =
  if n.list.len < 3:
    raise parseError(n.loc, "let requires bindings and at least 1 body expression")
  let bindings = n.list[1]
  if bindings.kind != skList:
    raise parseError(bindings.loc, "let bindings must be a list")
  var binds = ""
  for binding in bindings.list:
    if binding.kind != skList or binding.list.len != 2:
      raise parseError(binding.loc, "each binding must be (name value)")
    if binding.list[0].kind != skSymbol:
      raise parseError(binding.list[0].loc, "binding name must be a symbol")
    let name = sanitizeName(binding.list[0].symbol)
    let val = emitExpr(binding.list[1])
    if val.contains("\n"):
      binds.add "  var " & name & " = " & val.replace("\n", "\n  ") & "\n"
    else:
      binds.add "  var " & name & " = " & val & "\n"
  var body = ""
  for i in 2..<n.list.len - 1:
    body.add "  discard " & forceValue(n.list[i]) & "\n"
  body.add "  " & forceValue(n.list[n.list.len - 1]) & "\n"
  return "(block:\n" & binds & body & ")"

proc emitLambda(n: Sexp): string =
  if n.list.len != 3:
    raise parseError(n.loc, "lambda requires 2 arguments: params and body")
  let params = n.list[1]
  if params.kind != skList:
    raise parseError(params.loc, "lambda params must be a list")
  var paramList = ""
  var sep = ""
  for p in params.list:
    if p.kind == skSymbol:
      let name = sanitizeName(p.symbol)
      paramList.add sep & name & ": auto"
      sep = ", "
    elif p.kind == skList:
      if p.list.len != 2:
        raise parseError(p.loc, "typed param must be (name type)")
      if p.list[0].kind != skSymbol or p.list[1].kind != skSymbol:
        raise parseError(p.list[0].loc, "param name and type must be symbols")
      let name = sanitizeName(p.list[0].symbol)
      let typ = p.list[1].symbol
      paramList.add sep & name & ": " & typ
      sep = ", "
    else:
      raise parseError(p.loc, "param must be a symbol or (name type)")
  let bodyContent = emitBody(@[n.list[2]])
  return "(proc(" & paramList & "): auto =\n" & indentLines(bodyContent, 2) & "\n)"

proc emitProgn(n: Sexp): string =
  if n.list.len == 1: return "nil"
  var sb = ""
  for i in 1..<n.list.len - 1:
    sb.add "  discard " & forceValue(n.list[i]) & "\n"
  sb.add "  " & forceValue(n.list[n.list.len - 1]) & "\n"
  return "(block:\n" & sb & ")"

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

proc emitReverse(n: Sexp): string =
  if n.list.len != 2:
    raise parseError(n.loc, "reverse requires 1 argument")
  let list = emitExpr(n.list[1])
  return "block:\n  var revtmp = " & list & "\n  for i in 0 .. revtmp.len div 2 - 1:\n    let j = revtmp.len - 1 - i\n    let tmp = revtmp[i]\n    revtmp[i] = revtmp[j]\n    revtmp[j] = tmp\n  revtmp"

proc emitSet(n: Sexp): string =
  if n.list.len != 3:
    raise parseError(n.loc, "set! requires 2 arguments: name and value")
  if n.list[1].kind != skSymbol:
    raise parseError(n.list[1].loc, "set! name must be a symbol")
  let name = sanitizeName(n.list[1].symbol)
  let val = emitExpr(n.list[2])
  return "(block: " & name & " = " & val & "; " & name & ")"

proc emitCond(n: Sexp): string =
  if n.list.len < 2:
    raise parseError(n.loc, "cond requires at least 1 clause")
  var output = "(if "
  var first = true
  for i in 1..<n.list.len:
    let clause = n.list[i]
    if clause.kind != skList or clause.list.len < 2:
      raise parseError(clause.loc, "each cond clause must be (test body...)")
    let test = clause.list[0]
    var bodyStr = forceValue(clause.list[1])
    for j in 2..<clause.list.len:
      bodyStr = "(discard " & bodyStr & "; " & forceValue(clause.list[j]) & ")"
    if test.kind == skSymbol and test.symbol == "else":
      if not first:
        output.add " "
      output.add "else: " & bodyStr
    else:
      if first:
        output.add emitExpr(test) & ": " & bodyStr
        first = false
      else:
        output.add " elif " & emitExpr(test) & ": " & bodyStr
  output.add ")"
  return output

proc emitAnd(n: Sexp): string =
  if n.list.len < 2:
    raise parseError(n.loc, "and requires at least 1 argument")
  if n.list.len == 2:
    return emitExpr(n.list[1])
  var output = emitExpr(n.list[1])
  for i in 2..<n.list.len:
    output = "(if " & output & ": " & emitExpr(n.list[i]) & " else: false)"
  return output

proc emitOr(n: Sexp): string =
  if n.list.len < 2:
    raise parseError(n.loc, "or requires at least 1 argument")
  if n.list.len == 2:
    return emitExpr(n.list[1])
  var output = emitExpr(n.list[1])
  for i in 2..<n.list.len:
    output = "(if " & output & ": " & output & " else: " & emitExpr(n.list[i]) & ")"
  return output

proc emitApply(n: Sexp): string =
  if n.list.len != 3:
    raise parseError(n.loc, "apply requires 2 arguments: function and list")
  let fn = emitExpr(n.list[1])
  let lst = emitExpr(n.list[2])
  return "apply(" & fn & ", " & lst & ")"

proc emitWhile(n: Sexp): string =
  if n.list.len < 3:
    raise parseError(n.loc, "while requires at least 2 arguments: condition and body")
  let cond = emitExpr(n.list[1])
  var body = ""
  for i in 2..<n.list.len:
    body.add (if body.len > 0: "\n" else: "") & "discard " & forceValue(n.list[i])
  return "(block:\n  while " & cond & ":\n" & indentLines(body, 4) & "\n  nil)"

proc emitZeroPred(n: Sexp): string =
  if n.list.len != 2:
    raise parseError(n.loc, "zero? requires 1 argument")
  return "(" & emitExpr(n.list[1]) & " == 0)"

proc emitPositivePred(n: Sexp): string =
  if n.list.len != 2:
    raise parseError(n.loc, "positive? requires 1 argument")
  return "(" & emitExpr(n.list[1]) & " > 0)"

proc emitNegativePred(n: Sexp): string =
  if n.list.len != 2:
    raise parseError(n.loc, "negative? requires 1 argument")
  return "(" & emitExpr(n.list[1]) & " < 0)"

proc emitEvenPred(n: Sexp): string =
  if n.list.len != 2:
    raise parseError(n.loc, "even? requires 1 argument")
  return "(((" & emitExpr(n.list[1]) & " mod 2) == 0)"

proc emitOddPred(n: Sexp): string =
  if n.list.len != 2:
    raise parseError(n.loc, "odd? requires 1 argument")
  return "(((" & emitExpr(n.list[1]) & " mod 2) != 0)"

proc emitComparisonChain(n: Sexp, nimOp: string): string =
  if n.list.len < 3:
    raise parseError(n.loc, "comparison requires at least 2 arguments")
  if n.list.len == 3:
    return "(" & emitExpr(n.list[1]) & " " & nimOp & " " & emitExpr(n.list[2]) & ")"
  var blockStr = "block:\n"
  for i in 1..<n.list.len:
    blockStr.add "  let x" & $i & " = " & emitExpr(n.list[i]) & "\n"
  blockStr.add "  ("
  for i in 1..<n.list.len - 1:
    if i > 1: blockStr.add " and "
    blockStr.add "x" & $i & " " & nimOp & " x" & $(i + 1)
  blockStr.add ")"
  return "(" & blockStr & "\n)"

proc isDefine(n: Sexp): bool =
  n.kind == skList and n.list.len > 0 and
  n.list[0].kind == skSymbol and n.list[0].symbol == "define"

proc emitBody(exprs: seq[Sexp]): string =
  var bindings = ""
  var bodyExprs: seq[Sexp] = @[]

  for expr in exprs:
    if isDefine(expr):
      bindings.add emitDefine(expr, false) & "\n"
    else:
      bodyExprs.add(expr)

  if bodyExprs.len == 0:
    return bindings & "nil"

  var body = ""
  for i in 0..<bodyExprs.len - 1:
    body.add "discard " & forceValue(bodyExprs[i]) & "\n"
  body.add emitExpr(bodyExprs[bodyExprs.len - 1]) & "\n"

  return bindings & body

proc indentLines(s: string, spaces: int): string =
  let prefix = repeat(' ', spaces)
  result = ""
  var first = true
  for line in s.splitLines():
    if line.strip().len == 0: continue
    if not first:
      result.add "\n"
    result.add prefix & line
    first = false

proc emitDefine(n: Sexp, topLevel: bool): string =
  if n.list.len < 3:
    raise parseError(n.loc, "define requires name and value")

  if n.list[1].kind == skSymbol:
    let name = sanitizeName(n.list[1].symbol)
    if n.list.len == 3:
      let val = emitExpr(n.list[2])
      return "let " & name & " = " & val
    else:
      var bodyContent = emitBody(n.list[2..^1])
      return "let " & name & " = (block:\n" & indentLines(bodyContent, 2) & "\n)"
  elif n.list[1].kind == skList:
    let nameNode = n.list[1].list[0]
    if nameNode.kind != skSymbol:
      raise parseError(nameNode.loc, "function name must be a symbol")
    let name = sanitizeName(nameNode.symbol)
    var params = ""
    var sep = ""
    for i in 1..<n.list[1].list.len:
      let p = n.list[1].list[i]
      if p.kind == skSymbol:
        params.add sep & sanitizeName(p.symbol) & ": auto"
        sep = ", "
      elif p.kind == skList:
        if p.list.len != 2:
          raise parseError(p.loc, "typed param must be (name type)")
        params.add sep & sanitizeName(p.list[0].symbol) & ": " & p.list[1].symbol
        sep = ", "
      else:
        raise parseError(p.loc, "param must be a symbol or (name type)")

    let bodyContent = emitBody(n.list[2..^1])

    return "proc " & name & "(" & params & "): auto =\n" & indentLines(bodyContent, 2) & "\n"
  else:
    raise parseError(n.list[1].loc, "define name must be a symbol or (name params...)")

proc emitExpr(n: Sexp, quoted: bool = false): string =
  if n == nil: return "nil"
  case n.kind
  of skSymbol:
    if quoted:
      return quoteStr(n.symbol)
    return sanitizeName(n.symbol)
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
    of "reverse": return emitReverse(n)
    of "set!": return emitSet(n)
    of "define": return emitDefine(n, false)
    of "cond": return emitCond(n)
    of "and": return emitAnd(n)
    of "or": return emitOr(n)
    of "list":
      var args = ""
      var sep = ""
      for i in 1..<n.list.len:
        args.add sep & emitExpr(n.list[i])
        sep = ", "
      return "@[" & args & "]"
    of "map":
      if n.list.len != 3:
        raise parseError(n.loc, "map requires 2 arguments: function and list")
      let fn = emitExpr(n.list[1])
      let lst = emitExpr(n.list[2])
      let fnIndented = indentLines(fn, 6)
      return "block:\n    var r: seq[type(" & lst & "[0])] = @[]\n    for x in " & lst & ":\n      r.add((" & fnIndented & ")(x))\n    r"
    of "filter":
      if n.list.len != 3:
        raise parseError(n.loc, "filter requires 2 arguments: predicate and list")
      let pred = emitExpr(n.list[1])
      let lst = emitExpr(n.list[2])
      let predIndented = indentLines(pred, 6)
      return "block:\n    var r: seq[type(" & lst & "[0])] = @[]\n    for x in " & lst & ":\n      if (" & predIndented & ")(x):\n        r.add(x)\n    r"
    of "apply": return emitApply(n)
    of "while": return emitWhile(n)
    of "zero?": return emitZeroPred(n)
    of "positive?": return emitPositivePred(n)
    of "negative?": return emitNegativePred(n)
    of "even?": return emitEvenPred(n)
    of "odd?": return emitOddPred(n)
    of "=": return emitComparisonChain(n, "==")
    of "<=": return emitComparisonChain(n, "<=")
    of ">=": return emitComparisonChain(n, ">=")
    of "$":
      if n.list.len != 2:
        raise parseError(n.loc, "$ requires 1 argument")
      return "$(" & emitExpr(n.list[1]) & ")"
    of "mod":
      if n.list.len != 3:
        raise parseError(n.loc, "mod requires 2 arguments")
      return "(" & emitExpr(n.list[1]) & " mod " & emitExpr(n.list[2]) & ")"
    of "div":
      if n.list.len != 3:
        raise parseError(n.loc, "div requires 2 arguments")
      return "(" & emitExpr(n.list[1]) & " div " & emitExpr(n.list[2]) & ")"
    else:
      if isOpIdent(op) and n.list.len == 3:
        return "(" & emitExpr(n.list[1]) & " " & op & " " & emitExpr(n.list[2]) & ")"
      elif isOpIdent(op) and n.list.len > 3:
        var folded = emitExpr(n.list[1])
        for i in 2..<n.list.len:
          folded = "(" & folded & " " & op & " " & emitExpr(n.list[i]) & ")"
        return folded
      else:
        var opStr = sanitizeName(op)
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
  var output = "import std/nil\n\n"
  for i, sexp in sexps:
    if sexp.kind == skList and sexp.list.len > 0 and
       sexp.list[0].kind == skSymbol and sexp.list[0].symbol == "define":
      output.add emitDefine(sexp, true) & "\n"
    else:
      output.add "discard " & forceValue(sexp) & "\n"
  return output

proc transpileNoStdlib*(code: string): string =
  let sexps = parseAllSexps(code)
  if sexps.len == 0:
    return ""
  var output = ""
  for i, sexp in sexps:
    if sexp.kind == skList and sexp.list.len > 0 and
       sexp.list[0].kind == skSymbol and sexp.list[0].symbol == "define":
      output.add emitDefine(sexp, true) & "\n"
    else:
      output.add "discard " & forceValue(sexp) & "\n"
  return runtimeHelpers & "\n" & output

macro lisp*(body: string): untyped =
  try:
    let sexps = parseAllSexps(body.strVal)
    if sexps.len == 0:
      result = newStmtList()
    else:
      var stmts = newStmtList()
      stmts.add parseStmt(runtimeHelpers)
      for j in 0..<sexps.len - 1:
        let s = sexps[j]
        if s.kind == skList and s.list.len > 0 and
           s.list[0].kind == skSymbol and s.list[0].symbol == "define":
          let src = emitDefine(s, true)
          stmts.add parseStmt(src)
        else:
          let src = emitExpr(s)
          stmts.add parseStmt("discard " & src)
      let lastSexp = sexps[sexps.len - 1]
      if lastSexp.kind == skList and lastSexp.list.len > 0 and
         lastSexp.list[0].kind == skSymbol and lastSexp.list[0].symbol == "define":
        let src = emitDefine(lastSexp, true)
        stmts.add parseStmt(src)
      else:
        let lastSrc = emitExpr(lastSexp)
        stmts.add parseStmt(lastSrc)
      result = stmts
  except ValueError as e:
    error(e.msg)
