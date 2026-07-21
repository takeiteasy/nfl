import std/macros
import std/os
import std/strutils
import std/tables

import ./diagnostics
import ./runtime
import ./syntax

type EmitContext = object
  hygienicSymbols: Table[int, NimNode]

proc isSymbol(sx: Syntax; name: string): bool =
  sx.kind == sxSymbol and sx.sym == name

proc isPragmaClause(sx: Syntax): bool =
  sx.kind == sxList and sx.items.len > 0 and sx.items[0].isSymbol("pragma")

proc isDefvarForm(sx: Syntax): bool =
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

proc procGenericIdx(sx: Syntax): int =
  ## Returns the index of the optional generic-params vector in a `proc` or `type`
  ## form, or -1 if none is present.  Generic params appear as a `sxVector`
  ## immediately after the name (slot 2).
  if sx.items.len > 2 and sx.items[2].kind == sxVector:
    2
  else:
    -1

proc procParamsIdx(sx: Syntax): int =
  ## Returns the index of the parameter list in a `proc` form, skipping an
  ## optional generic-params vector and/or pragma clause that may appear between
  ## the name and params.
  var idx = 2
  if sx.items.len > idx and sx.items[idx].kind == sxVector:
    idx += 1   # skip [T …]
  if sx.items.len > idx and sx.items[idx].isPragmaClause():
    idx += 1   # skip {.pragma.}
  idx

proc procBodyStart(sx: Syntax): int =
  let paramsIdx = procParamsIdx(sx)
  result = paramsIdx + 1
  if sx.items.len > result and sx.items[result].kind == sxList and
     sx.items[result].items.len == 2 and sx.items[result].items[0].isSymbol(":"):
    result = paramsIdx + 2

proc formName(sx: Syntax): string =
  if sx.kind == sxSymbol: sx.sym else: "form"

proc expectArity(sx: Syntax; name: string; actual, expected: int) =
  if actual != expected:
    raiseCompilerError(sx.span, name & " expects " & $expected & " arguments, got " & $actual)

proc emitExpr(ctx: var EmitContext; sx: Syntax): NimNode
proc emitStmt(ctx: var EmitContext; sx: Syntax): NimNode
proc emitNamedArg(ctx: var EmitContext; sx: Syntax): NimNode
proc emitPragma(ctx: var EmitContext; sx: Syntax): NimNode
proc pragmaDeclIdent(ctx: var EmitContext; name: Syntax; pragma: Syntax; what: string): NimNode

proc isNamedArg(sx: Syntax): bool =
  sx.kind == sxList and sx.items.len > 0 and sx.items[0].isSymbol(":")

proc attachLineInfo(node: NimNode; sx: Syntax): NimNode =
  result = node
  if sx.span.file.len > 0 and sx.span.file[0] != '<' and fileExists(sx.span.file):
    result.setLineInfo(sx.span.file, sx.span.line, sx.span.col)

proc identForSymbol(ctx: var EmitContext; sx: Syntax): NimNode =
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, "expected symbol")
  if sx.hygieneId != 0:
    if not ctx.hygienicSymbols.hasKey(sx.hygieneId):
      ctx.hygienicSymbols[sx.hygieneId] = genSym(nskLet, sx.sym)
    return ctx.hygienicSymbols[sx.hygieneId].copyNimTree().attachLineInfo(sx)
  ident(sx.sym).attachLineInfo(sx)

proc emitDottedSymbol(sx: Syntax): NimNode =
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, "expected symbol")
  if sx.sym.len == 0 or sx.sym[0] == '.' or sx.sym[^1] == '.' or sx.sym.contains(".."):
    raiseCompilerError(sx.span, "invalid dotted symbol: " & sx.sym)
  let parts = sx.sym.split('.')
  result = ident(parts[0]).attachLineInfo(sx)
  for part in parts[1 .. ^1]:
    result = nnkDotExpr.newTree(result, ident(part)).attachLineInfo(sx)

proc emitSymbolRef(ctx: var EmitContext; sx: Syntax): NimNode =
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, "expected symbol")
  # Route `foo.bar` through emitDottedSymbol.  Symbols that are composed
  # entirely of dots (`.`, `..`, etc.) are Nim operators — leave them as
  # plain identifiers so that e.g. `(.. 1 5)` emits `\`..`(1, 5)`.
  if sx.hygieneId == 0 and sx.sym.contains('.') and sx.sym != ".":
    var allDots = true
    for c in sx.sym:
      if c != '.': allDots = false; break
    if not allDots:
      return emitDottedSymbol(sx)
  ctx.identForSymbol(sx)

proc identForTypeSymbol(sx: Syntax): NimNode =
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, "expected symbol")
  ident(sx.sym).attachLineInfo(sx)

proc declIdent(ctx: var EmitContext; sx: Syntax; what: string): NimNode =
  ## Build the declaration-site identifier for a symbol, handling both the
  ## export postfix (`name*` → `nnkPostfix(*, ident(name))`) and hygiene.
  ## Hygienic symbols cannot carry `*` — they have no stable public name.
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, what & " must be a symbol")
  if sx.sym.endsWith("*"):
    if sx.hygieneId != 0:
      raiseCompilerError(sx.span, "exported name cannot be a hygienic symbol")
    let base = sx.sym[0 ..< sx.sym.high]
    if base.len == 0:
      raiseCompilerError(sx.span, "exported name must have a base name")
    if base.contains("*"):
      raiseCompilerError(sx.span, "export marker is only allowed at the end of a name")
    return nnkPostfix.newTree(
      ident("*"),
      ident(base).attachLineInfo(sx)
    ).attachLineInfo(sx)
  ctx.identForSymbol(sx)

