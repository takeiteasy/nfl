## Runtime support linked into every compiled LFN program: the `LfnDatum`
## quoted-data representation, seq helpers backing LFN's functional
## builtins (`map`, `filter`, `fold`, ...), and the `throw`/`catch` and
## `defclass`/`:initarg` machinery. Exported (`export runtime` in
## `compiler.nim`) so generated code can call these directly.

import std/algorithm
import std/macros
import std/strutils

type
  LfnDatumKind* = enum
    ## Discriminates `LfnDatum`'s variants — the reader's own `Syntax` kinds,
    ## reduced to what a running program needs to represent quoted data.
    ndNil, ndBool, ndInt, ndFloat, ndString, ndSymbol, ndList, ndVector

  LfnDatum* = ref object
    ## Runtime representation of quoted/quasiquoted data (`'expr`), as
    ## opposed to `Syntax` which only exists at macro-expansion time.
    case kind*: LfnDatumKind
    of ndNil:
      discard
    of ndBool:
      boolVal*: bool
    of ndInt:
      intVal*: BiggestInt
    of ndFloat:
      floatVal*: BiggestFloat
    of ndString:
      strVal*: string
    of ndSymbol:
      sym*: string
    of ndList, ndVector:
      items*: seq[LfnDatum]

proc lfnNilDatum*(): LfnDatum =
  ## Builds an `ndNil` `LfnDatum`.
  LfnDatum(kind: ndNil)

proc lfnBoolDatum*(value: bool): LfnDatum =
  ## Builds an `ndBool` `LfnDatum`.
  LfnDatum(kind: ndBool, boolVal: value)

proc lfnIntDatum*(value: BiggestInt): LfnDatum =
  ## Builds an `ndInt` `LfnDatum`.
  LfnDatum(kind: ndInt, intVal: value)

proc lfnFloatDatum*(value: BiggestFloat): LfnDatum =
  ## Builds an `ndFloat` `LfnDatum`.
  LfnDatum(kind: ndFloat, floatVal: value)

proc lfnStringDatum*(value: string): LfnDatum =
  ## Builds an `ndString` `LfnDatum`.
  LfnDatum(kind: ndString, strVal: value)

proc lfnSymbolDatum*(value: string): LfnDatum =
  ## Builds an `ndSymbol` `LfnDatum`.
  LfnDatum(kind: ndSymbol, sym: value)

proc lfnListDatum*(items: varargs[LfnDatum]): LfnDatum =
  ## Builds an `ndList` `LfnDatum` from its elements.
  LfnDatum(kind: ndList, items: @items)

proc lfnVectorDatum*(items: varargs[LfnDatum]): LfnDatum =
  ## Builds an `ndVector` `LfnDatum` from its elements.
  LfnDatum(kind: ndVector, items: @items)

template lfnStmt*(body: untyped) =
  ## Wraps a top-level expression form in statement (void) position:
  ## discards `body`'s value if it has one, otherwise just runs it.
  ## `emitStmt`'s fallback for a form that isn't one of the recognized
  ## statement heads (`synforms.declFormHeads`).
  when compiles(block:
    discard body):
    discard body
  else:
    body

template lfnReplShow*(body: untyped) =
  ## Wraps a value expression the `lfn repl` (#14) reads at top level so its
  ## result gets printed once, consistently. Same `compiles(discard body)`
  ## dispatch as `lfnStmt` above, so a void form (an assignment, a loop,
  ## `discard`, …) simply runs for effect and prints nothing rather than
  ## failing to compile — the REPL wraps every non-declaration top-level
  ## form in this, not only ones already known to produce a value, and
  ## relies on that fallback. `body` is only ever evaluated once at runtime:
  ## the `compiles` check is purely a compile-time typecheck of a *second*,
  ## never-executed copy of `body`, exactly as `lfnStmt` relies on already.
  ## `string`/`char` are `repr`'d (quoted) rather than `$`'d so a REPL user
  ## can tell the string "1" apart from the int 1 in the output; every other
  ## type prefers `$` where available, falling back to `repr`.
  when compiles(block: discard body):
    let lfnReplShowValue = body
    when lfnReplShowValue is string or lfnReplShowValue is char:
      echo repr(lfnReplShowValue)
    elif compiles($lfnReplShowValue):
      echo $lfnReplShowValue
    else:
      echo repr(lfnReplShowValue)
  else:
    body

