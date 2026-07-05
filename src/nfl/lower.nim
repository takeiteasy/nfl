import std/tables
import std/strutils
import std/options

import ./diagnostics
import ./syntax

type
  BindingKind = enum
    bkImmutable, bkMutable

  LowerContext = object
    scopes: seq[Table[string, BindingKind]]

proc isSymbol(sx: Syntax; name: string): bool =
  sx.kind == sxSymbol and sx.sym == name

proc isPragmaClause(sx: Syntax): bool =
  sx.kind == sxList and sx.items.len > 0 and sx.items[0].isSymbol("pragma")

proc validatePragma(sx: Syntax) =
  ## Validates a pragma clause `(pragma m1 m2 …)`.  Each entry after the head
  ## must be a plain non-empty symbol with no export marker.
  for i in 1 ..< sx.items.len:
    let entry = sx.items[i]
    if entry.kind != sxSymbol or entry.sym.len == 0 or entry.sym.contains("*"):
      raiseCompilerError(entry.span, "pragma entry must be a marker symbol")

proc formName(sx: Syntax): string =
  if sx.kind == sxSymbol: sx.sym else: "form"

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

proc bindingName(binding: Syntax): Syntax =
  if binding.kind != sxList or binding.items.len != 2:
    raiseCompilerError(binding.span, "binding must be a pair")
  let target = binding.items[0]
  if target.kind == sxSymbol:
    return target
  # `(name type)` where type may be a symbol or a generic type vector `[Head T…]`
  if target.kind == sxList and target.items.len == 2 and target.items[0].kind == sxSymbol and
      (target.items[1].kind == sxSymbol or target.items[1].kind == sxVector):
    return target.items[0]
  raiseCompilerError(target.span, "binding name must be a symbol or (name type)")

proc lowerBody(ctx: var LowerContext; items: openArray[Syntax]; owner: Syntax) =
  if items.len == 0:
    raiseCompilerError(owner.span, "expected body expression")
  for item in items:
    lowerStmt(ctx, item)

proc lowerBindings(ctx: var LowerContext; bindings: Syntax; mutable: bool) =
  if bindings.kind != sxList:
    raiseCompilerError(bindings.span, "bindings must be a list")

  for binding in bindings.items:
    discard binding.bindingName()
    lowerExpr(ctx, binding.items[1])

  ctx.pushScope()
  let kind = if mutable: bkMutable else: bkImmutable
  for binding in bindings.items:
    declare(ctx, binding.bindingName(), kind)

proc lowerLetLike(ctx: var LowerContext; sx: Syntax; mutable: bool) =
  if sx.items.len < 3:
    raiseCompilerError(sx.span, formName(sx.items[0]) & " expects bindings and body")
  lowerBindings(ctx, sx.items[1], mutable)
  lowerBody(ctx, sx.items.toOpenArray(2, sx.items.high), sx)
  ctx.popScope()

proc lowerIf(ctx: var LowerContext; sx: Syntax) =
  expectArity(sx, "if", sx.items.len - 1, 3)
  lowerExpr(ctx, sx.items[1])
  lowerExpr(ctx, sx.items[2])
  lowerExpr(ctx, sx.items[3])

proc lowerBegin(ctx: var LowerContext; sx: Syntax) =
  if sx.items.len == 1:
    raiseCompilerError(sx.span, "block expects at least one expression")
  lowerBody(ctx, sx.items.toOpenArray(1, sx.items.high), sx)

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
  else:
    raiseCompilerError(param.span, "do parameter must be a symbol or (name type)")

proc lowerLambda(ctx: var LowerContext; sx: Syntax) =
  if sx.items.len < 3:
    raiseCompilerError(sx.span, "do expects parameters and body")
  let params = sx.items[1]
  if params.kind != sxList:
    raiseCompilerError(params.span, "do parameters must be a list")
  ctx.pushScope()
  for param in params.items:
    lowerParam(ctx, param)
  lowerBody(ctx, sx.items.toOpenArray(2, sx.items.high), sx)
  ctx.popScope()