proc emitTypeRef(sx: Syntax): NimNode =
  ## Emits a type reference: either a plain/dotted symbol or a generic type
  ## application `[Head arg …]` → `nnkBracketExpr(Head, arg, …)`.
  if sx.kind == sxVector:
    if sx.items.len < 2:
      raiseCompilerError(sx.span, "generic type application must have a head and at least one argument")
    result = nnkBracketExpr.newTree(emitTypeRef(sx.items[0])).attachLineInfo(sx)
    for i in 1 ..< sx.items.len:
      result.add emitTypeRef(sx.items[i])
    return
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, "expected type symbol or generic type application")
  if sx.sym.contains('.') and sx.sym != ".":
    emitDottedSymbol(sx)
  else:
    identForTypeSymbol(sx)

proc emitTypeReference(sx: Syntax): NimNode =
  ## Legacy thin wrapper — use emitTypeRef for new callers.
  emitTypeRef(sx)

proc emitGenericParams(sx: Syntax): NimNode =
  ## Emits `nnkGenericParams` from a `[T U …]` declaration vector.
  result = nnkGenericParams.newTree().attachLineInfo(sx)
  for entry in sx.items:
    result.add nnkIdentDefs.newTree(
      ident(entry.sym).attachLineInfo(entry),
      newEmptyNode(),
      newEmptyNode()
    ).attachLineInfo(entry)

proc emitModulePath(sx: Syntax): NimNode =
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, "import expects a module symbol")
  let parts = sx.sym.split('/')
  if parts.len == 0:
    raiseCompilerError(sx.span, "invalid import path")
  for part in parts:
    if part.len == 0:
      raiseCompilerError(sx.span, "invalid import path")
  result = ident(parts[0]).attachLineInfo(sx)
  for part in parts[1 .. ^1]:
    result = nnkInfix.newTree(ident("/"), result, ident(part)).attachLineInfo(sx)

proc emitBodyExpr(ctx: var EmitContext; items: openArray[Syntax]; owner: Syntax): NimNode =
  if items.len == 0:
    raiseCompilerError(owner.span, "expected body expression")
  if items.len == 1:
    return ctx.emitExpr(items[0])
  result = newStmtList()
  for i, item in items:
    if i == items.high:
      result.add ctx.emitExpr(item)
    else:
      result.add ctx.emitStmt(item)

proc emitBlockExpr(stmts: seq[NimNode]; body: NimNode): NimNode =
  var list = newStmtList()
  for stmt in stmts:
    list.add stmt
  list.add body
  nnkBlockStmt.newTree(newEmptyNode(), list)

proc emitBindingIdentDefs(ctx: var EmitContext; binding: Syntax): NimNode =
  if binding.kind != sxList or binding.items.len notin {2, 3}:
    raiseCompilerError(binding.span, "binding must be a pair or annotated triple")
  let target = binding.items[0]
  # Optional pragma clause at items[1] for annotated bindings `(target {.p.} value)`.
  var pragma: Syntax = nil
  if binding.items.len == 3:
    pragma = binding.items[1]
  let value = ctx.emitExpr(binding.items[binding.items.high])
  if target.kind == sxSymbol:
    return nnkIdentDefs.newTree(
      ctx.pragmaDeclIdent(target, pragma, "binding name"),
      newEmptyNode(),
      value
    ).attachLineInfo(binding)
  if target.kind == sxList and target.items.len == 2 and target.items[0].kind == sxSymbol and
      (target.items[1].kind == sxSymbol or target.items[1].kind == sxVector):
    return nnkIdentDefs.newTree(
      ctx.pragmaDeclIdent(target.items[0], pragma, "binding name"),
      emitTypeRef(target.items[1]),
      value
    ).attachLineInfo(binding)
  raiseCompilerError(target.span, "binding name must be a symbol or (name type)")

proc emitLetLike(ctx: var EmitContext; sx: Syntax; mutable: bool): NimNode =
  if sx.items.len < 3:
    raiseCompilerError(sx.span, formName(sx.items[0]) & " expects bindings and body")
  let bindings = sx.items[1]
  if bindings.kind != sxList:
    raiseCompilerError(bindings.span, "bindings must be a list")

  var section = if mutable: nnkVarSection.newTree() else: nnkLetSection.newTree()
  for binding in bindings.items:
    section.add ctx.emitBindingIdentDefs(binding)

  emitBlockExpr(@[section.attachLineInfo(sx)], ctx.emitBodyExpr(sx.items.toOpenArray(2, sx.items.high), sx)).attachLineInfo(sx)

proc isVarSectionForm(sx: Syntax): bool =
  ## Mirrors lower.nim's isVarSectionForm: a `var`/`const` section form
  ## declares multiple bindings at statement/module scope using the binding-
  ## list grammar with no body: `(var ((x 1) (y 2)))`.
  sx.items.len == 2 and not isDefvarForm(sx)

proc emitVarSection(ctx: var EmitContext; sx: Syntax; mutable: bool): NimNode =
  let bindings = sx.items[1]
  if bindings.kind != sxList or bindings.items.len == 0:
    raiseCompilerError(bindings.span, formName(sx.items[0]) & " section expects at least one binding")
  var section = if mutable: nnkVarSection.newTree() else: nnkConstSection.newTree()
  for binding in bindings.items:
    let identDefs = ctx.emitBindingIdentDefs(binding)
    if mutable:
      section.add identDefs
    else:
      # const sections use nnkConstDef rather than nnkIdentDefs; reuse the
      # same (name, type, value) children emitBindingIdentDefs already built.
      section.add nnkConstDef.newTree(
        identDefs[0], identDefs[1], identDefs[2]
      ).attachLineInfo(binding)
  section.attachLineInfo(sx)

proc emitIf(ctx: var EmitContext; sx: Syntax): NimNode =
  expectArity(sx, "if", sx.items.len - 1, 3)
  nnkIfExpr.newTree(
    nnkElifExpr.newTree(ctx.emitExpr(sx.items[1]), ctx.emitExpr(sx.items[2])),
    nnkElseExpr.newTree(ctx.emitExpr(sx.items[3]))
  ).attachLineInfo(sx)

