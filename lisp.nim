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

import os, macros, strutils, tables

const runtimeHelpers* = """
template apply(f: untyped, args: untyped): untyped =
  f(args[0])
"""

type
  SourceLoc = object
    line: int
    col: int

  SexpKind = enum skList, skSymbol, skString, skInt, skFloat, skQuasiquote, skUnquote, skUnquoteSplicing, skClosure
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
    of skQuasiquote, skUnquote, skUnquoteSplicing: child: Sexp
    of skClosure:
      closParams: seq[Sexp]
      closRestParam: string
      closBody: Sexp

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
  elif p.s[p.i] == '`':
    p.advance()
    let qq = p.parseSexp()
    if qq == nil:
      raise parseError(loc, "quasiquote requires an expression")
    return Sexp(kind: skQuasiquote, child: qq, loc: loc)
  elif p.s[p.i] == ',':
    p.advance()
    if p.i < p.s.len and p.s[p.i] == '@':
      p.advance()
      let uqs = p.parseSexp()
      if uqs == nil:
        raise parseError(loc, "unquote-splicing requires an expression")
      return Sexp(kind: skUnquoteSplicing, child: uqs, loc: loc)
    else:
      let uq = p.parseSexp()
      if uq == nil:
        raise parseError(loc, "unquote requires an expression")
      return Sexp(kind: skUnquote, child: uq, loc: loc)
  else:
    var token = ""
    while p.i < p.s.len and p.s[p.i] notin {' ', '\n', '\t', '\r', '(', ')', '[', ']', ',', '\'', ';', '#', '`', '@'}:
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


type
  MacroDef = object
    params: seq[Sexp]
    restParam: string
    body: Sexp

  MacroEnv = ref object
    bindings: Table[string, MacroDef]

  EnvEntryKind = enum eekSexp, eekClosure
  EnvEntry = object
    case kind: EnvEntryKind
    of eekSexp:
      value: Sexp
    of eekClosure:
      params: seq[Sexp]
      restParam: string
      body: Sexp

  EnvBinding = object
    name: string
    entry: EnvEntry
    next: ref EnvBinding

  Env = ref object
    head: ref EnvBinding
    parent: Env

proc newEnv(parent: Env = nil): Env =
  Env(head: nil, parent: parent)

proc envGet(env: Env, name: string, loc: SourceLoc): EnvEntry =
  var e = env
  var envCount = 0
  while e != nil:
    inc(envCount)
    if envCount > 1000:
      raise parseError(loc, "envGet cycle detected looking for: " & name)
    var binding = e.head
    var bindCount = 0
    while binding != nil:
      inc(bindCount)
      if bindCount > 1000:
        raise parseError(loc, "envGet binding cycle detected looking for: " & name)
      if binding.name == name:
        return binding.entry
      binding = binding.next
    e = e.parent
  raise parseError(loc, "unbound variable: " & name)

proc envSet(env: Env, name: string, entry: EnvEntry) =
  var newBinding: ref EnvBinding
  new(newBinding)
  newBinding.name = name
  newBinding.entry = entry
  newBinding.next = env.head
  env.head = newBinding

var gensymCounter*: int = 0

proc gensym*(prefix: string = "g"): string =
  inc(gensymCounter)
  prefix & $gensymCounter

proc sexpEqual(a, b: Sexp): bool =
  if a == nil and b == nil: return true
  if a == nil or b == nil: return false
  if a.kind != b.kind: return false
  case a.kind
  of skSymbol: return a.symbol == b.symbol
  of skString: return a.str == b.str
  of skInt: return a.intVal == b.intVal
  of skFloat: return a.floatVal == b.floatVal
  of skList:
    if a.list.len != b.list.len: return false
    for i in 0..<a.list.len:
      if not sexpEqual(a.list[i], b.list[i]): return false
    return true
  of skQuasiquote, skUnquote, skUnquoteSplicing:
    return sexpEqual(a.child, b.child)
  of skClosure:
    return false

proc getInt(sexp: Sexp, loc: SourceLoc): int =
  if sexp.kind == skInt: return sexp.intVal
  raise parseError(loc, "expected integer")

proc getFloat(sexp: Sexp, loc: SourceLoc): float =
  if sexp.kind == skFloat: return sexp.floatVal
  if sexp.kind == skInt: return float(sexp.intVal)
  raise parseError(loc, "expected number")

