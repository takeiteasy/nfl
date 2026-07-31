import std/tables
import std/strutils
import std/options

import ./diagnostics
import ./syntax
import ./synforms

type
  BindingKind = enum
    bkImmutable, bkMutable

  LabelFrame = object
    key: string
      ## Via `symbolKey` — see below.
    isLoop: bool
      ## True for a labelled `while`/`for`; false for a named `block`.
      ## `break-from` may only target a `block` frame; `break`/`continue`
      ## with a `:name` argument may only target a loop frame — mixing them
      ## up is a lowering error rather than a raw Nim compiler error.

  LowerContext = object
    scopes: seq[Table[string, BindingKind]]
    bodyDepth: int
      ## Counts nesting inside a proc/template/block/etc. body (see
      ## `lowerBody`). Zero at true module top level, where `defer` is not
      ## allowed since Nim itself rejects `defer` outside a body.
    namedBlocks: seq[LabelFrame]
      ## Enclosing named `block`s and labelled loops, innermost last, keyed
      ## (via `symbolKey`) the same way — the targets `break-from` (block
      ## frames only) and labelled `break`/`continue` (loop frames only) may
      ## validly reference. Reset to empty (not pushed/popped) at each
      ## proc/template/iterator/method/converter/`do` boundary in
      ## `lowerRoutine`/`lowerLambda`: Nim's `break lbl` cannot cross a
      ## routine boundary, so a label from an enclosing routine is never a
      ## valid target inside a nested one. Loops do *not* reset this —
      ## breaking out of a loop to an enclosing named block (or an outer
      ## labelled loop) is exactly what these forms are for.

proc isSymbol(sx: Syntax; name: string): bool =
  sx.kind == sxSymbol and sx.sym == name

proc validatePragma(sx: Syntax) =
  ## Validates a pragma clause `(pragma m1 m2 …)`.  Each entry after the head
  ## must be either:
  ##   - a plain non-empty symbol (marker pragma), or
  ##   - a value entry `(: key value)` where `key` is a non-empty symbol without `*`.
  for i in 1 ..< sx.items.len:
    let entry = sx.items[i]
    if entry.kind == sxSymbol:
      if entry.sym.len == 0 or entry.sym.contains("*"):
        raiseCompilerError(entry.span, "pragma entry must be a marker symbol")
    elif entry.kind == sxList and entry.items.len == 3 and entry.items[0].isSymbol(":"):
      let key = entry.items[1]
      if key.kind != sxSymbol or key.sym.len == 0 or key.sym.contains("*"):
        raiseCompilerError(key.span, "pragma key must be a non-empty symbol")
    else:
      raiseCompilerError(entry.span, "pragma entry must be a marker symbol or key: value pair")

proc symbolKey(sx: Syntax): string =
  if sx.hygieneId == 0:
    sx.sym
  else:
    sx.sym & "\0" & $sx.hygieneId

proc expectArity(sx: Syntax; name: string; actual, expected: int) =
  if actual != expected:
    raiseCompilerError(sx.span, name & " expects " & $expected & " arguments, got " & $actual)

proc pushScope(ctx: var LowerContext) =
  ctx.scopes.add initTable[string, BindingKind]()

proc popScope(ctx: var LowerContext) =
  discard ctx.scopes.pop()

proc declare(ctx: var LowerContext; name: Syntax; kind: BindingKind) =
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, "binding name must be a symbol")
  if ctx.scopes.len == 0:
    ctx.pushScope()
  var scope = addr ctx.scopes[^1]
  let key = name.symbolKey()
  if scope[].hasKey(key):
    raiseCompilerError(name.span, "duplicate binding: " & name.sym)
  scope[][key] = kind

proc declareRoutineName(ctx: var LowerContext; name: Syntax) =
  ## Register a routine name (proc/method/template/iterator) as an immutable
  ## binding.  Multiple declarations of the same name are silently allowed —
  ## Nim permits overloaded procs and methods with distinct parameter types.
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, "binding name must be a symbol")
  if ctx.scopes.len == 0:
    ctx.pushScope()
  var scope = addr ctx.scopes[^1]
  let key = name.symbolKey()
  if not scope[].hasKey(key):
    scope[][key] = bkImmutable

proc lookup(ctx: LowerContext; name: Syntax): Option[BindingKind] =
  let key = name.symbolKey()
  for i in countdown(ctx.scopes.high, 0):
    if ctx.scopes[i].hasKey(key):
      return some(ctx.scopes[i][key])
  none(BindingKind)

proc lowerExpr(ctx: var LowerContext; sx: Syntax)
proc lowerStmt(ctx: var LowerContext; sx: Syntax)
proc validateTypeReference(sx: Syntax; what: string)

proc isNamedArg(sx: Syntax): bool =
  sx.kind == sxList and sx.items.len > 0 and sx.items[0].isSymbol(":")

proc bindingTargets(binding: Syntax): seq[Syntax] =
  ## Returns the name symbol(s) to declare for a binding pair `(target
  ## value)` or an annotated binding triple `(target {.pragma.} value)`.
  ## `target` is a bare symbol, a typed `(name type)` pair, or — per #12/#47 —
  ## a destructuring pattern (a positional vector `[a b]` / `[head & rest]`
  ## or an object pattern `[:field ...]`), optionally nested, in which case
  ## every name bound by the pattern is returned.
  if binding.kind != sxList or binding.items.len notin {2, 3}:
    raiseCompilerError(binding.span, "binding must be a pair or annotated triple")
  if binding.items.len == 3:
    if not binding.items[1].isPragmaClause():
      raiseCompilerError(binding.items[1].span, "expected pragma clause between binding target and value")
    validatePragma(binding.items[1])
  let target = binding.items[0]
  if target.kind == sxSymbol:
    return @[target]
  # `(name type)` where type may be a symbol or a generic type vector `[Head T…]`
  if target.kind == sxList and target.items.len == 2 and target.items[0].kind == sxSymbol and
      (target.items[1].kind == sxSymbol or target.items[1].kind == sxVector):
    return @[target.items[0]]
  if target.kind == sxVector:
    if binding.items.len == 3:
      raiseCompilerError(binding.items[1].span, "destructuring pattern cannot carry a pragma clause")
    validatePattern(target, result)
    return
  raiseCompilerError(target.span, "binding name must be a symbol or (name type), or a destructuring pattern")

proc lowerBody(ctx: var LowerContext; items: openArray[Syntax]; owner: Syntax) =
  if items.len == 0:
    raiseCompilerError(owner.span, "expected body expression")
  inc ctx.bodyDepth
  for item in items:
    lowerStmt(ctx, item)
  dec ctx.bodyDepth

proc lowerBindings(ctx: var LowerContext; bindings: Syntax; mutable: bool) =
  if bindings.kind != sxList:
    raiseCompilerError(bindings.span, "bindings must be a list")

  for binding in bindings.items:
    discard binding.bindingTargets()                # validates structure + optional pragma
    lowerExpr(ctx, binding.items[binding.items.high])  # value is always the last item

  ctx.pushScope()
  let kind = if mutable: bkMutable else: bkImmutable
  for binding in bindings.items:
    for name in binding.bindingTargets():
      declare(ctx, name, kind)

proc lowerLetLike(ctx: var LowerContext; sx: Syntax; mutable: bool) =
  if sx.items.len < 3:
    raiseCompilerError(sx.span, formName(sx.items[0]) & " expects bindings and body")
  lowerBindings(ctx, sx.items[1], mutable)
  lowerBody(ctx, sx.items.toOpenArray(2, sx.items.high), sx)
  ctx.popScope()

proc isVarSectionForm(sx: Syntax): bool =
  ## A `var`/`const` section form declares multiple bindings at
  ## statement/module scope using the same binding-list grammar as the local
  ## mutable-binding form, but with no body: `(var ((x 1) (y 2)))`. This is
  ## distinguished from the local form (which requires a body) purely by
  ## arity — `(var (bindings…) body…)` has 3+ items, a section has exactly 2.
  sx.items.len == 2 and not isDefvarForm(sx)

