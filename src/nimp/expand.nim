import std/options
import std/tables

import ./diagnostics
import ./macros
import ./syntax

const maxExpansionDepth = 100

type EvalScope = Table[string, Syntax]

proc expandExpr*(env: MacroEnv; sx: Syntax; depth = 0): Syntax
proc expandModule*(forms: seq[Syntax]; env: MacroEnv = newMacroEnv()): seq[Syntax]

proc expectArity(sx: Syntax; name: string; actual, expected: int) =
  if actual != expected:
    raiseCompilerError(sx.span, name & " expects " & $expected & " arguments, got " & $actual)

proc truthy(sx: Syntax): bool =
  case sx.kind
  of sxNil:
    false
  of sxBool:
    sx.boolVal
  else:
    true

proc lookup(scope: EvalScope; sx: Syntax): Option[Syntax] =
  if sx.kind == sxSymbol and scope.hasKey(sx.sym):
    some(scope[sx.sym])
  else:
    none(Syntax)

proc evalMacroExpr(env: MacroEnv; scope: var EvalScope; sx: Syntax): Syntax

proc evalBody(env: MacroEnv; scope: var EvalScope; body: openArray[Syntax]; owner: Syntax): Syntax =
  if body.len == 0:
    raiseCompilerError(owner.span, "expected macro body expression")
  for item in body:
    result = evalMacroExpr(env, scope, item)

proc parseMacroParams(params: Syntax): tuple[names: seq[string], rest: string] =
  if params.kind != sxList:
    raiseCompilerError(params.span, "macro parameters must be a list")

  var sawRest = false
  var seen = initTable[string, bool]()
  for i, item in params.items:
    if item.kind != sxSymbol:
      raiseCompilerError(item.span, "macro parameter must be a symbol")
    if item.sym == ".":
      if sawRest or i != params.items.high - 1:
        raiseCompilerError(item.span, "invalid macro rest parameter")
      sawRest = true
    elif sawRest:
      if seen.hasKey(item.sym):
        raiseCompilerError(item.span, "duplicate macro parameter: " & item.sym)
      result.rest = item.sym
      seen[item.sym] = true
    else:
      if seen.hasKey(item.sym):
        raiseCompilerError(item.span, "duplicate macro parameter: " & item.sym)
      result.names.add item.sym
      seen[item.sym] = true

  if sawRest and result.rest.len == 0:
    raiseCompilerError(params.items[^1].span, "invalid macro rest parameter")

proc parseDefmacro(sx: Syntax): MacroDef =
  if sx.items.len < 4:
    raiseCompilerError(sx.span, "defmacro expects name, parameters, and body")
  let name = sx.items[1]
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, "defmacro name must be a symbol")
  let parsed = parseMacroParams(sx.items[2])
  MacroDef(name: name.sym, params: parsed.names, restParam: parsed.rest, body: sx.items[3 .. ^1], span: sx.span)

proc bindMacroArgs(def: MacroDef; call: Syntax): EvalScope =
  let actual = call.items.len - 1
  if def.restParam.len == 0 and actual != def.params.len:
    raiseCompilerError(call.span, def.name & " expects " & $def.params.len & " arguments, got " & $actual)
  if def.restParam.len > 0 and actual < def.params.len:
    raiseCompilerError(call.span, def.name & " expects at least " & $def.params.len & " arguments, got " & $actual)

  result = initTable[string, Syntax]()
  for i, name in def.params:
    result[name] = call.items[i + 1]
  if def.restParam.len > 0:
    var restItems: seq[Syntax] = @[]
    for i in def.params.len + 1 ..< call.items.len:
      restItems.add call.items[i]
    result[def.restParam] = newList(restItems, call.span)

proc evalQuasiquote(env: MacroEnv; scope: var EvalScope; sx: Syntax; allowSplice: bool): Syntax

proc evalQuasiquoteItems(env: MacroEnv; scope: var EvalScope; items: openArray[Syntax]; owner: Syntax): seq[Syntax] =
  for item in items:
    if item.kind == sxList and item.items.len > 0 and item.items[0].isSymbol("unquote-splicing"):
      expectArity(item, "unquote-splicing", item.items.len - 1, 1)
      let splice = evalMacroExpr(env, scope, item.items[1])
      if splice.kind != sxList and splice.kind != sxVector:
        raiseCompilerError(item.span, "unquote-splicing expects a list or vector")
      for spliceItem in splice.items:
        result.add spliceItem.copySyntax()
    else:
      result.add evalQuasiquote(env, scope, item, true)