proc evalSexp(sexp: Sexp, env: Env, macros: MacroEnv): Sexp
proc expandMacros(sexp: Sexp, macros: MacroEnv): Sexp
proc expandQuasiquoteEval(sexp: Sexp, depth: int, env: Env, macros: MacroEnv): Sexp

proc applyClosure(closure: EnvEntry, args: seq[Sexp], loc: SourceLoc, macros: MacroEnv): Sexp =
  let newEnv = newEnv(nil)
  for i, p in closure.params:
    if i < args.len:
      envSet(newEnv, sanitizeName(p.symbol), EnvEntry(kind: eekSexp, value: args[i]))
    else:
      raise parseError(loc, "too few arguments")
  if closure.restParam.len > 0:
    var restList: seq[Sexp] = @[]
    let startIdx = closure.params.len
    if startIdx < args.len:
      for i in startIdx..<args.len:
        restList.add(args[i])
    envSet(newEnv, closure.restParam, EnvEntry(kind: eekSexp, value: Sexp(kind: skList, list: restList, loc: loc)))
  result = evalSexp(closure.body, newEnv, macros)

proc applySexpClosure(clos: Sexp, args: seq[Sexp], loc: SourceLoc, macros: MacroEnv): Sexp =
  let newEnv = newEnv(nil)
  for i, p in clos.closParams:
    if i < args.len:
      envSet(newEnv, sanitizeName(p.symbol), EnvEntry(kind: eekSexp, value: args[i]))
    else:
      raise parseError(loc, "too few arguments")
  if clos.closRestParam.len > 0:
    var restList: seq[Sexp] = @[]
    let startIdx = clos.closParams.len
    if startIdx < args.len:
      for i in startIdx..<args.len:
        restList.add(args[i])
    envSet(newEnv, clos.closRestParam, EnvEntry(kind: eekSexp, value: Sexp(kind: skList, list: restList, loc: loc)))
  result = evalSexp(clos.closBody, newEnv, macros)

proc emitExpr(n: Sexp, quoted: bool = false): string
proc emitBody(exprs: seq[Sexp]): string
proc emitDefine(n: Sexp, topLevel: bool): string
proc indentLines(s: string, spaces: int): string


proc expandQuasiquoteEval(sexp: Sexp, depth: int, env: Env, macros: MacroEnv): Sexp =
  case sexp.kind
  of skUnquote:
    if depth == 1:
      return evalSexp(sexp.child, env, macros)
    else:
      return Sexp(kind: skUnquote, child: expandQuasiquoteEval(sexp.child, depth + 1, env, macros), loc: sexp.loc)
  of skUnquoteSplicing:
    if depth == 1:
      let evaluated = evalSexp(sexp.child, env, macros)
      if evaluated.kind != skList:
        raise parseError(sexp.loc, "unquote-splicing requires a list")
      return evaluated
    else:
      return Sexp(kind: skUnquoteSplicing, child: expandQuasiquoteEval(sexp.child, depth + 1, env, macros), loc: sexp.loc)
  of skQuasiquote:
    return Sexp(kind: skQuasiquote, child: expandQuasiquoteEval(sexp.child, depth + 1, env, macros), loc: sexp.loc)
  of skList:
    var items: seq[Sexp] = @[]
    for elem in sexp.list:
      if elem.kind == skUnquoteSplicing and depth == 1:
        let spliced = evalSexp(elem.child, env, macros)
        if spliced.kind != skList:
          raise parseError(elem.loc, "unquote-splicing requires a list")
        for s in spliced.list:
          items.add(s)
      else:
        items.add(expandQuasiquoteEval(elem, depth, env, macros))
    return Sexp(kind: skList, list: items, loc: sexp.loc, isBracket: sexp.isBracket, isQuoted: sexp.isQuoted)
  of skSymbol:
    return Sexp(kind: skSymbol, symbol: sexp.symbol, loc: sexp.loc)
  of skString:
    return Sexp(kind: skString, str: sexp.str, loc: sexp.loc)
  of skInt:
    return Sexp(kind: skInt, intVal: sexp.intVal, loc: sexp.loc)
  of skFloat:
    return Sexp(kind: skFloat, floatVal: sexp.floatVal, loc: sexp.loc)
  of skClosure:
    return sexp

