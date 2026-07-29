import std/options
import std/os
import std/sets
import std/strutils
import std/tables

import ./diagnostics
import ./macros
import ./reader
import ./syntax

const maxExpansionDepth = 100

type EvalScope = Table[string, Syntax]

proc expandExpr*(env: MacroEnv; sx: Syntax; depth = 0): Syntax
proc expandModule*(forms: seq[Syntax]; env: MacroEnv = newMacroEnv(); currentDir = ""; selfPath = ""): seq[Syntax]

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

# ---------- lambda list parsing ----------

type ParseMode = enum
  pmRequired, pmOptional, pmKey, pmDone

proc parseOptParam(item: Syntax): MacroOptParam =
  if item.kind == sxSymbol:
    return MacroOptParam(name: item.sym, default: none(Syntax))
  if item.kind == sxList and item.items.len == 2 and item.items[0].kind == sxSymbol:
    return MacroOptParam(name: item.items[0].sym, default: some(item.items[1]))
  raiseCompilerError(item.span, "&optional parameter must be a symbol or (name default)")

proc parseKeyParam(item: Syntax): MacroKeyParam =
  if item.kind == sxSymbol:
    return MacroKeyParam(keyword: item.sym, local: item.sym, default: none(Syntax))
  if item.kind == sxList and item.items.len == 2:
    let spec = item.items[0]
    let dflt = item.items[1]
    # simple name with default: (name default)
    if spec.kind == sxSymbol:
      return MacroKeyParam(keyword: spec.sym, local: spec.sym, default: some(dflt))
    # rename form: ((:keyword local) default)
    if spec.kind == sxList and spec.items.len == 2 and
       spec.items[0].kind == sxSymbol and spec.items[1].kind == sxSymbol:
      let kw = spec.items[0].sym
      if kw.len < 2 or kw[0] != ':':
        raiseCompilerError(spec.items[0].span, "&key rename keyword must start with :")
      return MacroKeyParam(keyword: kw[1 .. ^1], local: spec.items[1].sym, default: some(dflt))
  raiseCompilerError(item.span, "&key parameter must be a symbol, (name default), or ((:key local) default)")

proc parseMacroParams(params: Syntax): tuple[
    names: seq[string],
    optParams: seq[MacroOptParam],
    restParam: string,
    bodyParam: string,
    keyParams: seq[MacroKeyParam]] =
  if params.kind != sxList:
    raiseCompilerError(params.span, "macro parameters must be a list")

  var mode = pmRequired
  var seen = initTable[string, bool]()

  proc checkDup(name: string; span: Span) =
    if seen.hasKey(name):
      raiseCompilerError(span, "duplicate macro parameter: " & name)
    seen[name] = true

  for i, item in params.items:
    if item.kind == sxSymbol:
      case item.sym
      of "&optional":
        if mode != pmRequired:
          raiseCompilerError(item.span, "&optional must come before &rest, &body, and &key")
        mode = pmOptional
        continue
      of "&rest":
        if mode in {pmKey, pmDone}:
          raiseCompilerError(item.span, "&rest cannot follow &key")
        if result.restParam.len > 0 or result.bodyParam.len > 0:
          raiseCompilerError(item.span, "only one rest/body parameter allowed")
        if i == params.items.high:
          raiseCompilerError(item.span, "&rest requires a parameter name")
        let next = params.items[i + 1]
        if next.kind != sxSymbol:
          raiseCompilerError(next.span, "&rest parameter must be a symbol")
        checkDup(next.sym, next.span)
        result.restParam = next.sym
        mode = pmDone
        continue
      of "&body":
        if mode in {pmKey, pmDone}:
          raiseCompilerError(item.span, "&body cannot follow &key")
        if result.restParam.len > 0 or result.bodyParam.len > 0:
          raiseCompilerError(item.span, "only one rest/body parameter allowed")
        if i == params.items.high:
          raiseCompilerError(item.span, "&body requires a parameter name")
        let next = params.items[i + 1]
        if next.kind != sxSymbol:
          raiseCompilerError(next.span, "&body parameter must be a symbol")
        checkDup(next.sym, next.span)
        result.bodyParam = next.sym
        mode = pmDone
        continue
      of "&key":
        if mode == pmDone:
          raiseCompilerError(item.span, "&key cannot follow &rest or &body")
        mode = pmKey
        continue
      of ".":
        # dotted-pair rest: (a b . rest) — . must be second-to-last
        if mode != pmRequired:
          raiseCompilerError(item.span, "dotted-pair rest only valid among required parameters")
        if result.restParam.len > 0 or result.bodyParam.len > 0:
          raiseCompilerError(item.span, "only one rest/body parameter allowed")
        if i != params.items.high - 1:
          raiseCompilerError(item.span, "dotted-pair . must be second-to-last in parameter list")
        let next = params.items[i + 1]
        if next.kind != sxSymbol:
          raiseCompilerError(next.span, "dotted-pair rest parameter must be a symbol")
        checkDup(next.sym, next.span)
        result.restParam = next.sym
        mode = pmDone
        continue
      else:
        discard

    # skip the name that was already consumed by &rest / &body / dotted-pair
    if mode == pmDone and i > 0:
      let prev = params.items[i - 1]
      if prev.kind == sxSymbol and prev.sym in ["&rest", "&body", "."]:
        continue

    case mode
    of pmRequired:
      if item.kind != sxSymbol:
        raiseCompilerError(item.span, "required macro parameter must be a symbol")
      checkDup(item.sym, item.span)
      result.names.add item.sym
    of pmOptional:
      let op = parseOptParam(item)
      checkDup(op.name, item.span)
      result.optParams.add op
    of pmKey:
      let kp = parseKeyParam(item)
      checkDup(kp.local, item.span)
      result.keyParams.add kp
    of pmDone:
      raiseCompilerError(item.span, "unexpected parameter after rest/body parameter")