proc sectionBindingParts(binding: Syntax; mutable: bool): tuple[targets: seq[Syntax], valueIdx: int] =
  ## Parses a single binding within a `var`/`const` section — a target,
  ## optional pragma, and optional value: `(target)`, `(target value)`,
  ## `(target {.pragma.})`, `(target {.pragma.} value)`. Unlike the local
  ## mutable-binding form (`bindingName`), a value may be omitted when the
  ## target carries an explicit type — but only for `var` sections; `const`
  ## always requires a value, mirroring `lowerConst`. `target` may also (#47)
  ## be a destructuring pattern, in which case every name the pattern binds
  ## is returned; a pattern target never carries a type, so it always
  ## requires a value.
  if binding.kind != sxList or binding.items.len notin {1, 2, 3}:
    raiseCompilerError(binding.span, "binding must be a target, optional pragma, and optional value")
  let target = binding.items[0]
  var hasType = false
  var targets: seq[Syntax] = @[]
  if target.kind == sxSymbol:
    targets = @[target]
  elif target.kind == sxList and target.items.len == 2 and target.items[0].kind == sxSymbol and
      (target.items[1].kind == sxSymbol or target.items[1].kind == sxVector):
    targets = @[target.items[0]]
    validateTypeReference(target.items[1], "binding type")
    hasType = true
  elif target.kind == sxVector:
    validatePattern(target, targets)
  else:
    raiseCompilerError(target.span, "binding name must be a symbol or (name type), or a destructuring pattern")
  var pragmaIdx = -1
  var valueIdx = -1
  if binding.items.len == 2:
    if binding.items[1].isPragmaClause():
      if target.kind == sxVector:
        raiseCompilerError(binding.items[1].span, "destructuring pattern cannot carry a pragma clause")
      pragmaIdx = 1
    else:
      valueIdx = 1
  elif binding.items.len == 3:
    if not binding.items[1].isPragmaClause():
      raiseCompilerError(binding.items[1].span, "expected pragma clause between binding target and value")
    if target.kind == sxVector:
      raiseCompilerError(binding.items[1].span, "destructuring pattern cannot carry a pragma clause")
    pragmaIdx = 1
    valueIdx = 2
  if pragmaIdx >= 0:
    validatePragma(binding.items[pragmaIdx])
  if valueIdx < 0:
    if not mutable:
      raiseCompilerError(binding.span, "const section binding requires a value")
    if not hasType:
      raiseCompilerError(binding.span, "var section binding without a type annotation requires a value")
  result = (targets, valueIdx)

proc lowerVarSection(ctx: var LowerContext; sx: Syntax; mutable: bool) =
  let bindings = sx.items[1]
  if bindings.kind != sxList or bindings.items.len == 0:
    raiseCompilerError(bindings.span, formName(sx.items[0]) & " section expects at least one binding")
  var targets: seq[Syntax] = @[]
  for binding in bindings.items:
    let parts = sectionBindingParts(binding, mutable)
    if parts.valueIdx >= 0:
      lowerExpr(ctx, binding.items[parts.valueIdx])
    targets.add parts.targets
  let kind = if mutable: bkMutable else: bkImmutable
  for target in targets:
    declare(ctx, target, kind)

proc lowerIf(ctx: var LowerContext; sx: Syntax) =
  expectArity(sx, "if", sx.items.len - 1, 3)
  lowerExpr(ctx, sx.items[1])
  lowerExpr(ctx, sx.items[2])
  lowerExpr(ctx, sx.items[3])

proc findLabelFrame(ctx: LowerContext; key: string): int =
  ## Innermost-first lookup (shadowing: an inner loop/block reusing an outer
  ## label name binds first). -1 when no enclosing frame carries `key`.
  for i in countdown(ctx.namedBlocks.high, 0):
    if ctx.namedBlocks[i].key == key:
      return i
  -1

proc lowerBegin(ctx: var LowerContext; sx: Syntax) =
  if sx.items.len == 1:
    raiseCompilerError(sx.span, "block expects at least one expression")
  var bodyStart = 1
  var labelKey = ""
  var labelled = false
  if sx.items[1].isBlockLabel():
    if sx.items.len == 2:
      raiseCompilerError(sx.span, "block expects at least one expression")
    labelled = true
    labelKey = sx.items[1].symbolKey()
    bodyStart = 2
  if labelled:
    ctx.namedBlocks.add LabelFrame(key: labelKey, isLoop: false)
  lowerBody(ctx, sx.items.toOpenArray(bodyStart, sx.items.high), sx)
  if labelled:
    discard ctx.namedBlocks.pop()

proc lowerProgN(ctx: var LowerContext; sx: Syntax; minArgs: int; formName: string) =
  ## Validates `(prog1 expr rest…)` (minArgs 1) / `(prog2 e1 e2 rest…)`
  ## (minArgs 2) — sequences the body like `block`, just with a captured
  ## non-tail return value (no non-local-exit/typeof complexity, since the
  ## captured value is read in straight-line position).
  let nargs = sx.items.len - 1
  if nargs < minArgs:
    raiseCompilerError(sx.span,
      formName & " expects at least " & $minArgs & " argument(s), got " & $nargs)
  lowerBody(ctx, sx.items.toOpenArray(1, sx.items.high), sx)

proc lowerBreakFrom(ctx: var LowerContext; sx: Syntax) =
  ## Validates `(break-from :name)` (valueless) or `(break-from :name expr)`.
  let nargs = sx.items.len - 1
  if nargs notin [1, 2]:
    raiseCompilerError(sx.span, "break-from expects 1 or 2 arguments, got " & $nargs)
  let target = sx.items[1]
  if not target.isBlockLabel():
    raiseCompilerError(target.span, "break-from target must be a :name label")
  let frameIdx = ctx.findLabelFrame(target.symbolKey())
  if frameIdx < 0:
    raiseCompilerError(target.span,
      "break-from target is not an enclosing named block: " & target.sym)
  if ctx.namedBlocks[frameIdx].isLoop:
    raiseCompilerError(target.span,
      "break-from target is a labelled loop, not a named block — use (break " &
      target.sym & ") instead")
  if nargs == 2:
    lowerExpr(ctx, sx.items[2])

proc lowerSet(ctx: var LowerContext; sx: Syntax) =
  expectArity(sx, "set!", sx.items.len - 1, 2)
  let target = sx.items[1]
  if target.kind != sxSymbol:
    raiseCompilerError(target.span, "set! target must be a symbol")
  let binding = ctx.lookup(target)
  if binding.isNone:
    raiseCompilerError(target.span, "set! target is not a mutable local: " & target.sym)
  if binding.get() != bkMutable:
    raiseCompilerError(target.span, "cannot set! immutable binding: " & target.sym)
  lowerExpr(ctx, sx.items[2])

proc lowerParam(ctx: var LowerContext; param: Syntax) =
  if param.kind == sxSymbol:
    declare(ctx, param, bkImmutable)
  elif param.kind == sxList and param.items.len == 2 and param.items[0].kind == sxSymbol and
      (param.items[1].kind == sxSymbol or param.items[1].kind == sxVector):
    validateTypeReference(param.items[1], "parameter type")
    declare(ctx, param.items[0], bkImmutable)
  elif param.kind == sxList and param.items.len == 2 and param.items[0].kind == sxVector and
      (param.items[1].kind == sxSymbol or param.items[1].kind == sxVector):
    # A destructured parameter (#47) — `([a b] Point)` — must carry an
    # explicit type: Nim formal params feed the pattern's synthetic carrier
    # param directly, and that param always needs a concrete type.
    validateTypeReference(param.items[1], "parameter type")
    var names: seq[Syntax] = @[]
    validatePattern(param.items[0], names)
    for name in names:
      declare(ctx, name, bkImmutable)
  elif param.kind == sxVector:
    raiseCompilerError(param.span, "a destructured parameter requires a type annotation, e.g. ([a b] Point)")
  else:
    raiseCompilerError(param.span, "do parameter must be a symbol or (name type)")