proc emitIfStmt(ctx: var EmitContext; sx: Syntax): NimNode =
  expectArity(sx, "if", sx.items.len - 1, 3)
  nnkIfStmt.newTree(
    nnkElifBranch.newTree(ctx.emitExpr(sx.items[1]), ctx.emitStmt(sx.items[2])),
    nnkElse.newTree(ctx.emitStmt(sx.items[3]))
  ).attachLineInfo(sx)

proc emitBegin(ctx: var EmitContext; sx: Syntax): NimNode =
  if sx.items.len == 1:
    raiseCompilerError(sx.span, "block expects at least one expression")
  emitBlockExpr(@[], ctx.emitBodyExpr(sx.items.toOpenArray(1, sx.items.high), sx)).attachLineInfo(sx)

proc emitSet(ctx: var EmitContext; sx: Syntax): NimNode =
  expectArity(sx, "set!", sx.items.len - 1, 2)
  nnkAsgn.newTree(ctx.identForSymbol(sx.items[1]), ctx.emitExpr(sx.items[2])).attachLineInfo(sx)

proc emitParam(ctx: var EmitContext; param: Syntax): NimNode =
  if param.kind == sxSymbol:
    return nnkIdentDefs.newTree(ctx.identForSymbol(param), newEmptyNode(), newEmptyNode()).attachLineInfo(param)
  if param.kind == sxList and param.items.len == 2 and param.items[0].kind == sxSymbol and
      (param.items[1].kind == sxSymbol or param.items[1].kind == sxVector):
    return nnkIdentDefs.newTree(ctx.identForSymbol(param.items[0]), emitTypeRef(param.items[1]), newEmptyNode()).attachLineInfo(param)
  raiseCompilerError(param.span, "do parameter must be a symbol or (name type)")

proc emitLambda(ctx: var EmitContext; sx: Syntax): NimNode =
  if sx.items.len < 3:
    raiseCompilerError(sx.span, "do expects parameters and body")
  let params = sx.items[1]
  if params.kind != sxList:
    raiseCompilerError(params.span, "do parameters must be a list")
  var formalParams = nnkFormalParams.newTree(ident("auto"))
  for param in params.items:
    formalParams.add ctx.emitParam(param)
  nnkLambda.newTree(
    newEmptyNode(),
    newEmptyNode(),
    newEmptyNode(),
    formalParams,
    newEmptyNode(),
    newEmptyNode(),
    ctx.emitBodyExpr(sx.items.toOpenArray(2, sx.items.high), sx)
  ).attachLineInfo(sx)

proc emitPragma(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits a `nnkPragma` node from a `(pragma m1 m2 …)` syntax object.
  ## Each entry is either:
  ##   - a symbol (marker pragma) → bare `ident`
  ##   - a list `(: key value)` (value pragma) → `nnkExprColonExpr(ident(key), emitExpr(value))`
  result = nnkPragma.newTree().attachLineInfo(sx)
  for i in 1 ..< sx.items.len:
    let entry = sx.items[i]
    if entry.kind == sxSymbol:
      result.add ident(entry.sym).attachLineInfo(entry)
    elif entry.kind == sxList and entry.items.len == 3 and entry.items[0].isSymbol(":"):
      let key = entry.items[1]
      let value = entry.items[2]
      result.add nnkExprColonExpr.newTree(
        ident(key.sym).attachLineInfo(key),
        ctx.emitExpr(value)
      ).attachLineInfo(entry)
    else:
      raiseCompilerError(entry.span, "invalid pragma entry")

proc pragmaDeclIdent(ctx: var EmitContext; name: Syntax; pragma: Syntax; what: string): NimNode =
  ## Returns the declaration identifier for `name`, wrapped in `nnkPragmaExpr`
  ## when `pragma` is non-nil (i.e. a pragma clause was specified).  Handles
  ## the export postfix (`name*`) correctly in both cases.
  let nameNode = ctx.declIdent(name, what)
  if pragma == nil:
    return nameNode
  nnkPragmaExpr.newTree(nameNode, ctx.emitPragma(pragma)).attachLineInfo(name)

proc emitRoutine(ctx: var EmitContext; sx: Syntax; nodeKind: NimNodeKind;
                 formName: string; stmtBody: bool = false): NimNode =
  ## Shared emitter for proc/template/iterator definition forms.
  ## All three Nim routine kinds share the identical 7-slot AST layout as
  ## nnkProcDef: (name, patterns, genericParams, formalParams, pragma, reserved, body).
  ##
  ## `stmtBody` — when true the routine body is emitted as a plain statement
  ## list rather than as an expression (required for iterators whose bodies
  ## are yield-statement sequences, not value-producing expressions).
  if sx.items.len < 4:
    raiseCompilerError(sx.span, formName & " expects name, parameters, and body")
  let name = sx.items[1]
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, formName & " name must be a symbol")
  # Optional generic-params vector (slot 2) → routine node slot 2.
  let genIdx = procGenericIdx(sx)
  var genericParamsNode: NimNode = newEmptyNode()
  if genIdx >= 0:
    genericParamsNode = emitGenericParams(sx.items[genIdx])
  let paramsIdx = procParamsIdx(sx)
  # Extract optional pragma (goes into routine node slot 4).
  var pragmaNode: NimNode = newEmptyNode()
  let pragmaIdx = paramsIdx - 1
  if pragmaIdx >= 2 and sx.items[pragmaIdx].isPragmaClause():
    pragmaNode = ctx.emitPragma(sx.items[pragmaIdx])
  let params = sx.items[paramsIdx]
  if params.kind != sxList:
    raiseCompilerError(params.span, formName & " parameters must be a list")

  let bodyStart = procBodyStart(sx)
  if bodyStart > sx.items.high:
    raiseCompilerError(sx.span, formName & " expects body expression")

  var returnType = ident("auto")
  let retIdx = paramsIdx + 1
  if bodyStart == paramsIdx + 2:
    let annotation = sx.items[retIdx].items[1]
    returnType = emitTypeRef(annotation)

  var formalParams = nnkFormalParams.newTree(returnType)
  for param in params.items:
    formalParams.add ctx.emitParam(param)

  let bodyNode =
    if stmtBody:
      # Iterator bodies are pure statement sequences — do not use emitBodyExpr
      # which would wrap the last item as a value-producing expression.
      var stmts = newStmtList()
      for item in sx.items.toOpenArray(bodyStart, sx.items.high):
        stmts.add ctx.emitStmt(item)
      stmts
    else:
      ctx.emitBodyExpr(sx.items.toOpenArray(bodyStart, sx.items.high), sx)

  nodeKind.newTree(
    ctx.declIdent(name, formName & " name"),
    newEmptyNode(),
    genericParamsNode,
    formalParams,
    pragmaNode,
    newEmptyNode(),
    bodyNode
  ).attachLineInfo(sx)