proc evalSexp(sexp: Sexp, env: Env, macros: MacroEnv): Sexp =
  case sexp.kind
  of skInt, skFloat, skString, skClosure:
    return sexp
  of skSymbol:
    let entry = envGet(env, sexp.symbol, sexp.loc)
    return entry.value
  of skQuasiquote:
    return expandQuasiquoteEval(sexp.child, 1, env, macros)
  of skUnquote:
    raise parseError(sexp.loc, "unquote outside of quasiquote")
  of skUnquoteSplicing:
    raise parseError(sexp.loc, "unquote-splicing outside of quasiquote")
  of skList:
    if sexp.list.len == 0:
      return sexp
    let head = sexp.list[0]
    var op = ""
    if head.kind == skSymbol:
      op = head.symbol
    else:
      let fnVal = evalSexp(head, env, macros)
      if fnVal.kind == skClosure:
        var args: seq[Sexp] = @[]
        for i in 1..<sexp.list.len:
          args.add(evalSexp(sexp.list[i], env, macros))
        return applySexpClosure(fnVal, args, sexp.loc, macros)
      else:
        raise parseError(head.loc, "operator must evaluate to a function")
    case op
    of "quote":
      if sexp.list.len != 2:
        raise parseError(sexp.loc, "quote requires 1 argument")
      return sexp.list[1]
    of "if":
      if sexp.list.len != 4:
        raise parseError(sexp.loc, "if requires 3 arguments")
      let cond = evalSexp(sexp.list[1], env, macros)
      if cond.kind == skInt:
        if cond.intVal != 0: return evalSexp(sexp.list[2], env, macros)
        else: return evalSexp(sexp.list[3], env, macros)
      elif cond.kind == skFloat:
        if cond.floatVal != 0.0: return evalSexp(sexp.list[2], env, macros)
        else: return evalSexp(sexp.list[3], env, macros)
      elif cond.kind == skSymbol:
        if cond.symbol == "false" or cond.symbol == "nil": return evalSexp(sexp.list[3], env, macros)
        else: return evalSexp(sexp.list[2], env, macros)
      else:
        return evalSexp(sexp.list[2], env, macros)
    of "let":
      if sexp.list.len < 3:
        raise parseError(sexp.loc, "let requires bindings and body")
      let bindings = sexp.list[1]
      if bindings.kind != skList:
        raise parseError(bindings.loc, "let bindings must be a list")
      let newEnv = newEnv(env)
      for binding in bindings.list:
        if binding.kind != skList or binding.list.len != 2:
          raise parseError(binding.loc, "each binding must be (name value)")
        let name = sanitizeName(binding.list[0].symbol)
        let val = evalSexp(binding.list[1], env, macros)
        envSet(newEnv, name, EnvEntry(kind: eekSexp, value: val))
      var lastResult: Sexp = Sexp(kind: skInt, intVal: 0, loc: sexp.loc)
      for i in 2..<sexp.list.len:
        lastResult = evalSexp(sexp.list[i], newEnv, macros)
      return lastResult
    of "lambda":
      if sexp.list.len != 3:
        raise parseError(sexp.loc, "lambda requires params and body")
      let params = sexp.list[1]
      if params.kind != skList:
        raise parseError(params.loc, "lambda params must be a list")
      var restParam = ""
      var closParams: seq[Sexp] = @[]
      for p in params.list:
        if p.kind == skSymbol and p.symbol == "&rest":
          restParam = "&rest-marker"
        elif restParam == "&rest-marker":
          restParam = sanitizeName(p.symbol)
        else:
          closParams.add(p)
      return Sexp(kind: skClosure, closParams: closParams, closRestParam: restParam, closBody: sexp.list[2], loc: sexp.loc)
    of "progn":
      var lastResult: Sexp = Sexp(kind: skInt, intVal: 0, loc: sexp.loc)
      for i in 1..<sexp.list.len:
        lastResult = evalSexp(sexp.list[i], env, macros)
      return lastResult
    of "set!":
      if sexp.list.len != 3:
        raise parseError(sexp.loc, "set! requires 2 arguments")
      let name = sexp.list[1].symbol
      let val = evalSexp(sexp.list[2], env, macros)
      var e = env
      while e != nil:
        var binding = e.head
        while binding != nil:
          if binding.name == name:
            binding.entry = EnvEntry(kind: eekSexp, value: val)
            return val
          binding = binding.next
        e = e.parent
      raise parseError(sexp.list[1].loc, "set!: unbound variable " & name)
    of "car":
      if sexp.list.len != 2:
        raise parseError(sexp.loc, "car requires 1 argument")
      let lst = evalSexp(sexp.list[1], env, macros)
      if lst.kind != skList or lst.list.len == 0:
        raise parseError(sexp.loc, "car: expected non-empty list")
      return lst.list[0]
    of "cdr":
      if sexp.list.len != 2:
        raise parseError(sexp.loc, "cdr requires 1 argument")
      let lst = evalSexp(sexp.list[1], env, macros)
      if lst.kind != skList:
        raise parseError(sexp.loc, "cdr: expected list")
      if lst.list.len <= 1:
        return Sexp(kind: skList, list: @[], loc: lst.loc)
      return Sexp(kind: skList, list: lst.list[1..^1], loc: lst.loc)
    of "cons":
      if sexp.list.len != 3:
        raise parseError(sexp.loc, "cons requires 2 arguments")
      let elem = evalSexp(sexp.list[1], env, macros)
      let lst = evalSexp(sexp.list[2], env, macros)
      if lst.kind != skList:
        raise parseError(sexp.loc, "cons: second argument must be a list")
      var newList: seq[Sexp] = @[elem]
      for item in lst.list:
        newList.add(item)
      return Sexp(kind: skList, list: newList, loc: sexp.loc)
    of "null?":
      if sexp.list.len != 2:
        raise parseError(sexp.loc, "null? requires 1 argument")
      let lst = evalSexp(sexp.list[1], env, macros)
      if lst.kind == skList and lst.list.len == 0:
        return Sexp(kind: skSymbol, symbol: "true", loc: sexp.loc)
      else:
        return Sexp(kind: skSymbol, symbol: "false", loc: sexp.loc)
    of "list?":
      if sexp.list.len != 2:
        raise parseError(sexp.loc, "list? requires 1 argument")
      let val = evalSexp(sexp.list[1], env, macros)
      if val.kind == skList:
        return Sexp(kind: skSymbol, symbol: "true", loc: sexp.loc)
      else:
        return Sexp(kind: skSymbol, symbol: "false", loc: sexp.loc)
    of "length":
      if sexp.list.len != 2:
        raise parseError(sexp.loc, "length requires 1 argument")
      let lst = evalSexp(sexp.list[1], env, macros)
      if lst.kind != skList:
        raise parseError(sexp.loc, "length: expected list")
      return Sexp(kind: skInt, intVal: lst.list.len, loc: sexp.loc)
    of "append":
      if sexp.list.len < 2:
        raise parseError(sexp.loc, "append requires at least 1 argument")
      var combined: seq[Sexp] = @[]
      for i in 1..<sexp.list.len:
        let lst = evalSexp(sexp.list[i], env, macros)
        if lst.kind != skList:
          raise parseError(sexp.loc, "append: all arguments must be lists")
        for item in lst.list:
          combined.add(item)
      return Sexp(kind: skList, list: combined, loc: sexp.loc)
    of "reverse":
      if sexp.list.len != 2:
        raise parseError(sexp.loc, "reverse requires 1 argument")
      let lst = evalSexp(sexp.list[1], env, macros)
      if lst.kind != skList:
        raise parseError(sexp.loc, "reverse: expected list")
      var reversed: seq[Sexp] = @[]
      for i in 0..<lst.list.len:
        reversed.add(lst.list[lst.list.len - 1 - i])
      return Sexp(kind: skList, list: reversed, loc: sexp.loc)
    of "list":
      var items: seq[Sexp] = @[]
      for i in 1..<sexp.list.len:
        items.add(evalSexp(sexp.list[i], env, macros))
      return Sexp(kind: skList, list: items, loc: sexp.loc)
    of "gensym":
      if sexp.list.len == 1:
        return Sexp(kind: skSymbol, symbol: gensym(), loc: sexp.loc)
      elif sexp.list.len == 2:
        let prefix = sexp.list[1]
        if prefix.kind == skString:
          return Sexp(kind: skSymbol, symbol: gensym(prefix.str), loc: sexp.loc)
        elif prefix.kind == skSymbol:
          return Sexp(kind: skSymbol, symbol: gensym(prefix.symbol), loc: sexp.loc)
        else:
          raise parseError(sexp.loc, "gensym prefix must be a string or symbol")
      else:
        raise parseError(sexp.loc, "gensym takes 0 or 1 arguments")
    of "eq?":
      if sexp.list.len != 3:
        raise parseError(sexp.loc, "eq? requires 2 arguments")
      let a = evalSexp(sexp.list[1], env, macros)
      let b = evalSexp(sexp.list[2], env, macros)
      if sexpEqual(a, b):
        return Sexp(kind: skSymbol, symbol: "true", loc: sexp.loc)
      else:
        return Sexp(kind: skSymbol, symbol: "false", loc: sexp.loc)
    of "+":
      if sexp.list.len < 2:
        raise parseError(sexp.loc, "+ requires at least 1 argument")
      var useFloat = false
      for i in 1..<sexp.list.len:
        let arg = evalSexp(sexp.list[i], env, macros)
        if arg.kind == skFloat:
          useFloat = true
          break
      if useFloat:
        var sum = 0.0
        for i in 1..<sexp.list.len:
          sum += getFloat(evalSexp(sexp.list[i], env, macros), sexp.loc)
        return Sexp(kind: skFloat, floatVal: sum, loc: sexp.loc)
      else:
        var sum = 0
        for i in 1..<sexp.list.len:
          sum += getInt(evalSexp(sexp.list[i], env, macros), sexp.loc)
        return Sexp(kind: skInt, intVal: sum, loc: sexp.loc)
    of "-":
      if sexp.list.len < 2:
        raise parseError(sexp.loc, "- requires at least 1 argument")
      let first = evalSexp(sexp.list[1], env, macros)
      var useFloat = first.kind == skFloat
      if not useFloat:
        for i in 2..<sexp.list.len:
          if evalSexp(sexp.list[i], env, macros).kind == skFloat:
            useFloat = true
            break
      if sexp.list.len == 2:
        if useFloat:
          return Sexp(kind: skFloat, floatVal: -getFloat(first, sexp.loc), loc: sexp.loc)
        else:
          return Sexp(kind: skInt, intVal: -getInt(first, sexp.loc), loc: sexp.loc)
      if useFloat:
        var diff = getFloat(first, sexp.loc)
        for i in 2..<sexp.list.len:
          diff -= getFloat(evalSexp(sexp.list[i], env, macros), sexp.loc)
        return Sexp(kind: skFloat, floatVal: diff, loc: sexp.loc)
      else:
        var diff = getInt(first, sexp.loc)
        for i in 2..<sexp.list.len:
          diff -= getInt(evalSexp(sexp.list[i], env, macros), sexp.loc)
        return Sexp(kind: skInt, intVal: diff, loc: sexp.loc)
    of "*":
      if sexp.list.len < 2:
        raise parseError(sexp.loc, "* requires at least 1 argument")
      var useFloat = false
      for i in 1..<sexp.list.len:
        let arg = evalSexp(sexp.list[i], env, macros)
        if arg.kind == skFloat:
          useFloat = true
          break
      if useFloat:
        var prod = 1.0
        for i in 1..<sexp.list.len:
          prod *= getFloat(evalSexp(sexp.list[i], env, macros), sexp.loc)
        return Sexp(kind: skFloat, floatVal: prod, loc: sexp.loc)
      else:
        var prod = 1
        for i in 1..<sexp.list.len:
          prod *= getInt(evalSexp(sexp.list[i], env, macros), sexp.loc)
        return Sexp(kind: skInt, intVal: prod, loc: sexp.loc)
    of "/":
      if sexp.list.len < 2:
        raise parseError(sexp.loc, "/ requires at least 1 argument")
      var quot = getFloat(evalSexp(sexp.list[1], env, macros), sexp.loc)
      for i in 2..<sexp.list.len:
        quot /= getFloat(evalSexp(sexp.list[i], env, macros), sexp.loc)
      return Sexp(kind: skFloat, floatVal: quot, loc: sexp.loc)
    of "mod":
      if sexp.list.len != 3:
        raise parseError(sexp.loc, "mod requires 2 arguments")
      let a = getInt(evalSexp(sexp.list[1], env, macros), sexp.loc)
      let b = getInt(evalSexp(sexp.list[2], env, macros), sexp.loc)
      return Sexp(kind: skInt, intVal: a mod b, loc: sexp.loc)
    of "div":
      if sexp.list.len != 3:
        raise parseError(sexp.loc, "div requires 2 arguments")
      let a = getInt(evalSexp(sexp.list[1], env, macros), sexp.loc)
      let b = getInt(evalSexp(sexp.list[2], env, macros), sexp.loc)
      return Sexp(kind: skInt, intVal: a div b, loc: sexp.loc)
    of "==":
      if sexp.list.len != 3:
        raise parseError(sexp.loc, "== requires 2 arguments")
      let a = evalSexp(sexp.list[1], env, macros)
      let b = evalSexp(sexp.list[2], env, macros)
      if sexpEqual(a, b):
        return Sexp(kind: skSymbol, symbol: "true", loc: sexp.loc)
      else:
        return Sexp(kind: skSymbol, symbol: "false", loc: sexp.loc)
    of "=":
      if sexp.list.len < 3:
        raise parseError(sexp.loc, "= requires at least 2 arguments")
      for i in 1..<sexp.list.len - 1:
        let a = evalSexp(sexp.list[i], env, macros)
        let b = evalSexp(sexp.list[i + 1], env, macros)
        if not sexpEqual(a, b):
          return Sexp(kind: skSymbol, symbol: "false", loc: sexp.loc)
      return Sexp(kind: skSymbol, symbol: "true", loc: sexp.loc)
    of "!=":
      if sexp.list.len != 3:
        raise parseError(sexp.loc, "!= requires 2 arguments")
      let a = evalSexp(sexp.list[1], env, macros)
      let b = evalSexp(sexp.list[2], env, macros)
      if not sexpEqual(a, b):
        return Sexp(kind: skSymbol, symbol: "true", loc: sexp.loc)
      else:
        return Sexp(kind: skSymbol, symbol: "false", loc: sexp.loc)
    of "<":
      if sexp.list.len != 3:
        raise parseError(sexp.loc, "< requires 2 arguments")
      let a = getFloat(evalSexp(sexp.list[1], env, macros), sexp.loc)
      let b = getFloat(evalSexp(sexp.list[2], env, macros), sexp.loc)
      if a < b: return Sexp(kind: skSymbol, symbol: "true", loc: sexp.loc)
      else: return Sexp(kind: skSymbol, symbol: "false", loc: sexp.loc)
    of ">":
      if sexp.list.len != 3:
        raise parseError(sexp.loc, "> requires 2 arguments")
      let a = getFloat(evalSexp(sexp.list[1], env, macros), sexp.loc)
      let b = getFloat(evalSexp(sexp.list[2], env, macros), sexp.loc)
      if a > b: return Sexp(kind: skSymbol, symbol: "true", loc: sexp.loc)
      else: return Sexp(kind: skSymbol, symbol: "false", loc: sexp.loc)
    of "<=":
      if sexp.list.len != 3:
        raise parseError(sexp.loc, "<= requires 2 arguments")
      let a = getFloat(evalSexp(sexp.list[1], env, macros), sexp.loc)
      let b = getFloat(evalSexp(sexp.list[2], env, macros), sexp.loc)
      if a <= b: return Sexp(kind: skSymbol, symbol: "true", loc: sexp.loc)
      else: return Sexp(kind: skSymbol, symbol: "false", loc: sexp.loc)
    of ">=":
      if sexp.list.len != 3:
        raise parseError(sexp.loc, ">= requires 2 arguments")
      let a = getFloat(evalSexp(sexp.list[1], env, macros), sexp.loc)
      let b = getFloat(evalSexp(sexp.list[2], env, macros), sexp.loc)
      if a >= b: return Sexp(kind: skSymbol, symbol: "true", loc: sexp.loc)
      else: return Sexp(kind: skSymbol, symbol: "false", loc: sexp.loc)
    of "true":
      return Sexp(kind: skSymbol, symbol: "true", loc: sexp.loc)
    of "false":
      return Sexp(kind: skSymbol, symbol: "false", loc: sexp.loc)
    else:
      let entry = envGet(env, op, sexp.loc)
      if entry.kind == eekClosure:
        var args: seq[Sexp] = @[]
        for i in 1..<sexp.list.len:
          args.add(evalSexp(sexp.list[i], env, macros))
        return applyClosure(entry, args, sexp.loc, macros)
      elif entry.kind == eekSexp and entry.value.kind == skClosure:
        let clos = entry.value
        var args: seq[Sexp] = @[]
        for i in 1..<sexp.list.len:
          args.add(evalSexp(sexp.list[i], env, macros))
        return applySexpClosure(clos, args, sexp.loc, macros)
      else:
        raise parseError(sexp.loc, "not a function: " & op)

