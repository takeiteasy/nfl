import std/options
import std/os
import std/sets
import std/strutils
import std/tables

import ./diagnostics
import ./macros
import ./reader
import ./syntax
import ./synforms

const maxExpansionDepth = 100
# Deliberately well below a round number: each defmacro-proc recursion level
# costs ~4 native Nim call frames (evalMacroExpr -> applyMacroProc -> evalBody
# -> evalMacroExpr), and Nim's own debug-build call depth guard trips at 2000
# frames by default — a limit like 512 would hit that native guard (an
# uncatchable fatal error) before this counter ever got to report a clean
# CompilerError.
const maxMacroProcDepth = 200

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
proc applyMacroProc(env: MacroEnv; scope: var EvalScope; def: MacroDef; call: Syntax): Syntax

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
    names: seq[Syntax],
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
      if item.kind == sxSymbol:
        checkDup(item.sym, item.span)
        result.names.add item
      elif item.kind == sxVector:
        # A destructuring pattern (#47) — matched against the argument's
        # syntax form at bind time, not a runtime value, so object patterns
        # (which need a real Nim value to dot-access) are rejected here.
        var bound: seq[Syntax] = @[]
        validatePattern(item, bound, rejectObjectIn = "macro parameters")
        for name in bound:
          checkDup(name.sym, name.span)
        result.names.add item
      else:
        raiseCompilerError(item.span, "required macro parameter must be a symbol or a destructuring pattern")
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

proc parseDefmacroProc(sx: Syntax): MacroDef =
  ## Like `parseDefmacro`, but rejects `&key` — a macro-proc's arguments are
  ## evaluated (call-by-value) before binding, and `bindMacroArgs`'s
  ## `splitCallArgs` would misread an evaluated keyword-symbol argument (e.g.
  ## `':accessor` passed as a value, as CLOS-lite's helpers do) as the start
  ## of a `&key` section.
  if sx.items.len < 4:
    raiseCompilerError(sx.span, "defmacro-proc expects name, parameters, and body")
  let name = sx.items[1]
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, "defmacro-proc name must be a symbol")
  let parsed = parseMacroParams(sx.items[2])
  if parsed.keyParams.len > 0:
    raiseCompilerError(sx.items[2].span, "&key is not supported in a defmacro-proc parameter list")
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

proc bindMacroParam(scope: var EvalScope; paramSx: Syntax; argForm: Syntax) =
  ## Binds one required macro parameter against the corresponding positional
  ## argument's *syntax form* — a bare symbol binds the whole form; a
  ## destructuring pattern (#47) binds names to the form's sub-forms, the
  ## same shape #12's `let`/`var` patterns use, but matched against syntax
  ## rather than a runtime value (there is no "evaluate, then destructure"
  ## step for macro parameters).
  if paramSx.kind == sxSymbol:
    scope[paramSx.sym] = argForm
    return
  if argForm.kind notin {sxList, sxVector}:
    raiseCompilerError(argForm.span, "macro argument does not match destructuring pattern shape; expected a list or vector")
  var restIdx = -1
  for i, elem in paramSx.items:
    if elem.kind == sxSymbol and elem.sym == "&":
      restIdx = i
      break
  let headCount = if restIdx >= 0: restIdx else: paramSx.items.len
  if restIdx >= 0:
    if argForm.items.len < headCount:
      raiseCompilerError(argForm.span, "macro argument has too few elements for destructuring pattern")
  elif argForm.items.len != headCount:
    raiseCompilerError(argForm.span, "macro argument has " & $argForm.items.len &
      " elements, destructuring pattern expects " & $headCount)
  for i in 0 ..< headCount:
    let elem = paramSx.items[i]
    if elem.kind == sxSymbol:
      if elem.sym != "_":
        scope[elem.sym] = argForm.items[i]
    else:
      bindMacroParam(scope, elem, argForm.items[i])
  if restIdx >= 0:
    let restName = paramSx.items[restIdx + 1]
    if restName.kind == sxSymbol and restName.sym != "_":
      scope[restName.sym] = newList(argForm.items[headCount .. argForm.items.high], argForm.span)