proc evalQuasiquote(env: MacroEnv; scope: var EvalScope; sx: Syntax; allowSplice: bool): Syntax =
  if sx.kind == sxList and sx.items.len > 0:
    if sx.items[0].isSymbol("unquote"):
      expectArity(sx, "unquote", sx.items.len - 1, 1)
      return evalMacroExpr(env, scope, sx.items[1])
    if sx.items[0].isSymbol("unquote-splicing"):
      expectArity(sx, "unquote-splicing", sx.items.len - 1, 1)
      if not allowSplice:
        raiseCompilerError(sx.span, "unquote-splicing is only valid inside a quasiquoted list or vector")
      raiseCompilerError(sx.span, "unquote-splicing is only valid as a list or vector element")
  case sx.kind
  of sxList:
    newList(evalQuasiquoteItems(env, scope, sx.items, sx), sx.span)
  of sxVector:
    newVector(evalQuasiquoteItems(env, scope, sx.items, sx), sx.span)
  else:
    sx.copySyntax()

proc evalBuiltin(env: MacroEnv; scope: var EvalScope; call: Syntax): Syntax =
  let name = call.items[0].sym
  case name
  of "syntax?":
    expectArity(call, name, call.items.len - 1, 1)
    discard evalMacroExpr(env, scope, call.items[1])
    newBool(true, call.span)
  of "symbol?":
    expectArity(call, name, call.items.len - 1, 1)
    newBool(evalMacroExpr(env, scope, call.items[1]).kind == sxSymbol, call.span)
  of "list?":
    expectArity(call, name, call.items.len - 1, 1)
    newBool(evalMacroExpr(env, scope, call.items[1]).kind == sxList, call.span)
  of "nil?":
    expectArity(call, name, call.items.len - 1, 1)
    let value = evalMacroExpr(env, scope, call.items[1])
    newBool(value.kind == sxNil or ((value.kind == sxList or value.kind == sxVector) and value.items.len == 0), call.span)
  of "first":
    expectArity(call, name, call.items.len - 1, 1)
    let value = evalMacroExpr(env, scope, call.items[1])
    if value.kind != sxList and value.kind != sxVector:
      raiseCompilerError(call.items[1].span, "first expects a list or vector")
    if value.items.len == 0:
      return newNil(call.span)
    value.items[0].copySyntax()
  of "rest":
    expectArity(call, name, call.items.len - 1, 1)
    let value = evalMacroExpr(env, scope, call.items[1])
    if value.kind != sxList and value.kind != sxVector:
      raiseCompilerError(call.items[1].span, "rest expects a list or vector")
    var restItems: seq[Syntax] = @[]
    if value.items.len > 1:
      for i in 1 ..< value.items.len:
        restItems.add value.items[i].copySyntax()
    newList(restItems, value.span)
  of "cons":
    expectArity(call, name, call.items.len - 1, 2)
    let head = evalMacroExpr(env, scope, call.items[1])
    let tail = evalMacroExpr(env, scope, call.items[2])
    if tail.kind != sxList:
      raiseCompilerError(call.items[2].span, "cons expects a list tail")
    var items = @[head]
    for item in tail.items:
      items.add item.copySyntax()
    newList(items, call.span)
  of "list":
    var items: seq[Syntax] = @[]
    for i in 1 ..< call.items.len:
      items.add evalMacroExpr(env, scope, call.items[i])
    newList(items, call.span)
  of "append":
    var items: seq[Syntax] = @[]
    for i in 1 ..< call.items.len:
      let value = evalMacroExpr(env, scope, call.items[i])
      if value.kind != sxList and value.kind != sxVector:
        raiseCompilerError(call.items[i].span, "append expects lists or vectors")
      for item in value.items:
        items.add item.copySyntax()
    newList(items, call.span)
  of "syntax->datum", "datum->syntax":
    expectArity(call, name, call.items.len - 1, 1)
    evalMacroExpr(env, scope, call.items[1]).copySyntax()
  of "gensym":
    if call.items.len == 1:
      return env.gensym("g", call.span)
    expectArity(call, name, call.items.len - 1, 1)
    let hint = evalMacroExpr(env, scope, call.items[1])
    if hint.kind == sxSymbol:
      env.gensym(hint.sym, call.span)
    elif hint.kind == sxString:
      env.gensym(hint.strVal, call.span)
    else:
      raiseCompilerError(call.items[1].span, "gensym expects a symbol or string hint")
  of "macro-error":
    if call.items.len == 1:
      raiseCompilerError(call.span, "macro error")
    expectArity(call, name, call.items.len - 1, 1)
    let message = evalMacroExpr(env, scope, call.items[1])
    if message.kind == sxString:
      raiseCompilerError(call.span, message.strVal)
    raiseCompilerError(call.span, "macro error")
  else:
    raiseCompilerError(call.items[0].span, "unknown macro-time function: " & name)