proc parseDefmacro(sx: Syntax): MacroDef =
  if sx.items.len < 4:
    raiseCompilerError(sx.span, "defmacro expects name, parameters, and body")
  let name = sx.items[1]
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, "defmacro name must be a symbol")
  let parsed = parseMacroParams(sx.items[2])
  MacroDef(
    name: name.sym,
    params: parsed.names,
    optParams: parsed.optParams,
    restParam: parsed.restParam,
    bodyParam: parsed.bodyParam,
    keyParams: parsed.keyParams,
    body: sx.items[3 .. ^1],
    span: sx.span)

# ---------- argument binding ----------

proc isKeywordSym(sx: Syntax): bool =
  sx.kind == sxSymbol and sx.sym.len >= 2 and sx.sym[0] == ':'

proc splitCallArgs(call: Syntax): tuple[positional: seq[Syntax], keywords: Table[string, Syntax]] =
  # Split at the first :keyword symbol. Everything before is positional;
  # from there we expect alternating :key value pairs.
  var i = 1  # skip the macro name at index 0
  while i < call.items.len and not call.items[i].isKeywordSym:
    result.positional.add call.items[i]
    inc i
  result.keywords = initTable[string, Syntax]()
  while i < call.items.len:
    let kw = call.items[i]
    if not kw.isKeywordSym:
      raiseCompilerError(kw.span, "expected keyword argument (e.g. :name), got " & kw.sym)
    if i + 1 >= call.items.len:
      raiseCompilerError(kw.span, "keyword argument " & kw.sym & " has no value")
    let key = kw.sym[1 .. ^1]
    if result.keywords.hasKey(key):
      raiseCompilerError(kw.span, "duplicate keyword argument: " & kw.sym)
    result.keywords[key] = call.items[i + 1]
    i += 2

proc bindMacroArgs(env: MacroEnv; def: MacroDef; call: Syntax): EvalScope =
  let (positional, keywords) = splitCallArgs(call)
  let hasRest = def.restParam.len > 0 or def.bodyParam.len > 0
  let minArgs = def.params.len
  let maxArgs = def.params.len + def.optParams.len
  let isExact = not hasRest and def.optParams.len == 0 and def.keyParams.len == 0

  # required params
  if positional.len < minArgs:
    if isExact:
      raiseCompilerError(call.span, def.name & " expects " & $minArgs & " arguments, got " & $positional.len)
    else:
      raiseCompilerError(call.span, def.name & " expects at least " & $minArgs & " arguments, got " & $positional.len)

  result = initTable[string, Syntax]()
  for i, name in def.params:
    result[name] = positional[i]
  var pos = def.params.len

  # optional params
  for opt in def.optParams:
    if pos < positional.len:
      result[opt.name] = positional[pos]
      inc pos
    elif opt.default.isSome:
      result[opt.name] = evalMacroExpr(env, result, opt.default.get())
    else:
      result[opt.name] = newNil(call.span)

  # rest / body
  let restName = if def.restParam.len > 0: def.restParam else: def.bodyParam
  if restName.len > 0:
    var restItems: seq[Syntax] = @[]
    for i in pos ..< positional.len:
      restItems.add positional[i]
    result[restName] = newList(restItems, call.span)
  elif pos < positional.len:
    if isExact:
      raiseCompilerError(call.span, def.name & " expects " & $minArgs & " arguments, got " & $positional.len)
    else:
      raiseCompilerError(call.span, def.name & " expects at most " & $maxArgs & " arguments, got " & $positional.len)

  # key params
  for kp in def.keyParams:
    if keywords.hasKey(kp.keyword):
      result[kp.local] = keywords[kp.keyword]
    elif kp.default.isSome:
      result[kp.local] = evalMacroExpr(env, result, kp.default.get())
    else:
      result[kp.local] = newNil(call.span)

  # error on unknown keywords
  for key in keywords.keys:
    var found = false
    for kp in def.keyParams:
      if kp.keyword == key:
        found = true
        break
    if not found:
      raiseCompilerError(call.span, def.name & ": unknown keyword argument :" & key)

