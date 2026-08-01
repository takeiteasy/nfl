## Shared slot-layout helpers for proc/template/iterator/method/converter/type
## forms, used identically by both the lowering pass (lower.nim) and the
## emission pass (backend.nim). Kept in one place so the two passes cannot
## silently disagree on where generic params, pragmas, and bodies sit in the
## form (see #43).

import ./diagnostics
import ./syntax

proc isPragmaClause*(sx: Syntax): bool =
  sx.kind == sxList and sx.items.len > 0 and sx.items[0].isSymbol("pragma")

proc objectFieldParts*(field: Syntax): tuple[ok: bool, pragma: Syntax, typeIdx, defaultIdx: int] =
  ## Resolves the shape of an object field spec — `(name Type)`,
  ## `(name {.pragma.} Type)`, `(name Type default)`, or
  ## `(name {.pragma.} Type default)` — so `lower.nim` and `backend.nim` agree
  ## on where the pragma, type, and default sit. `ok` is false for anything
  ## else (wrong arity, or a 4-element form whose slot 1 is not a pragma
  ## clause); `pragma` is nil and `defaultIdx` is -1 when absent.
  if field.kind != sxList:
    return (false, nil, 0, -1)
  case field.items.len
  of 2:
    (true, nil, 1, -1)
  of 3:
    if field.items[1].isPragmaClause():
      (true, field.items[1], 2, -1)
    else:
      (true, nil, 1, 2)
  of 4:
    if field.items[1].isPragmaClause():
      (true, field.items[1], 2, 3)
    else:
      (false, nil, 0, -1)
  else:
    (false, nil, 0, -1)

proc isDefvarForm*(sx: Syntax): bool =
  ## `var` is overloaded: `(var name value)` / `(var (name type) value)` is a
  ## module/statement-level declaration, while `(var ((name value) …) body…)`
  ## is the local mutable-binding form (like `let`, but mutable). The two are
  ## distinguished by shape: a local binding list is always a list of lists
  ## (each entry a `(name value)` pair or `(name {.pragma.} value)` triple),
  ## while a declaration's name slot is never further nested that way — it is
  ## a bare symbol, or a flat `(name type)` pair whose first element is not
  ## itself a list. Anything not clearly a bindings list is treated as an
  ## (possibly malformed) declaration, so bad declarations still get
  ## declaration-shaped diagnostics instead of confusing "bad binding" errors.
  if sx.items.len < 2:
    return false
  let nameTarget = sx.items[1]
  not (nameTarget.kind == sxList and
       (nameTarget.items.len == 0 or nameTarget.items[0].kind == sxList))

proc isVarSectionForm*(sx: Syntax): bool =
  ## A `var`/`const` section form declares multiple bindings at
  ## statement/module scope using the same binding-list grammar as the local
  ## mutable-binding form, but with no body: `(var ((x 1) (y 2)))`. This is
  ## distinguished from the local form (which requires a body) purely by
  ## arity — `(var (bindings…) body…)` has 3+ items, a section has exactly 2.
  sx.items.len == 2 and not isDefvarForm(sx)

proc procGenericIdx*(sx: Syntax): int =
  ## Returns the index of the optional generic-params vector in a `proc` or
  ## `type` form, or -1 if none is present. Generic params appear as a
  ## `sxVector` immediately after the name (slot 2).
  if sx.items.len > 2 and sx.items[2].kind == sxVector:
    2
  else:
    -1

proc procParamsIdx*(sx: Syntax): int =
  ## Returns the index of the parameter list in a `proc` form, skipping an
  ## optional generic-params vector and/or pragma clause that may appear
  ## between the name and params.
  var idx = 2
  if sx.items.len > idx and sx.items[idx].kind == sxVector:
    idx += 1   # skip [T …]
  if sx.items.len > idx and sx.items[idx].isPragmaClause():
    idx += 1   # skip {.pragma.}
  idx

proc bodyStartAfterParams*(sx: Syntax; paramsIdx: int; formName = "proc"): int =
  ## Returns the index of the first body item after `paramsIdx`, skipping an
  ## optional `(: return-type)` clause immediately following the params.
  ## Shared by `procBodyStart` (name-bearing forms) and `lambdaBodyStart`
  ## (`do`, which has no name slot) so both agree on how a return-type clause
  ## is recognised and diagnosed.
  result = paramsIdx + 1
  if sx.items.len > result and sx.items[result].kind == sxList and
     sx.items[result].items.len == 2 and sx.items[result].items[0].isSymbol(":"):
    let returnType = sx.items[result].items[1]
    if returnType.kind != sxSymbol and returnType.kind != sxVector:
      raiseCompilerError(returnType.span, formName & " return type must be a symbol or generic type")
    result = paramsIdx + 2

proc procBodyStart*(sx: Syntax): int =
  bodyStartAfterParams(sx, procParamsIdx(sx))

proc lambdaBodyStart*(sx: Syntax): int =
  ## `do` has no name slot: `(do (params) (: T)? body…)`, so params sit at
  ## slot 1 and the optional return-type clause (if any) at slot 2.
  bodyStartAfterParams(sx, 1, "do")