proc lowerLambda(ctx: var LowerContext; sx: Syntax) =
  if sx.items.len < 3:
    raiseCompilerError(sx.span, "do expects parameters and body")
  let params = sx.items[1]
  if params.kind != sxList:
    raiseCompilerError(params.span, "do parameters must be a list")
  let bodyStart = lambdaBodyStart(sx)
  if bodyStart > sx.items.high:
    raiseCompilerError(sx.span, "do expects parameters and body")
  ctx.pushScope()
  let savedNamedBlocks = ctx.namedBlocks
  ctx.namedBlocks = @[]
  # A `do` with an explicit `(: type)` return clause gets Nim's implicit
  # mutable `result`, same as proc/method/func/converter (see #36); declared
  # before params so a param named `result` raises the usual duplicate-binding
  # error rather than silently shadowing it.
  if bodyStart == 3:
    declare(ctx, newSymbol("result", sx.items[2].span), bkMutable)
  for param in params.items:
    lowerParam(ctx, param)
  lowerBody(ctx, sx.items.toOpenArray(bodyStart, sx.items.high), sx)
  ctx.namedBlocks = savedNamedBlocks
  ctx.popScope()

proc validateExportedDecl(name: Syntax; what: string; allowOperator = false): string =
  ## Validates a declaration name that may optionally carry a trailing `*`
  ## export marker. Returns the base name with the marker stripped.
  ## Raises a CompilerError if the marker is malformed or the symbol is
  ## hygienic (hygienic symbols have no stable public name). See
  ## `splitExportMarker` (syntax.nim) for the marker/operator/escape rules.
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, what & " must be a symbol")
  let split = splitExportMarker(name.sym, name.escaped, allowOperator)
  if split.err.len > 0:
    raiseCompilerError(name.span, split.err)
  if split.exported and name.hygieneId != 0:
    raiseCompilerError(name.span, "exported name cannot be a hygienic symbol")
  result = split.base

proc validateGenericParams(sx: Syntax) =
  ## Validates a generic-params vector `[T U …]`.  Each entry must be a plain
  ## non-empty symbol with no export marker and no duplicates.
  if sx.items.len == 0:
    raiseCompilerError(sx.span, "generic parameter list must not be empty")
  var seen = initTable[string, bool]()
  for entry in sx.items:
    if entry.kind != sxSymbol or entry.sym.len == 0:
      raiseCompilerError(entry.span, "generic parameter must be a symbol")
    if entry.sym.contains("*"):
      raiseCompilerError(entry.span, "generic parameter cannot use export markers")
    if seen.hasKey(entry.sym):
      raiseCompilerError(entry.span, "duplicate generic parameter: " & entry.sym)
    seen[entry.sym] = true

proc lowerRoutine(ctx: var LowerContext; sx: Syntax; formName: string;
                  requireReturnType: bool) =
  ## Shared validation for proc/template/iterator/func/converter/method
  ## definition forms.  `requireReturnType` causes an error when no `(: type)`
  ## annotation is present — used for iterator and converter, which need an
  ## explicit element / target type.
  if sx.items.len < 4:
    raiseCompilerError(sx.span, formName & " expects name, parameters, and body")
  let name = sx.items[1]
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, formName & " name must be a symbol")
  if not name.sym.isValidRoutineName:
    raiseCompilerError(name.span, formName & " name must be a plain identifier or an operator (e.g. |+|), not a mix of both: " & name.sym)
  # Validate the export marker early so errors point at the name, not the body.
  let baseName = name.validateExportedDecl(formName & " name", allowOperator = true)
  # Optional generic-params vector immediately after the name.
  let genIdx = procGenericIdx(sx)
  if genIdx >= 0:
    if formName == "method":
      raiseCompilerError(sx.items[genIdx].span, "method cannot be generic; Nim does not support generic methods")
    validateGenericParams(sx.items[genIdx])
  # Optional pragma clause after generic params (or directly after name).
  let paramsIdx = procParamsIdx(sx)
  let pragmaIdx = paramsIdx - 1
  if pragmaIdx >= 2 and sx.items[pragmaIdx].isPragmaClause():
    if paramsIdx > sx.items.high:
      raiseCompilerError(sx.span, formName & " expects name, parameters, and body")
    validatePragma(sx.items[pragmaIdx])
  let params = sx.items[paramsIdx]
  if params.kind != sxList:
    raiseCompilerError(params.span, formName & " parameters must be a list")
  if formName == "converter" and params.items.len != 1:
    raiseCompilerError(params.span, "converter expects exactly one parameter")
  let bodyStart = procBodyStart(sx)
  if requireReturnType and bodyStart == paramsIdx + 1:
    raiseCompilerError(sx.span, formName & " requires an explicit return type (: type)")
  if bodyStart > sx.items.high:
    raiseCompilerError(sx.span, formName & " expects body expression")
  ctx.pushScope()
  # `break lbl` cannot cross a routine boundary, so a named block from an
  # enclosing routine is never a valid break-from target inside this one —
  # save and clear, then restore on the way out (mirrors how bodyDepth would
  # be scoped, not the pushScope/popScope stack, since loops inside this
  # routine must keep seeing blocks named *within* this routine).
  let savedNamedBlocks = ctx.namedBlocks
  ctx.namedBlocks = @[]
  # `proc`/`func`/`method`/`converter` forms with an explicit return type get
  # Nim's implicit mutable `result` variable; declared before params so a
  # param named `result` raises the same "duplicate binding" error Nim itself
  # would.
  if (formName == "proc" or formName == "method" or formName == "func" or
      formName == "converter") and bodyStart == paramsIdx + 2:
    declare(ctx, newSymbol("result", sx.items[paramsIdx + 1].span), bkMutable)
  for param in params.items:
    lowerParam(ctx, param)
  lowerBody(ctx, sx.items.toOpenArray(bodyStart, sx.items.high), sx)
  ctx.namedBlocks = savedNamedBlocks
  ctx.popScope()
  # Routine names resolve via Nim's own name resolution; we register under the
  # base name (stripped of any `*`) so local set!/lookup always finds it.
  # Overloaded names (same name, different parameters) are allowed; silently
  # skip re-registration rather than raising "duplicate binding".
  ctx.declareRoutineName(newSymbol(baseName, name.span))

proc lowerProc(ctx: var LowerContext; sx: Syntax) =
  lowerRoutine(ctx, sx, "proc", requireReturnType = false)

proc lowerTemplate(ctx: var LowerContext; sx: Syntax) =
  lowerRoutine(ctx, sx, "template", requireReturnType = false)

proc lowerIterator(ctx: var LowerContext; sx: Syntax) =
  lowerRoutine(ctx, sx, "iterator", requireReturnType = true)

proc lowerMethod(ctx: var LowerContext; sx: Syntax) =
  lowerRoutine(ctx, sx, "method", requireReturnType = false)

proc lowerFunc(ctx: var LowerContext; sx: Syntax) =
  lowerRoutine(ctx, sx, "func", requireReturnType = false)

proc lowerConverter(ctx: var LowerContext; sx: Syntax) =
  ## Nim requires a converter to declare exactly one parameter and an
  ## explicit return (target) type; both are enforced in lowerRoutine so the
  ## error surfaces as an NFL diagnostic rather than a raw Nim compile error.
  lowerRoutine(ctx, sx, "converter", requireReturnType = true)

proc lowerYield(ctx: var LowerContext; sx: Syntax) =
  ## Validates a `(yield expr)` form.  NFL does not enforce that yield only
  ## appears inside an iterator body — Nim's semantic pass handles that.
  if sx.items.len != 2:
    raiseCompilerError(sx.span, "yield expects exactly one expression")
  lowerExpr(ctx, sx.items[1])