proc bindPositionalArgs(env: MacroEnv; def: MacroDef; positional: seq[Syntax]; span: Span; hasKeyParams = false): EvalScope =
  ## Binds required → `&optional` → `&rest`/`&body` params against an
  ## already-split (`bindMacroArgs`) or already-evaluated (`applyMacroProc`)
  ## positional argument list. `hasKeyParams` only affects error phrasing —
  ## whether "expects N arguments" (exact) or "expects at least/most N
  ## arguments" is reported — since a macro-proc never has `&key` params
  ## (`parseDefmacroProc`), it always passes the `false` default.
  let hasRest = def.restParam.len > 0 or def.bodyParam.len > 0
  let minArgs = def.params.len
  let maxArgs = def.params.len + def.optParams.len
  let isExact = not hasRest and def.optParams.len == 0 and not hasKeyParams

  # required params
  if positional.len < minArgs:
    if isExact:
      raiseCompilerError(span, def.name & " expects " & $minArgs & " arguments, got " & $positional.len)
    else:
      raiseCompilerError(span, def.name & " expects at least " & $minArgs & " arguments, got " & $positional.len)

  result = initTable[string, Syntax]()
  for i, paramSx in def.params:
    bindMacroParam(result, paramSx, positional[i])
  var pos = def.params.len

  # optional params
  for opt in def.optParams:
    if pos < positional.len:
      result[opt.name] = positional[pos]
      inc pos
    elif opt.default.isSome:
      result[opt.name] = evalMacroExpr(env, result, opt.default.get())
    else:
      result[opt.name] = newNil(span)

  # rest / body
  let restName = if def.restParam.len > 0: def.restParam else: def.bodyParam
  if restName.len > 0:
    var restItems: seq[Syntax] = @[]
    for i in pos ..< positional.len:
      restItems.add positional[i]
    result[restName] = newList(restItems, span)
  elif pos < positional.len:
    if isExact:
      raiseCompilerError(span, def.name & " expects " & $minArgs & " arguments, got " & $positional.len)
    else:
      raiseCompilerError(span, def.name & " expects at most " & $maxArgs & " arguments, got " & $positional.len)

proc bindMacroArgs(env: MacroEnv; def: MacroDef; call: Syntax): EvalScope =
  let (positional, keywords) = splitCallArgs(call)
  result = bindPositionalArgs(env, def, positional, call.span, def.keyParams.len > 0)

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

# ---------- automatic template hygiene (#11, #62, #84) ----------
#
# Renames literal binding-target symbols introduced by a quasiquoted
# template — let/var (binding-list form and, #62, var/const section and
# single-declaration forms), const, do, for, and (#84) proc/func/method/
# converter/iterator/template parameters — so that a macro's own local
# bindings don't accidentally capture, or get captured by, identically-named
# symbols the caller passes in. This runs once over the whole template
# *before* evalQuasiquote substitutes unquotes, which is what makes leaving
# unquote/unquote-splicing subtrees untouched sufficient to avoid ever
# renaming caller-supplied syntax: at this point an unquoted expression is
# still the literal form `(unquote expr)`, not yet expr's value, so skipping
# recursion into it skips exactly the caller's syntax.
#
# `(unhygienic sym)` in binding-target position is the escape hatch for
# intentional capture (anaphoric macros): it unwraps to plain `sym`,
# without renaming it or registering it in scope, so both the binding and
# every literal reference to it stay capturable/capturing.
#
# A #12/#47 destructuring pattern target is walked and every name it binds
# is renamed (see `hygienicRenamePattern`) — `_`/`&`/`:field` markers are
# preserved, only bound names change.
#
# Deliberately unhandled, and so left unrenamed (matching how the preamble
# macros `let*`/`as->` already work, unaffected by this pass): a binding
# whose target is itself an unquote (`,name`, a macro-computed name — the
# macro author's own symbol).
#
# A `var`/`const` section (#62) and a single declaration have no body of
# their own — their names must stay visible to *following siblings* in the
# enclosing statement list, unlike a let/do/for binding, which is confined
# to its own body. `hygienicRenameBody` threads a mutable scope left-to-right
# across a list of siblings for exactly this; a plain (non-var) scope is
# still used everywhere a walk is in expression position (let-binding
# values, the for iterable) since those must not see names declared by
# their own form.

type HygieneScope = Table[string, int]  # literal name -> assigned hygieneId

proc hygienicRename(env: MacroEnv; sx: Syntax; scope: HygieneScope): Syntax
proc hygienicRenameGeneric(env: MacroEnv; sx: Syntax; scope: HygieneScope): Syntax

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