proc evalMacroExpr(env: MacroEnv; scope: var EvalScope; sx: Syntax): Syntax =
  case sx.kind
  of sxSymbol:
    let value = scope.lookup(sx)
    if value.isSome:
      value.get().copySyntax()
    else:
      sx.copySyntax()
  of sxList:
    if sx.items.len == 0:
      return sx.copySyntax()
    let head = sx.items[0]
    if head.isSymbol("quote"):
      expectArity(sx, "quote", sx.items.len - 1, 1)
      return sx.items[1].copySyntax()
    if head.isSymbol("quasiquote"):
      expectArity(sx, "quasiquote", sx.items.len - 1, 1)
      return evalQuasiquote(env, scope, sx.items[1], false)
    if head.isSymbol("if"):
      expectArity(sx, "if", sx.items.len - 1, 3)
      if evalMacroExpr(env, scope, sx.items[1]).truthy:
        return evalMacroExpr(env, scope, sx.items[2])
      return evalMacroExpr(env, scope, sx.items[3])
    if head.isSymbol("begin"):
      return evalBody(env, scope, sx.items.toOpenArray(1, sx.items.high), sx)
    if head.isSymbol("let"):
      if sx.items.len < 3:
        raiseCompilerError(sx.span, "let expects bindings and body")
      let bindings = sx.items[1]
      if bindings.kind != sxList:
        raiseCompilerError(bindings.span, "let bindings must be a list")
      var child = scope
      for binding in bindings.items:
        if binding.kind != sxList or binding.items.len != 2 or binding.items[0].kind != sxSymbol:
          raiseCompilerError(binding.span, "let binding must be (name value)")
        child[binding.items[0].sym] = evalMacroExpr(env, scope, binding.items[1])
      return evalBody(env, child, sx.items.toOpenArray(2, sx.items.high), sx)
    if head.kind != sxSymbol:
      raiseCompilerError(head.span, "macro-time call target must be a symbol")
    evalBuiltin(env, scope, sx)
  else:
    sx.copySyntax()

proc applyMacro(env: MacroEnv; def: MacroDef; call: Syntax): Syntax =
  var scope = bindMacroArgs(def, call)
  try:
    evalBody(env, scope, def.body, call).withSpan(call.span)
  except CompilerError as err:
    let message = "error expanding macro " & def.name & ": " & err.diagnostic.message
    raiseCompilerError(call.span, message)

proc expandList(env: MacroEnv; sx: Syntax; depth: int): Syntax =
  if sx.items.len == 0:
    return sx.copySyntax()
  let head = sx.items[0]
  if head.isSymbol("quote"):
    return sx.copySyntax()
  if head.isSymbol("unquote"):
    raiseCompilerError(sx.span, "unquote is only valid inside quasiquote")
  if head.isSymbol("unquote-splicing"):
    raiseCompilerError(sx.span, "unquote-splicing is only valid inside quasiquote")
  if head.isSymbol("defmacro"):
    raiseCompilerError(sx.span, "defmacro is only allowed at statement/module scope")
  if head.kind == sxSymbol and env.hasMacro(head.sym):
    if depth >= maxExpansionDepth:
      raiseCompilerError(sx.span, "macro expansion depth exceeded")
    return expandExpr(env, applyMacro(env, env.getMacro(head.sym), sx), depth + 1)

  var items: seq[Syntax] = @[]
  for item in sx.items:
    items.add expandExpr(env, item, depth)
  newList(items, sx.span)

proc expandExpr*(env: MacroEnv; sx: Syntax; depth = 0): Syntax =
  case sx.kind
  of sxList:
    expandList(env, sx, depth)
  of sxVector:
    var items: seq[Syntax] = @[]
    for item in sx.items:
      items.add expandExpr(env, item, depth)
    newVector(items, sx.span)
  else:
    sx.copySyntax()

proc expandModule*(forms: seq[Syntax]; env: MacroEnv = newMacroEnv()): seq[Syntax] =
  for form in forms:
    if form.kind == sxList and form.items.len > 0 and form.items[0].isSymbol("defmacro"):
      env.defineMacro parseDefmacro(form)
    else:
      result.add expandExpr(env, form)
