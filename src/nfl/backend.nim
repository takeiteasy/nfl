## Code generation: turns fully expanded and lowered `Syntax` forms into
## Nim `NimNode` AST via `std/macros`, the final step before the compiler
## macros in `compiler.nim` splice the result into the caller's module.
## Runs after `lower.nim`.

import std/macros
import std/os
import std/strutils
import std/tables

import ./diagnostics
import ./runtime
import ./syntax
import ./synforms

type
  NamedBlockFrame = object
    key: string
    label: NimNode
    carrier: NimNode
      ## The hidden var a `break-from` with a value assigns into before
      ## `break`ing. `nil` while emitting the void branch of a labelled
      ## block's `when …is void` split (see `emitLabelledBlock`) — in that
      ## branch the block produces no value, so a `break-from` with a value
      ## simply discards it.
    isLoop: bool
      ## True for a labelled `while`/`for` frame; false for a named `block`.
      ## `break-from` may only resolve a block frame; `(break :n)` /
      ## `(continue :n)` may only resolve a loop frame — lowering has
      ## already enforced this, so it is only asserted here (see
      ## `findNamedBlock`).
    iterLabel: NimNode
      ## Only set on loop frames: the per-iteration `block` label a
      ## `(continue :n)` targeting this frame compiles to (Nim has no
      ## labelled `continue`). `nil` when nothing inside this loop's body
      ## uses `(continue :n)` on this frame's key — see
      ## `usesLabelledContinue` — in which case the loop's body is emitted
      ## without a per-iteration wrapper at all.

  EmitContext = object
    hygienicSymbols: Table[int, tuple[node: NimNode, kind: NimSymKind]]
    namedBlocks: seq[NamedBlockFrame]
      ## Enclosing named `block`s and labelled loops, innermost last.
      ## Lowering has already validated every `break-from`/labelled
      ## `break`/`continue` target against the parallel stack in
      ## `lower.nim` (including resetting at proc/`do` boundaries), so
      ## backend only needs to look labels up here, not re-validate them.
    bareBreakLabel: NimNode
      ## The Nim label a *bare* `(break)` must target: the innermost
      ## enclosing loop's own wrapper block (see `emitLoopCore`), gensym'd
      ## when that loop has no user-facing `:name`. `nil` outside any loop
      ## (a bare `break` there is a pre-existing Nim compile error, same as
      ## before this field existed) and reset to `nil` at proc/`do`
      ## boundaries, mirroring `namedBlocks`.
      ##
      ## Needed because Nim's *unlabelled* `break` exits the innermost
      ## enclosing `block` OR loop, whichever is lexically nearer — and
      ## NFL's `(block …)` compiles to a real `block:` whenever it appears
      ## in expression position (`emitBegin`/`emitBlockExpr`). Without this,
      ## a bare `(break)` nested inside such a block (e.g. a non-tail item
      ## of `(if … (block (break) …) …)` used as a value) would silently
      ## exit that anonymous block instead of the loop. Always emitting
      ## `break <bareBreakLabel>` targets the loop directly regardless of
      ## any intervening anonymous blocks.

proc isSymbol(sx: Syntax; name: string): bool =
  sx.kind == sxSymbol and sx.sym == name

proc expectArity(sx: Syntax; name: string; actual, expected: int) =
  if actual != expected:
    raiseCompilerError(sx.span, name & " expects " & $expected & " arguments, got " & $actual)

proc emitExpr(ctx: var EmitContext; sx: Syntax): NimNode
proc emitStmt(ctx: var EmitContext; sx: Syntax): NimNode
proc emitNamedArg(ctx: var EmitContext; sx: Syntax): NimNode
proc emitPragma(ctx: var EmitContext; sx: Syntax): NimNode
proc pragmaDeclIdent(ctx: var EmitContext; name: Syntax; pragma: Syntax; what: string;
                      symKind = nskLet): NimNode

proc isNamedArg(sx: Syntax): bool =
  sx.kind == sxList and sx.items.len > 0 and sx.items[0].isSymbol(":")

proc isBreakFromForm(sx: Syntax): bool =
  sx.kind == sxList and sx.items.len > 0 and sx.items[0].isSymbol("break-from")

proc isLoopControlForm(sx: Syntax): bool =
  ## True for a bare or labelled `(break)`/`(break :name)`/`(continue)`/
  ## `(continue :name)` (#54) — like `break-from`, always noreturn from the
  ## enclosing named block's own fallthrough, so `emitNamedBlockBody` must
  ## not try to assign its (nonexistent) value into the block's carrier.
  sx.kind == sxList and sx.items.len > 0 and
    (sx.items[0].isSymbol("break") or sx.items[0].isSymbol("continue"))

proc namedBlockKey(sx: Syntax): string =
  ## Keyed the same way as lower.nim's `symbolKey`, so a hygienic label
  ## introduced by a template expansion can't collide with a user-written
  ## label of the same spelling.
  if sx.hygieneId == 0: sx.blockLabelName
  else: sx.blockLabelName & "\0" & $sx.hygieneId

proc isLoopForm(sx: Syntax): bool =
  sx.kind == sxList and sx.items.len > 0 and
    (sx.items[0].isSymbol("while") or sx.items[0].isSymbol("for"))

proc loopOwnLabelKey(sx: Syntax): string =
  ## The `:name` key of a `(while :name …)`/`(for :name …)` form, or "" when
  ## the loop is unlabelled. Only valid to call when `isLoopForm(sx)` holds.
  if sx.items.len > 1 and sx.items[1].isBlockLabel(): sx.items[1].namedBlockKey()
  else: ""

proc usesLabelledContinue(sx: Syntax; key: string): bool =
  ## True if `(continue :key)` appears anywhere in `sx`, not counting one
  ## inside a nested loop that re-labels the same `key` (shadowing: that
  ## inner `continue` resolves to the inner loop, per lowering's
  ## innermost-frame-wins lookup — see `findLabelFrame` in lower.nim).
  if sx.kind != sxList or sx.items.len == 0:
    return false
  if sx.items[0].isSymbol("continue") and sx.items.len == 2 and
      sx.items[1].isBlockLabel() and sx.items[1].namedBlockKey() == key:
    return true
  if sx.isLoopForm and sx.loopOwnLabelKey() == key:
    return false
  for item in sx.items:
    if item.usesLabelledContinue(key):
      return true
  false

proc usesLabelledContinue(items: openArray[Syntax]; key: string): bool =
  for item in items:
    if item.usesLabelledContinue(key):
      return true
  false

proc noreturnMarker(span: Span): Syntax =
  ## `(quit 1)` — used only inside `typeof(block: …)` (see
  ## `eraseBreakFrom`/`emitLabelledBlock`), so it never actually runs. `quit`
  ## is `{.noreturn.}`, so wherever this sits (an `if`/`case` branch, a
  ## block's own tail, …) it unifies with any sibling branch type, exactly
  ## like the real `break` it stands in for.
  newList(@[newSymbol("quit", span), newInt(1, span)], span)

proc eraseBreakFrom(sx: Syntax; targetKey: string; underLoop: bool = false): Syntax =
  ## Builds the "fallthrough" copy of `sx` for use inside `typeof(block: …)`
  ## when inferring a named block's carrier type (see `emitLabelledBlock`):
  ## every `(break-from :name …)` *targeting `targetKey`* becomes the
  ## `noreturnMarker` above, dropping its value entirely.
  ##
  ## A bare `(break)`/`(continue)` — labelled or not (#54) — gets the same
  ## treatment, but *only* when it is not nested inside a further loop form
  ## within this same body: such a loop-nested one always resolves to that
  ## inner loop (blocks, named or anonymous, never capture bare loop
  ## control — see `EmitContext.bareBreakLabel`), so control returns
  ## normally to whatever follows the inner loop once it exits; it is not
  ## an early exit from *this* named block's flow, and erasing it would
  ## wrongly hide that block's real fallthrough type. `underLoop` tracks
  ## whether the walk has already stepped past such a loop boundary.
  ##
  ## The value is dropped, not inlined, because inlining it here — in the
  ## exact spot the original `break-from` occupied — would force it to
  ## type-unify with whatever *other*, unrelated branch it sits next to
  ## (e.g. an `if`'s other arm), which is wrong: in the real, unerased code
  ## that other arm doesn't need to match, since a real `break` is noreturn
  ## there. A named block's carrier type therefore mainly comes from its own
  ## ordinary fallthrough tail — a `break-from` with a value must already
  ## agree with that type, and if it doesn't, the mismatch still surfaces,
  ## just at the real `carrier = value` assignment in `emitBreakFrom` rather
  ## than here.
  ##
  ## The one exception is the block's own top-level *tail item*: if that is
  ## itself a same-target `break-from` with a value, `emitLabelledBlock`
  ## calls this on the break-from's value directly (not on the whole
  ## break-from node) instead of going through the branch above — it's the
  ## one position with no sibling to unify against, so inlining the value
  ## there is both safe and necessary (a bare `(block :b (break-from :b 5))`
  ## has no *other* fallthrough to tell `typeof` it's `int`).
  ##
  ## A `break-from` targeting a *different*, enclosing label is left
  ## completely alone (recursed into normally) — it is still emitted for
  ## real when this copy itself is emitted, and resolves against that
  ## ancestor's still-active real frame, since building this copy happens
  ## nested inside the ancestor's own real emission. The same goes for
  ## nested `(block :other …)` forms: left fully intact, recursed into with
  ## the same `targetKey`, and emitted by the ordinary recursive
  ## `emitLabelledBlock` machinery when the copy is emitted.
  case sx.kind
  of sxList:
    if sx.isBreakFromForm() and sx.items[1].namedBlockKey() == targetKey:
      return noreturnMarker(sx.span)
    if not underLoop and sx.items.len > 0 and
        (sx.items[0].isSymbol("break") or sx.items[0].isSymbol("continue")):
      return noreturnMarker(sx.span)
    let childUnderLoop = underLoop or sx.isLoopForm()
    var newItems: seq[Syntax] = @[]
    for item in sx.items:
      newItems.add eraseBreakFrom(item, targetKey, childUnderLoop)
    newList(newItems, sx.span)
  of sxVector:
    var newItems: seq[Syntax] = @[]
    for item in sx.items:
      newItems.add eraseBreakFrom(item, targetKey, underLoop)
    newVector(newItems, sx.span)
  else:
    sx