proc isDefmacro(n: Sexp): bool =
  n.kind == skList and n.list.len > 0 and
  n.list[0].kind == skSymbol and n.list[0].symbol == "defmacro"

proc collectMacros(sexps: seq[Sexp]): MacroEnv =
  result = MacroEnv(bindings: initTable[string, MacroDef]())
  for sexp in sexps:
    if isDefmacro(sexp):
      if sexp.list.len < 3:
        raise parseError(sexp.loc, "defmacro requires name, params, and body")
      let nameNode = sexp.list[1]
      var name: string
      var params: seq[Sexp]
      var restParam = ""
      if nameNode.kind == skSymbol:
        name = nameNode.symbol
        let paramsNode = sexp.list[2]
        if paramsNode.kind != skList:
          raise parseError(paramsNode.loc, "defmacro params must be a list")
        for p in paramsNode.list:
          if p.kind == skSymbol:
            if p.symbol == "&rest":
              restParam = "&rest-marker"
            elif restParam == "&rest-marker":
              restParam = sanitizeName(p.symbol)
            else:
              params.add(p)
          else:
            raise parseError(p.loc, "macro param must be a symbol")
        result.bindings[name] = MacroDef(params: params, restParam: restParam, body: sexp.list[3])
      elif nameNode.kind == skList:
        if nameNode.list.len == 0:
          raise parseError(nameNode.loc, "defmacro name list cannot be empty")
        name = nameNode.list[0].symbol
        for i in 1..<nameNode.list.len:
          let p = nameNode.list[i]
          if p.kind == skSymbol:
            if p.symbol == "&rest":
              restParam = "&rest-marker"
            elif restParam == "&rest-marker":
              restParam = sanitizeName(p.symbol)
            else:
              params.add(p)
          else:
            raise parseError(p.loc, "macro param must be a symbol")
        result.bindings[name] = MacroDef(params: params, restParam: restParam, body: sexp.list[2])
      else:
        raise parseError(nameNode.loc, "defmacro name must be a symbol or (name params...)")