proc lowerVarDecl(ctx: var LowerContext; sx: Syntax) =
  let formName = sx.items[0].sym
  let nargs = sx.items.len - 1
  if nargs < 1 or nargs > 3:
    raiseCompilerError(sx.span, formName & " expects 1 to 3 arguments, got " & $nargs)
  let nameTarget = sx.items[1]
  var baseName: string
  var nameSpan: Span
  var hasType = false
  # Accept `name` (plain symbol) or `(name type)` (typed form).
  if nameTarget.kind == sxSymbol:
    baseName = nameTarget.validateExportedDecl(formName & " name")
    nameSpan = nameTarget.span
  elif nameTarget.kind == sxList and nameTarget.items.len == 2 and
       nameTarget.items[0].kind == sxSymbol and
       (nameTarget.items[1].kind == sxSymbol or nameTarget.items[1].kind == sxVector):
    baseName = nameTarget.items[0].validateExportedDecl(formName & " name")
    nameSpan = nameTarget.items[0].span
    validateTypeReference(nameTarget.items[1], formName & " type")
    hasType = true
  else:
    raiseCompilerError(nameTarget.span, formName & " name must be a symbol or (name type)")
  # Parse the optional pragma clause and optional value expression.
  var pragmaIdx = -1
  var valueIdx = -1
  var nextIdx = 2
  if nextIdx <= nargs and sx.items[nextIdx].isPragmaClause():
    pragmaIdx = nextIdx
    validatePragma(sx.items[pragmaIdx])
    nextIdx += 1
  if nextIdx <= nargs:
    valueIdx = nextIdx
    nextIdx += 1
  if nextIdx <= nargs:
    raiseCompilerError(sx.items[nextIdx].span, "unexpected extra argument in " & formName)
  # A value is required unless there is an explicit type annotation.
  if valueIdx < 0 and not hasType:
    raiseCompilerError(sx.span, formName & " without a type annotation requires a value")
  if valueIdx >= 0:
    lowerExpr(ctx, sx.items[valueIdx])
  declare(ctx, newSymbol(baseName, nameSpan), bkMutable)

proc lowerConst(ctx: var LowerContext; sx: Syntax) =
  let formName = sx.items[0].sym
  let nargs = sx.items.len - 1
  if nargs < 2 or nargs > 3:
    raiseCompilerError(sx.span, formName & " expects 2 arguments, got " & $nargs)
  let nameTarget = sx.items[1]
  var baseName: string
  var nameSpan: Span
  if nameTarget.kind == sxSymbol:
    baseName = nameTarget.validateExportedDecl(formName & " name")
    nameSpan = nameTarget.span
  elif nameTarget.kind == sxList and nameTarget.items.len == 2 and
       nameTarget.items[0].kind == sxSymbol and
       (nameTarget.items[1].kind == sxSymbol or nameTarget.items[1].kind == sxVector):
    baseName = nameTarget.items[0].validateExportedDecl(formName & " name")
    nameSpan = nameTarget.items[0].span
    validateTypeReference(nameTarget.items[1], formName & " type")
  else:
    raiseCompilerError(nameTarget.span, formName & " name must be a symbol or (name type)")
  # Optional pragma clause immediately after the name.
  var valueIdx = 2
  if nargs == 3:
    if not sx.items[2].isPragmaClause():
      raiseCompilerError(sx.items[2].span, "expected pragma clause between " & formName & " name and value")
    validatePragma(sx.items[2])
    valueIdx = 3
  lowerExpr(ctx, sx.items[valueIdx])
  declare(ctx, newSymbol(baseName, nameSpan), bkImmutable)

proc isNflModulePath(sym: string): bool =
  sym.endsWith(".nfl")

proc validateModulePath(module: Syntax; formName: string) =
  if module.kind != sxSymbol:
    raiseCompilerError(module.span, formName & " expects a module symbol")
  if module.sym.len == 0 or module.sym[0] == '/' or module.sym[^1] == '/' or module.sym.contains("//"):
    raiseCompilerError(module.span, "invalid import path")

proc lowerImport(sx: Syntax) =
  expectArity(sx, "import", sx.items.len - 1, 1)
  validateModulePath(sx.items[1], "import")
  if sx.items[1].sym.isNflModulePath():
    raiseCompilerError(sx.span, "nfl file imports are only allowed at the top level of a module")

proc validateFieldName(name: Syntax; what: string): string =
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, what & " must be a symbol")
  if name.sym.contains("*"):
    raiseCompilerError(name.span, what & " cannot use export markers")
  if name.sym.len == 0 or name.sym[0] == '.' or name.sym[^1] == '.' or name.sym.contains(".."):
    raiseCompilerError(name.span, "invalid " & what & ": " & name.sym)
  name.sym

proc lowerFrom(sx: Syntax) =
  if sx.items.len < 4:
    raiseCompilerError(sx.span, "from expects (from module import sym...)")
  validateModulePath(sx.items[1], "from")
  if sx.items[1].sym.isNflModulePath():
    raiseCompilerError(sx.items[1].span, "from does not support importing nfl files")
  if not sx.items[2].isSymbol("import"):
    raiseCompilerError(sx.items[2].span, "from expects the literal symbol 'import' after the module")
  let rest = sx.items[3 .. ^1]
  if rest.len == 1 and rest[0].kind == sxList and rest[0].items.len > 0 and rest[0].items[0].isSymbol("except"):
    let excepted = rest[0].items[1 .. ^1]
    if excepted.len == 0:
      raiseCompilerError(rest[0].span, "from ... import (except ...) expects at least one symbol")
    for sym in excepted:
      discard validateFieldName(sym, "from import except symbol")
  else:
    for sym in rest:
      discard validateFieldName(sym, "from import symbol")

proc lowerNamedArg(ctx: var LowerContext; sx: Syntax; seen: var Table[string, bool]) =
  if sx.items.len != 3:
    raiseCompilerError(sx.span, "named argument must be (: name value)")
  let key = validateFieldName(sx.items[1], "named argument name")
  if seen.hasKey(key):
    raiseCompilerError(sx.items[1].span, "duplicate named argument: " & key)
  seen[key] = true
  lowerExpr(ctx, sx.items[2])

proc lowerDot(ctx: var LowerContext; sx: Syntax) =
  if sx.items.len < 3:
    raiseCompilerError(sx.span, ". expects object and field or method name")
  if sx.items[2].kind != sxSymbol:
    raiseCompilerError(sx.items[2].span, ". field or method name must be a symbol")
  lowerExpr(ctx, sx.items[1])
  var seenNamedArgs = initTable[string, bool]()
  for i in 3 ..< sx.items.len:
    if sx.items[i].isNamedArg():
      lowerNamedArg(ctx, sx.items[i], seenNamedArgs)
    else:
      lowerExpr(ctx, sx.items[i])

proc lowerAt(ctx: var LowerContext; sx: Syntax) =
  expectArity(sx, "at", sx.items.len - 1, 2)
  for i in 1 ..< sx.items.len:
    lowerExpr(ctx, sx.items[i])

proc lowerSlice(ctx: var LowerContext; sx: Syntax) =
  expectArity(sx, "slice", sx.items.len - 1, 3)
  for i in 1 ..< sx.items.len:
    lowerExpr(ctx, sx.items[i])

proc lowerNew(ctx: var LowerContext; sx: Syntax) =
  if sx.items.len < 2:
    raiseCompilerError(sx.span, "new expects a type and field initializers")
  validateTypeReference(sx.items[1], "new type")
  var seen = initTable[string, bool]()
  for field in sx.items.toOpenArray(2, sx.items.high):
    if field.kind != sxList or field.items.len != 2:
      raiseCompilerError(field.span, "new field initializer must be (name value)")
    let key = validateFieldName(field.items[0], "new field name")
    if seen.hasKey(key):
      raiseCompilerError(field.items[0].span, "duplicate new field: " & key)
    seen[key] = true
    lowerExpr(ctx, field.items[1])