proc formName*(sx: Syntax): string =
  if sx.kind == sxSymbol: sx.sym else: "form"

proc isKeywordSym*(sx: Syntax): bool =
  ## True for a `:field`-style keyword symbol — used both by macro `&key`
  ## parameter parsing (expand.nim) and by destructuring object patterns
  ## (`[:name n]`, #47).
  sx.kind == sxSymbol and sx.sym.len >= 2 and sx.sym[0] == ':'

proc isObjectPattern*(pattern: Syntax): bool =
  ## A destructuring vector pattern (#12) is an *object* pattern (matches by
  ## field name, #47) rather than a positional one when its first element is
  ## a `:field` keyword; anything else — including an empty vector — is
  ## positional.
  pattern.kind == sxVector and pattern.items.len > 0 and pattern.items[0].isKeywordSym()

proc validatePattern*(pattern: Syntax; names: var seq[Syntax]; rejectObjectIn: string = "")

proc validatePatternElem(elem: Syntax; names: var seq[Syntax]; rejectObjectIn: string) =
  case elem.kind
  of sxSymbol:
    if elem.isKeywordSym():
      raiseCompilerError(elem.span, "a :field key is only valid in an object pattern, whose first element must be a :field keyword")
    if elem.sym != "_":
      names.add elem
  of sxVector:
    validatePattern(elem, names, rejectObjectIn)
  else:
    raiseCompilerError(elem.span, "destructuring pattern element must be a symbol, _, or a nested vector pattern")

proc validateObjectPattern(pattern: Syntax; names: var seq[Syntax]; rejectObjectIn: string) =
  ## Validates an object pattern `[:field1 target1? :field2 target2? …]` — a
  ## `:field` keyword optionally followed by a binding target (symbol, `_`,
  ## or a nested pattern). A bare key with no following target is shorthand,
  ## binding a variable named after the field. Collects every bound name,
  ## skipping `_`.
  var seenFields: seq[string] = @[]
  var i = 0
  while i < pattern.items.len:
    let key = pattern.items[i]
    if not key.isKeywordSym():
      if key.kind == sxSymbol and key.sym == "&":
        raiseCompilerError(key.span, "& rest capture is not supported in an object pattern")
      raiseCompilerError(key.span, "object pattern key must be a :field keyword")
    let field = key.sym[1 .. ^1]
    if field in seenFields:
      raiseCompilerError(key.span, "duplicate object pattern field: " & field)
    seenFields.add field
    if i + 1 < pattern.items.len and not pattern.items[i + 1].isKeywordSym():
      let target = pattern.items[i + 1]
      if target.kind == sxSymbol and target.sym == "&":
        raiseCompilerError(target.span, "& rest capture is not supported in an object pattern")
      validatePatternElem(target, names, rejectObjectIn)
      i += 2
    else:
      names.add newSymbol(field, key.span)
      i += 1

proc validatePattern*(pattern: Syntax; names: var seq[Syntax]; rejectObjectIn: string = "") =
  ## Validates a destructuring pattern (#12/#47) — a positional vector
  ## pattern `[a b]` / `[head & rest]`, or an object pattern `[:field ...]` —
  ## optionally nested, and collects every name that must be declared,
  ## skipping `_` (the discard placeholder). `&` marks the final element of a
  ## positional pattern as a rest capture binding the remaining slice; at
  ## most one is allowed, and it must be the second-to-last element
  ## (immediately before the rest-binding name).
  ##
  ## `rejectObjectIn`, when non-empty, names the context (e.g. "match",
  ## "macro parameters") in which object patterns are not meaningful and
  ## should be rejected with a dedicated diagnostic; it propagates into
  ## nested patterns too.
  if pattern.items.len == 0:
    raiseCompilerError(pattern.span, "destructuring pattern must not be empty")
  if pattern.isObjectPattern():
    if rejectObjectIn.len > 0:
      raiseCompilerError(pattern.span, "object patterns are not supported in " & rejectObjectIn & "; use a vector pattern")
    validateObjectPattern(pattern, names, rejectObjectIn)
    return
  var ampersands: seq[Syntax] = @[]
  for elem in pattern.items:
    if elem.kind == sxSymbol and elem.sym == "&":
      ampersands.add elem
  if ampersands.len > 1:
    raiseCompilerError(ampersands[1].span, "destructuring pattern allows only one & rest capture")
  if ampersands.len == 1:
    if not (pattern.items[^2].kind == sxSymbol and pattern.items[^2].sym == "&"):
      raiseCompilerError(ampersands[0].span, "& must be immediately followed by the final rest binding")
    let restName = pattern.items[^1]
    if restName.kind != sxSymbol:
      raiseCompilerError(restName.span, "destructuring rest binding must be a symbol")
    if restName.isKeywordSym():
      raiseCompilerError(restName.span, "a :field key is only valid in an object pattern, whose first element must be a :field keyword")
    if restName.sym != "_":
      names.add restName
    for i in 0 ..< pattern.items.len - 2:
      validatePatternElem(pattern.items[i], names, rejectObjectIn)
    return
  for elem in pattern.items:
    validatePatternElem(elem, names, rejectObjectIn)
