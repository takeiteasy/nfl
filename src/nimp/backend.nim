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

proc formName(sx: Syntax): string =
  if sx.kind == sxSymbol: sx.sym else: "form"

proc expectArity(sx: Syntax; name: string; actual, expected: int) =
  if actual != expected:
    raiseCompilerError(sx.span, name & " expects " & $expected & " arguments, got " & $actual)

proc emitExpr(ctx: var EmitContext; sx: Syntax): NimNode
proc emitStmt(ctx: var EmitContext; sx: Syntax): NimNode
proc emitNamedArg(ctx: var EmitContext; sx: Syntax): NimNode

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
  if sx.hygieneId == 0 and sx.sym.contains('.') and sx.sym != ".":
    emitDottedSymbol(sx)
  else:
    ctx.identForSymbol(sx)

proc identForTypeSymbol(sx: Syntax): NimNode =
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, "expected symbol")
  ident(sx.sym).attachLineInfo(sx)

proc exportedIdentForSymbol(sx: Syntax; what: string): NimNode =
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, what & " must be a symbol")
  if sx.sym.endsWith("*"):
    let base = sx.sym[0 ..< sx.sym.high]
    if base.len == 0:
      raiseCompilerError(sx.span, "exported name must have a base name")
    return nnkPostfix.newTree(ident("*"), ident(base).attachLineInfo(sx)).attachLineInfo(sx)
  ident(sx.sym).attachLineInfo(sx)

proc emitTypeReference(sx: Syntax): NimNode =
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, "expected type symbol")
  if sx.sym.contains('.') and sx.sym != ".":
    emitDottedSymbol(sx)
  else:
    identForTypeSymbol(sx)

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
  if binding.kind != sxList or binding.items.len != 2:
    raiseCompilerError(binding.span, "binding must be a pair")
  let target = binding.items[0]
  let value = ctx.emitExpr(binding.items[1])
  if target.kind == sxSymbol:
    return nnkIdentDefs.newTree(ctx.identForSymbol(target), newEmptyNode(), value).attachLineInfo(binding)
  if target.kind == sxList and target.items.len == 2 and target.items[0].kind == sxSymbol and target.items[1].kind == sxSymbol:
    return nnkIdentDefs.newTree(ctx.identForSymbol(target.items[0]), identForTypeSymbol(target.items[1]), value).attachLineInfo(binding)
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
  if param.kind == sxList and param.items.len == 2 and param.items[0].kind == sxSymbol and param.items[1].kind == sxSymbol:
    return nnkIdentDefs.newTree(ctx.identForSymbol(param.items[0]), identForTypeSymbol(param.items[1]), newEmptyNode()).attachLineInfo(param)
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

proc procBodyStart(sx: Syntax): int =
  result = 3
  if sx.items.len > 3 and sx.items[3].kind == sxList and sx.items[3].items.len == 2 and sx.items[3].items[0].isSymbol(":"):
    result = 4

proc emitProc(ctx: var EmitContext; sx: Syntax): NimNode =
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

  var returnType = ident("auto")
  if bodyStart == 4:
    let annotation = sx.items[3].items[1]
    if annotation.kind != sxSymbol:
      raiseCompilerError(annotation.span, "proc return type must be a symbol")
    returnType = identForTypeSymbol(annotation)

  var formalParams = nnkFormalParams.newTree(returnType)
  for param in params.items:
    formalParams.add ctx.emitParam(param)

  nnkProcDef.newTree(
    ctx.identForSymbol(name),
    newEmptyNode(),
    newEmptyNode(),
    formalParams,
    newEmptyNode(),
    newEmptyNode(),
    ctx.emitBodyExpr(sx.items.toOpenArray(bodyStart, sx.items.high), sx)
  ).attachLineInfo(sx)

proc emitDefvar(ctx: var EmitContext; sx: Syntax): NimNode =
  let formName = sx.items[0].sym
  expectArity(sx, formName, sx.items.len - 1, 2)
  let name = sx.items[1]
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, formName & " name must be a symbol")
  nnkVarSection.newTree(nnkIdentDefs.newTree(ctx.identForSymbol(name), newEmptyNode(), ctx.emitExpr(sx.items[2])).attachLineInfo(sx)).attachLineInfo(sx)

proc emitImport(sx: Syntax): NimNode =
  expectArity(sx, "import", sx.items.len - 1, 1)
  nnkImportStmt.newTree(emitModulePath(sx.items[1])).attachLineInfo(sx)