proc lowerTupleNew(ctx: var LowerContext; sx: Syntax) =
  ## Validates `(tuple-new Type (field value) …)` — named tuple construction
  ## (#35). Mirrors `lowerNew`, but requires at least one field: an empty
  ## tuple constructor has no use case here and Nim's `()` reads as `void`,
  ## not an empty tuple.
  if sx.items.len < 3:
    raiseCompilerError(sx.span, "tuple-new expects a type and at least one field initializer")
  validateTypeReference(sx.items[1], "tuple-new type")
  var seen = initTable[string, bool]()
  for field in sx.items.toOpenArray(2, sx.items.high):
    if field.kind != sxList or field.items.len != 2:
      raiseCompilerError(field.span, "tuple-new field initializer must be (name value)")
    let key = validateFieldName(field.items[0], "tuple-new field name")
    if seen.hasKey(key):
      raiseCompilerError(field.items[0].span, "duplicate tuple-new field: " & key)
    seen[key] = true
    lowerExpr(ctx, field.items[1])

proc lowerQuote(sx: Syntax) =
  expectArity(sx, "quote", sx.items.len - 1, 1)

proc lowerFor(ctx: var LowerContext; sx: Syntax) =
  ## Validates `(for [:name] CLAUSE body…)` where CLAUSE is `(BINDING
  ## ITERABLE)`. BINDING is a symbol (one var) or a list of symbols (multiple
  ## vars, e.g. for pair/tuple iterators). Loop variables are declared
  ## immutable so that `set!` inside the body raises a lowering error. An
  ## optional leading `:name` labels the loop as a target for `(break :name)`
  ## / `(continue :name)` from a nested loop.
  var idx = 1
  var labelKey = ""
  var labelled = false
  if sx.items.len > 1 and sx.items[1].isBlockLabel():
    labelled = true
    labelKey = sx.items[1].symbolKey()
    idx = 2
  if sx.items.len < idx + 2:
    raiseCompilerError(sx.span, "for expects a binding clause and body")
  let clause = sx.items[idx]
  if clause.kind != sxList or clause.items.len != 2:
    raiseCompilerError(clause.span, "for clause must be a (binding iterable) pair")
  let binding = clause.items[0]
  let iterable = clause.items[1]
  var vars: seq[Syntax]
  if binding.kind == sxSymbol:
    vars = @[binding]
  elif binding.kind == sxList:
    if binding.items.len == 0:
      raiseCompilerError(binding.span, "for binding list must not be empty")
    for v in binding.items:
      if v.kind != sxSymbol:
        raiseCompilerError(v.span, "for loop variable must be a symbol")
    vars = binding.items
  else:
    raiseCompilerError(binding.span, "for loop variable must be a symbol or list of symbols")
  # Lower the iterable in the outer scope before introducing loop vars.
  lowerExpr(ctx, iterable)
  ctx.pushScope()
  for v in vars:
    declare(ctx, v, bkImmutable)
  if labelled:
    ctx.namedBlocks.add LabelFrame(key: labelKey, isLoop: true)
  lowerBody(ctx, sx.items.toOpenArray(idx + 1, sx.items.high), sx)
  if labelled:
    discard ctx.namedBlocks.pop()
  ctx.popScope()

proc lowerRangeForm(ctx: var LowerContext; sx: Syntax) =
  ## Validates and lowers a `(.. lo hi)` range form used as a case of-value.
  if not sx.isRangeForm:
    raiseCompilerError(sx.span, "case range branch expects (.. lo hi)")
  lowerExpr(ctx, sx.items[1])
  lowerExpr(ctx, sx.items[2])

proc lowerCaseOfValue(ctx: var LowerContext; sx: Syntax) =
  ## Lowers the value form of a single `of` branch: a range `(.. lo hi)`, a
  ## multi-value/mixed list `(1 (.. 3 5) 7)`, or a single (possibly compound)
  ## expression — see `isCaseValueList` for the disambiguation rule.
  if sx.isRangeShaped:
    lowerRangeForm(ctx, sx)
  elif sx.isCaseValueList:
    for item in sx.items:
      if item.isRangeForm:
        lowerRangeForm(ctx, item)
      else:
        lowerExpr(ctx, item)
  else:
    lowerExpr(ctx, sx)

proc lowerCase(ctx: var LowerContext; sx: Syntax) =
  ## Validates `(case VALUE (of LIT body…)… [(else body…)])`.
  ## `of` and `else` are recognized positionally inside case only.
  if sx.items.len < 3:
    raiseCompilerError(sx.span, "case expects a value and at least one branch")
  lowerExpr(ctx, sx.items[1])
  var seenElse = false
  for i in 2 ..< sx.items.len:
    let branch = sx.items[i]
    if branch.kind != sxList or branch.items.len == 0:
      raiseCompilerError(branch.span, "case branch must be a list headed by of or else")
    if seenElse:
      raiseCompilerError(branch.span, "case else branch must be last")
    if branch.items[0].isSymbol("of"):
      if branch.items.len < 3:
        raiseCompilerError(branch.span, "case of branch expects a value and body")
      lowerCaseOfValue(ctx, branch.items[1])
      lowerBody(ctx, branch.items.toOpenArray(2, branch.items.high), branch)
    elif branch.items[0].isSymbol("else"):
      if branch.items.len < 2:
        raiseCompilerError(branch.span, "case else branch expects a body")
      seenElse = true
      lowerBody(ctx, branch.items.toOpenArray(1, branch.items.high), branch)
    else:
      raiseCompilerError(branch.items[0].span, "case branch must be headed by of or else")

proc lowerMatchPattern(ctx: var LowerContext; pattern: Syntax) =
  ## Validates a single `match` pattern and declares any names it binds.
  ## Mirrors backend.nim's `emitMatchTest`/`emitMatchBindings` (see #43 for
  ## the general lower.nim/backend.nim shape-duplication this follows).
  ##
  ## Pattern kinds (#13): a literal (nil/bool/int/float/string) matches by
  ## equality and binds nothing; `_` matches anything and binds nothing; any
  ## other bare symbol matches anything and binds that name; `'sym` (the
  ## reader's quote sugar) matches by equality against the symbol `sym` —
  ## e.g. an enum label or a module-level const; a vector pattern
  ## destructures like #12's `let`/`var` patterns, reusing `validatePattern`.
  ## Object patterns (#47) are rejected here — there is no arity/field-
  ## presence test `emitMatchTest` can emit for a Nim object, unlike the
  ## `nflMatchArity` runtime check available for positional patterns.
  case pattern.kind
  of sxNil, sxBool, sxInt, sxFloat, sxString:
    discard
  of sxSymbol:
    if pattern.sym != "_":
      declare(ctx, pattern, bkImmutable)
  of sxVector:
    var names: seq[Syntax] = @[]
    validatePattern(pattern, names, rejectObjectIn = "match")
    for name in names:
      declare(ctx, name, bkImmutable)
  of sxList:
    if pattern.items.len == 2 and pattern.items[0].isSymbol("quote") and pattern.items[1].kind == sxSymbol:
      discard
    else:
      raiseCompilerError(pattern.span, "unsupported match pattern")