proc hygienicRenamePattern(env: MacroEnv; pattern: Syntax; childScope: var HygieneScope): Syntax =
  ## Renames every name a destructuring pattern (#12/#47) binds, registering
  ## each in `childScope` like `renameHygienicTarget` — `_`, `&`, and object-
  ## pattern `:field` keys are preserved as-is; only bound names change. A
  ## shorthand `:field` (no explicit target) is rewritten to the explicit
  ## `:field renamed-name` form so the rename isn't lost.
  if pattern.isObjectPattern():
    var items: seq[Syntax] = @[]
    var i = 0
    while i < pattern.items.len:
      let key = pattern.items[i]
      items.add key.copySyntax()
      if i + 1 < pattern.items.len and not pattern.items[i + 1].isKeywordSym():
        let elem = pattern.items[i + 1]
        if elem.kind == sxSymbol:
          items.add (if elem.sym == "_": elem.copySyntax() else: renameHygienicTarget(env, elem, childScope))
        else:
          items.add hygienicRenamePattern(env, elem, childScope)
        i += 2
      else:
        let shorthandTarget = newSymbol(key.sym[1 .. ^1], key.span)
        items.add renameHygienicTarget(env, shorthandTarget, childScope)
        i += 1
    return newVector(items, pattern.span)
  var items: seq[Syntax] = @[]
  for elem in pattern.items:
    case elem.kind
    of sxSymbol:
      items.add (if elem.sym in ["_", "&"]: elem.copySyntax() else: renameHygienicTarget(env, elem, childScope))
    of sxVector:
      items.add hygienicRenamePattern(env, elem, childScope)
    else:
      items.add elem.copySyntax()
  newVector(items, pattern.span)

proc hygienicRenameTypedTarget(env: MacroEnv; target: Syntax; childScope: var HygieneScope): Syntax =
  ## Renames the shared `symbol` / `(name type)` / `(name type default)` /
  ## `(unhygienic ...)` / destructuring-pattern binding-target shape used by
  ## let/var bindings, do/proc params, and for loop variables. Any other
  ## shape (an unquoted/computed name, …) is left untouched — see the
  ## module-level comment.
  let (inner, skip) = unwrapUnhygienicTarget(target)
  if skip:
    inner.copySyntax()
  elif inner.kind == sxSymbol:
    renameHygienicTarget(env, inner, childScope)
  elif inner.kind == sxList and inner.items.len > 0 and inner.items[0].isSymbol("unquote"):
    inner.copySyntax()
  elif inner.kind == sxVector:
    hygienicRenamePattern(env, inner, childScope)
  elif inner.kind == sxList and inner.items.len == 3 and inner.items[0].kind == sxSymbol and
      (inner.items[1].kind == sxSymbol or inner.items[1].kind == sxVector):
    # `(name type default)` — a #77/#84 parameter default. lowerParam runs in
    # a loop after pushScope, so a default may reference an earlier param;
    # renamed with the accumulating `childScope` (the opposite of a let/var
    # binding value, which is parallel and uses the outer scope instead).
    let newName = renameHygienicTarget(env, inner.items[0], childScope)
    newList(@[newName, inner.items[1].copySyntax(), hygienicRename(env, inner.items[2], childScope)], inner.span)
  elif inner.kind == sxList and inner.items.len == 2 and
      (inner.items[0].kind == sxSymbol or inner.items[0].kind == sxVector) and
      (inner.items[1].kind == sxSymbol or inner.items[1].kind == sxVector):
    let newName =
      if inner.items[0].kind == sxSymbol: renameHygienicTarget(env, inner.items[0], childScope)
      else: hygienicRenamePattern(env, inner.items[0], childScope)
    newList(@[newName, inner.items[1].copySyntax()], inner.span)
  else:
    inner.copySyntax()

