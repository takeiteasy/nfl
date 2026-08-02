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

type StaticWhenClause* = object
  isElse*: bool
    ## True for the trailing `(else body…)` clause; `test` is unused then.
  test*: Syntax
  body*: seq[Syntax]

proc parseStaticWhenClauses*(sx: Syntax; requireElse: bool): seq[StaticWhenClause] =
  ## Parses `(static-when (test body…)… [(else body…)])` into its clauses,
  ## shared by `lower.nim` and `backend.nim` so the two passes can't
  ## disagree on shape (#32). `requireElse` is true in expression position —
  ## a `static-when` whose tests are all false has no value there, so an
  ## expression-position use without `else` is rejected here rather than
  ## letting Nim fail obscurely on the resulting `when` with no matching
  ## branch.
  if sx.items.len < 2:
    raiseCompilerError(sx.span, "static-when expects at least one clause")
  var sawElse = false
  for i in 1 ..< sx.items.len:
    let clause = sx.items[i]
    if clause.kind != sxList or clause.items.len < 2:
      raiseCompilerError(clause.span, "static-when clause must be (test body…) or (else body…)")
    if sawElse:
      raiseCompilerError(clause.span, "static-when else clause must be last")
    if clause.items[0].isSymbol("else"):
      sawElse = true
      result.add StaticWhenClause(isElse: true, body: clause.items[1 .. ^1])
    else:
      result.add StaticWhenClause(isElse: false, test: clause.items[0], body: clause.items[1 .. ^1])
  if requireElse and not sawElse:
    raiseCompilerError(sx.span, "static-when in expression position requires an else clause")

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
  ## `rejectObjectIn`, when non-empty, names the context (e.g. "macro
  ## parameters") in which object patterns are not meaningful and should be
  ## rejected with a dedicated diagnostic; it propagates into nested patterns
  ## too. `match` (#48) no longer routes through here for object patterns —
  ## it validates and lowers them itself, since a match object pattern's
  ## field targets are arbitrary match patterns, not plain binding targets.
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

const declFormHeads = [
  "var", "const", "import", "from", "proc", "template", "iterator", "type",
  "method", "func", "converter", "discard", "defer", "break", "continue",
  "yield", "return", "raise",
]
  ## The statement heads `lower.nim`'s `lowerStmt` and `backend.nim`'s
  ## `emitStmt` both switch on. Shared here (see the module comment) so
  ## `repl.nim`'s decl/expression classification (#14) — "does this
  ## top-level form declare something, or produce a printable value?" —
  ## can't drift from what the lowering/emission passes actually treat as a
  ## declaration or void statement.

proc isDeclForm*(sx: Syntax): bool =
  ## True for a top-level form the REPL (#14) should treat as a declaration
  ## or void statement — never wrapped for value printing — rather than a
  ## printable expression. Covers every head `lowerStmt`/`emitStmt` special-
  ## case (`declFormHeads`), plus a `block` when any of its direct children
  ## is itself a decl form: `defclass` (preamble.nfl) expands to `(block
  ## (type …) (proc …) …)`, which must stay a declaration, while a `progn`-
  ## style `(block expr)` wrapping a single printable value should not.
  if sx.kind != sxList or sx.items.len == 0 or sx.items[0].kind != sxSymbol:
    return false
  let head = sx.items[0].sym
  if head in declFormHeads:
    return true
  if head == "block":
    for i in 1 ..< sx.items.len:
      if isDeclForm(sx.items[i]):
        return true
  if head == "static-when":
    # Same rule as `block`: a static-when carrying a declaration (e.g. a
    # per-platform `proc`) in any clause must stay a declaration for the
    # REPL (#14), even though other clauses' bodies may be plain expressions.
    for i in 1 ..< sx.items.len:
      let clause = sx.items[i]
      if clause.kind != sxList:
        continue
      for j in 1 ..< clause.items.len:
        if isDeclForm(clause.items[j]):
          return true
  false

proc sectionTargetNames(target: Syntax; names: var seq[string]) =
  ## Collects the name(s) a single `var`/`const` section binding target
  ## declares — mirrors the target shapes `lower.nim`'s
  ## `sectionBindingParts` accepts: a plain symbol, a typed `(name Type)`
  ## pair, or a destructuring vector pattern (every name it binds).
  case target.kind
  of sxSymbol:
    names.add target.sym
  of sxList:
    if target.items.len == 2 and target.items[0].kind == sxSymbol:
      names.add target.items[0].sym
  of sxVector:
    var patternNames: seq[Syntax] = @[]
    try:
      validatePattern(target, patternNames)
    except CatchableError:
      discard
    for n in patternNames:
      names.add n.sym
  else:
    discard

proc declaredNames*(sx: Syntax): seq[string] =
  ## The top-level name(s) a decl form (`isDeclForm`) binds — used by the
  ## REPL (#14) to detect when a new transcript entry redefines an earlier
  ## one. Every returned name has its export marker (trailing `*`) already
  ## stripped, so `(proc f* …)` and a later `(proc f …)` are recognized as
  ## the same binding. Best-effort: an unrecognized or malformed shape
  ## (already destined to be rejected by `lower.nim` at compile time)
  ## simply contributes no names rather than raising here.
  if sx.kind != sxList or sx.items.len < 2 or sx.items[0].kind != sxSymbol:
    return @[]
  proc stripped(sym: string): string =
    if sym.len > 0 and sym[^1] == '*': sym[0 ..< sym.high] else: sym
  let head = sx.items[0].sym
  case head
  of "proc", "template", "iterator", "type", "method", "func", "converter":
    let name = sx.items[1]
    if name.kind == sxSymbol:
      result.add stripped(name.sym)
  of "var", "const":
    if isVarSectionForm(sx):
      # `(var ((n1 v1) (n2 v2) …))` / `(const (…))` — a list of bindings,
      # each possibly binding multiple names via a destructuring pattern.
      let bindings = sx.items[1]
      if bindings.kind == sxList:
        for binding in bindings.items:
          if binding.kind == sxList and binding.items.len > 0:
            var names: seq[string] = @[]
            sectionTargetNames(binding.items[0], names)
            for n in names: result.add stripped(n)
    else:
      # `(var name value)` / `(var (name Type) value)` declaration form.
      let nameTarget = sx.items[1]
      if nameTarget.kind == sxSymbol:
        result.add stripped(nameTarget.sym)
      elif nameTarget.kind == sxList and nameTarget.items.len == 2 and
           nameTarget.items[0].kind == sxSymbol:
        result.add stripped(nameTarget.items[0].sym)
  of "block":
    for i in 1 ..< sx.items.len:
      result.add declaredNames(sx.items[i])
  of "static-when":
    for i in 1 ..< sx.items.len:
      let clause = sx.items[i]
      if clause.kind != sxList:
        continue
      for j in 1 ..< clause.items.len:
        result.add declaredNames(clause.items[j])
  else:
    discard
