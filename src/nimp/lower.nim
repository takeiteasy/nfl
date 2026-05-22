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
  if target.kind == sxList and target.items.len == 2 and target.items[0].kind == sxSymbol and target.items[1].kind == sxSymbol:
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
  elif param.kind == sxList and param.items.len == 2 and param.items[0].kind == sxSymbol and param.items[1].kind == sxSymbol:
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

proc procBodyStart(sx: Syntax): int =
  result = 3
  if sx.items.len > 3 and sx.items[3].kind == sxList and sx.items[3].items.len == 2 and sx.items[3].items[0].isSymbol(":"):
    let returnType = sx.items[3].items[1]
    if returnType.kind != sxSymbol:
      raiseCompilerError(returnType.span, "proc return type must be a symbol")
    result = 4

proc lowerProc(ctx: var LowerContext; sx: Syntax) =
  if sx.items.len < 4:
    raiseCompilerError(sx.span, "proc expects name, parameters, and body")
  let name = sx.items[1]
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, "proc name must be a symbol")
  let params = sx.items[2]
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
  declare(ctx, name, bkImmutable)

proc lowerDefine(ctx: var LowerContext; sx: Syntax) =
  expectArity(sx, "define", sx.items.len - 1, 2)
  let name = sx.items[1]
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, "define name must be a symbol")
  lowerExpr(ctx, sx.items[2])
  declare(ctx, name, bkImmutable)

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

proc exportedBaseName(name: Syntax): string =
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, "type name must be a symbol")
  result = name.sym
  if result.endsWith("*"):
    result = result[0 ..< result.high]
    if result.len == 0:
      raiseCompilerError(name.span, "exported name must have a base name")
  if result.contains("*"):
    raiseCompilerError(name.span, "export marker is only allowed at the end of a name")

proc validateTypeReference(sx: Syntax; what: string) =
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
    if field.kind != sxList or field.items.len != 2:
      raiseCompilerError(field.span, "object field must be (name Type)")
    let name = field.items[0]
    if name.kind != sxSymbol:
      raiseCompilerError(name.span, "object field name must be a symbol")
    let key = name.exportedBaseName()
    if seen.hasKey(key):
      raiseCompilerError(name.span, "duplicate object field: " & key)
    seen[key] = true
    validateTypeReference(field.items[1], "object field type")

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
  expectArity(sx, "type", sx.items.len - 1, 2)
  let name = sx.items[1]
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, "type name must be a symbol")
  let declaredName = newSymbol(name.exportedBaseName(), name.span)
  let body = sx.items[2]
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
    elif sx.items[0].isSymbol("define"):
      raiseCompilerError(sx.span, "define is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("import"):
      raiseCompilerError(sx.span, "import is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("quote"):
      lowerQuote(sx)
    elif sx.items[0].isSymbol("quasiquote"):
      raiseCompilerError(sx.span, "runtime quasiquote is not implemented yet")
    else:
      lowerCall(ctx, sx)

proc lowerStmt(ctx: var LowerContext; sx: Syntax) =
  if sx.kind == sxList and sx.items.len > 0:
    if sx.items[0].isSymbol("define"):
      lowerDefine(ctx, sx)
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