proc validateExportedDecl(name: Syntax; what: string): string =
  ## Validates a declaration name that may optionally carry a trailing `*`
  ## export marker. Returns the base name with the marker stripped.
  ## Raises a CompilerError if the marker is malformed or the symbol is
  ## hygienic (hygienic symbols have no stable public name).
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, what & " must be a symbol")
  result = name.sym
  if result.endsWith("*"):
    if name.hygieneId != 0:
      raiseCompilerError(name.span, "exported name cannot be a hygienic symbol")
    result = result[0 ..< result.high]
    if result.len == 0:
      raiseCompilerError(name.span, "exported name must have a base name")
  if result.contains("*"):
    raiseCompilerError(name.span, "export marker is only allowed at the end of a name")

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
    let returnType = sx.items[result].items[1]
    if returnType.kind != sxSymbol and returnType.kind != sxVector:
      raiseCompilerError(returnType.span, "proc return type must be a symbol or generic type")
    result = paramsIdx + 2

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

proc lowerProc(ctx: var LowerContext; sx: Syntax) =
  if sx.items.len < 4:
    raiseCompilerError(sx.span, "proc expects name, parameters, and body")
  let name = sx.items[1]
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, "proc name must be a symbol")
  # Validate the export marker early so errors point at the name, not the body.
  let baseName = name.validateExportedDecl("proc name")
  # Optional generic-params vector immediately after the name.
  let genIdx = procGenericIdx(sx)
  if genIdx >= 0:
    validateGenericParams(sx.items[genIdx])
  # Optional pragma clause after generic params (or directly after name).
  let paramsIdx = procParamsIdx(sx)
  let pragmaIdx = paramsIdx - 1
  if pragmaIdx >= 2 and sx.items[pragmaIdx].isPragmaClause():
    if paramsIdx > sx.items.high:
      raiseCompilerError(sx.span, "proc expects name, parameters, and body")
    validatePragma(sx.items[pragmaIdx])
  let params = sx.items[paramsIdx]
  if params.kind != sxList:
    raiseCompilerError(params.span, "proc parameters must be a list")
  let bodyStart = procBodyStart(sx)
  if bodyStart > sx.items.high:
    raiseCompilerError(sx.span, "proc expects body expression")
  ctx.pushScope()
  for param in params.items:
    lowerParam(ctx, param)
  lowerBody(ctx, sx.items.toOpenArray(bodyStart, sx.items.high), sx)
  ctx.popScope()
  # Proc names resolve via Nim's own name resolution; we register under the
  # base name (stripped of any `*`) so local set!/lookup always finds it.
  declare(ctx, newSymbol(baseName, name.span), bkImmutable)

proc lowerDefvar(ctx: var LowerContext; sx: Syntax) =
  let formName = sx.items[0].sym
  let nargs = sx.items.len - 1
  if nargs < 2 or nargs > 3:
    raiseCompilerError(sx.span, formName & " expects 2 arguments, got " & $nargs)
  let name = sx.items[1]
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, formName & " name must be a symbol")
  # Validate the export marker and strip it so the binding is registered under
  # the base name; references always use the bare name, not `name*`.
  let baseName = name.validateExportedDecl(formName & " name")
  # Optional pragma clause immediately after the name.
  var valueIdx = 2
  if nargs == 3:
    if not sx.items[2].isPragmaClause():
      raiseCompilerError(sx.items[2].span, "expected pragma clause between " & formName & " name and value")
    validatePragma(sx.items[2])
    valueIdx = 3
  lowerExpr(ctx, sx.items[valueIdx])
  declare(ctx, newSymbol(baseName, name.span), bkMutable)

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

proc lowerImport(sx: Syntax) =
  expectArity(sx, "import", sx.items.len - 1, 1)
  let module = sx.items[1]
  if module.kind != sxSymbol:
    raiseCompilerError(module.span, "import expects a module symbol")
  if module.sym.len == 0 or module.sym[0] == '/' or module.sym[^1] == '/' or module.sym.contains("//"):
    raiseCompilerError(module.span, "invalid import path")