proc hygienicRenameVarSection(env: MacroEnv; sx: Syntax; scope: var HygieneScope): Syntax =
  ## #62: a `var`/`const` *section* — `(var ((x 1) (y 2)))`, no body — has no
  ## body of its own confining its names, unlike let/do/for; its targets must
  ## stay visible to *following siblings* in the enclosing statement list, so
  ## `scope` is threaded in and mutated (see `hygienicRenameBody`, the only
  ## caller that can actually observe the mutation). Binding shapes mirror
  ## lower.nim's `sectionBindingParts`: `(target)`, `(target value)`,
  ## `(target {.pragma.})`, `(target {.pragma.} value)`. Values are renamed
  ## with a snapshot of `scope` taken before any of this section's own
  ## targets are registered — lowerVarSection lowers every value before
  ## declaring any target, so (like a let/var binding-list's values) no
  ## binding in a section can see another binding the same section declares.
  let bindingsList = sx.items[1]
  if bindingsList.kind != sxList or bindingsList.items.len == 0:
    var childScope = scope
    return hygienicRenameGeneric(env, sx, childScope)
  let outerScope = scope
  var newBindings: seq[Syntax] = @[]
  for binding in bindingsList.items:
    if binding.kind != sxList or binding.items.len notin {1, 2, 3}:
      newBindings.add hygienicRenameGeneric(env, binding, outerScope)
      continue
    let target = binding.items[0]
    if target.kind == sxList and target.items.len > 0 and target.items[0].isSymbol("unquote"):
      # The whole target is computed — left entirely untouched; nothing to
      # add to scope.
      newBindings.add binding.copySyntax()
      continue
    let newTarget = hygienicRenameTypedTarget(env, target, scope)
    var items = @[newTarget]
    for i in 1 ..< binding.items.len:
      items.add hygienicRename(env, binding.items[i], outerScope)
    newBindings.add newList(items, binding.span)
  newList(@[sx.items[0].copySyntax(), newList(newBindings, bindingsList.span)], sx.span)

proc hygienicRenameVarDecl(env: MacroEnv; sx: Syntax; scope: var HygieneScope): Syntax =
  ## #62: a single `var`/`const` declaration — `(var name value)` /
  ## `(var (name type) value)` / `(const …)` — recognized by `isDefvarForm`.
  ## Mirrors lowerVarDecl/lowerConst, which lower the value before declaring
  ## the name: the value is renamed with the scope snapshot taken before
  ## this declaration's own target is registered, and (like a section) the
  ## registration is visible to following siblings via the threaded `scope`.
  if sx.items.len < 2:
    var childScope = scope
    return hygienicRenameGeneric(env, sx, childScope)
  let outerScope = scope
  let newName = hygienicRenameTypedTarget(env, sx.items[1], scope)
  var items = @[sx.items[0].copySyntax(), newName]
  for i in 2 ..< sx.items.len:
    items.add hygienicRename(env, sx.items[i], outerScope)
  newList(items, sx.span)

proc hygienicRenameBody(env: MacroEnv; items: openArray[Syntax]; scope: var HygieneScope): seq[Syntax] =
  ## Walks a list of siblings — a block/let/do/for/proc body, or any other
  ## list — threading `scope` left-to-right so a #62 var/const section or
  ## single declaration's names are visible to the siblings that follow it,
  ## the same way Nim's own statement-list scoping works. Any other item is
  ## walked with the (mutated-so-far) `scope`, unchanged, via `hygienicRename`.
  for item in items:
    if item.kind == sxList and item.items.len > 0 and
        (item.items[0].isSymbol("var") or item.items[0].isSymbol("const")):
      if isVarSectionForm(item):
        result.add hygienicRenameVarSection(env, item, scope)
        continue
      if isDefvarForm(item):
        result.add hygienicRenameVarDecl(env, item, scope)
        continue
    result.add hygienicRename(env, item, scope)

proc hygienicRenameGeneric(env: MacroEnv; sx: Syntax; scope: HygieneScope): Syntax =
  case sx.kind
  of sxSymbol:
    if scope.hasKey(sx.sym):
      newSymbol(sx.sym, sx.span, scope[sx.sym])
    else:
      sx.copySyntax()
  of sxList:
    var childScope = scope
    newList(hygienicRenameBody(env, sx.items, childScope), sx.span)
  of sxVector:
    var childScope = scope
    newVector(hygienicRenameBody(env, sx.items, childScope), sx.span)
  else:
    sx.copySyntax()

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
  items.add hygienicRenameBody(env, sx.items.toOpenArray(2, sx.items.high), childScope)
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
  # threaded body walk as the rest of the body — its only content is a type
  # symbol, which is never a hygiene-rename target, exactly like a proc's
  # return type today.
  items.add hygienicRenameBody(env, sx.items.toOpenArray(2, sx.items.high), childScope)
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
  items.add hygienicRenameBody(env, sx.items.toOpenArray(clauseIdx + 1, sx.items.high), childScope)
  newList(items, sx.span)