template lfnMatchArity*(x: untyped; n: static[int]; exact: static[bool]): bool =
  ## Arity test for a `match` (#13) vector pattern against a tuple, array, or
  ## seq scrutinee. Tuples have no `.len`, so `compiles(len(x))` picks
  ## between the two: an indexable-but-lenless value (a tuple) always passes
  ## — its arity was already fixed by its type, so Nim itself would reject
  ## an out-of-range accessor at compile time — while a seq/array is
  ## checked for at least (or exactly, for a pattern with no `& rest`) `n`
  ## elements.
  when compiles(len(x)):
    when exact: len(x) == n else: len(x) >= n
  else:
    true

proc lfnSeqMap*[T, U](items: openArray[T]; op: proc(item: T): U {.nimcall.}): seq[U] =
  ## Backs LFN's `map` builtin. Overloaded on `{.nimcall.}`/`{.closure.}`
  ## so both a plain proc and a closure (e.g. a lambda capturing locals)
  ## can be passed as `op` without an explicit cast at the call site.
  for item in items:
    result.add op(item)

proc lfnSeqMap*[T, U](items: openArray[T]; op: proc(item: T): U {.closure.}): seq[U] =
  ## Closure-`op` overload of `lfnSeqMap`.
  for item in items:
    result.add op(item)

proc lfnSeqFilter*[T](items: openArray[T]; pred: proc(item: T): bool {.nimcall.}): seq[T] =
  ## Backs LFN's `filter` builtin — keeps elements where `pred` is true.
  for item in items:
    if pred(item):
      result.add item

proc lfnSeqFilter*[T](items: openArray[T]; pred: proc(item: T): bool {.closure.}): seq[T] =
  ## Closure-`pred` overload of `lfnSeqFilter`.
  for item in items:
    if pred(item):
      result.add item

proc lfnSeqFoldl*[T, U](items: openArray[T]; initial: U; op: proc(acc: U; item: T): U {.nimcall.}): U =
  ## Backs LFN's `foldl` builtin — left fold, `initial` as the seed
  ## accumulator.
  result = initial
  for item in items:
    result = op(result, item)

proc lfnSeqFoldl*[T, U](items: openArray[T]; initial: U; op: proc(acc: U; item: T): U {.closure.}): U =
  ## Closure-`op` overload of `lfnSeqFoldl`.
  result = initial
  for item in items:
    result = op(result, item)

proc lfnSeqFoldr*[T, U](items: openArray[T]; initial: U; op: proc(item: T; acc: U): U {.nimcall.}): U =
  ## Backs LFN's `foldr` builtin — right fold, `initial` as the seed
  ## accumulator.
  result = initial
  for i in countdown(items.high, 0):
    result = op(items[i], result)

proc lfnSeqFoldr*[T, U](items: openArray[T]; initial: U; op: proc(item: T; acc: U): U {.closure.}): U =
  ## Closure-`op` overload of `lfnSeqFoldr`.
  result = initial
  for i in countdown(items.high, 0):
    result = op(items[i], result)

proc lfnSeqRemoveIf*[T](items: openArray[T]; pred: proc(item: T): bool {.nimcall.}): seq[T] =
  ## Backs LFN's `remove-if` builtin — the inverse of `lfnSeqFilter`.
  for item in items:
    if not pred(item):
      result.add item

proc lfnSeqRemoveIf*[T](items: openArray[T]; pred: proc(item: T): bool {.closure.}): seq[T] =
  ## Closure-`pred` overload of `lfnSeqRemoveIf`.
  for item in items:
    if not pred(item):
      result.add item