proc lowerMatch(ctx: var LowerContext; sx: Syntax) =
  ## Validates `(match VALUE (PATTERN body…)… )`, where a clause may carry a
  ## guard: `(PATTERN :when guard body…)`. `:when` is recognized
  ## positionally right after the pattern, inside `match` clauses only —
  ## the same technique `lowerCase` uses for `of`/`else`.
  if sx.items.len < 3:
    raiseCompilerError(sx.span, "match expects a value and at least one clause")
  lowerExpr(ctx, sx.items[1])
  for i in 2 ..< sx.items.len:
    let clause = sx.items[i]
    if clause.kind != sxList or clause.items.len < 2:
      raiseCompilerError(clause.span, "match clause must be (pattern body…) or (pattern :when guard body…)")
    ctx.pushScope()
    lowerMatchPattern(ctx, clause.items[0])
    var bodyStart = 1
    if clause.items[1].isSymbol(":when"):
      if clause.items.len < 3:
        raiseCompilerError(clause.span, "match :when expects a guard expression")
      lowerExpr(ctx, clause.items[2])
      bodyStart = 3
    if bodyStart > clause.items.high:
      raiseCompilerError(clause.span, "match clause expects a body")
    lowerBody(ctx, clause.items.toOpenArray(bodyStart, clause.items.high), clause)
    ctx.popScope()

proc lowerRaise(ctx: var LowerContext; sx: Syntax) =
  ## Validates `(raise)` (re-raise) or `(raise expr)`.
  let nargs = sx.items.len - 1
  if nargs > 1:
    raiseCompilerError(sx.span, "raise expects 0 or 1 arguments, got " & $nargs)
  if nargs == 1:
    lowerExpr(ctx, sx.items[1])

proc lowerReturn(ctx: var LowerContext; sx: Syntax) =
  ## Validates `(return)` (void return) or `(return expr)`.
  let nargs = sx.items.len - 1
  if nargs > 1:
    raiseCompilerError(sx.span, "return expects 0 or 1 arguments, got " & $nargs)
  if nargs == 1:
    lowerExpr(ctx, sx.items[1])

proc lowerDiscard(ctx: var LowerContext; sx: Syntax) =
  ## Validates `(discard)` or `(discard expr)`.
  let nargs = sx.items.len - 1
  if nargs > 1:
    raiseCompilerError(sx.span, "discard expects 0 or 1 arguments, got " & $nargs)
  if nargs == 1:
    lowerExpr(ctx, sx.items[1])

proc lowerDefer(ctx: var LowerContext; sx: Syntax) =
  ## Validates `(defer body…)`. Only allowed inside a proc/block/etc. body —
  ## Nim rejects `defer` at module top level, so NFL diagnoses it up front
  ## instead of surfacing a raw Nim compiler error.
  if ctx.bodyDepth == 0:
    raiseCompilerError(sx.span, "defer is only allowed inside a proc or block body")
  lowerBody(ctx, sx.items.toOpenArray(1, sx.items.high), sx)

proc lowerWhile(ctx: var LowerContext; sx: Syntax) =
  ## Validates `(while [:name] condition body…)`. An optional leading `:name`
  ## labels the loop as a target for `(break :name)` / `(continue :name)`
  ## from a nested loop.
  var idx = 1
  var labelKey = ""
  var labelled = false
  if sx.items.len > 1 and sx.items[1].isBlockLabel():
    labelled = true
    labelKey = sx.items[1].symbolKey()
    idx = 2
  if sx.items.len < idx + 2:
    raiseCompilerError(sx.span, "while expects a condition and body")
  lowerExpr(ctx, sx.items[idx])
  if labelled:
    ctx.namedBlocks.add LabelFrame(key: labelKey, isLoop: true)
  lowerBody(ctx, sx.items.toOpenArray(idx + 1, sx.items.high), sx)
  if labelled:
    discard ctx.namedBlocks.pop()

proc lowerLoopControl(ctx: var LowerContext; sx: Syntax; formName: string) =
  ## Validates `(break)` / `(break :name)` and `(continue)` / `(continue
  ## :name)` — 0 or 1 arguments; a 1-argument form must be a `:name` label
  ## resolving to an enclosing labelled loop (not a named `block`, which is
  ## `break-from`'s domain).
  let nargs = sx.items.len - 1
  if nargs notin [0, 1]:
    raiseCompilerError(sx.span, formName & " expects 0 or 1 arguments, got " & $nargs)
  if nargs == 0:
    return
  let target = sx.items[1]
  if not target.isBlockLabel():
    raiseCompilerError(target.span, formName & " target must be a :name label")
  let frameIdx = ctx.findLabelFrame(target.symbolKey())
  if frameIdx < 0:
    raiseCompilerError(target.span,
      formName & " target is not an enclosing labelled loop: " & target.sym)
  if not ctx.namedBlocks[frameIdx].isLoop:
    if formName == "break":
      raiseCompilerError(target.span,
        "break target is a named block, not a labelled loop — use " &
        "(break-from " & target.sym & ") instead")
    else:
      raiseCompilerError(target.span,
        "continue target is a named block, not a labelled loop — a block " &
        "cannot be continued")

proc lowerBreak(ctx: var LowerContext; sx: Syntax) =
  lowerLoopControl(ctx, sx, "break")

proc lowerContinue(ctx: var LowerContext; sx: Syntax) =
  lowerLoopControl(ctx, sx, "continue")

proc isExceptClause(sx: Syntax): bool =
  sx.kind == sxList and sx.items.len > 0 and sx.items[0].isSymbol("except")

proc isFinallyClause(sx: Syntax): bool =
  sx.kind == sxList and sx.items.len > 0 and sx.items[0].isSymbol("finally")

proc isExceptBinding(sx: Syntax): bool =
  ## True if sx looks like a `(name TypeRef)` exception binding.
  ## Disambiguation: items[0] is the bound name symbol; items[1] is a type
  ## symbol or generic vector.  A bare catch-all body form starting with a
  ## call would need items[1] to be a list where items[1][1] is NOT a
  ## symbol/vector — that case falls through to the bare catch-all branch.
  sx.kind == sxList and sx.items.len == 2 and
  sx.items[0].kind == sxSymbol and
  (sx.items[1].kind == sxSymbol or sx.items[1].kind == sxVector)

proc lowerTry(ctx: var LowerContext; sx: Syntax) =
  ## Validates `(try body… (except …)… [(finally body…)])`.
  ## Body is the leading run of forms before the first except/finally clause.
  ## A bare `(except body…)` catch-all must be the last except branch.
  ## At most one `(finally body…)` clause is allowed and must be last.
  if sx.items.len < 2:
    raiseCompilerError(sx.span, "try expects a body")
  # Locate the boundary between body forms and except/finally clauses.
  var bodyEnd = 1
  while bodyEnd <= sx.items.high and
      not sx.items[bodyEnd].isExceptClause() and
      not sx.items[bodyEnd].isFinallyClause():
    inc bodyEnd
  if bodyEnd == 1:
    raiseCompilerError(sx.span, "try body must not be empty")
  lowerBody(ctx, sx.items.toOpenArray(1, bodyEnd - 1), sx)
  var i = bodyEnd
  # Except branches.
  var seenBare = false
  while i <= sx.items.high and sx.items[i].isExceptClause():
    let branch = sx.items[i]
    if seenBare:
      raiseCompilerError(branch.span, "bare except must be the last except branch")
    if branch.items.len < 2:
      raiseCompilerError(branch.span, "except branch expects a type or body")
    if branch.items[1].kind == sxSymbol:
      # typed: (except Type body…)
      validateTypeReference(branch.items[1], "except type")
      if branch.items.len < 3:
        raiseCompilerError(branch.span, "except branch expects a body after the type")
      lowerBody(ctx, branch.items.toOpenArray(2, branch.items.high), branch)
    elif branch.items[1].isExceptBinding():
      # named: (except (e Type) body…)
      validateTypeReference(branch.items[1].items[1], "except type")
      if branch.items.len < 3:
        raiseCompilerError(branch.span, "except branch expects a body after the binding")
      ctx.pushScope()
      declare(ctx, branch.items[1].items[0], bkImmutable)
      lowerBody(ctx, branch.items.toOpenArray(2, branch.items.high), branch)
      ctx.popScope()
    else:
      # bare catch-all: (except body…) — body starts at items[1]
      seenBare = true
      lowerBody(ctx, branch.items.toOpenArray(1, branch.items.high), branch)
    inc i
  # Optional finally clause.
  if i <= sx.items.high:
    let fin = sx.items[i]
    if not fin.isFinallyClause():
      raiseCompilerError(fin.span, "expected except or finally clause in try")
    if fin.items.len < 2:
      raiseCompilerError(fin.span, "finally expects a body")
    lowerBody(ctx, fin.items.toOpenArray(1, fin.items.high), fin)
    inc i
  if i <= sx.items.high:
    raiseCompilerError(sx.items[i].span, "unexpected form after try clauses")