proc hygienicRenameProc(env: MacroEnv; sx: Syntax; scope: HygieneScope): Syntax =
  ## #84: proc/func/method/converter/iterator/template routine forms — only
  ## the parameter list is a hygiene-rename target, mirroring `do`'s params.
  ## The routine name (slot 1) is never renamed: `declIdent` hard-rejects a
  ## hygienic exported name, and preamble macros like `defproc`/`deffunc`
  ## forward a caller-supplied name that must stay resolvable by its literal
  ## spelling. The optional generic-params vector and each param's type are
  ## never renamed either — `identForTypeSymbol` silently drops hygieneId,
  ## so a renamed type would fail to resolve, with no diagnostic at all.
  if sx.items.len < 4:
    return hygienicRenameGeneric(env, sx, scope)
  let paramsIdx = procParamsIdx(sx)
  if sx.items.len <= paramsIdx or sx.items[paramsIdx].kind != sxList:
    return hygienicRenameGeneric(env, sx, scope)
  let params = sx.items[paramsIdx]
  var childScope = scope
  var newParams: seq[Syntax] = @[]
  for param in params.items:
    newParams.add hygienicRenameTypedTarget(env, param, childScope)
  var items: seq[Syntax] = @[]
  for i in 0 ..< paramsIdx:
    items.add sx.items[i].copySyntax()
  items.add newList(newParams, params.span)
  # Everything after the params — an optional `(: return-type)` clause and
  # the body — rides through the same threaded body walk as `do` uses,
  # for the same reason (the return type is never a rename target, and a
  # #62 var/const section in the body must see the renamed params).
  items.add hygienicRenameBody(env, sx.items.toOpenArray(paramsIdx + 1, sx.items.high), childScope)
  newList(items, sx.span)

proc hygienicRename(env: MacroEnv; sx: Syntax; scope: HygieneScope): Syntax =
  if sx.kind == sxList and sx.items.len > 0:
    if sx.items[0].isSymbol("unquote") or sx.items[0].isSymbol("unquote-splicing"):
      return sx.copySyntax()
    if sx.items[0].isSymbol("let"):
      return hygienicRenameLetLike(env, sx, scope)
    if sx.items[0].isSymbol("var"):
      if isVarSectionForm(sx):
        var childScope = scope
        return hygienicRenameVarSection(env, sx, childScope)
      if isDefvarForm(sx):
        var childScope = scope
        return hygienicRenameVarDecl(env, sx, childScope)
      return hygienicRenameLetLike(env, sx, scope)
    if sx.items[0].isSymbol("const"):
      if isVarSectionForm(sx):
        var childScope = scope
        return hygienicRenameVarSection(env, sx, childScope)
      if isDefvarForm(sx):
        var childScope = scope
        return hygienicRenameVarDecl(env, sx, childScope)
      return hygienicRenameGeneric(env, sx, scope)
    if sx.items[0].isSymbol("do"):
      return hygienicRenameDo(env, sx, scope)
    if sx.items[0].isSymbol("for"):
      return hygienicRenameFor(env, sx, scope)
    if sx.items[0].isSymbol("proc") or sx.items[0].isSymbol("func") or
        sx.items[0].isSymbol("method") or sx.items[0].isSymbol("converter") or
        sx.items[0].isSymbol("iterator") or sx.items[0].isSymbol("template"):
      return hygienicRenameProc(env, sx, scope)
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

proc expectNumber(sx: Syntax): Syntax =
  if sx.kind notin {sxInt, sxFloat}:
    raiseCompilerError(sx.span, "expected a number, got " & $sx.kind)
  sx

proc asFloat(sx: Syntax): BiggestFloat =
  if sx.kind == sxFloat: sx.floatVal else: sx.intVal.BiggestFloat

proc evalNumericArgs(env: MacroEnv; scope: var EvalScope; call: Syntax; minArgs: int): seq[Syntax] =
  if call.items.len - 1 < minArgs:
    raiseCompilerError(call.span, call.items[0].sym & " expects at least " & $minArgs & " arguments, got " & $(call.items.len - 1))
  for i in 1 ..< call.items.len:
    result.add expectNumber(evalMacroExpr(env, scope, call.items[i]))

proc anyFloat(args: openArray[Syntax]): bool =
  for a in args:
    if a.kind == sxFloat:
      return true
  false