proc emitObjectType(sx: Syntax): NimNode =
  var fields = nnkRecList.newTree().attachLineInfo(sx)
  for field in sx.items.toOpenArray(1, sx.items.high):
    fields.add nnkIdentDefs.newTree(
      exportedIdentForSymbol(field.items[0], "object field name"),
      emitTypeReference(field.items[1]),
      newEmptyNode()
    ).attachLineInfo(field)
  nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), fields).attachLineInfo(sx)

proc emitEnumType(sx: Syntax): NimNode =
  result = nnkEnumTy.newTree(newEmptyNode()).attachLineInfo(sx)
  for value in sx.items.toOpenArray(1, sx.items.high):
    result.add identForTypeSymbol(value)

proc emitTypeBody(sx: Syntax): NimNode =
  if sx.kind == sxSymbol:
    return emitTypeReference(sx)
  if sx.kind == sxList and sx.items.len > 0:
    if sx.items[0].isSymbol("object"):
      return emitObjectType(sx)
    if sx.items[0].isSymbol("enum"):
      return emitEnumType(sx)
  raiseCompilerError(sx.span, "unsupported type declaration")

proc emitTypeDecl(sx: Syntax): NimNode =
  expectArity(sx, "type", sx.items.len - 1, 2)
  nnkTypeSection.newTree(
    nnkTypeDef.newTree(
      exportedIdentForSymbol(sx.items[1], "type name"),
      newEmptyNode(),
      emitTypeBody(sx.items[2])
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
    result = newCall(bindSym"nimpNilDatum").attachLineInfo(sx)
  of sxBool:
    result = newCall(bindSym"nimpBoolDatum", newLit(sx.boolVal)).attachLineInfo(sx)
  of sxInt:
    result = newCall(bindSym"nimpIntDatum", newLit(sx.intVal)).attachLineInfo(sx)
  of sxFloat:
    result = newCall(bindSym"nimpFloatDatum", newLit(sx.floatVal)).attachLineInfo(sx)
  of sxString:
    result = newCall(bindSym"nimpStringDatum", newLit(sx.strVal)).attachLineInfo(sx)
  of sxSymbol:
    result = newCall(bindSym"nimpSymbolDatum", newLit(sx.sym)).attachLineInfo(sx)
  of sxList:
    result = newCall(bindSym"nimpListDatum").attachLineInfo(sx)
    for item in sx.items:
      result.add emitQuotedDatum(item)
  of sxVector:
    result = newCall(bindSym"nimpVectorDatum").attachLineInfo(sx)
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
      ctx.emitLetLike(sx, true)
    elif sx.items[0].isSymbol("set!"):
      ctx.emitSet(sx)
    elif sx.items[0].isSymbol("do"):
      ctx.emitLambda(sx)
    elif sx.items[0].isSymbol("."):
      ctx.emitDot(sx)
    elif sx.items[0].isSymbol("at"):
      ctx.emitAt(sx)
    elif sx.items[0].isSymbol("slice"):
      ctx.emitSlice(sx)
    elif sx.items[0].isSymbol("new"):
      ctx.emitNew(sx)
    elif sx.items[0].isSymbol(":"):
      raiseCompilerError(sx.span, "named argument marker is only allowed in call argument position")
    elif sx.items[0].isSymbol("defvar") or sx.items[0].isSymbol("defparameter"):
      raiseCompilerError(sx.span, sx.items[0].sym & " is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("proc"):
      raiseCompilerError(sx.span, "proc is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("type"):
      raiseCompilerError(sx.span, "type is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("import"):
      raiseCompilerError(sx.span, "import is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("quote"):
      emitQuote(sx)
    elif sx.items[0].isSymbol("quasiquote"):
      raiseCompilerError(sx.span, "runtime quasiquote is not implemented yet")
    else:
      ctx.emitCall(sx)

proc emitStmt(ctx: var EmitContext; sx: Syntax): NimNode =
  if sx.kind == sxNil:
    return newStmtList()
  if sx.kind == sxList and sx.items.len > 0:
    if sx.items[0].isSymbol("if"):
      return ctx.emitIfStmt(sx)
    if sx.items[0].isSymbol("block"):
      result = newStmtList()
      for i in 1 ..< sx.items.len:
        result.add ctx.emitStmt(sx.items[i])
      return
    if sx.items[0].isSymbol("defvar") or sx.items[0].isSymbol("defparameter"):
      return ctx.emitDefvar(sx)
    if sx.items[0].isSymbol("import"):
      return emitImport(sx)
    if sx.items[0].isSymbol("proc"):
      return ctx.emitProc(sx)
    if sx.items[0].isSymbol("type"):
      return emitTypeDecl(sx)
  newCall(bindSym"nimpStmt", ctx.emitExpr(sx)).attachLineInfo(sx)

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