proc validateTypeReference(sx: Syntax; what: string) =
  ## Accepts a plain type symbol or a generic type application `[Head arg …]`.
  if sx.kind == sxVector:
    if sx.items.len < 2:
      raiseCompilerError(sx.span, what & ": generic type application must have a head and at least one argument")
    validateTypeReference(sx.items[0], what & " head")
    for i in 1 ..< sx.items.len:
      validateTypeReference(sx.items[i], what & " argument")
    return
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, what & " must be a type symbol")
  if sx.sym.contains("*"):
    raiseCompilerError(sx.span, "type references cannot use export markers")
  if sx.sym.len == 0 or sx.sym[0] == '.' or sx.sym[^1] == '.' or sx.sym.contains(".."):
    raiseCompilerError(sx.span, "invalid type symbol: " & sx.sym)

proc lowerDistinctType(sx: Syntax) =
  ## Validates `(distinct BaseType)` — a newtype wrapper around a base type.
  if sx.items.len != 2:
    raiseCompilerError(sx.span, "distinct expects a base type, got " & $(sx.items.len - 1) & " arguments")
  validateTypeReference(sx.items[1], "distinct base type")

proc lowerTupleType(sx: Syntax) =
  ## Validates `(tuple (name1 type1) …)` — structural record type.
  if sx.items.len < 2:
    raiseCompilerError(sx.span, "tuple type expects at least one field")
  var seen = initTable[string, bool]()
  for field in sx.items.toOpenArray(1, sx.items.high):
    if field.kind != sxList or field.items.len != 2:
      raiseCompilerError(field.span, "tuple field must be (name type)")
    let name = field.items[0]
    if name.kind != sxSymbol:
      raiseCompilerError(name.span, "tuple field name must be a symbol")
    let key = name.sym
    if seen.hasKey(key):
      raiseCompilerError(name.span, "duplicate tuple field: " & key)
    seen[key] = true
    validateTypeReference(field.items[1], "tuple field type")

proc lowerObjectType(sx: Syntax) =
  ## Validates `(object [of Base] (field type) …)`.
  ## The optional `(of Base)` clause immediately after `object` declares a base
  ## type for inheritance; all remaining items are field definitions.
  if sx.items.len == 1:
    raiseCompilerError(sx.span, "object type expects fields or an inheritance clause")
  # Check for optional `(of Base)` inheritance clause at items[1].
  var fieldStart = 1
  if sx.items[1].kind == sxList and sx.items[1].items.len > 0 and
     sx.items[1].items[0].isSymbol("of"):
    # Validate arity: must be exactly `(of Base)`.
    if sx.items[1].items.len != 2:
      raiseCompilerError(sx.items[1].span,
        "object inheritance clause must be (of Base), got " & $(sx.items[1].items.len - 1) & " argument(s)")
    let baseType = sx.items[1].items[1]
    validateTypeReference(baseType, "object base type")
    fieldStart = 2
    if sx.items.len == 2:
      # Inheritance-only object with no fields is valid (e.g. pure vtable base).
      return
  var seen = initTable[string, bool]()
  for field in sx.items.toOpenArray(fieldStart, sx.items.high):
    # Field form: `(name Type)` or `(name {.p.} Type)` — 2 or 3 items.
    if field.kind != sxList or (field.items.len != 2 and field.items.len != 3):
      raiseCompilerError(field.span, "object field must be (name Type)")
    let name = field.items[0]
    if name.kind != sxSymbol:
      raiseCompilerError(name.span, "object field name must be a symbol")
    let key = name.validateExportedDecl("object field name")
    if seen.hasKey(key):
      raiseCompilerError(name.span, "duplicate object field: " & key)
    seen[key] = true
    var typeIdx = 1
    if field.items.len == 3:
      if not field.items[1].isPragmaClause():
        raiseCompilerError(field.items[1].span, "expected pragma clause between field name and type")
      validatePragma(field.items[1])
      typeIdx = 2
    validateTypeReference(field.items[typeIdx], "object field type")

proc lowerRefType(sx: Syntax) =
  ## Validates `(ref X)` where X is a type symbol or an `(object …)` / `(tuple …)` body.
  if sx.items.len != 2:
    raiseCompilerError(sx.span, "ref expects a base type, got " & $(sx.items.len - 1) & " arguments")
  let inner = sx.items[1]
  if inner.kind == sxSymbol or inner.kind == sxVector:
    validateTypeReference(inner, "ref base type")
  elif inner.kind == sxList and inner.items.len > 0:
    if inner.items[0].isSymbol("object"):
      lowerObjectType(inner)
    elif inner.items[0].isSymbol("tuple"):
      lowerTupleType(inner)
    else:
      raiseCompilerError(inner.span, "ref base must be a type symbol or (object …) or (tuple …) body")
  else:
    raiseCompilerError(inner.span, "ref base must be a type symbol or (object …) body")

proc checkEnumValueName(name: Syntax; seen: var Table[string, bool]) =
  ## Shared validation for an enum label name, whether it comes from a bare
  ## symbol entry or the name slot of a `(Name value)` pair. Routes the
  ## export-marker check through `splitExportMarker`, the same helper every
  ## other declaration site uses (see `validateExportedDecl` above), so
  ## escaped names (`|...|`, #46) are handled consistently rather than via an
  ## ad hoc `endsWith("*")` check.
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, "enum value name must be a symbol")
  let split = splitExportMarker(name.sym, name.escaped, false)
  if split.err.len > 0:
    raiseCompilerError(name.span, split.err)
  if split.exported:
    raiseCompilerError(name.span, "enum values cannot use export markers; export the enum type instead")
  let key = split.base
  if seen.hasKey(key):
    raiseCompilerError(name.span, "duplicate enum value: " & key)
  seen[key] = true

proc lowerEnumType(ctx: var LowerContext; sx: Syntax) =
  if sx.items.len == 1:
    raiseCompilerError(sx.span, "enum type expects values")
  var seen = initTable[string, bool]()
  for value in sx.items.toOpenArray(1, sx.items.high):
    case value.kind
    of sxSymbol:
      checkEnumValueName(value, seen)
    of sxList:
      if value.items.len != 2:
        raiseCompilerError(value.span, "enum value pair must be (Name value), got " & $value.items.len & " item(s)")
      checkEnumValueName(value.items[0], seen)
      lowerExpr(ctx, value.items[1])
    else:
      raiseCompilerError(value.span, "enum value must be a symbol or (Name value) pair")

proc lowerTypeDecl(ctx: var LowerContext; sx: Syntax) =
  let nargs = sx.items.len - 1
  if nargs < 2:
    raiseCompilerError(sx.span, "type expects 2 arguments, got " & $nargs)
  let name = sx.items[1]
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, "type name must be a symbol")
  let declaredName = newSymbol(name.validateExportedDecl("type name"), name.span)
  # Optional generic-params vector `[T …]` immediately after the name.
  var idx = 2
  let genIdx = procGenericIdx(sx)
  if genIdx >= 0:
    validateGenericParams(sx.items[genIdx])
    idx = genIdx + 1
  # Optional pragma clause after generic params (or directly after name).
  if sx.items.len > idx and sx.items[idx].isPragmaClause():
    validatePragma(sx.items[idx])
    idx += 1
  if idx > sx.items.high:
    raiseCompilerError(sx.span, "type expects a body")
  let body = sx.items[idx]
  if body.kind == sxSymbol:
    validateTypeReference(body, "type alias target")
  elif body.kind == sxList and body.items.len > 0:
    if body.items[0].isSymbol("object"):
      lowerObjectType(body)
    elif body.items[0].isSymbol("enum"):
      if genIdx >= 0:
        raiseCompilerError(sx.items[genIdx].span, "enum type cannot be generic")
      lowerEnumType(ctx, body)
    elif body.items[0].isSymbol("tuple"):
      lowerTupleType(body)
    elif body.items[0].isSymbol("distinct"):
      lowerDistinctType(body)
    elif body.items[0].isSymbol("ref"):
      lowerRefType(body)
    else:
      raiseCompilerError(body.items[0].span, "unknown type declaration form: " & formName(body.items[0]))
  else:
    raiseCompilerError(body.span, "type body must be an alias target or type form")
  declare(ctx, declaredName, bkImmutable)