proc emitProc(ctx: var EmitContext; sx: Syntax): NimNode =
  ctx.emitRoutine(sx, nnkProcDef, "proc")

proc emitTemplate(ctx: var EmitContext; sx: Syntax): NimNode =
  ctx.emitRoutine(sx, nnkTemplateDef, "template")

proc emitIterator(ctx: var EmitContext; sx: Syntax): NimNode =
  ctx.emitRoutine(sx, nnkIteratorDef, "iterator", stmtBody = true)

proc emitMethod(ctx: var EmitContext; sx: Syntax): NimNode =
  ctx.emitRoutine(sx, nnkMethodDef, "method")

proc emitYield(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits a `(yield expr)` form as `nnkYieldStmt`.
  nnkYieldStmt.newTree(ctx.emitExpr(sx.items[1])).attachLineInfo(sx)

proc emitVarDecl(ctx: var EmitContext; sx: Syntax): NimNode =
  let formName = sx.items[0].sym
  let nameTarget = sx.items[1]
  # Determine name ident and optional type ident.
  var pragma: Syntax = nil
  var nameIdent: NimNode
  var typeIdent: NimNode = newEmptyNode()
  if nameTarget.kind == sxSymbol:
    nameIdent = pragmaDeclIdent(ctx, nameTarget, pragma, formName & " name")
  elif nameTarget.kind == sxList and nameTarget.items.len == 2 and
       nameTarget.items[0].kind == sxSymbol and
       (nameTarget.items[1].kind == sxSymbol or nameTarget.items[1].kind == sxVector):
    nameIdent = pragmaDeclIdent(ctx, nameTarget.items[0], pragma, formName & " name")
    typeIdent = emitTypeRef(nameTarget.items[1])
  else:
    raiseCompilerError(nameTarget.span, formName & " name must be a symbol or (name type)")
  # Parse the optional pragma clause and optional value expression.
  var nextIdx = 2
  if nextIdx < sx.items.len and sx.items[nextIdx].isPragmaClause():
    pragma = sx.items[nextIdx]
    nextIdx += 1
    # Re-emit nameIdent now that pragma is known.
    if nameTarget.kind == sxSymbol:
      nameIdent = pragmaDeclIdent(ctx, nameTarget, pragma, formName & " name")
    else:
      nameIdent = pragmaDeclIdent(ctx, nameTarget.items[0], pragma, formName & " name")
  let valueSlot: NimNode =
    if nextIdx < sx.items.len: ctx.emitExpr(sx.items[nextIdx])
    else: newEmptyNode()
  nnkVarSection.newTree(
    nnkIdentDefs.newTree(nameIdent, typeIdent, valueSlot).attachLineInfo(sx)
  ).attachLineInfo(sx)

proc emitConst(ctx: var EmitContext; sx: Syntax): NimNode =
  let formName = sx.items[0].sym
  let nameTarget = sx.items[1]
  # Optional pragma clause between name and value.
  var pragma: Syntax = nil
  var valueIdx = 2
  if sx.items.len == 4 and sx.items[2].isPragmaClause():
    pragma = sx.items[2]
    valueIdx = 3
  let value = ctx.emitExpr(sx.items[valueIdx])
  var nameIdent: NimNode
  var typeIdent: NimNode = newEmptyNode()
  if nameTarget.kind == sxSymbol:
    nameIdent = pragmaDeclIdent(ctx, nameTarget, pragma, formName & " name")
  elif nameTarget.kind == sxList and nameTarget.items.len == 2 and
       nameTarget.items[0].kind == sxSymbol and
       (nameTarget.items[1].kind == sxSymbol or nameTarget.items[1].kind == sxVector):
    nameIdent = pragmaDeclIdent(ctx, nameTarget.items[0], pragma, formName & " name")
    typeIdent = emitTypeRef(nameTarget.items[1])
  else:
    raiseCompilerError(nameTarget.span, formName & " name must be a symbol or (name type)")
  nnkConstSection.newTree(
    nnkConstDef.newTree(nameIdent, typeIdent, value).attachLineInfo(sx)
  ).attachLineInfo(sx)

proc emitImport(sx: Syntax): NimNode =
  expectArity(sx, "import", sx.items.len - 1, 1)
  nnkImportStmt.newTree(emitModulePath(sx.items[1])).attachLineInfo(sx)

proc emitObjectType(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits `(object [of Base] (field type) …)` as `nnkObjectTy`.
  ## The optional `(of Base)` clause at items[1] populates the inheritance slot.
  var fieldStart = 1
  var inheritNode: NimNode = newEmptyNode()
  if sx.items.len > 1 and sx.items[1].kind == sxList and
     sx.items[1].items.len == 2 and sx.items[1].items[0].isSymbol("of"):
    inheritNode = nnkOfInherit.newTree(
      emitTypeReference(sx.items[1].items[1])
    ).attachLineInfo(sx.items[1])
    fieldStart = 2
  var fields = nnkRecList.newTree().attachLineInfo(sx)
  for field in sx.items.toOpenArray(fieldStart, sx.items.high):
    # Field form: `(name Type)` or `(name {.p.} Type)` — 2 or 3 items.
    var pragma: Syntax = nil
    var typeIdx = 1
    if field.items.len == 3 and field.items[1].isPragmaClause():
      pragma = field.items[1]
      typeIdx = 2
    fields.add nnkIdentDefs.newTree(
      pragmaDeclIdent(ctx, field.items[0], pragma, "object field name"),
      emitTypeReference(field.items[typeIdx]),
      newEmptyNode()
    ).attachLineInfo(field)
  nnkObjectTy.newTree(newEmptyNode(), inheritNode, fields).attachLineInfo(sx)

proc emitEnumType(sx: Syntax): NimNode =
  result = nnkEnumTy.newTree(newEmptyNode()).attachLineInfo(sx)
  for value in sx.items.toOpenArray(1, sx.items.high):
    result.add identForTypeSymbol(value)

proc emitTupleType(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits `(tuple (name1 type1) …)` as `nnkTupleTy`.
  result = nnkTupleTy.newTree().attachLineInfo(sx)
  for field in sx.items.toOpenArray(1, sx.items.high):
    result.add nnkIdentDefs.newTree(
      ctx.identForSymbol(field.items[0]),
      emitTypeReference(field.items[1]),
      newEmptyNode()
    ).attachLineInfo(field)

proc emitTypeBody(ctx: var EmitContext; sx: Syntax): NimNode =
  if sx.kind == sxSymbol or sx.kind == sxVector:
    return emitTypeReference(sx)
  if sx.kind == sxList and sx.items.len > 0:
    if sx.items[0].isSymbol("object"):
      return ctx.emitObjectType(sx)
    if sx.items[0].isSymbol("enum"):
      return emitEnumType(sx)
    if sx.items[0].isSymbol("tuple"):
      return ctx.emitTupleType(sx)
    if sx.items[0].isSymbol("distinct"):
      return nnkDistinctTy.newTree(emitTypeReference(sx.items[1])).attachLineInfo(sx)
    if sx.items[0].isSymbol("ref"):
      return nnkRefTy.newTree(ctx.emitTypeBody(sx.items[1])).attachLineInfo(sx)
  raiseCompilerError(sx.span, "unsupported type declaration")

proc emitTypeDecl(ctx: var EmitContext; sx: Syntax): NimNode =
  # Optional generic-params vector `[T …]` immediately after the name → nnkTypeDef slot 1.
  var idx = 2
  var genericParamsNode: NimNode = newEmptyNode()
  if sx.items.len > idx and sx.items[idx].kind == sxVector:
    genericParamsNode = emitGenericParams(sx.items[idx])
    idx += 1
  # Optional pragma clause after generic params (or directly after name).
  var pragma: Syntax = nil
  if sx.items.len > idx and sx.items[idx].isPragmaClause():
    pragma = sx.items[idx]
    idx += 1
  nnkTypeSection.newTree(
    nnkTypeDef.newTree(
      pragmaDeclIdent(ctx, sx.items[1], pragma, "type name"),
      genericParamsNode,
      ctx.emitTypeBody(sx.items[idx])
    ).attachLineInfo(sx)
  ).attachLineInfo(sx)

proc emitDot(ctx: var EmitContext; sx: Syntax): NimNode =
  if sx.items.len < 3:
    raiseCompilerError(sx.span, ". expects object and field or method name")
  let name = sx.items[2]
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, ". field or method name must be a symbol")
  let dot = nnkDotExpr.newTree(ctx.emitExpr(sx.items[1]), ctx.identForSymbol(name)).attachLineInfo(sx)
  if sx.items.len == 3:
    return dot
  result = newCall(dot).attachLineInfo(sx)
  for i in 3 ..< sx.items.len:
    if sx.items[i].isNamedArg():
      result.add ctx.emitNamedArg(sx.items[i])
    else:
      result.add ctx.emitExpr(sx.items[i])

proc emitAt(ctx: var EmitContext; sx: Syntax): NimNode =
  expectArity(sx, "at", sx.items.len - 1, 2)
  result = nnkBracketExpr.newTree(ctx.emitExpr(sx.items[1])).attachLineInfo(sx)
  result.add ctx.emitExpr(sx.items[2])

proc emitSlice(ctx: var EmitContext; sx: Syntax): NimNode =
  expectArity(sx, "slice", sx.items.len - 1, 3)
  result = nnkBracketExpr.newTree(ctx.emitExpr(sx.items[1])).attachLineInfo(sx)
  result.add nnkInfix.newTree(ident(".."), ctx.emitExpr(sx.items[2]), ctx.emitExpr(sx.items[3])).attachLineInfo(sx)

proc identForFieldSymbol(sx: Syntax): NimNode =
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, "new field name must be a symbol")
  ident(sx.sym).attachLineInfo(sx)

proc emitNamedArg(ctx: var EmitContext; sx: Syntax): NimNode =
  if sx.items.len != 3:
    raiseCompilerError(sx.span, "named argument must be (: name value)")
  if sx.items[1].kind != sxSymbol:
    raiseCompilerError(sx.items[1].span, "named argument name must be a symbol")
  nnkExprEqExpr.newTree(ctx.identForSymbol(sx.items[1]), ctx.emitExpr(sx.items[2])).attachLineInfo(sx)

proc emitNew(ctx: var EmitContext; sx: Syntax): NimNode =
  if sx.items.len < 2:
    raiseCompilerError(sx.span, "new expects a type and field initializers")
  result = nnkObjConstr.newTree(emitTypeReference(sx.items[1])).attachLineInfo(sx)
  for field in sx.items.toOpenArray(2, sx.items.high):
    if field.kind != sxList or field.items.len != 2:
      raiseCompilerError(field.span, "new field initializer must be (name value)")
    result.add nnkExprColonExpr.newTree(
      identForFieldSymbol(field.items[0]),
      ctx.emitExpr(field.items[1])
    ).attachLineInfo(field)

proc emitQuotedDatum(sx: Syntax): NimNode =
  case sx.kind
  of sxNil:
    result = newCall(bindSym"nflNilDatum").attachLineInfo(sx)
  of sxBool:
    result = newCall(bindSym"nflBoolDatum", newLit(sx.boolVal)).attachLineInfo(sx)
  of sxInt:
    result = newCall(bindSym"nflIntDatum", newLit(sx.intVal)).attachLineInfo(sx)
  of sxFloat:
    result = newCall(bindSym"nflFloatDatum", newLit(sx.floatVal)).attachLineInfo(sx)
  of sxString:
    result = newCall(bindSym"nflStringDatum", newLit(sx.strVal)).attachLineInfo(sx)
  of sxSymbol:
    result = newCall(bindSym"nflSymbolDatum", newLit(sx.sym)).attachLineInfo(sx)
  of sxList:
    result = newCall(bindSym"nflListDatum").attachLineInfo(sx)
    for item in sx.items:
      result.add emitQuotedDatum(item)
  of sxVector:
    result = newCall(bindSym"nflVectorDatum").attachLineInfo(sx)
    for item in sx.items:
      result.add emitQuotedDatum(item)

proc emitQuote(sx: Syntax): NimNode =
  expectArity(sx, "quote", sx.items.len - 1, 1)
  emitQuotedDatum(sx.items[1])

proc emitCall(ctx: var EmitContext; sx: Syntax): NimNode =
  if sx.items.len == 0:
    raiseCompilerError(sx.span, "empty list is not callable")
  var call = newCall(ctx.emitSymbolRef(sx.items[0])).attachLineInfo(sx)
  for i in 1 ..< sx.items.len:
    if sx.items[i].isNamedArg():
      call.add ctx.emitNamedArg(sx.items[i])
    else:
      call.add ctx.emitExpr(sx.items[i])
  call

# ---------------------------------------------------------------------------
# for / case / raise / try
# ---------------------------------------------------------------------------

proc isExceptClause(sx: Syntax): bool =
  sx.kind == sxList and sx.items.len > 0 and sx.items[0].isSymbol("except")

proc isFinallyClause(sx: Syntax): bool =
  sx.kind == sxList and sx.items.len > 0 and sx.items[0].isSymbol("finally")

proc isExceptBinding(sx: Syntax): bool =
  ## True when sx has the shape `(name TypeRef)` — used to distinguish a named
  ## exception binding `(e ValueError)` from a bare catch-all body.
  sx.kind == sxList and sx.items.len == 2 and
  sx.items[0].kind == sxSymbol and
  (sx.items[1].kind == sxSymbol or sx.items[1].kind == sxVector)

proc emitForCore(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Builds the `nnkForStmt` for `(for CLAUSE body…)`.
  ## Always returns a statement node; wrap in `emitBlockExpr` for expr context.
  let clause = sx.items[1]
  let binding = clause.items[0]
  let iterable = clause.items[1]
  result = nnkForStmt.newTree()
  if binding.kind == sxSymbol:
    result.add ctx.identForSymbol(binding)
  else:
    for v in binding.items:
      result.add ctx.identForSymbol(v)
  result.add ctx.emitExpr(iterable)
  var body = newStmtList()
  for i in 2 ..< sx.items.len:
    body.add ctx.emitStmt(sx.items[i])
  result.add body
  result = result.attachLineInfo(sx)

proc emitCase(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits `nnkCaseStmt` with branch bodies as expressions (for expr context).
  result = nnkCaseStmt.newTree(ctx.emitExpr(sx.items[1])).attachLineInfo(sx)
  for i in 2 ..< sx.items.len:
    let branch = sx.items[i]
    if branch.items[0].isSymbol("of"):
      result.add nnkOfBranch.newTree(
        ctx.emitExpr(branch.items[1]),
        ctx.emitBodyExpr(branch.items.toOpenArray(2, branch.items.high), branch)
      ).attachLineInfo(branch)
    else: # else branch
      result.add nnkElse.newTree(
        ctx.emitBodyExpr(branch.items.toOpenArray(1, branch.items.high), branch)
      ).attachLineInfo(branch)

proc emitCaseStmt(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits `nnkCaseStmt` with branch bodies as statements (for stmt context).
  result = nnkCaseStmt.newTree(ctx.emitExpr(sx.items[1])).attachLineInfo(sx)
  for i in 2 ..< sx.items.len:
    let branch = sx.items[i]
    if branch.items[0].isSymbol("of"):
      var body = newStmtList()
      for j in 2 ..< branch.items.len:
        body.add ctx.emitStmt(branch.items[j])
      result.add nnkOfBranch.newTree(
        ctx.emitExpr(branch.items[1]),
        body
      ).attachLineInfo(branch)
    else:
      var body = newStmtList()
      for j in 1 ..< branch.items.len:
        body.add ctx.emitStmt(branch.items[j])
      result.add nnkElse.newTree(body).attachLineInfo(branch)

proc emitRaise(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits `nnkRaiseStmt`.  Nim accepts `raise` in expression position as a
  ## noreturn expression (e.g. in the branch of an `if` expression).
  let nargs = sx.items.len - 1
  if nargs > 1:
    raiseCompilerError(sx.span, "raise expects 0 or 1 arguments, got " & $nargs)
  let operand = if nargs == 1: ctx.emitExpr(sx.items[1]) else: newEmptyNode()
  nnkRaiseStmt.newTree(operand).attachLineInfo(sx)

proc emitReturn(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits `(return)` or `(return expr)` as `nnkReturnStmt`.
  let nargs = sx.items.len - 1
  let operand = if nargs == 1: ctx.emitExpr(sx.items[1]) else: newEmptyNode()
  nnkReturnStmt.newTree(operand).attachLineInfo(sx)

proc emitDiscard(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits `(discard)` or `(discard expr)` as `nnkDiscardStmt`.
  let nargs = sx.items.len - 1
  let operand = if nargs == 1: ctx.emitExpr(sx.items[1]) else: newEmptyNode()
  nnkDiscardStmt.newTree(operand).attachLineInfo(sx)

proc emitWhileCore(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Builds the `nnkWhileStmt` for `(while COND body…)`.
  ## Always returns a statement node; wrap in `emitBlockExpr` for expr context.
  var body = newStmtList()
  for i in 2 ..< sx.items.len:
    body.add ctx.emitStmt(sx.items[i])
  nnkWhileStmt.newTree(ctx.emitExpr(sx.items[1]), body).attachLineInfo(sx)

proc emitExceptBranch(ctx: var EmitContext; branch: Syntax; asExpr: bool): NimNode =
  ## Emits one `nnkExceptBranch` node.  `asExpr` controls whether the branch
  ## body is lowered as an expression or a statement list.
  result = nnkExceptBranch.newTree().attachLineInfo(branch)
  var bodyStart: int
  if branch.items[1].kind == sxSymbol:
    # typed: (except Type body…)
    result.add emitTypeRef(branch.items[1])
    bodyStart = 2
  elif branch.items[1].isExceptBinding():
    # named: (except (e Type) body…) → `except Type as e:`
    result.add nnkInfix.newTree(
      ident("as"),
      emitTypeRef(branch.items[1].items[1]),
      ctx.identForSymbol(branch.items[1].items[0])
    ).attachLineInfo(branch.items[1])
    bodyStart = 2
  else:
    # bare catch-all: (except body…)
    bodyStart = 1
  if asExpr:
    result.add ctx.emitBodyExpr(branch.items.toOpenArray(bodyStart, branch.items.high), branch)
  else:
    var stmts = newStmtList()
    for i in bodyStart ..< branch.items.len:
      stmts.add ctx.emitStmt(branch.items[i])
    result.add stmts

proc emitTryCore(ctx: var EmitContext; sx: Syntax; asExpr: bool): NimNode =
  ## Shared implementation for try in expression and statement contexts.
  result = nnkTryStmt.newTree().attachLineInfo(sx)
  # Locate body boundary.
  var bodyEnd = 1
  while bodyEnd <= sx.items.high and
      not sx.items[bodyEnd].isExceptClause() and
      not sx.items[bodyEnd].isFinallyClause():
    inc bodyEnd
  if asExpr:
    result.add ctx.emitBodyExpr(sx.items.toOpenArray(1, bodyEnd - 1), sx)
  else:
    var body = newStmtList()
    for i in 1 ..< bodyEnd:
      body.add ctx.emitStmt(sx.items[i])
    result.add body
  var i = bodyEnd
  # Except branches.
  while i <= sx.items.high and sx.items[i].isExceptClause():
    result.add ctx.emitExceptBranch(sx.items[i], asExpr)
    inc i
  # Optional finally.
  if i <= sx.items.high and sx.items[i].isFinallyClause():
    let fin = sx.items[i]
    if asExpr:
      result.add nnkFinally.newTree(
        ctx.emitBodyExpr(fin.items.toOpenArray(1, fin.items.high), fin)
      ).attachLineInfo(fin)
    else:
      var body = newStmtList()
      for j in 1 ..< fin.items.len:
        body.add ctx.emitStmt(fin.items[j])
      result.add nnkFinally.newTree(body).attachLineInfo(fin)

proc emitTry(ctx: var EmitContext; sx: Syntax): NimNode =
  emitTryCore(ctx, sx, true)

proc emitTryStmt(ctx: var EmitContext; sx: Syntax): NimNode =
  emitTryCore(ctx, sx, false)

proc emitExpr(ctx: var EmitContext; sx: Syntax): NimNode =
  case sx.kind
  of sxNil:
    newNilLit().attachLineInfo(sx)
  of sxBool:
    newLit(sx.boolVal).attachLineInfo(sx)
  of sxInt:
    newLit(sx.intVal).attachLineInfo(sx)
  of sxFloat:
    newLit(sx.floatVal).attachLineInfo(sx)
  of sxString:
    newLit(sx.strVal).attachLineInfo(sx)
  of sxSymbol:
    ctx.emitSymbolRef(sx)
  of sxVector:
    var bracket = nnkBracket.newTree()
    for item in sx.items:
      bracket.add ctx.emitExpr(item)
    bracket.attachLineInfo(sx)
  of sxList:
    if sx.items.len == 0:
      raiseCompilerError(sx.span, "empty list is not an expression")
    if sx.items[0].isSymbol("if"):
      ctx.emitIf(sx)
    elif sx.items[0].isSymbol("block"):
      ctx.emitBegin(sx)
    elif sx.items[0].isSymbol("let"):
      ctx.emitLetLike(sx, false)
    elif sx.items[0].isSymbol("var"):
      if isDefvarForm(sx):
        raiseCompilerError(sx.span, "var is only allowed at statement/module scope")
      else:
        ctx.emitLetLike(sx, true)
    elif sx.items[0].isSymbol("set!"):
      ctx.emitSet(sx)
    elif sx.items[0].isSymbol("do"):
      ctx.emitLambda(sx)
    elif sx.items[0].isSymbol("yield"):
      ctx.emitYield(sx)
    elif sx.items[0].isSymbol("."):
      ctx.emitDot(sx)
    elif sx.items[0].isSymbol("at"):
      ctx.emitAt(sx)
    elif sx.items[0].isSymbol("slice"):
      ctx.emitSlice(sx)
    elif sx.items[0].isSymbol("new"):
      ctx.emitNew(sx)
    elif sx.items[0].isSymbol("for"):
      emitBlockExpr(@[ctx.emitForCore(sx)], newNilLit()).attachLineInfo(sx)
    elif sx.items[0].isSymbol("while"):
      emitBlockExpr(@[ctx.emitWhileCore(sx)], newNilLit()).attachLineInfo(sx)
    elif sx.items[0].isSymbol("case"):
      ctx.emitCase(sx)
    elif sx.items[0].isSymbol("raise"):
      ctx.emitRaise(sx)
    elif sx.items[0].isSymbol("return"):
      ctx.emitReturn(sx)
    elif sx.items[0].isSymbol("try"):
      ctx.emitTry(sx)
    elif sx.items[0].isSymbol(":"):
      raiseCompilerError(sx.span, "named argument marker is only allowed in call argument position")
    elif sx.items[0].isSymbol("discard"):
      raiseCompilerError(sx.span, "discard is only allowed at statement scope")
    elif sx.items[0].isSymbol("break"):
      raiseCompilerError(sx.span, "break is only allowed inside a loop body")
    elif sx.items[0].isSymbol("continue"):
      raiseCompilerError(sx.span, "continue is only allowed inside a loop body")
    elif sx.items[0].isSymbol("const"):
      raiseCompilerError(sx.span, sx.items[0].sym & " is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("proc"):
      raiseCompilerError(sx.span, "proc is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("template"):
      raiseCompilerError(sx.span, "template is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("iterator"):
      raiseCompilerError(sx.span, "iterator is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("method"):
      raiseCompilerError(sx.span, "method is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("type"):
      raiseCompilerError(sx.span, "type is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("import"):
      raiseCompilerError(sx.span, "import is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("quote"):
      emitQuote(sx)
    elif sx.items[0].isSymbol("quasiquote"):
      raiseCompilerError(sx.span, "runtime quasiquote is not implemented yet")
    elif sx.items[0].isSymbol("pragma"):
      raiseCompilerError(sx.span, "pragma is only allowed as a declaration annotation")
    else:
      ctx.emitCall(sx)

proc emitStmt(ctx: var EmitContext; sx: Syntax): NimNode =
  if sx.kind == sxNil:
    return newStmtList()
  if sx.kind == sxList and sx.items.len > 0:
    if sx.items[0].isSymbol("if"):
      return ctx.emitIfStmt(sx)
    if sx.items[0].isSymbol("for"):
      return ctx.emitForCore(sx)
    if sx.items[0].isSymbol("while"):
      return ctx.emitWhileCore(sx)
    if sx.items[0].isSymbol("case"):
      return ctx.emitCaseStmt(sx)
    if sx.items[0].isSymbol("raise"):
      return ctx.emitRaise(sx)
    if sx.items[0].isSymbol("return"):
      return ctx.emitReturn(sx)
    if sx.items[0].isSymbol("discard"):
      return ctx.emitDiscard(sx)
    if sx.items[0].isSymbol("break"):
      return nnkBreakStmt.newTree(newEmptyNode()).attachLineInfo(sx)
    if sx.items[0].isSymbol("continue"):
      return nnkContinueStmt.newTree(newEmptyNode()).attachLineInfo(sx)
    if sx.items[0].isSymbol("try"):
      return ctx.emitTryStmt(sx)
    if sx.items[0].isSymbol("block"):
      result = newStmtList()
      for i in 1 ..< sx.items.len:
        result.add ctx.emitStmt(sx.items[i])
      return
    if sx.items[0].isSymbol("var"):
      if isDefvarForm(sx):
        return ctx.emitVarDecl(sx)
      if isVarSectionForm(sx):
        return ctx.emitVarSection(sx, mutable = true)
      # Binding-list shape with a body falls through to the local
      # mutable-binding block form below, unchanged.
    if sx.items[0].isSymbol("const"):
      if isVarSectionForm(sx):
        return ctx.emitVarSection(sx, mutable = false)
      if not isDefvarForm(sx):
        raiseCompilerError(sx.span, "const does not support a local binding body")
      return ctx.emitConst(sx)
    if sx.items[0].isSymbol("import"):
      return emitImport(sx)
    if sx.items[0].isSymbol("proc"):
      return ctx.emitProc(sx)
    if sx.items[0].isSymbol("template"):
      return ctx.emitTemplate(sx)
    if sx.items[0].isSymbol("iterator"):
      return ctx.emitIterator(sx)
    if sx.items[0].isSymbol("method"):
      return ctx.emitMethod(sx)
    if sx.items[0].isSymbol("yield"):
      return ctx.emitYield(sx)
    if sx.items[0].isSymbol("type"):
      return ctx.emitTypeDecl(sx)
  newCall(bindSym"nflStmt", ctx.emitExpr(sx)).attachLineInfo(sx)

proc emitExpr*(sx: Syntax): NimNode =
  var ctx = EmitContext(hygienicSymbols: initTable[int, NimNode]())
  ctx.emitExpr(sx)

proc emitStmt*(sx: Syntax): NimNode =
  var ctx = EmitContext(hygienicSymbols: initTable[int, NimNode]())
  ctx.emitStmt(sx)

proc emitModule*(forms: seq[Syntax]): NimNode =
  var ctx = EmitContext(hygienicSymbols: initTable[int, NimNode]())
  result = newStmtList()
  for form in forms:
    result.add ctx.emitStmt(form)