proc expandMacros(sexp: Sexp, macros: MacroEnv): Sexp =
  case sexp.kind
  of skList:
    if sexp.list.len == 0:
      return sexp
    let head = sexp.list[0]
    if head.kind == skSymbol and macros.bindings.hasKey(head.symbol):
      let macroDef = macros.bindings[head.symbol]
      let argCount = sexp.list.len - 1
      let paramCount = macroDef.params.len
      var args: seq[Sexp] = @[]
      if macroDef.restParam.len > 0:
        if argCount < paramCount:
          raise parseError(sexp.loc, "macro " & head.symbol & " requires at least " & $paramCount & " arguments")
        for i in 1..paramCount:
          args.add(sexp.list[i])
        var restList: seq[Sexp] = @[]
        for i in (paramCount + 1)..<sexp.list.len:
          restList.add(sexp.list[i])
        let macroEnv = newEnv(nil)
        for i, p in macroDef.params:
          envSet(macroEnv, sanitizeName(p.symbol), EnvEntry(kind: eekSexp, value: args[i]))
        envSet(macroEnv, macroDef.restParam, EnvEntry(kind: eekSexp, value: Sexp(kind: skList, list: restList, loc: sexp.loc)))
        let expanded = evalSexp(macroDef.body, macroEnv, macros)
        return expandMacros(expanded, macros)
      else:
        if argCount != paramCount:
          raise parseError(sexp.loc, "macro " & head.symbol & " requires " & $paramCount & " arguments, got " & $argCount)
        let macroEnv = newEnv(nil)
        for i in 0..<paramCount:
          envSet(macroEnv, sanitizeName(macroDef.params[i].symbol), EnvEntry(kind: eekSexp, value: sexp.list[i + 1]))
        let expanded = evalSexp(macroDef.body, macroEnv, macros)
        return expandMacros(expanded, macros)
    else:
      var newList: seq[Sexp] = @[]
      for item in sexp.list:
        newList.add(expandMacros(item, macros))
      return Sexp(kind: skList, list: newList, loc: sexp.loc, isBracket: sexp.isBracket, isQuoted: sexp.isQuoted)
  of skQuasiquote:
    return Sexp(kind: skQuasiquote, child: expandMacros(sexp.child, macros), loc: sexp.loc)
  of skUnquote:
    return Sexp(kind: skUnquote, child: expandMacros(sexp.child, macros), loc: sexp.loc)
  of skUnquoteSplicing:
    return Sexp(kind: skUnquoteSplicing, child: expandMacros(sexp.child, macros), loc: sexp.loc)
  of skClosure:
    return Sexp(kind: skClosure, closParams: sexp.closParams, closRestParam: sexp.closRestParam, closBody: expandMacros(sexp.closBody, macros), loc: sexp.loc)
  else:
    return sexp

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
  of skQuasiquote:
    raise parseError(n.loc, "quasiquote used outside of macro context")
  of skUnquote:
    raise parseError(n.loc, "unquote used outside of quasiquote")
  of skUnquoteSplicing:
    raise parseError(n.loc, "unquote-splicing used outside of quasiquote")
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
  of skClosure:
    return "(proc() = nil)"
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