# ---------- automatic template hygiene (#11) ----------
#
# Renames literal binding-target symbols introduced by a quasiquoted
# template — let/var (binding-list form), do, and for — so that a macro's
# own local bindings don't accidentally capture, or get captured by,
# identically-named symbols the caller passes in. This runs once over the
# whole template *before* evalQuasiquote substitutes unquotes, which is
# what makes leaving unquote/unquote-splicing subtrees untouched sufficient
# to avoid ever renaming caller-supplied syntax: at this point an unquoted
# expression is still the literal form `(unquote expr)`, not yet expr's
# value, so skipping recursion into it skips exactly the caller's syntax.
#
# `(unhygienic sym)` in binding-target position is the escape hatch for
# intentional capture (anaphoric macros): it unwraps to plain `sym`,
# without renaming it or registering it in scope, so both the binding and
# every literal reference to it stay capturable/capturing.
#
# Deliberately unhandled, and so left unrenamed (matching how the preamble
# macros `let*`/`as->` already work, unaffected by this pass): a binding
# whose target is itself an unquote (`,name`, a macro-computed name — the
# macro author's own symbol) or a #12 destructuring vector pattern.

type HygieneScope = Table[string, int]  # literal name -> assigned hygieneId

proc hygienicRename(env: MacroEnv; sx: Syntax; scope: HygieneScope): Syntax

proc renameHygienicTarget(env: MacroEnv; target: Syntax; scope: var HygieneScope): Syntax =
  let id = env.newHygienicId()
  scope[target.sym] = id
  newSymbol(target.sym, target.span, id)

proc unwrapUnhygienicTarget(target: Syntax): tuple[inner: Syntax, skip: bool] =
  ## Recognizes `(unhygienic sym)` in binding-target position.
  if target.kind == sxList and target.items.len > 0 and target.items[0].isSymbol("unhygienic"):
    if target.items.len != 2 or target.items[1].kind != sxSymbol:
      raiseCompilerError(target.span, "unhygienic expects exactly one symbol argument")
    return (target.items[1], true)
  (target, false)

proc hygienicRenameItems(env: MacroEnv; items: openArray[Syntax]; scope: HygieneScope): seq[Syntax] =
  for item in items:
    result.add hygienicRename(env, item, scope)

proc hygienicRenameGeneric(env: MacroEnv; sx: Syntax; scope: HygieneScope): Syntax =
  case sx.kind
  of sxSymbol:
    if scope.hasKey(sx.sym):
      newSymbol(sx.sym, sx.span, scope[sx.sym])
    else:
      sx.copySyntax()
  of sxList:
    newList(hygienicRenameItems(env, sx.items, scope), sx.span)
  of sxVector:
    newVector(hygienicRenameItems(env, sx.items, scope), sx.span)
  else:
    sx.copySyntax()

proc hygienicRenameTypedTarget(env: MacroEnv; target: Syntax; childScope: var HygieneScope): Syntax =
  ## Renames the shared `symbol` / `(name type)` / `(unhygienic ...)`
  ## binding-target shape used by let/var bindings, do params, and for loop
  ## variables. Any other shape (an unquoted/computed name, a destructuring
  ## vector pattern, …) is left untouched — see the module-level comment.
  let (inner, skip) = unwrapUnhygienicTarget(target)
  if skip:
    inner.copySyntax()
  elif inner.kind == sxSymbol:
    renameHygienicTarget(env, inner, childScope)
  elif inner.kind == sxList and inner.items.len > 0 and inner.items[0].isSymbol("unquote"):
    inner.copySyntax()
  elif inner.kind == sxList and inner.items.len == 2 and inner.items[0].kind == sxSymbol and
      (inner.items[1].kind == sxSymbol or inner.items[1].kind == sxVector):
    newList(@[renameHygienicTarget(env, inner.items[0], childScope), inner.items[1].copySyntax()], inner.span)
  else:
    inner.copySyntax()