proc attachLineInfo(node: NimNode; sx: Syntax): NimNode =
  result = node
  if sx.span.file.len > 0 and sx.span.file[0] != '<' and fileExists(sx.span.file):
    result.setLineInfo(sx.span.file, sx.span.line, sx.span.col)

proc findNamedBlock(ctx: EmitContext; target: Syntax): NamedBlockFrame =
  ## Looks up the frame for a `break-from`/labelled `break`/`continue`
  ## target. Lowering has already validated every target resolves to an
  ## enclosing frame of the right kind, so a miss here would mean a
  ## lowering/backend mismatch, not a user error.
  let key = target.namedBlockKey()
  for i in countdown(ctx.namedBlocks.high, 0):
    if ctx.namedBlocks[i].key == key:
      return ctx.namedBlocks[i]
  raiseCompilerError(target.span, "internal error: label target not found: " & target.sym)

proc labelIdent(labelSx: Syntax): NimNode =
  ## A `:name` label is never a hygiene-rename target — `hygienicRename`
  ## (expand.nim) only renames let/var/do-param/for-loop binding targets, so
  ## `labelSx.hygieneId` is always 0 here — unlike `identForSymbol`, this
  ## needs no genSym-and-cache path for a hygienic case that can't occur.
  ident(labelSx.blockLabelName).attachLineInfo(labelSx)

proc plainIntLit(v: BiggestInt): NimNode =
  ## `newLit` on a `BiggestInt` yields an `nnkInt64Lit`, which Nim types as a
  ## concrete `int64` rather than an untyped integer literal — that
  ## suppresses literal narrowing, converter matching and generic inference.
  ## Build the node directly so NFL integer literals behave like ordinary
  ## Nim integer literals.
  result = nnkIntLit.newNimNode()
  result.intVal = v

proc plainFloatLit(v: BiggestFloat): NimNode =
  ## See `plainIntLit` — same reasoning for float literals.
  result = nnkFloatLit.newNimNode()
  result.floatVal = v

proc identForSymbol(ctx: var EmitContext; sx: Syntax; symKind = nskLet): NimNode =
  ## `symKind` is only consulted the first time a given `hygieneId` is seen
  ## (i.e. at its declaration site) — it picks the Nim symbol kind the
  ## `genSym` is created with, so a hygienic/gensym'd symbol declared as a
  ## `proc`/`do` parameter emits `nskParam` (see #81; a `let`-kind symbol in
  ## `nnkFormalParams` position is a hard Nim error, "cannot use symbol of
  ## kind 'let' as a 'param'") and one declared as a `for` binding emits
  ## `nskForVar` (see #82; likewise a hard error, "cannot use symbol of kind
  ## 'let' as a 'forVar'") instead of the default `nskLet`.
  ## `except Type as e` bindings deliberately keep the `nskLet` default —
  ## audited under #82: Nim has no dedicated except-binding symbol kind, and
  ## `nskLet` is what it accepts there, so `emitExceptBranch` passes no
  ## `symKind` and needs no change.
  ## Reference sites pass no `symKind` and must resolve to the exact same
  ## Nim symbol as the declaration, so the cache is keyed on `hygieneId`
  ## alone and defaults `symKind` to `nskLet`. That default means a
  ## reference-site call is indistinguishable from a *declaration* that
  ## legitimately wants `nskLet` (a `let`/`var`/`except` binding) — only a
  ## non-`nskLet` declaration (currently `nskParam`/`nskForVar`) reaching an
  ## id already cached under a different kind is caught below and raises;
  ## the `nskLet` direction passes through silently. This asymmetric guard
  ## is not currently known to be reachable either way: every `hygieneId`
  ## is unique per hygiene-rename or `gensym` call, so two declaration
  ## sites sharing one id should never occur. For `for` bindings specifically,
  ## `emitForCore` always adds the binding to the `nnkForStmt` before emitting
  ## the iterable or body, so no reference site can seed the cache with
  ## `nskLet` ahead of the `nskForVar` declaration.
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, "expected symbol")
  if sx.hygieneId != 0:
    if not ctx.hygienicSymbols.hasKey(sx.hygieneId):
      ctx.hygienicSymbols[sx.hygieneId] = (genSym(symKind, sx.sym), symKind)
    let entry = ctx.hygienicSymbols[sx.hygieneId]
    if entry.kind != symKind and symKind != nskLet:
      raiseCompilerError(sx.span,
        "internal error: hygienic symbol " & sx.sym & " declared with conflicting kinds")
    return entry.node.copyNimTree().attachLineInfo(sx)
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

proc declIdent(ctx: var EmitContext; sx: Syntax; what: string; allowOperator = false;
                symKind = nskLet): NimNode =
  ## Build the declaration-site identifier for a symbol, handling both the
  ## export postfix (`name*` → `nnkPostfix(*, ident(name))`) and hygiene.
  ## Hygienic symbols cannot carry `*` — they have no stable public name.
  ## Mirrors lower.nim's `validateExportedDecl`; see `splitExportMarker`
  ## (syntax.nim) for the marker/operator/escape rules. A plain
  ## `ident(...)` node is emitted for operator names either way — Nim's
  ## parser tokenizes any run of operator characters as a single operator,
  ## so no `nnkAccQuoted` wrapping is needed at the declaration site
  ## (verified: `nnkProcDef` with a plain `ident("+")` name, including
  ## multi-char and exported forms, compiles and is callable infix).
  ## `symKind` is forwarded to `identForSymbol` — see its doc comment; callers
  ## outside a `var`/`const` section leave it at the `nskLet` default.
  if sx.kind != sxSymbol:
    raiseCompilerError(sx.span, what & " must be a symbol")
  let (base, exported, err) = splitExportMarker(sx.sym, sx.escaped, allowOperator)
  if err.len > 0:
    raiseCompilerError(sx.span, err)
  if exported:
    if sx.hygieneId != 0:
      raiseCompilerError(sx.span, "exported name cannot be a hygienic symbol")
    return nnkPostfix.newTree(
      ident("*"),
      ident(base).attachLineInfo(sx)
    ).attachLineInfo(sx)
  if allowOperator and sx.sym.isOperatorName:
    return ident(base).attachLineInfo(sx)
  ctx.identForSymbol(sx, symKind)

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

proc isDeferForm(sx: Syntax): bool =
  sx.kind == sxList and sx.items.len > 0 and sx.items[0].isSymbol("defer")

proc emitBodyExpr(ctx: var EmitContext; items: openArray[Syntax]; owner: Syntax): NimNode =
  if items.len == 0:
    raiseCompilerError(owner.span, "expected body expression")
  # A trailing `defer` cannot be routed through emitExpr — `defer` is
  # statement-only — so a body ending in `defer` emits entirely as
  # statements instead of expression-tailing the last item. This is what
  # makes `(proc f () (open h) (defer (close h)))` work: the ergonomic,
  # most natural way to write scope-exit cleanup as the last form in a body.
  if items[items.high].isDeferForm():
    result = newStmtList()
    for item in items:
      result.add ctx.emitStmt(item)
    return
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

