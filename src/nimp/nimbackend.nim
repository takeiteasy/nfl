import std/macros
import std/os
import std/strutils

import ./diagnostics
import ./syntax

proc isSymbol(sx: Syntax; name: string): bool =
  sx.kind == sxSymbol and sx.sym == name

proc formName(sx: Syntax): string =
  if sx.kind == sxSymbol: sx.sym else: "form"

proc expectArity(sx: Syntax; name: string; actual, expected: int) =
  if actual != expected:
    raiseCompilerError(sx.span, name & " expects " & $expected & " arguments, got " & $actual)

proc emitExpr*(sx: Syntax): NimNode
proc emitStmt*(sx: Syntax): NimNode

proc attachLineInfo(node: NimNode; sx: Syntax): NimNode =
  result = node
  if sx.span.file.len > 0 and sx.span.file[0] != '<' and fileExists(sx.span.file):
    result.setLineInfo(sx.span.file, sx.span.line, sx.span.col)

proc identForSymbol(sx: Syntax): NimNode =
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, "expected symbol")
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

proc emitSymbolRef(sx: Syntax): NimNode =
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, "expected symbol")
  if sx.sym.contains('.') and sx.sym != ".":
    emitDottedSymbol(sx)
  else:
    identForSymbol(sx)

proc identForTypeSymbol(sx: Syntax): NimNode =
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, "expected symbol")
  ident(sx.sym).attachLineInfo(sx)

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

proc emitBodyExpr(items: openArray[Syntax]; owner: Syntax): NimNode =
  if items.len == 0:
    raiseCompilerError(owner.span, "expected body expression")
  if items.len == 1:
    return emitExpr(items[0])
  result = newStmtList()
  for i, item in items:
    if i == items.high:
      result.add emitExpr(item)
    else:
      result.add emitStmt(item)

proc emitBlockExpr(stmts: seq[NimNode]; body: NimNode): NimNode =
  var list = newStmtList()
  for stmt in stmts:
    list.add stmt
  list.add body
  nnkBlockStmt.newTree(newEmptyNode(), list)

proc emitLetLike(sx: Syntax; mutable: bool): NimNode =
  if sx.items.len < 3:
    raiseCompilerError(sx.span, formName(sx.items[0]) & " expects bindings and body")
  let bindings = sx.items[1]
  if bindings.kind != sxList:
    raiseCompilerError(bindings.span, "bindings must be a list")

  var section = if mutable: nnkVarSection.newTree() else: nnkLetSection.newTree()
  for binding in bindings.items:
    if binding.kind != sxList or binding.items.len != 2:
      raiseCompilerError(binding.span, "binding must be a pair")
    let name = binding.items[0]
    if name.kind != sxSymbol:
      raiseCompilerError(name.span, "binding name must be a symbol")
    section.add nnkIdentDefs.newTree(identForSymbol(name), newEmptyNode(), emitExpr(binding.items[1])).attachLineInfo(binding)

  emitBlockExpr(@[section.attachLineInfo(sx)], emitBodyExpr(sx.items.toOpenArray(2, sx.items.high), sx)).attachLineInfo(sx)

proc emitIf(sx: Syntax): NimNode =
  expectArity(sx, "if", sx.items.len - 1, 3)
  nnkIfExpr.newTree(
    nnkElifExpr.newTree(emitExpr(sx.items[1]), emitExpr(sx.items[2])),
    nnkElseExpr.newTree(emitExpr(sx.items[3]))
  ).attachLineInfo(sx)

proc emitIfStmt(sx: Syntax): NimNode =
  expectArity(sx, "if", sx.items.len - 1, 3)
  nnkIfStmt.newTree(
    nnkElifBranch.newTree(emitExpr(sx.items[1]), emitStmt(sx.items[2])),
    nnkElse.newTree(emitStmt(sx.items[3]))
  ).attachLineInfo(sx)

proc emitBegin(sx: Syntax): NimNode =
  if sx.items.len == 1:
    raiseCompilerError(sx.span, "begin expects at least one expression")
  emitBlockExpr(@[], emitBodyExpr(sx.items.toOpenArray(1, sx.items.high), sx)).attachLineInfo(sx)

proc emitSet(sx: Syntax): NimNode =
  expectArity(sx, "set!", sx.items.len - 1, 2)
  nnkAsgn.newTree(identForSymbol(sx.items[1]), emitExpr(sx.items[2])).attachLineInfo(sx)

proc emitParam(param: Syntax): NimNode =
  if param.kind == sxSymbol:
    return nnkIdentDefs.newTree(identForSymbol(param), newEmptyNode(), newEmptyNode()).attachLineInfo(param)
  if param.kind == sxList and param.items.len == 2 and param.items[0].kind == sxSymbol and param.items[1].kind == sxSymbol:
    return nnkIdentDefs.newTree(identForSymbol(param.items[0]), identForTypeSymbol(param.items[1]), newEmptyNode()).attachLineInfo(param)
  raiseCompilerError(param.span, "lambda parameter must be a symbol or (name type)")

proc emitLambda(sx: Syntax): NimNode =
  if sx.items.len < 3:
    raiseCompilerError(sx.span, "lambda expects parameters and body")
  let params = sx.items[1]
  if params.kind != sxList:
    raiseCompilerError(params.span, "lambda parameters must be a list")
  var formalParams = nnkFormalParams.newTree(ident("auto"))
  for param in params.items:
    formalParams.add emitParam(param)
  nnkLambda.newTree(
    newEmptyNode(),
    newEmptyNode(),
    newEmptyNode(),
    formalParams,
    newEmptyNode(),
    newEmptyNode(),
    emitBodyExpr(sx.items.toOpenArray(2, sx.items.high), sx)
  ).attachLineInfo(sx)