proc hygienicRenameLetLike(env: MacroEnv; sx: Syntax; scope: HygieneScope): Syntax =
  if sx.items.len < 3:
    return hygienicRenameGeneric(env, sx, scope)
  let bindingsList = sx.items[1]
  if bindingsList.kind != sxList:
    return hygienicRenameGeneric(env, sx, scope)
  var childScope = scope
  var newBindings: seq[Syntax] = @[]
  for binding in bindingsList.items:
    if binding.kind == sxList and binding.items.len > 0 and binding.items[0].isSymbol("unquote"):
      # The whole binding is computed (e.g. `,(first bindings)` in let*) —
      # left entirely untouched; nothing to add to childScope.
      newBindings.add binding.copySyntax()
      continue
    if binding.kind != sxList or binding.items.len notin {2, 3}:
      newBindings.add hygienicRenameGeneric(env, binding, scope)
      continue
    let newTarget = hygienicRenameTypedTarget(env, binding.items[0], childScope)
    var items = @[newTarget]
    for i in 1 ..< binding.items.len:
      # Binding values are parallel, not sequential (lower.nim's
      # lowerBindings lowers every value in the outer scope before
      # declaring any of this let's names) — walked with `scope`, not
      # `childScope`.
      items.add hygienicRename(env, binding.items[i], scope)
    newBindings.add newList(items, binding.span)
  var items = @[sx.items[0].copySyntax(), newList(newBindings, bindingsList.span)]
  for i in 2 ..< sx.items.len:
    items.add hygienicRename(env, sx.items[i], childScope)
  newList(items, sx.span)

proc hygienicRenameDo(env: MacroEnv; sx: Syntax; scope: HygieneScope): Syntax =
  if sx.items.len < 3:
    return hygienicRenameGeneric(env, sx, scope)
  let params = sx.items[1]
  if params.kind != sxList:
    return hygienicRenameGeneric(env, sx, scope)
  var childScope = scope
  var newParams: seq[Syntax] = @[]
  for param in params.items:
    newParams.add hygienicRenameTypedTarget(env, param, childScope)
  var items = @[sx.items[0].copySyntax(), newList(newParams, params.span)]
  # An optional `(: return-type)` clause (see #40) rides through the same
  # generic `hygienicRename` call as the rest of the body — its only content
  # is a type symbol, which is never a hygiene-rename target, exactly like a
  # proc's return type today.
  for i in 2 ..< sx.items.len:
    items.add hygienicRename(env, sx.items[i], childScope)
  newList(items, sx.span)

proc hygienicRenameFor(env: MacroEnv; sx: Syntax; scope: HygieneScope): Syntax =
  ## `(for [:name] CLAUSE body…)` — an optional leading `:name` label (#54)
  ## is never a hygiene-rename target (same reasoning as the `block` skip in
  ## `evalMacroExpr` below and `labelIdent`'s note in backend.nim: it is not
  ## a binding, and renaming it would desync it from the lowering-side key,
  ## which is never renamed either), so it is carried through unchanged and
  ## the clause is read from the slot after it.
  let clauseIdx = if sx.items.len > 1 and sx.items[1].isBlockLabel(): 2 else: 1
  if sx.items.len < clauseIdx + 2:
    return hygienicRenameGeneric(env, sx, scope)
  let clause = sx.items[clauseIdx]
  if clause.kind != sxList or clause.items.len != 2:
    return hygienicRenameGeneric(env, sx, scope)
  let binding = clause.items[0]
  var childScope = scope
  var newBinding: Syntax
  if binding.kind == sxSymbol:
    newBinding = renameHygienicTarget(env, binding, childScope)
  elif binding.kind == sxList and binding.items.len > 0:
    var allSymbols = true
    for v in binding.items:
      if v.kind != sxSymbol:
        allSymbols = false
        break
    if allSymbols:
      var vars: seq[Syntax] = @[]
      for v in binding.items:
        vars.add renameHygienicTarget(env, v, childScope)
      newBinding = newList(vars, binding.span)
    else:
      newBinding = binding.copySyntax()
  else:
    newBinding = binding.copySyntax()
  # The iterable is walked with the OUTER scope — mirrors lower.nim's
  # lowerFor: "Lower the iterable in the outer scope before introducing
  # loop vars."
  let newIterable = hygienicRename(env, clause.items[1], scope)
  var items = @[sx.items[0].copySyntax()]
  if clauseIdx == 2:
    items.add sx.items[1].copySyntax()
  items.add newList(@[newBinding, newIterable], clause.span)
  for i in (clauseIdx + 1) ..< sx.items.len:
    items.add hygienicRename(env, sx.items[i], childScope)
  newList(items, sx.span)