proc emitBreakFrom(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits `(break-from :name)` / `(break-from :name expr)`: assigns into
  ## the target named block's carrier var (if it has one — see
  ## `NamedBlockFrame.carrier`) and `break`s to its label. Always builds a
  ## small statement list; expression-position callers wrap it (see the
  ## `emitExpr` dispatch), since a `break` is noreturn and must type-unify
  ## with whatever the use site expects rather than being forced to a
  ## concrete type.
  let frame = ctx.findNamedBlock(sx.items[1])
  result = newStmtList()
  if sx.items.len == 3:
    let valueNode = ctx.emitExpr(sx.items[2])
    if frame.carrier != nil:
      result.add nnkAsgn.newTree(frame.carrier.copyNimTree(), valueNode).attachLineInfo(sx)
    else:
      result.add nnkDiscardStmt.newTree(valueNode).attachLineInfo(sx)
  result.add nnkBreakStmt.newTree(frame.label.copyNimTree()).attachLineInfo(sx)

proc emitBreak(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits `(break)` — targets `ctx.bareBreakLabel`, the innermost enclosing
  ## loop's own wrapper block (see `EmitContext.bareBreakLabel`) — or
  ## `(break :name)`, which targets the named loop frame's label directly.
  let nargs = sx.items.len - 1
  let label =
    if nargs == 0: ctx.bareBreakLabel
    else: ctx.findNamedBlock(sx.items[1]).label.copyNimTree()
  nnkBreakStmt.newTree(if label == nil: newEmptyNode() else: label).attachLineInfo(sx)

proc emitContinue(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits `(continue)` — Nim's own unlabelled `continue` always targets the
  ## nearest enclosing loop, even through an intervening anonymous `block`,
  ## so this needs no special-casing (unlike bare `break` — see
  ## `EmitContext.bareBreakLabel`). `(continue :name)` targets the named
  ## loop frame's per-iteration block (`iterLabel`) as a `break`, since Nim
  ## has no labelled `continue`.
  let nargs = sx.items.len - 1
  if nargs == 0:
    return nnkContinueStmt.newTree(newEmptyNode()).attachLineInfo(sx)
  nnkBreakStmt.newTree(ctx.findNamedBlock(sx.items[1]).iterLabel.copyNimTree()).attachLineInfo(sx)

proc emitNamedBlockBody(ctx: var EmitContext; items: openArray[Syntax]; carrier: NimNode): NimNode =
  ## Emits the inside of a labelled block's `block LBL: …`. Every non-tail
  ## item — and every `break-from`/bare or labelled `break`/`continue`
  ## (#54), wherever it appears — emits as a plain statement (a
  ## `break-from` assigns its own value into `carrier`, if any, and breaks;
  ## see `emitBreakFrom`; a bare/labelled `break`/`continue` never produces
  ## a value at all, and always exits past this block, per
  ## `isLoopControlForm`). The true tail item, when `carrier` is non-nil and
  ## the tail is neither of those, additionally assigns its expression
  ## value into `carrier`.
  result = newStmtList()
  for i, item in items:
    if i == items.high and carrier != nil and not item.isBreakFromForm() and
        not item.isLoopControlForm():
      result.add nnkAsgn.newTree(carrier, ctx.emitExpr(item)).attachLineInfo(item)
    else:
      result.add ctx.emitStmt(item)

proc emitNamedBlockBranch(ctx: var EmitContext; bodyItems: openArray[Syntax]; owner: Syntax;
                           key: string; label: NimNode; typeProbe: NimNode): NimNode =
  ## Builds one branch of a labelled block: `typeProbe == nil` selects the
  ## void branch (no carrier var, just `block LBL: …`); otherwise builds
  ## `block: var TMP: typeProbe; block LBL: …; TMP`.
  let carrier = if typeProbe == nil: nil else: genSym(nskVar, "carry")
  ctx.namedBlocks.add NamedBlockFrame(key: key, label: label, carrier: carrier)
  let inner = ctx.emitNamedBlockBody(bodyItems, carrier)
  discard ctx.namedBlocks.pop()
  let blockStmt = nnkBlockStmt.newTree(label.copyNimTree(), inner).attachLineInfo(owner)
  if carrier == nil:
    return blockStmt
  let varSection = nnkVarSection.newTree(
    nnkIdentDefs.newTree(carrier, typeProbe, newEmptyNode())).attachLineInfo(owner)
  emitBlockExpr(@[varSection, blockStmt], carrier.copyNimTree())

proc emitLabelledBlock(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits `(block :name body…)`. Nim's `break lbl` carries no value, so a
  ## `break-from` with a value stashes it in a hidden var (the carrier)
  ## before breaking; the block's trailing expression then reads that var.
  ##
  ## The carrier's type is inferred with `typeof` over the body's ordinary
  ## fallthrough — a copy with every same-target `break-from` replaced
  ## in-place by a noreturn marker (`eraseBreakFrom`), preserving the
  ## body's exact lexical structure (so e.g. a `break-from` reading a `for`
  ## loop's own variable still resolves inside the copy) and letting Nim's
  ## ordinary noreturn-branch exemption do the rest, exactly as it does for
  ## the real, unerased code. This never runs — it's only used inside
  ## `typeof` — so side effects in the body are irrelevant, and the copy's
  ## own block-local bindings stay in scope for it since it's a structural
  ## copy, not a hoisted one.
  ##
  ## A `var TMP: typeof(…)` where that type is `void` is illegal in Nim, so
  ## this always guards with `when …is void` and skips the carrier var
  ## entirely in that branch — needed even in `emitExpr`'s call site
  ## (`emitBegin`), since NFL emits every proc's tail expression through
  ## `emitExpr` regardless of whether the proc has an explicit (possibly
  ## void) return type; the `auto` return type then infers void from
  ## whichever branch `when` actually selects, same as a plain (unlabelled)
  ## void-tailed block already relies on.
  let labelSx = sx.items[1]
  let bodyItems = sx.items[2 .. ^1]
  let label = labelIdent(labelSx)
  let key = labelSx.namedBlockKey()
  var copyItems: seq[Syntax] = @[]
  for i, item in bodyItems:
    # The block's own top-level tail is the one position with no sibling
    # branch to unify against, so — unlike everywhere else — it's safe (and
    # necessary) to inline a same-target break-from's *value* there instead
    # of the noreturn marker: a bare `(block :b (break-from :b 5))`, with no
    # other fallthrough at all, has no other way to tell `typeof` it's `int`.
    if i == bodyItems.high and item.isBreakFromForm() and
        item.items[1].namedBlockKey() == key and item.items.len == 3:
      copyItems.add eraseBreakFrom(item.items[2], key)
    else:
      copyItems.add eraseBreakFrom(item, key)

  proc typeProbe(ctx: var EmitContext): NimNode =
    nnkCall.newTree(ident("typeof"),
      emitBlockExpr(@[], ctx.emitBodyExpr(copyItems, sx))).attachLineInfo(sx)

  let isVoidCheck = nnkInfix.newTree(ident("is"), ctx.typeProbe(), ident("void")).attachLineInfo(sx)
  let voidBranch = ctx.emitNamedBlockBranch(bodyItems, sx, key, label, nil)
  let valueBranch = ctx.emitNamedBlockBranch(bodyItems, sx, key, label, ctx.typeProbe())
  nnkWhenStmt.newTree(
    nnkElifBranch.newTree(isVoidCheck, voidBranch),
    nnkElse.newTree(valueBranch)).attachLineInfo(sx)

proc emitPatternIdentDefs(ctx: var EmitContext; pattern: Syntax; valueNode: NimNode; symKind: NimSymKind; defs: var seq[NimNode]) =
  ## Emits a hidden temp (`genSym`) bound to `valueNode`, plus one
  ## `nnkIdentDefs` per pattern name indexing — or, for a `& rest` capture,
  ## slicing — into that temp; an object pattern (#47) instead dot-accesses
  ## each named field. A nested pattern recurses with a fresh temp bound to
  ## its element's accessor expression. Mirrors lower.nim's `validatePattern`,
  ## which runs first in the normal compiler pipeline (`nflModule`/`nflExpr`)
  ## and rejects malformed shapes; this assumes a valid pattern, the same
  ## division of labor `emitNew` and `lowerNew` use for field-initializer
  ## shape.
  ##
  ## `symKind` picks the temp's genSym kind to match the enclosing section
  ## (`nnkVarSection`, `nnkLetSection`, or `nnkConstSection`) — Nim rejects
  ## mixing a `genSym`'d symbol's declared kind with a different section
  ## kind.
  if pattern.items.len == 0:
    raiseCompilerError(pattern.span, "destructuring pattern must not be empty")
  let tmp = genSym(symKind, "d")
  defs.add nnkIdentDefs.newTree(tmp, newEmptyNode(), valueNode).attachLineInfo(pattern)
  if pattern.isObjectPattern():
    var i = 0
    while i < pattern.items.len:
      let key = pattern.items[i]
      let field = key.sym[1 .. ^1]
      let accessor = nnkDotExpr.newTree(tmp.copyNimTree(), ident(field)).attachLineInfo(key)
      if i + 1 < pattern.items.len and not pattern.items[i + 1].isKeywordSym():
        let elem = pattern.items[i + 1]
        if elem.kind == sxSymbol:
          if elem.sym != "_":
            defs.add nnkIdentDefs.newTree(ctx.identForSymbol(elem, symKind), newEmptyNode(), accessor).attachLineInfo(elem)
        else:
          ctx.emitPatternIdentDefs(elem, accessor, symKind, defs)
        i += 2
      else:
        defs.add nnkIdentDefs.newTree(ctx.identForSymbol(newSymbol(field, key.span), symKind), newEmptyNode(), accessor).attachLineInfo(key)
        i += 1
    return
  var restIdx = -1
  for i, elem in pattern.items:
    if elem.kind == sxSymbol and elem.sym == "&":
      restIdx = i
      break
  let headCount = if restIdx >= 0: restIdx else: pattern.items.len
  for i in 0 ..< headCount:
    let elem = pattern.items[i]
    let accessor = nnkBracketExpr.newTree(tmp.copyNimTree(), newLit(i)).attachLineInfo(elem)
    if elem.kind == sxSymbol:
      if elem.sym != "_":
        defs.add nnkIdentDefs.newTree(ctx.identForSymbol(elem, symKind), newEmptyNode(), accessor).attachLineInfo(elem)
    elif elem.kind == sxVector:
      ctx.emitPatternIdentDefs(elem, accessor, symKind, defs)
    else:
      raiseCompilerError(elem.span, "destructuring pattern element must be a symbol, _, or a nested vector pattern")
  if restIdx >= 0 and restIdx + 1 <= pattern.items.high:
    let restName = pattern.items[restIdx + 1]
    if restName.kind == sxSymbol and restName.sym != "_":
      let sliceNode = nnkBracketExpr.newTree(
        tmp.copyNimTree(),
        nnkInfix.newTree(ident(".."), newLit(headCount), nnkPrefix.newTree(ident("^"), newLit(1)))
      ).attachLineInfo(pattern)
      defs.add nnkIdentDefs.newTree(ctx.identForSymbol(restName, symKind), newEmptyNode(), sliceNode).attachLineInfo(pattern)

proc emitBindingIdentDefs(ctx: var EmitContext; binding: Syntax; mutable: bool): seq[NimNode] =
  if binding.kind != sxList or binding.items.len notin {2, 3}:
    raiseCompilerError(binding.span, "binding must be a pair or annotated triple")
  let target = binding.items[0]
  # Optional pragma clause at items[1] for annotated bindings `(target {.p.} value)`.
  var pragma: Syntax = nil
  if binding.items.len == 3:
    pragma = binding.items[1]
  let value = ctx.emitExpr(binding.items[binding.items.high])
  let symKind = if mutable: nskVar else: nskLet
  if target.kind == sxSymbol:
    return @[nnkIdentDefs.newTree(
      ctx.pragmaDeclIdent(target, pragma, "binding name", symKind),
      newEmptyNode(),
      value
    ).attachLineInfo(binding)]
  if target.kind == sxList and target.items.len == 2 and target.items[0].kind == sxSymbol and
      (target.items[1].kind == sxSymbol or target.items[1].kind == sxVector):
    return @[nnkIdentDefs.newTree(
      ctx.pragmaDeclIdent(target.items[0], pragma, "binding name", symKind),
      emitTypeRef(target.items[1]),
      value
    ).attachLineInfo(binding)]
  if target.kind == sxVector:
    if pragma != nil:
      raiseCompilerError(pragma.span, "destructuring pattern cannot carry a pragma clause")
    var defs: seq[NimNode] = @[]
    ctx.emitPatternIdentDefs(target, value, (if mutable: nskVar else: nskLet), defs)
    return defs
  raiseCompilerError(target.span, "binding name must be a symbol or (name type), or a destructuring pattern")

proc emitLetLike(ctx: var EmitContext; sx: Syntax; mutable: bool): NimNode =
  if sx.items.len < 3:
    raiseCompilerError(sx.span, formName(sx.items[0]) & " expects bindings and body")
  let bindings = sx.items[1]
  if bindings.kind != sxList:
    raiseCompilerError(bindings.span, "bindings must be a list")

  var section = if mutable: nnkVarSection.newTree() else: nnkLetSection.newTree()
  for binding in bindings.items:
    for identDefs in ctx.emitBindingIdentDefs(binding, mutable):
      section.add identDefs

  emitBlockExpr(@[section.attachLineInfo(sx)], ctx.emitBodyExpr(sx.items.toOpenArray(2, sx.items.high), sx)).attachLineInfo(sx)

proc emitSectionBindingIdentDefs(ctx: var EmitContext; binding: Syntax; mutable: bool): seq[NimNode] =
  ## Mirrors lower.nim's sectionBindingParts. Unlike emitBindingIdentDefs
  ## (used by the local mutable-binding form, which always requires a
  ## value), a `var` section binding may omit the value when the target
  ## carries an explicit type — the value slot is then emitted empty
  ## (zero-initialized), matching emitVarDecl's single-declaration behavior.
  ## `const` sections always require a value. `target` may also (#47) be a
  ## destructuring pattern, in which case every identDefs the pattern binds
  ## is returned — a pattern target never carries a type, so it always
  ## requires a value.
  if binding.kind != sxList or binding.items.len notin {1, 2, 3}:
    raiseCompilerError(binding.span, "binding must be a target, optional pragma, and optional value")
  let target = binding.items[0]
  var nameSx: Syntax
  var typeIdent: NimNode = newEmptyNode()
  var hasType = false
  var isPattern = false
  if target.kind == sxSymbol:
    nameSx = target
  elif target.kind == sxList and target.items.len == 2 and target.items[0].kind == sxSymbol and
      (target.items[1].kind == sxSymbol or target.items[1].kind == sxVector):
    nameSx = target.items[0]
    typeIdent = emitTypeRef(target.items[1])
    hasType = true
  elif target.kind == sxVector:
    isPattern = true
  else:
    raiseCompilerError(target.span, "binding name must be a symbol or (name type), or a destructuring pattern")
  var pragma: Syntax = nil
  var valueIdx = -1
  if binding.items.len == 2:
    if binding.items[1].isPragmaClause():
      if isPattern:
        raiseCompilerError(binding.items[1].span, "destructuring pattern cannot carry a pragma clause")
      pragma = binding.items[1]
    else:
      valueIdx = 1
  elif binding.items.len == 3:
    if isPattern:
      raiseCompilerError(binding.items[1].span, "destructuring pattern cannot carry a pragma clause")
    pragma = binding.items[1]
    valueIdx = 2
  if valueIdx < 0:
    if not mutable:
      raiseCompilerError(binding.span, "const section binding requires a value")
    if not hasType:
      raiseCompilerError(binding.span, "var section binding without a type annotation requires a value")
  let valueNode = if valueIdx >= 0: ctx.emitExpr(binding.items[valueIdx]) else: newEmptyNode()
  if isPattern:
    var defs: seq[NimNode] = @[]
    ctx.emitPatternIdentDefs(target, valueNode, (if mutable: nskVar else: nskConst), defs)
    return defs
  @[nnkIdentDefs.newTree(
    ctx.pragmaDeclIdent(nameSx, pragma, "binding name", (if mutable: nskVar else: nskConst)),
    typeIdent,
    valueNode
  ).attachLineInfo(binding)]

proc emitVarSection(ctx: var EmitContext; sx: Syntax; mutable: bool): NimNode =
  let bindings = sx.items[1]
  if bindings.kind != sxList or bindings.items.len == 0:
    raiseCompilerError(bindings.span, formName(sx.items[0]) & " section expects at least one binding")
  var section = if mutable: nnkVarSection.newTree() else: nnkConstSection.newTree()
  for binding in bindings.items:
    for identDefs in ctx.emitSectionBindingIdentDefs(binding, mutable):
      if mutable:
        section.add identDefs
      else:
        # const sections use nnkConstDef rather than nnkIdentDefs; reuse the
        # same (name, type, value) children emitSectionBindingIdentDefs built.
        section.add nnkConstDef.newTree(
          identDefs[0], identDefs[1], identDefs[2]
        ).attachLineInfo(binding)
  section.attachLineInfo(sx)

proc emitIfBranchExpr(ctx: var EmitContext; branch: Syntax): NimNode =
  ## Emits one `if`-expression branch. A literal `nil` branch — the
  ## established idiom for the dead branch of a statement-shaped `if` (e.g.
  ## the core `when` macro's `(if test (block …) nil)`) — emits as
  ## `discard`, giving the branch type `void` rather than `typeof(nil)`. A
  ## bare `nnkNilLit` there previously unified against the other branch's
  ## type (or against `void`/noreturn, e.g. `(if c (raise …) nil)`), which
  ## crashed the Nim compiler with `getTypeDescAux(tyAnything)` (#73).
  if branch.kind == sxNil:
    nnkDiscardStmt.newTree(newEmptyNode()).attachLineInfo(branch)
  else:
    ctx.emitExpr(branch)

proc emitIf(ctx: var EmitContext; sx: Syntax): NimNode =
  expectArity(sx, "if", sx.items.len - 1, 3)
  nnkIfExpr.newTree(
    nnkElifExpr.newTree(ctx.emitExpr(sx.items[1]), ctx.emitIfBranchExpr(sx.items[2])),
    nnkElseExpr.newTree(ctx.emitIfBranchExpr(sx.items[3]))
  ).attachLineInfo(sx)

proc emitIfStmt(ctx: var EmitContext; sx: Syntax): NimNode =
  expectArity(sx, "if", sx.items.len - 1, 3)
  nnkIfStmt.newTree(
    nnkElifBranch.newTree(ctx.emitExpr(sx.items[1]), ctx.emitStmt(sx.items[2])),
    nnkElse.newTree(ctx.emitStmt(sx.items[3]))
  ).attachLineInfo(sx)

proc emitStaticWhen(ctx: var EmitContext; sx: Syntax): NimNode =
  ## `(static-when (test body…)… [(else body…)])` (#32), expression
  ## position — requires an `else` clause (enforced by
  ## `parseStaticWhenClauses`, shared with `lower.nim`); a `when` with no
  ## matching branch has no value. Each branch wraps its body the same way
  ## `emitBegin`/`emitLabelledBlock` do: an `nnkBlockStmt` around
  ## `emitBodyExpr`, so the branch's value is its last form.
  let clauses = parseStaticWhenClauses(sx, requireElse = true)
  result = nnkWhenStmt.newTree()
  for clause in clauses:
    let branchValue = emitBlockExpr(@[], ctx.emitBodyExpr(clause.body, sx))
    if clause.isElse:
      result.add nnkElse.newTree(branchValue)
    else:
      result.add nnkElifBranch.newTree(ctx.emitExpr(clause.test), branchValue)
  result = result.attachLineInfo(sx)

proc emitStaticWhenStmt(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Statement/module position of `static-when` (#32) — `else` is optional;
  ## an all-false `when` with no `else` simply contributes nothing, exactly
  ## like Nim's own `when` at statement scope.
  let clauses = parseStaticWhenClauses(sx, requireElse = false)
  result = nnkWhenStmt.newTree()
  for clause in clauses:
    var branchStmts = newStmtList()
    for form in clause.body:
      branchStmts.add ctx.emitStmt(form)
    if clause.isElse:
      result.add nnkElse.newTree(branchStmts)
    else:
      result.add nnkElifBranch.newTree(ctx.emitExpr(clause.test), branchStmts)
  result = result.attachLineInfo(sx)

proc emitBegin(ctx: var EmitContext; sx: Syntax): NimNode =
  if sx.items.len == 1:
    raiseCompilerError(sx.span, "block expects at least one expression")
  if sx.items[1].isBlockLabel():
    return ctx.emitLabelledBlock(sx)
  emitBlockExpr(@[], ctx.emitBodyExpr(sx.items.toOpenArray(1, sx.items.high), sx)).attachLineInfo(sx)

proc checkProgNArity(sx: Syntax; captureIdx: int; formName: string) =
  let minArgs = captureIdx + 1
  let nargs = sx.items.len - 1
  if nargs < minArgs:
    raiseCompilerError(sx.span,
      formName & " expects at least " & $minArgs & " argument(s), got " & $nargs)

proc emitProgN(ctx: var EmitContext; sx: Syntax; captureIdx: int; formName: string): NimNode =
  ## Emits `(prog1 expr rest…)` (captureIdx 0) / `(prog2 e1 e2 rest…)`
  ## (captureIdx 1): sequences the body as statements, in order, capturing
  ## the `captureIdx`'th form's value into a hidden `let` where it occurs
  ## and yielding that as the tail expression. Unlike `break-from`'s carrier
  ## (see `emitLabelledBlock`), the capture is read in straight-line
  ## position, not from a jump target, so no `typeof`/non-local-exit
  ## handling is needed — the `let`'s own initializer gives it a type.
  checkProgNArity(sx, captureIdx, formName)
  let carrier = genSym(nskLet, formName)
  var stmts: seq[NimNode] = @[]
  for i in 1 ..< sx.items.len:
    let item = sx.items[i]
    if i - 1 == captureIdx:
      stmts.add nnkLetSection.newTree(
        nnkIdentDefs.newTree(carrier, newEmptyNode(), ctx.emitExpr(item))).attachLineInfo(item)
    else:
      stmts.add ctx.emitStmt(item)
  emitBlockExpr(stmts, carrier.copyNimTree()).attachLineInfo(sx)

proc emitSet(ctx: var EmitContext; sx: Syntax): NimNode =
  ## See `lowerSet` (lower.nim) for the accepted target shapes; lowering has
  ## already validated the target, so this only needs to pick the right Nim
  ## AST shape per case. `(. o f)`/`(at s i)`/`(slice s a b)` all emit
  ## straight through `emitExpr` into `nnkAsgn` over the matching
  ## `nnkDotExpr`/`nnkBracketExpr` node (verified against Nim: assignment to
  ## any of those, including a `.`-getter name that resolves to a setter
  ## proc, works even when the base is a `let`-bound `ref object`). An
  ## accessor call target is different: `nnkAsgn` over an `nnkCall` LHS does
  ## NOT compile ("cannot be assigned to" — verified), so it must instead
  ## be emitted as an explicit call on the derived `` `f=` `` setter name.
  expectArity(sx, "set!", sx.items.len - 1, 2)
  let target = sx.items[1]
  let value = ctx.emitExpr(sx.items[2])
  if target.kind == sxList and target.items.len > 0 and target.items[0].kind == sxSymbol and
      not target.items[0].isSymbol(".") and not target.items[0].isSymbol("at") and
      not target.items[0].isSymbol("slice"):
    result = newCall(nnkAccQuoted.newTree(ident(target.items[0].sym), ident("=")).attachLineInfo(target.items[0])).attachLineInfo(sx)
    for i in 1 ..< target.items.len:
      result.add ctx.emitExpr(target.items[i])
    result.add value
    return result
  nnkAsgn.newTree(ctx.emitExpr(target), value).attachLineInfo(sx)

proc emitParam(ctx: var EmitContext; param: Syntax; patternDefs: var seq[NimNode]): NimNode =
  ## Emits one `nnkIdentDefs` for the formal-params list. A destructured
  ## parameter (#47) — `([a b] Point)` — instead emits a synthetic gensym'd
  ## carrier param and appends the pattern's accessor `nnkIdentDefs` to
  ## `patternDefs`, for the caller to assemble into a body-prelude
  ## `nnkLetSection` (see `emitLambda`/`emitRoutine`).
  if param.kind == sxSymbol:
    return nnkIdentDefs.newTree(ctx.identForSymbol(param, nskParam), newEmptyNode(), newEmptyNode()).attachLineInfo(param)
  if param.kind == sxList and param.items.len in [2, 3] and param.items[0].kind == sxSymbol and
      (param.items[1].kind == sxSymbol or param.items[1].kind == sxVector):
    let default = if param.items.len == 3: ctx.emitExpr(param.items[2]) else: newEmptyNode()
    return nnkIdentDefs.newTree(ctx.identForSymbol(param.items[0], nskParam), emitTypeRef(param.items[1]), default).attachLineInfo(param)
  if param.kind == sxList and param.items.len == 2 and param.items[0].kind == sxVector and
      (param.items[1].kind == sxSymbol or param.items[1].kind == sxVector):
    let carrier = genSym(nskParam, "p")
    let typeIdent = emitTypeRef(param.items[1])
    ctx.emitPatternIdentDefs(param.items[0], carrier.copyNimTree(), nskLet, patternDefs)
    return nnkIdentDefs.newTree(carrier, typeIdent, newEmptyNode()).attachLineInfo(param)
  raiseCompilerError(param.span, "parameter must be a symbol, (name type) or (name type default), or a typed destructuring pattern")

proc emitLambda(ctx: var EmitContext; sx: Syntax): NimNode =
  if sx.items.len < 3:
    raiseCompilerError(sx.span, "do expects parameters and body")
  let params = sx.items[1]
  if params.kind != sxList:
    raiseCompilerError(params.span, "do parameters must be a list")
  let bodyStart = lambdaBodyStart(sx)
  if bodyStart > sx.items.high:
    raiseCompilerError(sx.span, "do expects parameters and body")
  var returnType = ident("auto")
  if bodyStart == 3:
    returnType = emitTypeRef(sx.items[2].items[1])
  var formalParams = nnkFormalParams.newTree(returnType)
  var patternDefs: seq[NimNode] = @[]
  for param in params.items:
    formalParams.add ctx.emitParam(param, patternDefs)
  # `break lbl`/`break` cannot cross a routine boundary, so a bare `break`'s
  # target loop (like `namedBlocks`, see its comment in `lowerLambda`) must
  # never leak in from an enclosing routine.
  let savedBareBreak = ctx.bareBreakLabel
  ctx.bareBreakLabel = nil
  var bodyNode = ctx.emitBodyExpr(sx.items.toOpenArray(bodyStart, sx.items.high), sx)
  ctx.bareBreakLabel = savedBareBreak
  if patternDefs.len > 0:
    # Destructured params (#47) bind via a body-prelude `let` section, same
    # shape as `emitLetLike` and `emitMatchClauseBody`.
    var section = nnkLetSection.newTree()
    for identDefs in patternDefs:
      section.add identDefs
    bodyNode = emitBlockExpr(@[section], bodyNode)
  nnkLambda.newTree(
    newEmptyNode(),
    newEmptyNode(),
    newEmptyNode(),
    formalParams,
    newEmptyNode(),
    newEmptyNode(),
    bodyNode
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

proc pragmaDeclIdent(ctx: var EmitContext; name: Syntax; pragma: Syntax; what: string;
                      symKind = nskLet): NimNode =
  ## Returns the declaration identifier for `name`, wrapped in `nnkPragmaExpr`
  ## when `pragma` is non-nil (i.e. a pragma clause was specified).  Handles
  ## the export postfix (`name*`) correctly in both cases. `symKind` is
  ## forwarded to `declIdent`.
  let nameNode = ctx.declIdent(name, what, symKind = symKind)
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
  var patternDefs: seq[NimNode] = @[]
  for param in params.items:
    formalParams.add ctx.emitParam(param, patternDefs)

  # `break lbl`/`break` cannot cross a routine boundary — reset for the same
  # reason as `namedBlocks` (see `lowerRoutine`'s comment): a bare `break`'s
  # target loop from an enclosing routine must never leak into this one.
  let savedBareBreak = ctx.bareBreakLabel
  ctx.bareBreakLabel = nil
  var bodyNode =
    if stmtBody:
      # Iterator bodies are pure statement sequences — do not use emitBodyExpr
      # which would wrap the last item as a value-producing expression.
      var stmts = newStmtList()
      for item in sx.items.toOpenArray(bodyStart, sx.items.high):
        stmts.add ctx.emitStmt(item)
      stmts
    else:
      ctx.emitBodyExpr(sx.items.toOpenArray(bodyStart, sx.items.high), sx)
  ctx.bareBreakLabel = savedBareBreak

  if patternDefs.len > 0:
    var section = nnkLetSection.newTree()
    for identDefs in patternDefs:
      section.add identDefs
    if stmtBody:
      # A bare `nnkBlockStmt` wrap would retarget an unlabelled `break`
      # inside an iterator body, so prepend the prelude section into the
      # existing statement list instead of wrapping it (see emitLambda /
      # emitLetLike for the expression-body case, which can safely wrap).
      var stmts = newStmtList()
      stmts.add section
      for child in bodyNode.children:
        stmts.add child
      bodyNode = stmts
    else:
      bodyNode = emitBlockExpr(@[section], bodyNode)

  nodeKind.newTree(
    ctx.declIdent(name, formName & " name", allowOperator = true),
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

proc emitFunc(ctx: var EmitContext; sx: Syntax): NimNode =
  ctx.emitRoutine(sx, nnkFuncDef, "func")

proc emitConverter(ctx: var EmitContext; sx: Syntax): NimNode =
  ctx.emitRoutine(sx, nnkConverterDef, "converter")

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
    nameIdent = pragmaDeclIdent(ctx, nameTarget, pragma, formName & " name", nskVar)
  elif nameTarget.kind == sxList and nameTarget.items.len == 2 and
       nameTarget.items[0].kind == sxSymbol and
       (nameTarget.items[1].kind == sxSymbol or nameTarget.items[1].kind == sxVector):
    nameIdent = pragmaDeclIdent(ctx, nameTarget.items[0], pragma, formName & " name", nskVar)
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
      nameIdent = pragmaDeclIdent(ctx, nameTarget, pragma, formName & " name", nskVar)
    else:
      nameIdent = pragmaDeclIdent(ctx, nameTarget.items[0], pragma, formName & " name", nskVar)
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
    nameIdent = pragmaDeclIdent(ctx, nameTarget, pragma, formName & " name", nskConst)
  elif nameTarget.kind == sxList and nameTarget.items.len == 2 and
       nameTarget.items[0].kind == sxSymbol and
       (nameTarget.items[1].kind == sxSymbol or nameTarget.items[1].kind == sxVector):
    nameIdent = pragmaDeclIdent(ctx, nameTarget.items[0], pragma, formName & " name", nskConst)
    typeIdent = emitTypeRef(nameTarget.items[1])
  else:
    raiseCompilerError(nameTarget.span, formName & " name must be a symbol or (name type)")
  nnkConstSection.newTree(
    nnkConstDef.newTree(nameIdent, typeIdent, value).attachLineInfo(sx)
  ).attachLineInfo(sx)

proc emitImport(sx: Syntax): NimNode =
  expectArity(sx, "import", sx.items.len - 1, 1)
  if sx.items[1].kind == sxSymbol and sx.items[1].sym.endsWith(".nfl"):
    raiseCompilerError(sx.span, "nfl file imports are only allowed at the top level of a module")
  nnkImportStmt.newTree(emitModulePath(sx.items[1])).attachLineInfo(sx)

proc emitFrom(sx: Syntax): NimNode =
  let modulePath = emitModulePath(sx.items[1])
  let rest = sx.items[3 .. ^1]
  if rest.len == 1 and rest[0].kind == sxList and rest[0].items.len > 0 and rest[0].items[0].isSymbol("except"):
    result = nnkImportExceptStmt.newTree(modulePath).attachLineInfo(sx)
    for sym in rest[0].items[1 .. ^1]:
      result.add ident(sym.sym).attachLineInfo(sym)
  else:
    result = nnkFromStmt.newTree(modulePath).attachLineInfo(sx)
    for sym in rest:
      result.add ident(sym.sym).attachLineInfo(sym)

proc isCaseClause(sx: Syntax): bool =
  sx.kind == sxList and sx.items.len > 0 and sx.items[0].isSymbol("case")

proc emitObjectFieldDef(ctx: var EmitContext; field: Syntax): NimNode =
  ## Emits one `nnkIdentDefs` for a `(name Type)` / `(name {.p.} Type)` /
  ## `(name Type default)` / `(name {.p.} Type default)` field (#76) —
  ## shared by the plain-field loop and each variant branch's field list
  ## (#65), since lowering already validated both have the same shape.
  let parts = field.objectFieldParts()
  if not parts.ok:
    raiseCompilerError(field.span, "object field must be (name Type [default])")
  let default = if parts.defaultIdx >= 0: ctx.emitExpr(field.items[parts.defaultIdx]) else: newEmptyNode()
  nnkIdentDefs.newTree(
    pragmaDeclIdent(ctx, field.items[0], parts.pragma, "object field name"),
    emitTypeReference(field.items[parts.typeIdx]),
    default
  ).attachLineInfo(field)

proc emitVariantBranch(ctx: var EmitContext; branch: Syntax): NimNode =
  ## Emits one `nnkOfBranch`/`nnkElse` for a `case` clause's `(of tag
  ## field…)` / `(of [tag1 tag2 …] field…)` / `(else field…)` branch (#65).
  ## An empty field list emits `nnkRecList(newNilLit())` — Nim's spelling for
  ## an empty variant branch, i.e. `discard` in the record body.
  let isElse = branch.items[0].isSymbol("else")
  var fieldStart = 1
  var head = if isElse: nnkElse.newTree() else: nnkOfBranch.newTree()
  if not isElse:
    let tagSlot = branch.items[1]
    if tagSlot.kind == sxVector:
      for tag in tagSlot.items:
        head.add identForTypeSymbol(tag)
    else:
      head.add identForTypeSymbol(tagSlot)
    fieldStart = 2
  var fields = nnkRecList.newTree()
  for field in branch.items.toOpenArray(fieldStart, branch.items.high):
    fields.add ctx.emitObjectFieldDef(field)
  if fields.len == 0:
    fields.add newNilLit()
  head.add fields
  head.attachLineInfo(branch)

proc emitObjectType(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits `(object [of Base] (field type) … [(case name Type) (of
  ## tag field…)|(else field…) …])` as `nnkObjectTy`. The optional `(of
  ## Base)` clause at items[1] populates the inheritance slot; the optional
  ## trailing `(case …)` clause (#65) populates an `nnkRecCase` appended to
  ## the same `nnkRecList` as the plain fields — lowering has already
  ## validated the body's shape (at most one `case`, running to the end of
  ## the object), so this just walks it and emits directly.
  var fieldStart = 1
  var inheritNode: NimNode = newEmptyNode()
  if sx.items.len > 1 and sx.items[1].kind == sxList and
     sx.items[1].items.len == 2 and sx.items[1].items[0].isSymbol("of"):
    inheritNode = nnkOfInherit.newTree(
      emitTypeReference(sx.items[1].items[1])
    ).attachLineInfo(sx.items[1])
    fieldStart = 2
  var fields = nnkRecList.newTree().attachLineInfo(sx)
  var i = fieldStart
  while i <= sx.items.high and not sx.items[i].isCaseClause():
    fields.add ctx.emitObjectFieldDef(sx.items[i])
    inc i
  if i <= sx.items.high:
    let caseClause = sx.items[i]
    let discDefault = if caseClause.items.len == 4: ctx.emitExpr(caseClause.items[3]) else: newEmptyNode()
    let discIdentDefs = nnkIdentDefs.newTree(
      pragmaDeclIdent(ctx, caseClause.items[1], nil, "case discriminator name"),
      emitTypeReference(caseClause.items[2]),
      discDefault
    ).attachLineInfo(caseClause)
    var recCase = nnkRecCase.newTree(discIdentDefs)
    for j in (i + 1) .. sx.items.high:
      recCase.add ctx.emitVariantBranch(sx.items[j])
    fields.add recCase.attachLineInfo(caseClause)
  nnkObjectTy.newTree(newEmptyNode(), inheritNode, fields).attachLineInfo(sx)

proc emitEnumType(ctx: var EmitContext; sx: Syntax): NimNode =
  result = nnkEnumTy.newTree(newEmptyNode()).attachLineInfo(sx)
  for value in sx.items.toOpenArray(1, sx.items.high):
    if value.kind == sxList:
      result.add nnkEnumFieldDef.newTree(
        identForTypeSymbol(value.items[0]),
        ctx.emitExpr(value.items[1])
      ).attachLineInfo(value)
    else:
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
      return ctx.emitEnumType(sx)
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
  let genIdx = procGenericIdx(sx)
  if genIdx >= 0:
    genericParamsNode = emitGenericParams(sx.items[genIdx])
    idx = genIdx + 1
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

proc emitTupleNew(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits `(tuple-new Type (field value) …)` (#35) as
  ## `Type((field: value, …))` — an object-constructor-style call wrapping a
  ## tuple constructor, the shape Nim requires to build a *named* tuple type
  ## rather than an anonymous structural tuple.
  if sx.items.len < 3:
    raiseCompilerError(sx.span, "tuple-new expects a type and at least one field initializer")
  var tupleConstr = nnkTupleConstr.newTree().attachLineInfo(sx)
  for field in sx.items.toOpenArray(2, sx.items.high):
    if field.kind != sxList or field.items.len != 2:
      raiseCompilerError(field.span, "tuple-new field initializer must be (name value)")
    tupleConstr.add nnkExprColonExpr.newTree(
      identForFieldSymbol(field.items[0]),
      ctx.emitExpr(field.items[1])
    ).attachLineInfo(field)
  newCall(emitTypeReference(sx.items[1]), tupleConstr).attachLineInfo(sx)

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

proc loopLabelOrNil(sx: Syntax): Syntax =
  ## The `:name` label syntax node for a `(while [:name] …)`/`(for [:name]
  ## …)` form, or `nil` when unlabelled.
  if sx.items.len > 1 and sx.items[1].isBlockLabel(): sx.items[1] else: nil

proc emitLoopBody(ctx: var EmitContext; owner: Syntax; labelSx: Syntax;
                   bodyItems: openArray[Syntax]): tuple[wrapperLabel, body: NimNode] =
  ## Shared machinery for `(while …)`/`(for …)`. Every loop gets a Nim
  ## wrapper `block` label — the user's `:name` when present, else a gensym
  ## — because a *bare* `(break)` must always be able to target its own
  ## loop directly regardless of any intervening anonymous `(block …)` in
  ## expression position (see `EmitContext.bareBreakLabel`). The loop body
  ## additionally gets a per-iteration `block` only when a `(continue
  ## :name)` inside it actually targets this loop — Nim has no labelled
  ## `continue`, so that is compiled as `break` out of the per-iteration
  ## block. Callers wrap the returned `body` in their own
  ## `nnkForStmt`/`nnkWhileStmt`, then that in `block wrapperLabel: …`.
  let labelled = labelSx != nil
  let labelKey = if labelled: labelSx.namedBlockKey() else: ""
  let wrapperLabel =
    if labelled: labelIdent(labelSx)
    else: genSym(nskLabel, "loop")
  let needsIter = labelled and usesLabelledContinue(bodyItems, labelKey)
  let iterLabel = if needsIter: genSym(nskLabel, "iter") else: nil
  if labelled:
    ctx.namedBlocks.add NamedBlockFrame(key: labelKey, label: wrapperLabel,
      carrier: nil, isLoop: true, iterLabel: iterLabel)
  let savedBareBreak = ctx.bareBreakLabel
  ctx.bareBreakLabel = wrapperLabel
  var innerBody = newStmtList()
  for item in bodyItems:
    innerBody.add ctx.emitStmt(item)
  ctx.bareBreakLabel = savedBareBreak
  if labelled:
    discard ctx.namedBlocks.pop()
  let body =
    if needsIter: nnkBlockStmt.newTree(iterLabel, innerBody).attachLineInfo(owner)
    else: innerBody
  (wrapperLabel, body)

proc emitForCore(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Builds `(for [:name] CLAUSE body…)`, wrapped per `emitLoopBody`.
  ## Always returns a statement node (`void`) — the same node is used
  ## unmodified in both statement and expression context; a loop has no
  ## value (#73).
  let labelSx = loopLabelOrNil(sx)
  let clauseIdx = if labelSx != nil: 2 else: 1
  let clause = sx.items[clauseIdx]
  let binding = clause.items[0]
  let iterable = clause.items[1]
  var forStmt = nnkForStmt.newTree()
  if binding.kind == sxSymbol:
    forStmt.add ctx.identForSymbol(binding, nskForVar)
  else:
    for v in binding.items:
      forStmt.add ctx.identForSymbol(v, nskForVar)
  forStmt.add ctx.emitExpr(iterable)
  let (wrapperLabel, body) = ctx.emitLoopBody(sx, labelSx,
    sx.items.toOpenArray(clauseIdx + 1, sx.items.high))
  forStmt.add body
  nnkBlockStmt.newTree(wrapperLabel, forStmt.attachLineInfo(sx)).attachLineInfo(sx)

proc emitRangeForm(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits a `(.. lo hi)` range form as `nnkInfix(.., lo, hi)` — the same
  ## node shape Nim's own parser produces for `lo..hi`, so it drops straight
  ## into a case-branch value list.
  nnkInfix.newTree(ident(".."), ctx.emitExpr(sx.items[1]), ctx.emitExpr(sx.items[2])).attachLineInfo(sx)

proc emitOfValues(ctx: var EmitContext; sx: Syntax): seq[NimNode] =
  ## Emits the value(s) of a single `of` branch's leading form: a range
  ## `(.. lo hi)`, a multi-value/mixed list `(1 (.. 3 5) 7)`, or a single
  ## (possibly compound) expression — mirrors `lowerCaseOfValue`.
  if sx.isRangeShaped:
    @[ctx.emitRangeForm(sx)]
  elif sx.isCaseValueList:
    var values: seq[NimNode] = @[]
    for item in sx.items:
      if item.isRangeForm:
        values.add ctx.emitRangeForm(item)
      else:
        values.add ctx.emitExpr(item)
    values
  else:
    @[ctx.emitExpr(sx)]

proc emitCase(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits `nnkCaseStmt` with branch bodies as expressions (for expr context).
  result = nnkCaseStmt.newTree(ctx.emitExpr(sx.items[1])).attachLineInfo(sx)
  for i in 2 ..< sx.items.len:
    let branch = sx.items[i]
    if branch.items[0].isSymbol("of"):
      var ofBranch = nnkOfBranch.newTree()
      for value in ctx.emitOfValues(branch.items[1]):
        ofBranch.add value
      ofBranch.add ctx.emitBodyExpr(branch.items.toOpenArray(2, branch.items.high), branch)
      result.add ofBranch.attachLineInfo(branch)
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
      var ofBranch = nnkOfBranch.newTree()
      for value in ctx.emitOfValues(branch.items[1]):
        ofBranch.add value
      ofBranch.add body
      result.add ofBranch.attachLineInfo(branch)
    else:
      var body = newStmtList()
      for j in 1 ..< branch.items.len:
        body.add ctx.emitStmt(branch.items[j])
      result.add nnkElse.newTree(body).attachLineInfo(branch)

# ---------------------------------------------------------------------------
# match (#13)
# ---------------------------------------------------------------------------

proc emitMatchObjectTest(ctx: var EmitContext; pattern: Syntax; tmp: NimNode): NimNode

proc emitMatchTest(ctx: var EmitContext; pattern: Syntax; tmp: NimNode): NimNode =
  ## Builds the boolean test for one match pattern against `tmp`. Mirrors
  ## lower.nim's `lowerMatchPattern` — see #43 for the general
  ## lower.nim/backend.nim shape-duplication this follows.
  case pattern.kind
  of sxNil:
    nnkInfix.newTree(ident("=="), tmp.copyNimTree(), newNilLit()).attachLineInfo(pattern)
  of sxBool:
    nnkInfix.newTree(ident("=="), tmp.copyNimTree(), newLit(pattern.boolVal)).attachLineInfo(pattern)
  of sxInt:
    nnkInfix.newTree(ident("=="), tmp.copyNimTree(), plainIntLit(pattern.intVal)).attachLineInfo(pattern)
  of sxFloat:
    nnkInfix.newTree(ident("=="), tmp.copyNimTree(), plainFloatLit(pattern.floatVal)).attachLineInfo(pattern)
  of sxString:
    nnkInfix.newTree(ident("=="), tmp.copyNimTree(), newLit(pattern.strVal)).attachLineInfo(pattern)
  of sxSymbol:
    # `_` (wildcard) and any other bare symbol (bind) both match
    # unconditionally — the difference is only whether a binding is emitted.
    newLit(true).attachLineInfo(pattern)
  of sxVector:
    if pattern.isObjectPattern():
      ctx.emitMatchObjectTest(pattern, tmp)
    else:
      var restIdx = -1
      for i, elem in pattern.items:
        if elem.kind == sxSymbol and elem.sym == "&":
          restIdx = i
          break
      let headCount = if restIdx >= 0: restIdx else: pattern.items.len
      newCall(bindSym"nflMatchArity", tmp.copyNimTree(), newLit(headCount), newLit(restIdx < 0)).attachLineInfo(pattern)
  of sxList:
    if pattern.items.len == 2 and pattern.items[0].isSymbol("quote") and pattern.items[1].kind == sxSymbol:
      # 'sym — equality against the symbol's value (an enum label, a const, …).
      nnkInfix.newTree(ident("=="), tmp.copyNimTree(), ctx.identForSymbol(pattern.items[1])).attachLineInfo(pattern)
    elif pattern.items.len > 0 and pattern.items[0].isSymbol("of"):
      # (of Type) / (of Type pattern) — a runtime type test (#48), `and`ed
      # with the nested pattern's test evaluated against a `Type(tmp)`
      # downcast so subclass-only fields resolve.
      let ofTest = nnkInfix.newTree(ident("of"), tmp.copyNimTree(), identForTypeSymbol(pattern.items[1])).attachLineInfo(pattern)
      if pattern.items.len == 3:
        let downcast = newCall(identForTypeSymbol(pattern.items[1]), tmp.copyNimTree()).attachLineInfo(pattern)
        nnkInfix.newTree(ident("and"), ofTest, ctx.emitMatchTest(pattern.items[2], downcast)).attachLineInfo(pattern)
      else:
        ofTest
    else:
      raiseCompilerError(pattern.span, "unsupported match pattern")

proc emitMatchObjectTest(ctx: var EmitContext; pattern: Syntax; tmp: NimNode): NimNode =
  ## Builds the conjunction of each field target's test against `tmp.field`
  ## (#48) — a bare-symbol/`_`/shorthand target contributes `true` (matching
  ## `emitMatchTest`'s `sxSymbol` arm), so a pattern that only binds reduces
  ## to `true` overall.
  var i = 0
  while i < pattern.items.len:
    let key = pattern.items[i]
    let field = key.sym[1 .. ^1]
    let accessor = nnkDotExpr.newTree(tmp.copyNimTree(), ident(field)).attachLineInfo(key)
    var target: Syntax = nil
    if i + 1 < pattern.items.len and not pattern.items[i + 1].isKeywordSym():
      target = pattern.items[i + 1]
      i += 2
    else:
      i += 1
    let test = if target != nil: ctx.emitMatchTest(target, accessor) else: newLit(true).attachLineInfo(key)
    result = if result == nil: test else: nnkInfix.newTree(ident("and"), result, test).attachLineInfo(key)
  if result == nil:
    result = newLit(true).attachLineInfo(pattern)

proc emitMatchBindings(ctx: var EmitContext; pattern: Syntax; tmp: NimNode): seq[NimNode]

proc emitMatchObjectBindings(ctx: var EmitContext; pattern: Syntax; tmp: NimNode; defs: var seq[NimNode]) =
  ## Emits each field target's bindings (#48) against `tmp.field`, recursing
  ## `emitMatchBindings` per target; a bare-symbol/shorthand target binds the
  ## field's value directly.
  var i = 0
  while i < pattern.items.len:
    let key = pattern.items[i]
    let field = key.sym[1 .. ^1]
    let accessor = nnkDotExpr.newTree(tmp.copyNimTree(), ident(field)).attachLineInfo(key)
    if i + 1 < pattern.items.len and not pattern.items[i + 1].isKeywordSym():
      let target = pattern.items[i + 1]
      case target.kind
      of sxSymbol:
        if target.sym != "_":
          defs.add nnkIdentDefs.newTree(ctx.identForSymbol(target), newEmptyNode(), accessor).attachLineInfo(target)
      else:
        defs.add ctx.emitMatchBindings(target, accessor)
      i += 2
    else:
      defs.add nnkIdentDefs.newTree(ctx.identForSymbol(newSymbol(field, key.span)), newEmptyNode(), accessor).attachLineInfo(key)
      i += 1

proc emitMatchBindings(ctx: var EmitContext; pattern: Syntax; tmp: NimNode): seq[NimNode] =
  ## Emits the accessor `nnkIdentDefs` a match pattern binds against `tmp` —
  ## a bare symbol binds the whole scrutinee; a vector pattern destructures
  ## it via #12's `emitPatternIdentDefs`, or (#48) an object pattern's field
  ## targets via `emitMatchObjectBindings`; `(of Type pattern)` (#48) binds
  ## the nested pattern against a `Type(tmp)` downcast; every other pattern
  ## kind (literals, `_`, `'sym`) binds nothing.
  case pattern.kind
  of sxSymbol:
    if pattern.sym != "_":
      result = @[nnkIdentDefs.newTree(ctx.identForSymbol(pattern), newEmptyNode(), tmp.copyNimTree()).attachLineInfo(pattern)]
  of sxVector:
    if pattern.isObjectPattern():
      ctx.emitMatchObjectBindings(pattern, tmp, result)
    else:
      ctx.emitPatternIdentDefs(pattern, tmp.copyNimTree(), nskLet, result)
  of sxList:
    if pattern.items.len == 3 and pattern.items[0].isSymbol("of"):
      let downcast = newCall(identForTypeSymbol(pattern.items[1]), tmp.copyNimTree()).attachLineInfo(pattern)
      result = ctx.emitMatchBindings(pattern.items[2], downcast)
  else:
    discard

proc emitMatchCondition(ctx: var EmitContext; clause: Syntax; tmp: NimNode): NimNode =
  ## The full branch condition: the pattern test, `and`ed with the `:when`
  ## guard (if any) evaluated in a block that has the pattern's bindings in
  ## scope, so a guard can reference names the pattern just bound.
  let pattern = clause.items[0]
  let patternTest = ctx.emitMatchTest(pattern, tmp)
  if clause.items[1].isSymbol(":when"):
    let bindings = ctx.emitMatchBindings(pattern, tmp)
    var stmts: seq[NimNode] = @[]
    if bindings.len > 0:
      stmts.add nnkLetSection.newTree(bindings).attachLineInfo(clause)
    let guardBlock = emitBlockExpr(stmts, ctx.emitExpr(clause.items[2])).attachLineInfo(clause)
    nnkInfix.newTree(ident("and"), patternTest, guardBlock).attachLineInfo(clause)
  else:
    patternTest

proc emitMatchBody(ctx: var EmitContext; clause: Syntax; tmp: NimNode; asExpr: bool): NimNode =
  ## Emits one clause's body, with the pattern's bindings (re-emitted — they
  ## are cheap index expressions on `tmp`, and the `:when` guard's copy above
  ## is in a separate scope) declared ahead of it.
  let pattern = clause.items[0]
  let bodyStart = if clause.items[1].isSymbol(":when"): 3 else: 1
  let bindings = ctx.emitMatchBindings(pattern, tmp)
  var stmts: seq[NimNode] = @[]
  if bindings.len > 0:
    stmts.add nnkLetSection.newTree(bindings).attachLineInfo(clause)
  if asExpr:
    result = emitBlockExpr(stmts, ctx.emitBodyExpr(clause.items.toOpenArray(bodyStart, clause.items.high), clause)).attachLineInfo(clause)
  else:
    result = newStmtList()
    for s in stmts:
      result.add s
    for i in bodyStart ..< clause.items.len:
      result.add ctx.emitStmt(clause.items[i])

proc emitMatchCore(ctx: var EmitContext; sx: Syntax; asExpr: bool): NimNode =
  ## Emits:
  ##   block:
  ##     let tmp = <scrutinee>
  ##     if <test1>:   block: <bindings1>; <body1>
  ##     elif <test2>: block: <bindings2>; <body2>
  ##     else:         raise newException(ValueError, "match: no branch matched")
  if sx.items.len < 3:
    raiseCompilerError(sx.span, "match expects a value and at least one clause")
  let tmp = genSym(nskLet, "m")
  let letSec = nnkLetSection.newTree(
    nnkIdentDefs.newTree(tmp, newEmptyNode(), ctx.emitExpr(sx.items[1])).attachLineInfo(sx)
  ).attachLineInfo(sx)
  var ifNode = (if asExpr: nnkIfExpr.newTree() else: nnkIfStmt.newTree())
  for i in 2 ..< sx.items.len:
    let clause = sx.items[i]
    if clause.kind != sxList or clause.items.len < 2:
      raiseCompilerError(clause.span, "match clause must be (pattern body…) or (pattern :when guard body…)")
    let cond = ctx.emitMatchCondition(clause, tmp)
    let body = ctx.emitMatchBody(clause, tmp, asExpr)
    if asExpr:
      ifNode.add nnkElifExpr.newTree(cond, body).attachLineInfo(clause)
    else:
      ifNode.add nnkElifBranch.newTree(cond, body).attachLineInfo(clause)
  let raiseNode = nnkRaiseStmt.newTree(
    newCall(ident("newException"), ident("ValueError"), newLit("match: no branch matched"))
  ).attachLineInfo(sx)
  if asExpr:
    ifNode.add nnkElseExpr.newTree(raiseNode).attachLineInfo(sx)
  else:
    ifNode.add nnkElse.newTree(newStmtList(raiseNode)).attachLineInfo(sx)
  emitBlockExpr(@[letSec], ifNode).attachLineInfo(sx)

proc emitMatch(ctx: var EmitContext; sx: Syntax): NimNode =
  ctx.emitMatchCore(sx, true)

proc emitMatchStmt(ctx: var EmitContext; sx: Syntax): NimNode =
  ctx.emitMatchCore(sx, false)

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

proc emitDefer(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits `(defer body…)` as `nnkDefer`.
  var body = newStmtList()
  for i in 1 ..< sx.items.len:
    body.add ctx.emitStmt(sx.items[i])
  nnkDefer.newTree(body).attachLineInfo(sx)

proc emitWhileCore(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Builds `(while [:name] COND body…)`, wrapped per `emitLoopBody`.
  ## Always returns a statement node (`void`) — the same node is used
  ## unmodified in both statement and expression context; a loop has no
  ## value (#73).
  let labelSx = loopLabelOrNil(sx)
  let condIdx = if labelSx != nil: 2 else: 1
  let condNode = ctx.emitExpr(sx.items[condIdx])
  let (wrapperLabel, body) = ctx.emitLoopBody(sx, labelSx,
    sx.items.toOpenArray(condIdx + 1, sx.items.high))
  let whileStmt = nnkWhileStmt.newTree(condNode, body).attachLineInfo(sx)
  nnkBlockStmt.newTree(wrapperLabel, whileStmt).attachLineInfo(sx)

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

proc emitCatchCore(ctx: var EmitContext; sx: Syntax; asExpr: bool): NimNode =
  ## Shared implementation for `(catch :tag body…)` (#55) in expression and
  ## statement contexts — mirrors `emitTryCore`'s `asExpr` split. Unlike a
  ## named `block`, there is no carrier var or label frame to manage here:
  ## the whole form lowers to a single call/wrap of the runtime's `nflCatch`
  ## template, which does the tag comparison and value extraction itself.
  let tag = blockLabelName(sx.items[1])
  let body =
    if asExpr:
      ctx.emitBodyExpr(sx.items.toOpenArray(2, sx.items.high), sx)
    else:
      var stmts = newStmtList()
      for i in 2 ..< sx.items.len:
        stmts.add ctx.emitStmt(sx.items[i])
      stmts
  newCall(bindSym"nflCatch", newLit(tag), body).attachLineInfo(sx)

proc emitCatch(ctx: var EmitContext; sx: Syntax): NimNode =
  ctx.emitCatchCore(sx, true)

proc emitCatchStmt(ctx: var EmitContext; sx: Syntax): NimNode =
  ctx.emitCatchCore(sx, false)

proc emitThrow(ctx: var EmitContext; sx: Syntax): NimNode =
  ## Emits `(throw :tag value)` (#55) as a raw `nnkRaiseStmt` raising the
  ## runtime's `newNflThrow(...)` — see the doc comment on `newNflThrow` for
  ## why this is a literal `raise` node rather than a call to a
  ## `{.noreturn.}` proc. Left unwrapped in expression position — like
  ## `emitRaise`/`emitBreakFrom` — since Nim treats a raw `nnkRaiseStmt` as
  ## noreturn and lets it type-unify with whatever the surrounding
  ## expression expects.
  let tag = blockLabelName(sx.items[1])
  let value = ctx.emitExpr(sx.items[2])
  nnkRaiseStmt.newTree(
    newCall(bindSym"newNflThrow", newLit(tag), value)
  ).attachLineInfo(sx)

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
    plainIntLit(sx.intVal).attachLineInfo(sx)
  of sxFloat:
    plainFloatLit(sx.floatVal).attachLineInfo(sx)
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
    elif sx.items[0].isSymbol("static-when"):
      ctx.emitStaticWhen(sx)
    elif sx.items[0].isSymbol("block"):
      ctx.emitBegin(sx)
    elif sx.items[0].isSymbol("prog1"):
      ctx.emitProgN(sx, 0, "prog1")
    elif sx.items[0].isSymbol("prog2"):
      ctx.emitProgN(sx, 1, "prog2")
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
    elif sx.items[0].isSymbol("tuple-new"):
      ctx.emitTupleNew(sx)
    elif sx.items[0].isSymbol("for"):
      # A loop has no value — emit the statement core directly rather than
      # wrapping it with a `nil` filler. A `block: <loop>; nil` filler gave
      # the loop type `typeof(nil)`, which an `auto`-inferred routine tail
      # (or any other value position) could not resolve, crashing the Nim
      # compiler with `getTypeDescAux(tyAnything)` (#73). `void` is correct:
      # this is the same node the statement-position dispatch below emits.
      ctx.emitForCore(sx)
    elif sx.items[0].isSymbol("while"):
      ctx.emitWhileCore(sx)
    elif sx.items[0].isSymbol("case"):
      ctx.emitCase(sx)
    elif sx.items[0].isSymbol("match"):
      ctx.emitMatch(sx)
    elif sx.items[0].isSymbol("raise"):
      ctx.emitRaise(sx)
    elif sx.items[0].isSymbol("return"):
      ctx.emitReturn(sx)
    elif sx.items[0].isSymbol("break-from"):
      # Unwrapped, like `return` just above: a `break` is noreturn, so this
      # statement list (ending in `break`) type-unifies with any expected
      # type at its use site (e.g. as one branch of an `if`-expression whose
      # other branch has an unrelated type) — forcing a concrete type here
      # (e.g. by wrapping with a filler value) would break that unification.
      ctx.emitBreakFrom(sx)
    elif sx.items[0].isSymbol("catch"):
      ctx.emitCatch(sx)
    elif sx.items[0].isSymbol("throw"):
      # Unwrapped for the same reason as `break-from`/`raise` just above:
      # `nflThrow` is `{.noreturn.}`, so this must type-unify with whatever
      # the call site expects rather than being forced to a concrete type.
      ctx.emitThrow(sx)
    elif sx.items[0].isSymbol("try"):
      ctx.emitTry(sx)
    elif sx.items[0].isSymbol(":"):
      raiseCompilerError(sx.span, "named argument marker is only allowed in call argument position")
    elif sx.items[0].isSymbol("discard"):
      raiseCompilerError(sx.span, "discard is only allowed at statement scope")
    elif sx.items[0].isSymbol("defer"):
      raiseCompilerError(sx.span, "defer is only allowed at statement scope")
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
    elif sx.items[0].isSymbol("func"):
      raiseCompilerError(sx.span, "func is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("converter"):
      raiseCompilerError(sx.span, "converter is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("type"):
      raiseCompilerError(sx.span, "type is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("import"):
      raiseCompilerError(sx.span, "import is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("from"):
      raiseCompilerError(sx.span, "from is only allowed at statement/module scope")
    elif sx.items[0].isSymbol("quote"):
      emitQuote(sx)
    elif sx.items[0].isSymbol("quasiquote"):
      raiseCompilerError(sx.span, "runtime quasiquote is not implemented yet")
    elif sx.items[0].isSymbol("unhygienic"):
      raiseCompilerError(sx.span, "unhygienic is only valid as a binding target inside a quasiquote template")
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
    if sx.items[0].isSymbol("static-when"):
      return ctx.emitStaticWhenStmt(sx)
    if sx.items[0].isSymbol("for"):
      return ctx.emitForCore(sx)
    if sx.items[0].isSymbol("while"):
      return ctx.emitWhileCore(sx)
    if sx.items[0].isSymbol("case"):
      return ctx.emitCaseStmt(sx)
    if sx.items[0].isSymbol("match"):
      return ctx.emitMatchStmt(sx)
    if sx.items[0].isSymbol("raise"):
      return ctx.emitRaise(sx)
    if sx.items[0].isSymbol("return"):
      return ctx.emitReturn(sx)
    if sx.items[0].isSymbol("discard"):
      return ctx.emitDiscard(sx)
    if sx.items[0].isSymbol("defer"):
      return ctx.emitDefer(sx)
    if sx.items[0].isSymbol("break"):
      return ctx.emitBreak(sx)
    if sx.items[0].isSymbol("continue"):
      return ctx.emitContinue(sx)
    if sx.items[0].isSymbol("try"):
      return ctx.emitTryStmt(sx)
    if sx.items[0].isSymbol("catch"):
      return ctx.emitCatchStmt(sx)
    if sx.items[0].isSymbol("throw"):
      return ctx.emitThrow(sx)
    if sx.items[0].isSymbol("block"):
      if sx.items.len > 1 and sx.items[1].isBlockLabel():
        return ctx.emitLabelledBlock(sx)
      result = newStmtList()
      for i in 1 ..< sx.items.len:
        result.add ctx.emitStmt(sx.items[i])
      return
    if sx.items[0].isSymbol("prog1"):
      checkProgNArity(sx, 0, "prog1")
      result = newStmtList()
      for i in 1 ..< sx.items.len:
        result.add ctx.emitStmt(sx.items[i])
      return
    if sx.items[0].isSymbol("prog2"):
      checkProgNArity(sx, 1, "prog2")
      result = newStmtList()
      for i in 1 ..< sx.items.len:
        result.add ctx.emitStmt(sx.items[i])
      return
    if sx.items[0].isSymbol("break-from"):
      return ctx.emitBreakFrom(sx)
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
    if sx.items[0].isSymbol("from"):
      return emitFrom(sx)
    if sx.items[0].isSymbol("proc"):
      return ctx.emitProc(sx)
    if sx.items[0].isSymbol("template"):
      return ctx.emitTemplate(sx)
    if sx.items[0].isSymbol("iterator"):
      return ctx.emitIterator(sx)
    if sx.items[0].isSymbol("method"):
      return ctx.emitMethod(sx)
    if sx.items[0].isSymbol("func"):
      return ctx.emitFunc(sx)
    if sx.items[0].isSymbol("converter"):
      return ctx.emitConverter(sx)
    if sx.items[0].isSymbol("yield"):
      return ctx.emitYield(sx)
    if sx.items[0].isSymbol("type"):
      return ctx.emitTypeDecl(sx)
  newCall(bindSym"nflStmt", ctx.emitExpr(sx)).attachLineInfo(sx)

proc emitExpr*(sx: Syntax): NimNode =
  ## Emits a single lowered expression as a Nim expression `NimNode`, in
  ## a fresh emit context (its own hygienic-symbol table).
  var ctx = EmitContext(hygienicSymbols: initTable[int, tuple[node: NimNode, kind: NimSymKind]]())
  ctx.emitExpr(sx)

proc emitStmt*(sx: Syntax): NimNode =
  ## Emits a single lowered form as a Nim statement `NimNode`.
  var ctx = EmitContext(hygienicSymbols: initTable[int, tuple[node: NimNode, kind: NimSymKind]]())
  ctx.emitStmt(sx)

proc emitModule*(forms: seq[Syntax]): NimNode =
  ## Emits a whole module's lowered top-level forms as a single Nim
  ## `NimNode` statement list, sharing one emit context (and therefore one
  ## hygienic-symbol table) across all of them.
  var ctx = EmitContext(hygienicSymbols: initTable[int, tuple[node: NimNode, kind: NimSymKind]]())
  result = newStmtList()
  for form in forms:
    result.add ctx.emitStmt(form)