proc loadStdlibMacros*(): MacroEnv =
  result = MacroEnv(bindings: initTable[string, MacroDef]())
  try:
    let stdPath = currentSourcePath().parentDir() / "std" / "nilpkg.nil"
    if fileExists(stdPath):
      let stdContent = readFile(stdPath)
      let stdSexps = parseAllSexps(stdContent)
      let stdMacros = collectMacros(stdSexps)
      for k, v in stdMacros.bindings:
        result.bindings[k] = v
  except:
    discard

proc mergeMacroEnvs*(a, b: MacroEnv): MacroEnv =
  result = MacroEnv(bindings: initTable[string, MacroDef]())
  for k, v in a.bindings:
    result.bindings[k] = v
  for k, v in b.bindings:
    result.bindings[k] = v

proc lispToNim*(code: string): string =
  let sexps = parseAllSexps(code)
  if sexps.len == 0:
    return ""
  let stdMacros = loadStdlibMacros()
  let fileMacros = collectMacros(sexps)
  let macros = mergeMacroEnvs(stdMacros, fileMacros)
  var output = "import std/nilpkg\n\n"
  for i, sexp in sexps:
    if isDefmacro(sexp):
      continue
    let expanded = expandMacros(sexp, macros)
    if expanded.kind == skList and expanded.list.len > 0 and
       expanded.list[0].kind == skSymbol and expanded.list[0].symbol == "define":
      output.add emitDefine(expanded, true) & "\n"
    else:
      output.add "discard " & forceValue(expanded) & "\n"
  return output