proc validateFieldName(name: Syntax; what: string): string =
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, what & " must be a symbol")
  if name.sym.contains("*"):
    raiseCompilerError(name.span, what & " cannot use export markers")
  if name.sym.len == 0 or name.sym[0] == '.' or name.sym[^1] == '.' or name.sym.contains(".."):
    raiseCompilerError(name.span, "invalid " & what & ": " & name.sym)
  name.sym

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

proc lowerQuote(sx: Syntax) =
  expectArity(sx, "quote", sx.items.len - 1, 1)

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

proc lowerObjectType(sx: Syntax) =
  if sx.items.len == 1:
    raiseCompilerError(sx.span, "object type expects fields")
  var seen = initTable[string, bool]()
  for field in sx.items.toOpenArray(1, sx.items.high):
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

proc lowerEnumType(sx: Syntax) =
  if sx.items.len == 1:
    raiseCompilerError(sx.span, "enum type expects values")
  var seen = initTable[string, bool]()
  for value in sx.items.toOpenArray(1, sx.items.high):
    if value.kind != sxSymbol:
      raiseCompilerError(value.span, "enum value must be a symbol")
    if value.sym.endsWith("*"):
      raiseCompilerError(value.span, "enum values cannot use export markers; export the enum type instead")
    let key = value.sym
    if seen.hasKey(key):
      raiseCompilerError(value.span, "duplicate enum value: " & key)
    seen[key] = true

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
  if sx.items.len > idx and sx.items[idx].kind == sxVector:
    validateGenericParams(sx.items[idx])
    idx += 1
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
      lowerEnumType(body)
    elif body.items[0].isSymbol("tuple"):
      raiseCompilerError(body.span, "tuple type declarations are not implemented yet")
    elif body.items[0].isSymbol("distinct"):
      raiseCompilerError(body.span, "distinct type declarations are not implemented yet")
    elif body.items[0].isSymbol("ref"):
      raiseCompilerError(body.span, "ref object type declarations are not implemented yet")
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
    elif sx.items[0].isSymbol("let"):
      lowerLetLike(ctx, sx, false)
    elif sx.items[0].isSymbol("var"):
      lowerLetLike(ctx, sx, true)
    elif sx.items[0].isSymbol("set!"):
      lowerSet(ctx, sx)
    elif sx.items[0].isSymbol("do"):
      lowerLambda(ctx, sx)
    elif sx.items[0].isSymbol("proc"):
      raiseCompilerError(sx.span, "proc is only allowed at statement/module scope")
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
    elif sx.items[0].isSymbol(":"):
      raiseCompilerError(sx.span, "named argument marker is only allowed in call argument position")
    elif sx.items[0].isSymbol("defvar") or sx.items[0].isSymbol("defparameter"):
      raiseCompilerError(sx.span, sx.items[0].sym & " is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("const"):
      raiseCompilerError(sx.span, sx.items[0].sym & " is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("import"):
      raiseCompilerError(sx.span, "import is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("quote"):
      lowerQuote(sx)
    elif sx.items[0].isSymbol("quasiquote"):
      raiseCompilerError(sx.span, "runtime quasiquote is not implemented yet")
    elif sx.items[0].isSymbol("pragma"):
      raiseCompilerError(sx.span, "pragma is only allowed as a declaration annotation")
    else:
      lowerCall(ctx, sx)

proc lowerStmt(ctx: var LowerContext; sx: Syntax) =
  if sx.kind == sxList and sx.items.len > 0:
    if sx.items[0].isSymbol("defvar") or sx.items[0].isSymbol("defparameter"):
      lowerDefvar(ctx, sx)
      return
    if sx.items[0].isSymbol("const"):
      lowerConst(ctx, sx)
      return
    if sx.items[0].isSymbol("import"):
      lowerImport(sx)
      return
    if sx.items[0].isSymbol("proc"):
      lowerProc(ctx, sx)
      return
    if sx.items[0].isSymbol("type"):
      lowerTypeDecl(ctx, sx)
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