proc evalBuiltin(env: MacroEnv; scope: var EvalScope; call: Syntax): Syntax =
  let name = call.items[0].sym
  case name
  of "+", "*":
    let args = evalNumericArgs(env, scope, call, 1)
    if anyFloat(args):
      var acc = if name == "+": 0.0 else: 1.0
      for a in args:
        acc = if name == "+": acc + a.asFloat else: acc * a.asFloat
      newFloat(acc, call.span)
    else:
      var acc = if name == "+": 0.BiggestInt else: 1.BiggestInt
      for a in args:
        acc = if name == "+": acc + a.intVal else: acc * a.intVal
      newInt(acc, call.span)
  of "-":
    let args = evalNumericArgs(env, scope, call, 1)
    if anyFloat(args):
      if args.len == 1:
        newFloat(-args[0].asFloat, call.span)
      else:
        var acc = args[0].asFloat
        for i in 1 ..< args.len:
          acc -= args[i].asFloat
        newFloat(acc, call.span)
    else:
      if args.len == 1:
        newInt(-args[0].intVal, call.span)
      else:
        var acc = args[0].intVal
        for i in 1 ..< args.len:
          acc -= args[i].intVal
        newInt(acc, call.span)
  of "/":
    let args = evalNumericArgs(env, scope, call, 1)
    var vals: seq[BiggestFloat] = @[]
    for a in args: vals.add a.asFloat
    if vals.len == 1:
      if vals[0] == 0.0:
        raiseCompilerError(call.span, "division by zero")
      newFloat(1.0 / vals[0], call.span)
    else:
      var acc = vals[0]
      for i in 1 ..< vals.len:
        if vals[i] == 0.0:
          raiseCompilerError(call.span, "division by zero")
        acc = acc / vals[i]
      newFloat(acc, call.span)
  of "div", "mod":
    let args = evalNumericArgs(env, scope, call, 2)
    if anyFloat(args):
      raiseCompilerError(call.span, name & " expects integer arguments")
    var acc = args[0].intVal
    for i in 1 ..< args.len:
      if args[i].intVal == 0:
        raiseCompilerError(call.span, "division by zero")
      acc = if name == "div": acc div args[i].intVal else: acc mod args[i].intVal
    newInt(acc, call.span)
  of "<", "<=", ">", ">=":
    let args = evalNumericArgs(env, scope, call, 2)
    var ok = true
    for i in 1 ..< args.len:
      let a = args[i - 1].asFloat
      let b = args[i].asFloat
      let step = case name
        of "<": a < b
        of "<=": a <= b
        of ">": a > b
        else: a >= b
      if not step:
        ok = false
        break
    newBool(ok, call.span)
  of "=", "/=":
    expectArity(call, name, call.items.len - 1, 2)
    let a = evalMacroExpr(env, scope, call.items[1])
    let b = evalMacroExpr(env, scope, call.items[2])
    let eq = sameSyntax(a, b)
    newBool(if name == "=": eq else: not eq, call.span)
  of "not":
    expectArity(call, name, call.items.len - 1, 1)
    newBool(not evalMacroExpr(env, scope, call.items[1]).truthy, call.span)
  of "nth":
    expectArity(call, name, call.items.len - 1, 2)
    let value = evalMacroExpr(env, scope, call.items[1])
    if value.kind != sxList and value.kind != sxVector:
      raiseCompilerError(call.items[1].span, "nth expects a list or vector")
    let idxSx = evalMacroExpr(env, scope, call.items[2])
    if idxSx.kind != sxInt:
      raiseCompilerError(call.items[2].span, "nth expects an integer index")
    let idx = idxSx.intVal
    if idx < 0 or idx >= value.items.len:
      newNil(call.span)
    else:
      value.items[idx].copySyntax()
  of "length":
    expectArity(call, name, call.items.len - 1, 1)
    let value = evalMacroExpr(env, scope, call.items[1])
    if value.kind != sxList and value.kind != sxVector:
      raiseCompilerError(call.items[1].span, "length expects a list or vector")
    newInt(value.items.len, call.span)
  of "reverse":
    expectArity(call, name, call.items.len - 1, 1)
    let value = evalMacroExpr(env, scope, call.items[1])
    if value.kind != sxList and value.kind != sxVector:
      raiseCompilerError(call.items[1].span, "reverse expects a list or vector")
    var items: seq[Syntax] = @[]
    for i in countdown(value.items.high, 0):
      items.add value.items[i].copySyntax()
    newList(items, call.span)
  of "member":
    expectArity(call, name, call.items.len - 1, 2)
    let target = evalMacroExpr(env, scope, call.items[1])
    let value = evalMacroExpr(env, scope, call.items[2])
    if value.kind != sxList and value.kind != sxVector:
      raiseCompilerError(call.items[2].span, "member expects a list or vector")
    var found = false
    for item in value.items:
      if sameSyntax(item, target):
        found = true
        break
    newBool(found, call.span)
  of "symbol->string":
    expectArity(call, name, call.items.len - 1, 1)
    let value = evalMacroExpr(env, scope, call.items[1])
    if value.kind != sxSymbol:
      raiseCompilerError(call.items[1].span, "symbol->string expects a symbol")
    newString(value.sym, call.span)
  of "string->symbol":
    expectArity(call, name, call.items.len - 1, 1)
    let value = evalMacroExpr(env, scope, call.items[1])
    if value.kind != sxString:
      raiseCompilerError(call.items[1].span, "string->symbol expects a string")
    newSymbol(value.strVal, call.span)
  of "string-append":
    var parts: seq[string] = @[]
    for i in 1 ..< call.items.len:
      let value = evalMacroExpr(env, scope, call.items[i])
      if value.kind != sxString:
        raiseCompilerError(call.items[i].span, "string-append expects strings")
      parts.add value.strVal
    newString(parts.join(""), call.span)
  of "symbol?":
    expectArity(call, name, call.items.len - 1, 1)
    newBool(evalMacroExpr(env, scope, call.items[1]).kind == sxSymbol, call.span)
  of "list?":
    expectArity(call, name, call.items.len - 1, 1)
    newBool(evalMacroExpr(env, scope, call.items[1]).kind == sxList, call.span)
  of "vector?":
    expectArity(call, name, call.items.len - 1, 1)
    newBool(evalMacroExpr(env, scope, call.items[1]).kind == sxVector, call.span)
  of "string?":
    expectArity(call, name, call.items.len - 1, 1)
    newBool(evalMacroExpr(env, scope, call.items[1]).kind == sxString, call.span)
  of "int?":
    expectArity(call, name, call.items.len - 1, 1)
    newBool(evalMacroExpr(env, scope, call.items[1]).kind == sxInt, call.span)
  of "float?":
    expectArity(call, name, call.items.len - 1, 1)
    newBool(evalMacroExpr(env, scope, call.items[1]).kind == sxFloat, call.span)
  of "bool?":
    expectArity(call, name, call.items.len - 1, 1)
    newBool(evalMacroExpr(env, scope, call.items[1]).kind == sxBool, call.span)
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
    if env.hasMacroProc(head.sym):
      return applyMacroProc(env, scope, env.getMacroProc(head.sym), sx)
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