proc lfnSeqCount*[T](items: openArray[T]; pred: proc(item: T): bool {.nimcall.}): int =
  ## Backs LFN's `count` builtin — the number of elements matching `pred`.
  for item in items:
    if pred(item):
      inc result

proc lfnSeqCount*[T](items: openArray[T]; pred: proc(item: T): bool {.closure.}): int =
  ## Closure-`pred` overload of `lfnSeqCount`.
  for item in items:
    if pred(item):
      inc result

proc lfnSeqAny*[T](items: openArray[T]; pred: proc(item: T): bool {.nimcall.}): bool =
  ## Backs LFN's `any?` builtin — true if `pred` matches at least one
  ## element.
  for item in items:
    if pred(item):
      return true
  false

proc lfnSeqAny*[T](items: openArray[T]; pred: proc(item: T): bool {.closure.}): bool =
  ## Closure-`pred` overload of `lfnSeqAny`.
  for item in items:
    if pred(item):
      return true
  false

proc lfnSeqEvery*[T](items: openArray[T]; pred: proc(item: T): bool {.nimcall.}): bool =
  ## Backs LFN's `every?` builtin — true if `pred` matches every element.
  for item in items:
    if not pred(item):
      return false
  true

proc lfnSeqEvery*[T](items: openArray[T]; pred: proc(item: T): bool {.closure.}): bool =
  ## Closure-`pred` overload of `lfnSeqEvery`.
  for item in items:
    if not pred(item):
      return false
  true

proc lfnSeqPosition*[T](items: openArray[T]; value: T): int =
  ## Backs LFN's `position` builtin. -1 when `value` isn't present —
  ## Nim's own `find`-style sentinel, rather than CL's nil, since a
  ## generic `T` has no nil-like value.
  for i, item in items:
    if item == value:
      return i
  -1

proc lfnReversed*[T](items: openArray[T]): seq[T] =
  ## Backs LFN's `reverse` builtin.
  reversed(items)

proc lfnSorted*[T](items: openArray[T]): seq[T] =
  ## Backs LFN's `sort` builtin (non-mutating, returns a new seq).
  sorted(items)

proc lfnMakeArray*[T](n: int; fill: T): seq[T] =
  ## Backs LFN's `make-array` builtin — an `n`-element seq with every
  ## slot set to `fill`.
  result = newSeq[T](n)
  for i in 0 ..< n:
    result[i] = fill

type
  LfnThrow* = ref object of CatchableError
    ## Shared base raised by `throw` (#55) — every `catch`/`throw` pair in a
    ## program raises/catches this same type, discriminated at runtime by
    ## `tag` rather than by a distinct Nim exception type per label. `tag` is
    ## the label spelling with its leading `:` stripped (`blockLabelName`),
    ## matched by string equality — deliberately *not* hygiene-folded like
    ## `break-from`'s lexical label keys, since `throw` must be able to reach
    ## a `catch` written in ordinary user code from inside a macro expansion.
    tag*: string
  LfnThrowVal*[T] = ref object of LfnThrow
    ## Carries the value passed to `(throw :tag value)`. Generic so the same
    ## exception hierarchy serves every value type; `lfnCatch` downcasts to
    ## the branch's own `typeof(body)` instantiation and re-raises if that
    ## downcast wouldn't apply, rather than deferring to Nim's `of` semantics
    ## on a general `LfnThrow`.
    value*: T

