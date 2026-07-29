## Shared slot-layout helpers for proc/template/iterator/method/converter/type
## forms, used identically by both the lowering pass (lower.nim) and the
## emission pass (backend.nim). Kept in one place so the two passes cannot
## silently disagree on where generic params, pragmas, and bodies sit in the
## form (see #43).

import ./diagnostics
import ./syntax

proc isPragmaClause*(sx: Syntax): bool =
  sx.kind == sxList and sx.items.len > 0 and sx.items[0].isSymbol("pragma")

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