proc transpileNoStdlib*(code: string): string =
  let sexps = parseAllSexps(code)
  if sexps.len == 0:
    return ""
  let stdMacros = loadStdlibMacros()
  let fileMacros = collectMacros(sexps)
  let macros = mergeMacroEnvs(stdMacros, fileMacros)
  var output = ""
  for i, sexp in sexps:
    if isDefmacro(sexp):
      continue
    let expanded = expandMacros(sexp, macros)
    if expanded.kind == skList and expanded.list.len > 0 and
       expanded.list[0].kind == skSymbol and expanded.list[0].symbol == "define":
      output.add emitDefine(expanded, true) & "\n"
    else:
      output.add "discard " & forceValue(expanded) & "\n"
  return runtimeHelpers & "\n" & output

macro lisp*(body: string): untyped =
  try:
    let sexps = parseAllSexps(body.strVal)
    if sexps.len == 0:
      result = newStmtList()
    else:
      let stdMacros = loadStdlibMacros()
      let fileMacros = collectMacros(sexps)
      let macros = mergeMacroEnvs(stdMacros, fileMacros)
      var stmts = newStmtList()
      stmts.add parseStmt(runtimeHelpers)
      for j in 0..<sexps.len - 1:
        let s = sexps[j]
        if isDefmacro(s):
          continue
        let expanded = expandMacros(s, macros)
        if expanded.kind == skList and expanded.list.len > 0 and
           expanded.list[0].kind == skSymbol and expanded.list[0].symbol == "define":
          let src = emitDefine(expanded, true)
          stmts.add parseStmt(src)
        else:
          let src = emitExpr(expanded)
          stmts.add parseStmt("discard " & src)
      let lastSexp = sexps[sexps.len - 1]
      if isDefmacro(lastSexp):
        discard
      elif lastSexp.kind == skList and lastSexp.list.len > 0 and
          lastSexp.list[0].kind == skSymbol and lastSexp.list[0].symbol == "define":
        let expanded = expandMacros(lastSexp, macros)
        let src = emitDefine(expanded, true)
        stmts.add parseStmt(src)
      else:
        let expanded = expandMacros(lastSexp, macros)
        let lastSrc = emitExpr(expanded)
        stmts.add parseStmt(lastSrc)
      result = stmts
  except ValueError as e:
    error(e.msg)
