import std/macros
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

proc identForSymbol(sx: Syntax): NimNode =
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, "expected symbol")
  ident(sx.sym)

proc emitModulePath(sx: Syntax): NimNode =
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, "import expects a module symbol")
  let parts = sx.sym.split('/')
  if parts.len == 0:
    raiseCompilerError(sx.span, "invalid import path")
  for part in parts:
    if part.len == 0:
      raiseCompilerError(sx.span, "invalid import path")
  result = ident(parts[0])
  for part in parts[1 .. ^1]:
    result = nnkInfix.newTree(ident("/"), result, ident(part))

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
    section.add nnkIdentDefs.newTree(ident(name.sym), newEmptyNode(), emitExpr(binding.items[1]))

  emitBlockExpr(@[section], emitBodyExpr(sx.items.toOpenArray(2, sx.items.high), sx))

proc emitIf(sx: Syntax): NimNode =
  expectArity(sx, "if", sx.items.len - 1, 3)
  nnkIfExpr.newTree(
    nnkElifExpr.newTree(emitExpr(sx.items[1]), emitExpr(sx.items[2])),
    nnkElseExpr.newTree(emitExpr(sx.items[3]))
  )

proc emitBegin(sx: Syntax): NimNode =
  if sx.items.len == 1:
    raiseCompilerError(sx.span, "begin expects at least one expression")
  emitBlockExpr(@[], emitBodyExpr(sx.items.toOpenArray(1, sx.items.high), sx))

proc emitSet(sx: Syntax): NimNode =
  expectArity(sx, "set!", sx.items.len - 1, 2)
  nnkAsgn.newTree(identForSymbol(sx.items[1]), emitExpr(sx.items[2]))

proc emitParam(param: Syntax): NimNode =
  if param.kind == sxSymbol:
    return nnkIdentDefs.newTree(ident(param.sym), newEmptyNode(), newEmptyNode())
  if param.kind == sxList and param.items.len == 2 and param.items[0].kind == sxSymbol and param.items[1].kind == sxSymbol:
    return nnkIdentDefs.newTree(ident(param.items[0].sym), ident(param.items[1].sym), newEmptyNode())
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
  )

proc emitDefine(sx: Syntax): NimNode =
  expectArity(sx, "define", sx.items.len - 1, 2)
  let name = sx.items[1]
  if name.kind != sxSymbol:
    raiseCompilerError(name.span, "define name must be a symbol")
  nnkLetSection.newTree(nnkIdentDefs.newTree(ident(name.sym), newEmptyNode(), emitExpr(sx.items[2])))

proc emitImport(sx: Syntax): NimNode =
  expectArity(sx, "import", sx.items.len - 1, 1)
  nnkImportStmt.newTree(emitModulePath(sx.items[1]))

proc emitCall(sx: Syntax): NimNode =
  if sx.items.len == 0:
    raiseCompilerError(sx.span, "empty list is not callable")
  var call = newCall(identForSymbol(sx.items[0]))
  for i in 1 ..< sx.items.len:
    call.add emitExpr(sx.items[i])
  call

proc emitExpr*(sx: Syntax): NimNode =
  case sx.kind
  of sxNil:
    newNilLit()
  of sxBool:
    newLit(sx.boolVal)
  of sxInt:
    newLit(sx.intVal)
  of sxFloat:
    newLit(sx.floatVal)
  of sxString:
    newLit(sx.strVal)
  of sxSymbol:
    ident(sx.sym)
  of sxVector:
    var bracket = nnkBracket.newTree()
    for item in sx.items:
      bracket.add emitExpr(item)
    bracket
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
    elif sx.items[0].isSymbol("define"):
      raiseCompilerError(sx.span, "define is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("import"):
      raiseCompilerError(sx.span, "import is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("quote"):
      raiseCompilerError(sx.span, "quote is not implemented yet")
    else:
      emitCall(sx)

proc emitStmt*(sx: Syntax): NimNode =
  if sx.kind == sxList and sx.items.len > 0:
    if sx.items[0].isSymbol("define"):
      return emitDefine(sx)
    if sx.items[0].isSymbol("import"):
      return emitImport(sx)
  emitExpr(sx)

proc emitModule*(forms: seq[Syntax]): NimNode =
  result = newStmtList()
  for form in forms:
    result.add emitStmt(form)