proc procBodyStart(sx: Syntax): int =
  result = 3
  if sx.items.len > 3 and sx.items[3].kind == sxList and sx.items[3].items.len == 2 and sx.items[3].items[0].isSymbol(":"):
    result = 4

proc emitProc(sx: Syntax): NimNode =
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
    formalParams.add emitParam(param)

  nnkProcDef.newTree(
    identForSymbol(name),
    newEmptyNode(),
    newEmptyNode(),
    formalParams,
    newEmptyNode(),
    newEmptyNode(),
    emitBodyExpr(sx.items.toOpenArray(bodyStart, sx.items.high), sx)
  ).attachLineInfo(sx)

proc emitDefine(sx: Syntax): NimNode =
  expectArity(sx, "define", sx.items.len - 1, 2)
  let name = sx.items[1]
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, "define name must be a symbol")
  nnkLetSection.newTree(nnkIdentDefs.newTree(identForSymbol(name), newEmptyNode(), emitExpr(sx.items[2])).attachLineInfo(sx)).attachLineInfo(sx)

proc emitImport(sx: Syntax): NimNode =
  expectArity(sx, "import", sx.items.len - 1, 1)
  nnkImportStmt.newTree(emitModulePath(sx.items[1])).attachLineInfo(sx)

proc emitDot(sx: Syntax): NimNode =
  if sx.items.len < 3:
    raiseCompilerError(sx.span, ". expects object and field or method name")
  let name = sx.items[2]
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, ". field or method name must be a symbol")
  let dot = nnkDotExpr.newTree(emitExpr(sx.items[1]), identForSymbol(name)).attachLineInfo(sx)
  if sx.items.len == 3:
    return dot
  result = newCall(dot).attachLineInfo(sx)
  for i in 3 ..< sx.items.len:
    result.add emitExpr(sx.items[i])

proc emitAt(sx: Syntax): NimNode =
  expectArity(sx, "at", sx.items.len - 1, 2)
  result = nnkBracketExpr.newTree(emitExpr(sx.items[1])).attachLineInfo(sx)
  result.add emitExpr(sx.items[2])

proc emitSlice(sx: Syntax): NimNode =
  expectArity(sx, "slice", sx.items.len - 1, 3)
  result = nnkBracketExpr.newTree(emitExpr(sx.items[1])).attachLineInfo(sx)
  result.add nnkInfix.newTree(ident(".."), emitExpr(sx.items[2]), emitExpr(sx.items[3])).attachLineInfo(sx)

proc emitCall(sx: Syntax): NimNode =
  if sx.items.len == 0:
    raiseCompilerError(sx.span, "empty list is not callable")
  var call = newCall(emitSymbolRef(sx.items[0])).attachLineInfo(sx)
  for i in 1 ..< sx.items.len:
    call.add emitExpr(sx.items[i])
  call

proc emitExpr*(sx: Syntax): NimNode =
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
    emitSymbolRef(sx)
  of sxVector:
    var bracket = nnkBracket.newTree()
    for item in sx.items:
      bracket.add emitExpr(item)
    bracket.attachLineInfo(sx)
  of sxList:
    if sx.items.len == 0:
      raiseCompilerError(sx.span, "empty list is not an expression")
    if sx.items[0].isSymbol("if"):
      emitIf(sx)
    elif sx.items[0].isSymbol("begin"):
      emitBegin(sx)
    elif sx.items[0].isSymbol("let"):
      emitLetLike(sx, false)
    elif sx.items[0].isSymbol("var"):
      emitLetLike(sx, true)
    elif sx.items[0].isSymbol("set!"):
      emitSet(sx)
    elif sx.items[0].isSymbol("lambda"):
      emitLambda(sx)
    elif sx.items[0].isSymbol("."):
      emitDot(sx)
    elif sx.items[0].isSymbol("at"):
      emitAt(sx)
    elif sx.items[0].isSymbol("slice"):
      emitSlice(sx)
    elif sx.items[0].isSymbol("define"):
      raiseCompilerError(sx.span, "define is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("proc"):
      raiseCompilerError(sx.span, "proc is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("import"):
      raiseCompilerError(sx.span, "import is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("quote"):
      raiseCompilerError(sx.span, "quote is not implemented yet")
    else:
      emitCall(sx)

proc emitStmt*(sx: Syntax): NimNode =
  if sx.kind == sxNil:
    return newStmtList()
  if sx.kind == sxList and sx.items.len > 0:
    if sx.items[0].isSymbol("if"):
      return emitIfStmt(sx)
    if sx.items[0].isSymbol("begin"):
      result = newStmtList()
      for i in 1 ..< sx.items.len:
        result.add emitStmt(sx.items[i])
      return
    if sx.items[0].isSymbol("define"):
      return emitDefine(sx)
    if sx.items[0].isSymbol("import"):
      return emitImport(sx)
    if sx.items[0].isSymbol("proc"):
      return emitProc(sx)
  emitExpr(sx)

proc emitModule*(forms: seq[Syntax]): NimNode =
  result = newStmtList()
  for form in forms:
    result.add emitStmt(form)