proc newLfnThrow*[T](tag: string; value: T): LfnThrowVal[T] =
  ## Builds the exception object raised by `(throw :tag value)` (#55). The
  ## backend wraps the call to this in a raw `nnkRaiseStmt` (see `emitThrow`)
  ## rather than calling a `{.noreturn.}` proc directly, purely to follow the
  ## same convention `emitRaise`/`emitBreakFrom` already use for their own
  ## noreturn forms — a raw `raise`/`break` statement node is unambiguously
  ## noreturn to Nim's typechecker in any expression position, so keeping
  ## `throw` in that same shape avoids relying on `{.noreturn.}` inference on
  ## an ordinary proc call, which is a separate (and less predictable) path
  ## through the compiler.
  LfnThrowVal[T](tag: tag, value: value, msg: "unhandled lfn throw :" & tag)

template lfnCatch*(tagName: static string; body: untyped): untyped =
  ## Implements `(catch :tag body…)` (#55). `body` is `typeof`'d directly (no
  ## type slot in the surface syntax to draw the carried type from), unlike
  ## `emitLabelledBlock`'s carrier for `break-from` — that copies the body
  ## with same-target `break-from`s erased before taking `typeof`, since a
  ## lexical, in-place `break`/`return` there would otherwise foul the type
  ## check. Here `typeof(body)` is expanded in place at the use site, so an
  ## ordinary `break`/`continue`/`return` inside `body` still semchecks fine.
  ##
  ## The `e of LfnThrowVal[typeof(body)]` guard matters: without it, a
  ## same-tag throw carrying a value of a different type is an
  ## `ObjectConversionDefect` in debug builds and silently unchecked under
  ## `-d:danger`. With the guard, a tag match with a mismatched value type
  ## re-raises instead, so it propagates to (and can be handled by) an outer
  ## catch rather than corrupting the result.
  when typeof(body) is void:
    try:
      body
    except LfnThrow as e:
      if e.tag != tagName:
        raise
  else:
    try:
      body
    except LfnThrow as e:
      if e.tag != tagName or not (e of LfnThrowVal[typeof(body)]):
        raise
      LfnThrowVal[typeof(body)](e).value

template lfnInitarg*(name: string) {.pragma.}
  ## The field pragma `defclass` attaches to a slot carrying an `:initarg`
  ## (#85) — `(name Type :initarg :nom)` emits the object field as
  ## `name {.lfnInitarg: "nom".}: Type`. `lfnMakeInstance` reads this pragma
  ## back off the field via `getImpl` (not `getTypeImpl`, which normalizes
  ## a type and has historically dropped field pragmas) to map an external
  ## initarg name onto its field, including across an inherited slot — the
  ## visibility a macro-expand-time `defclass`/`make-instance` pair can't
  ## have, since they're separate macro invocations over separate classes.

proc lfnInitargPragmaValue(entry: NimNode): tuple[ok: bool, name: string] =
  ## Matches one entry of a field's pragma list against `lfnInitarg: "x"`.
  ## A single-argument custom pragma can be represented either as
  ## `nnkExprColonExpr(lfnInitarg, strLit)` or `nnkCall(lfnInitarg, strLit)`,
  ## and its head may be a resolved `nnkSym` rather than a bare `nnkIdent`
  ## (the type came back through `getImpl`, already partially resolved) —
  ## `eqIdent` compares by spelling regardless of which.
  if entry.kind in {nnkExprColonExpr, nnkCall} and entry.len == 2 and
      entry[0].eqIdent("lfnInitarg") and entry[1].kind == nnkStrLit:
    (true, entry[1].strVal)
  else:
    (false, "")

proc lfnWalkRecList(recList: NimNode; fields: var seq[string]; initargs: var seq[(string, string)]) =
  ## Collects field names and `lfnInitarg`-tagged initargs from one
  ## `nnkRecList`, recursing into a `case` field's discriminator and every
  ## branch's own field list.
  for field in recList:
    case field.kind
    of nnkIdentDefs:
      for i in 0 ..< field.len - 2:
        let nameNode = field[i]
        if nameNode.kind == nnkPragmaExpr:
          fields.add nameNode[0].strVal
          for entry in nameNode[1]:
            let (ok, initarg) = lfnInitargPragmaValue(entry)
            if ok:
              # The pragma carries the keyword's own text, colon included
              # (defclass's lfn-slot-field has no substring primitive to
              # strip it with) — stripped here instead, once, on the Nim
              # side where slicing is trivial.
              let stripped = if initarg.startsWith(":"): initarg[1 .. ^1] else: initarg
              initargs.add (stripped, nameNode[0].strVal)
        else:
          fields.add nameNode.strVal
    of nnkRecCase:
      lfnWalkRecList(newTree(nnkRecList, field[0]), fields, initargs)
      for branch in field[1 .. ^1]:
        lfnWalkRecList(branch[^1], fields, initargs)
    else:
      discard