proc applyMacroProc(env: MacroEnv; scope: var EvalScope; def: MacroDef; call: Syntax): Syntax =
  ## Applies a `defmacro-proc` at a call site — unlike `applyMacro`, this is
  ## call-by-value: every argument is evaluated in the *caller's* scope
  ## before binding, and `maxExpansionDepth` (which only counts `defmacro`
  ## expansions) does not bound this recursion, so `macroProcDepth` is
  ## tracked separately and always unwound via `finally`, even when a
  ## builtin or `macro-error` raises mid-call.
  var args: seq[Syntax] = @[]
  for i in 1 ..< call.items.len:
    args.add evalMacroExpr(env, scope, call.items[i])
  var procScope = bindPositionalArgs(env, def, args, call.span)
  inc env.macroProcDepth
  try:
    if env.macroProcDepth > maxMacroProcDepth:
      raiseCompilerError(call.span, "macro-time procedure recursion depth exceeded")
    evalBody(env, procScope, def.body, call).withSpan(call.span)
  except CompilerError as err:
    let message = "error expanding macro-proc " & def.name & ": " & err.diagnostic.message
    raiseCompilerError(call.span, message)
  finally:
    dec env.macroProcDepth

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
  if head.isSymbol("defmacro-proc"):
    raiseCompilerError(sx.span, "defmacro-proc is only allowed at statement/module scope")
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
    elif form.kind == sxList and form.items.len > 0 and form.items[0].isSymbol("defmacro-proc"):
      env.defineMacroProc parseDefmacroProc(form)
    elif form.isNflImportForm():
      result.add expandModuleFile(resolveNflImportPath(currentDir, form.items[1].sym), env, form.span)
    else:
      result.add expandExpr(env, form)
  if selfPath.len > 0:
    discard env.includingStack.pop()
    env.includedFiles.incl selfPath