proc lowerCall(ctx: var LowerContext; sx: Syntax) =
  if sx.items.len == 0:
    raiseCompilerError(sx.span, "empty list is not callable")
  if sx.items[0].kind != sxSymbol:
    raiseCompilerError(sx.items[0].span, "call target must be a symbol")
  var seenNamedArgs = initTable[string, bool]()
  for i in 1 ..< sx.items.len:
    if sx.items[i].isNamedArg():
      lowerNamedArg(ctx, sx.items[i], seenNamedArgs)
    else:
      lowerExpr(ctx, sx.items[i])

proc lowerExpr(ctx: var LowerContext; sx: Syntax) =
  case sx.kind
  of sxNil, sxBool, sxInt, sxFloat, sxString, sxSymbol:
    discard
  of sxVector:
    for item in sx.items:
      lowerExpr(ctx, item)
  of sxList:
    if sx.items.len == 0:
      raiseCompilerError(sx.span, "empty list is not an expression")
    if sx.items[0].isSymbol("if"):
      lowerIf(ctx, sx)
    elif sx.items[0].isSymbol("block"):
      lowerBegin(ctx, sx)
    elif sx.items[0].isSymbol("prog1"):
      lowerProgN(ctx, sx, 1, "prog1")
    elif sx.items[0].isSymbol("prog2"):
      lowerProgN(ctx, sx, 2, "prog2")
    elif sx.items[0].isSymbol("let"):
      lowerLetLike(ctx, sx, false)
    elif sx.items[0].isSymbol("var"):
      if isDefvarForm(sx):
        raiseCompilerError(sx.span, "var is only allowed at statement/module scope")
      else:
        lowerLetLike(ctx, sx, true)
    elif sx.items[0].isSymbol("set!"):
      lowerSet(ctx, sx)
    elif sx.items[0].isSymbol("do"):
      lowerLambda(ctx, sx)
    elif sx.items[0].isSymbol("yield"):
      lowerYield(ctx, sx)
    elif sx.items[0].isSymbol("proc"):
      raiseCompilerError(sx.span, "proc is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("template"):
      raiseCompilerError(sx.span, "template is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("iterator"):
      raiseCompilerError(sx.span, "iterator is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("method"):
      raiseCompilerError(sx.span, "method is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("func"):
      raiseCompilerError(sx.span, "func is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("converter"):
      raiseCompilerError(sx.span, "converter is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("defer"):
      raiseCompilerError(sx.span, "defer is only allowed at statement scope")
    elif sx.items[0].isSymbol("type"):
      raiseCompilerError(sx.span, "type is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("."):
      lowerDot(ctx, sx)
    elif sx.items[0].isSymbol("at"):
      lowerAt(ctx, sx)
    elif sx.items[0].isSymbol("slice"):
      lowerSlice(ctx, sx)
    elif sx.items[0].isSymbol("new"):
      lowerNew(ctx, sx)
    elif sx.items[0].isSymbol("tuple-new"):
      lowerTupleNew(ctx, sx)
    elif sx.items[0].isSymbol(":"):
      raiseCompilerError(sx.span, "named argument marker is only allowed in call argument position")
    elif sx.items[0].isSymbol("const"):
      raiseCompilerError(sx.span, sx.items[0].sym & " is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("import"):
      raiseCompilerError(sx.span, "import is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("from"):
      raiseCompilerError(sx.span, "from is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("for"):
      lowerFor(ctx, sx)
    elif sx.items[0].isSymbol("while"):
      lowerWhile(ctx, sx)
    elif sx.items[0].isSymbol("case"):
      lowerCase(ctx, sx)
    elif sx.items[0].isSymbol("match"):
      lowerMatch(ctx, sx)
    elif sx.items[0].isSymbol("raise"):
      lowerRaise(ctx, sx)
    elif sx.items[0].isSymbol("return"):
      lowerReturn(ctx, sx)
    elif sx.items[0].isSymbol("break-from"):
      lowerBreakFrom(ctx, sx)
    elif sx.items[0].isSymbol("try"):
      lowerTry(ctx, sx)
    elif sx.items[0].isSymbol("quote"):
      lowerQuote(sx)
    elif sx.items[0].isSymbol("quasiquote"):
      raiseCompilerError(sx.span, "runtime quasiquote is not implemented yet")
    elif sx.items[0].isSymbol("unhygienic"):
      raiseCompilerError(sx.span, "unhygienic is only valid as a binding target inside a quasiquote template")
    elif sx.items[0].isSymbol("pragma"):
      raiseCompilerError(sx.span, "pragma is only allowed as a declaration annotation")
    else:
      lowerCall(ctx, sx)

proc lowerStmt(ctx: var LowerContext; sx: Syntax) =
  if sx.kind == sxList and sx.items.len > 0:
    if sx.items[0].isSymbol("var"):
      if isDefvarForm(sx):
        lowerVarDecl(ctx, sx)
        return
      if isVarSectionForm(sx):
        lowerVarSection(ctx, sx, mutable = true)
        return
      # Binding-list shape with a body: falls through to the local
      # mutable-binding block form via lowerExpr, unchanged.
    if sx.items[0].isSymbol("const"):
      if isVarSectionForm(sx):
        lowerVarSection(ctx, sx, mutable = false)
        return
      if not isDefvarForm(sx):
        raiseCompilerError(sx.span, "const does not support a local binding body")
      lowerConst(ctx, sx)
      return
    if sx.items[0].isSymbol("import"):
      lowerImport(sx)
      return
    if sx.items[0].isSymbol("from"):
      lowerFrom(sx)
      return
    if sx.items[0].isSymbol("proc"):
      lowerProc(ctx, sx)
      return
    if sx.items[0].isSymbol("template"):
      lowerTemplate(ctx, sx)
      return
    if sx.items[0].isSymbol("iterator"):
      lowerIterator(ctx, sx)
      return
    if sx.items[0].isSymbol("type"):
      lowerTypeDecl(ctx, sx)
      return
    if sx.items[0].isSymbol("method"):
      lowerMethod(ctx, sx)
      return
    if sx.items[0].isSymbol("func"):
      lowerFunc(ctx, sx)
      return
    if sx.items[0].isSymbol("converter"):
      lowerConverter(ctx, sx)
      return
    if sx.items[0].isSymbol("discard"):
      lowerDiscard(ctx, sx)
      return
    if sx.items[0].isSymbol("defer"):
      lowerDefer(ctx, sx)
      return
    if sx.items[0].isSymbol("break"):
      lowerBreak(ctx, sx)
      return
    if sx.items[0].isSymbol("continue"):
      lowerContinue(ctx, sx)
      return
  lowerExpr(ctx, sx)

proc lowerExpr*(sx: Syntax): Syntax =
  var ctx = LowerContext(scopes: @[initTable[string, BindingKind]()])
  lowerExpr(ctx, sx)
  sx

proc lowerModule*(forms: seq[Syntax]): seq[Syntax] =
  var ctx = LowerContext(scopes: @[initTable[string, BindingKind]()])
  for form in forms:
    lowerStmt(ctx, form)
  forms