proc hygienicRename(env: MacroEnv; sx: Syntax; scope: HygieneScope): Syntax =
  if sx.kind == sxList and sx.items.len > 0:
    if sx.items[0].isSymbol("unquote") or sx.items[0].isSymbol("unquote-splicing"):
      return sx.copySyntax()
    if sx.items[0].isSymbol("let") or sx.items[0].isSymbol("var"):
      return hygienicRenameLetLike(env, sx, scope)
    if sx.items[0].isSymbol("do"):
      return hygienicRenameDo(env, sx, scope)
    if sx.items[0].isSymbol("for"):
      return hygienicRenameFor(env, sx, scope)
  hygienicRenameGeneric(env, sx, scope)

# ---------- quasiquote ----------

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

# ---------- built-in macro-time functions ----------

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
      let hygieneScope: HygieneScope = initTable[string, int]()
      let renamedTemplate = hygienicRename(env, sx.items[1], hygieneScope)
      return evalQuasiquote(env, scope, renamedTemplate, false)
    if head.isSymbol("if"):
      expectArity(sx, "if", sx.items.len - 1, 3)
      if evalMacroExpr(env, scope, sx.items[1]).truthy:
        return evalMacroExpr(env, scope, sx.items[2])
      return evalMacroExpr(env, scope, sx.items[3])
    if head.isSymbol("block"):
      # `(block :name body…)` — the label only matters to lowering/backend's
      # break-from validation and codegen; at macro-expansion time a named
      # block evaluates exactly like an anonymous one, simply skipping the
      # leading label. break-from itself isn't supported in macro bodies
      # (see below), so there is no non-local exit to account for here.
      let bodyStart = if sx.items.len > 1 and sx.items[1].isBlockLabel(): 2 else: 1
      return evalBody(env, scope, sx.items.toOpenArray(bodyStart, sx.items.high), sx)
    if head.isSymbol("break-from"):
      raiseCompilerError(sx.span, "break-from is not supported in macro bodies")
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
  var scope = bindMacroArgs(env, def, call)
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
  if head.isSymbol("unhygienic"):
    raiseCompilerError(sx.span, "unhygienic is only valid as a binding target inside a quasiquote template")
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

proc isNflImportForm(form: Syntax): bool =
  form.kind == sxList and form.items.len == 2 and form.items[0].isSymbol("import") and
    form.items[1].kind == sxSymbol and form.items[1].sym.endsWith(".nfl")

proc resolveNflImportPath(currentDir, raw: string): string =
  ## Never falls back to `getCurrentDir()` — this runs at Nim compile time
  ## inside the `nflModule` macro during `nfl run`/`compile`/`check`, where
  ## the VM refuses it (compile-time FFI). `currentDir` is empty only for
  ## synthetic, non-file-backed sources, which can't resolve relative
  ## imports meaningfully anyway.
  if currentDir.len == 0: raw
  else: normalizedPath(absolutePath(raw, currentDir))

proc expandModuleFile(path: string; env: MacroEnv; span: Span): seq[Syntax] =
  ## Inline-includes an `.nfl` file's expanded forms in place of the
  ## `(import path.nfl)` form that referenced it (#10). Files already fully
  ## included are skipped (diamond imports don't duplicate declarations);
  ## a file still being included when it's requested again — including the
  ## entry file itself, which `expandModule*` also pushes onto
  ## `includingStack` via its `selfPath` argument — is a cycle.
  if path in env.includedFiles:
    return @[]
  if path in env.includingStack:
    var chain = env.includingStack
    chain.add path
    raiseCompilerError(span, "circular import: " & chain.join(" -> "))
  if not fileExists(path):
    raiseCompilerError(span, "cannot find imported file: " & path)
  let forms = readAll(readFile(path), path)
  expandModule(forms, env, parentDir(path), path)

proc expandModule*(forms: seq[Syntax]; env: MacroEnv = newMacroEnv(); currentDir = ""; selfPath = ""): seq[Syntax] =
  if selfPath.len > 0:
    env.includingStack.add selfPath
  for form in forms:
    if form.kind == sxList and form.items.len > 0 and form.items[0].isSymbol("defmacro"):
      env.defineMacro parseDefmacro(form)
    elif form.isNflImportForm():
      result.add expandModuleFile(resolveNflImportPath(currentDir, form.items[1].sym), env, form.span)
    else:
      result.add expandExpr(env, form)
  if selfPath.len > 0:
    discard env.includingStack.pop()
    env.includedFiles.incl selfPath