proc lfnCollectClassShape(typeSym: NimNode): tuple[fields: seq[string], initargs: seq[(string, string)]] =
  ## Walks `typeSym`'s definition — through `ref`/`ptr` and `type X = Y`
  ## aliasing, and up the `nnkOfInherit` chain to `RootObj`/`object` — and
  ## collects every field name (`fields`) and every `(initarg, fieldName)`
  ## pair recorded via `lfnInitarg` (`initargs`), across the whole
  ## inheritance chain. A `case` object's discriminator and per-branch
  ## fields are walked too, so `lfnMakeInstance` works the same as `new`
  ## for a variant object, not just a plain one.
  var cur = typeSym
  while true:
    var typeNode = cur.getImpl()[2]
    while typeNode.kind in {nnkRefTy, nnkPtrTy} and typeNode.len == 1:
      typeNode = typeNode[0]
    while typeNode.kind == nnkSym:
      typeNode = typeNode.getImpl()[2]
    if typeNode.kind != nnkObjectTy:
      break
    var parentSym: NimNode = nil
    if typeNode[1].kind == nnkOfInherit:
      parentSym = typeNode[1][0]
    lfnWalkRecList(typeNode[2], result.fields, result.initargs)
    if parentSym == nil or parentSym.eqIdent("RootObj"):
      break
    cur = parentSym

macro lfnMakeInstance*(T: typedesc; args: varargs[untyped]): untyped =
  ## Implements `make-instance` (#85): builds the same `nnkObjConstr` as
  ## `new` (backend.nim's `emitNew`), after resolving each initializer's
  ## name against `T`'s fields and `:initarg`-tagged fields across its
  ## whole inheritance chain (`lfnCollectClassShape`) — visibility a
  ## macro-expand-time `defclass`/`make-instance` pair can't have on their
  ## own. A slot's own field name and its `:initarg` are both accepted
  ## (aliases, not a rename): `(name Type :initarg :nom)` can be
  ## initialized as either `(name ...)` or `(nom ...)`.
  ##
  ## Each entry of `args` arrives as `nnkCall(ident, valueExpr)` — exactly
  ## the shape `backend.nim`'s `emitCall` builds for `(name value)` — since
  ## `varargs[untyped]` skips Nim's own symbol resolution, so an
  ## initializer name like `nom` need not itself be a callable.
  let typeSym = T.getTypeInst()[1]
  let shape = lfnCollectClassShape(typeSym)
  result = nnkObjConstr.newTree(typeSym)
  var usedFields: seq[string]
  for arg in args:
    if arg.kind notin {nnkCall, nnkCommand} or arg.len != 2 or arg[0].kind != nnkIdent:
      error("make-instance field initializer must be (name value)", arg)
    let rawName = arg[0].strVal
    var fieldName = ""
    if rawName in shape.fields:
      fieldName = rawName
    else:
      for (initarg, target) in shape.initargs:
        if initarg == rawName:
          fieldName = target
          break
    if fieldName.len == 0:
      error("unknown make-instance field or initarg '" & rawName & "' for " & typeSym.repr, arg)
    if fieldName in usedFields:
      error("duplicate make-instance initializer for field '" & fieldName & "'", arg)
    usedFields.add fieldName
    result.add nnkExprColonExpr.newTree(ident(fieldName), arg[1])
