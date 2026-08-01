import std/algorithm
import std/macros
import std/strutils

type
  NflDatumKind* = enum
    ndNil, ndBool, ndInt, ndFloat, ndString, ndSymbol, ndList, ndVector

  NflDatum* = ref object
    case kind*: NflDatumKind
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
      items*: seq[NflDatum]

proc nflNilDatum*(): NflDatum =
  NflDatum(kind: ndNil)

proc nflBoolDatum*(value: bool): NflDatum =
  NflDatum(kind: ndBool, boolVal: value)

proc nflIntDatum*(value: BiggestInt): NflDatum =
  NflDatum(kind: ndInt, intVal: value)

proc nflFloatDatum*(value: BiggestFloat): NflDatum =
  NflDatum(kind: ndFloat, floatVal: value)

proc nflStringDatum*(value: string): NflDatum =
  NflDatum(kind: ndString, strVal: value)

proc nflSymbolDatum*(value: string): NflDatum =
  NflDatum(kind: ndSymbol, sym: value)

proc nflListDatum*(items: varargs[NflDatum]): NflDatum =
  NflDatum(kind: ndList, items: @items)

proc nflVectorDatum*(items: varargs[NflDatum]): NflDatum =
  NflDatum(kind: ndVector, items: @items)

template nflStmt*(body: untyped) =
  when compiles(block:
    discard body):
    discard body
  else:
    body

template nflMatchArity*(x: untyped; n: static[int]; exact: static[bool]): bool =
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

proc nflSeqMap*[T, U](items: openArray[T]; op: proc(item: T): U {.nimcall.}): seq[U] =
  for item in items:
    result.add op(item)

proc nflSeqMap*[T, U](items: openArray[T]; op: proc(item: T): U {.closure.}): seq[U] =
  for item in items:
    result.add op(item)

proc nflSeqFilter*[T](items: openArray[T]; pred: proc(item: T): bool {.nimcall.}): seq[T] =
  for item in items:
    if pred(item):
      result.add item

proc nflSeqFilter*[T](items: openArray[T]; pred: proc(item: T): bool {.closure.}): seq[T] =
  for item in items:
    if pred(item):
      result.add item

proc nflSeqFoldl*[T, U](items: openArray[T]; initial: U; op: proc(acc: U; item: T): U {.nimcall.}): U =
  result = initial
  for item in items:
    result = op(result, item)

proc nflSeqFoldl*[T, U](items: openArray[T]; initial: U; op: proc(acc: U; item: T): U {.closure.}): U =
  result = initial
  for item in items:
    result = op(result, item)

proc nflSeqFoldr*[T, U](items: openArray[T]; initial: U; op: proc(item: T; acc: U): U {.nimcall.}): U =
  result = initial
  for i in countdown(items.high, 0):
    result = op(items[i], result)

proc nflSeqFoldr*[T, U](items: openArray[T]; initial: U; op: proc(item: T; acc: U): U {.closure.}): U =
  result = initial
  for i in countdown(items.high, 0):
    result = op(items[i], result)

proc nflSeqRemoveIf*[T](items: openArray[T]; pred: proc(item: T): bool {.nimcall.}): seq[T] =
  for item in items:
    if not pred(item):
      result.add item

proc nflSeqRemoveIf*[T](items: openArray[T]; pred: proc(item: T): bool {.closure.}): seq[T] =
  for item in items:
    if not pred(item):
      result.add item

proc nflSeqCount*[T](items: openArray[T]; pred: proc(item: T): bool {.nimcall.}): int =
  for item in items:
    if pred(item):
      inc result

proc nflSeqCount*[T](items: openArray[T]; pred: proc(item: T): bool {.closure.}): int =
  for item in items:
    if pred(item):
      inc result

proc nflSeqAny*[T](items: openArray[T]; pred: proc(item: T): bool {.nimcall.}): bool =
  for item in items:
    if pred(item):
      return true
  false

proc nflSeqAny*[T](items: openArray[T]; pred: proc(item: T): bool {.closure.}): bool =
  for item in items:
    if pred(item):
      return true
  false

proc nflSeqEvery*[T](items: openArray[T]; pred: proc(item: T): bool {.nimcall.}): bool =
  for item in items:
    if not pred(item):
      return false
  true

proc nflSeqEvery*[T](items: openArray[T]; pred: proc(item: T): bool {.closure.}): bool =
  for item in items:
    if not pred(item):
      return false
  true

proc nflSeqPosition*[T](items: openArray[T]; value: T): int =
  ## -1 when `value` isn't present — Nim's own `find`-style sentinel,
  ## rather than CL's nil, since a generic `T` has no nil-like value.
  for i, item in items:
    if item == value:
      return i
  -1

proc nflReversed*[T](items: openArray[T]): seq[T] =
  reversed(items)

proc nflSorted*[T](items: openArray[T]): seq[T] =
  sorted(items)

proc nflMakeArray*[T](n: int; fill: T): seq[T] =
  result = newSeq[T](n)
  for i in 0 ..< n:
    result[i] = fill

type
  NflThrow* = ref object of CatchableError
    ## Shared base raised by `throw` (#55) — every `catch`/`throw` pair in a
    ## program raises/catches this same type, discriminated at runtime by
    ## `tag` rather than by a distinct Nim exception type per label. `tag` is
    ## the label spelling with its leading `:` stripped (`blockLabelName`),
    ## matched by string equality — deliberately *not* hygiene-folded like
    ## `break-from`'s lexical label keys, since `throw` must be able to reach
    ## a `catch` written in ordinary user code from inside a macro expansion.
    tag*: string
  NflThrowVal*[T] = ref object of NflThrow
    ## Carries the value passed to `(throw :tag value)`. Generic so the same
    ## exception hierarchy serves every value type; `nflCatch` downcasts to
    ## the branch's own `typeof(body)` instantiation and re-raises if that
    ## downcast wouldn't apply, rather than deferring to Nim's `of` semantics
    ## on a general `NflThrow`.
    value*: T

proc newNflThrow*[T](tag: string; value: T): NflThrowVal[T] =
  ## Builds the exception object raised by `(throw :tag value)` (#55). The
  ## backend wraps the call to this in a raw `nnkRaiseStmt` (see `emitThrow`)
  ## rather than calling a `{.noreturn.}` proc directly, purely to follow the
  ## same convention `emitRaise`/`emitBreakFrom` already use for their own
  ## noreturn forms — a raw `raise`/`break` statement node is unambiguously
  ## noreturn to Nim's typechecker in any expression position, so keeping
  ## `throw` in that same shape avoids relying on `{.noreturn.}` inference on
  ## an ordinary proc call, which is a separate (and less predictable) path
  ## through the compiler.
  NflThrowVal[T](tag: tag, value: value, msg: "unhandled nfl throw :" & tag)

template nflCatch*(tagName: static string; body: untyped): untyped =
  ## Implements `(catch :tag body…)` (#55). `body` is `typeof`'d directly (no
  ## type slot in the surface syntax to draw the carried type from), unlike
  ## `emitLabelledBlock`'s carrier for `break-from` — that copies the body
  ## with same-target `break-from`s erased before taking `typeof`, since a
  ## lexical, in-place `break`/`return` there would otherwise foul the type
  ## check. Here `typeof(body)` is expanded in place at the use site, so an
  ## ordinary `break`/`continue`/`return` inside `body` still semchecks fine.
  ##
  ## The `e of NflThrowVal[typeof(body)]` guard matters: without it, a
  ## same-tag throw carrying a value of a different type is an
  ## `ObjectConversionDefect` in debug builds and silently unchecked under
  ## `-d:danger`. With the guard, a tag match with a mismatched value type
  ## re-raises instead, so it propagates to (and can be handled by) an outer
  ## catch rather than corrupting the result.
  when typeof(body) is void:
    try:
      body
    except NflThrow as e:
      if e.tag != tagName:
        raise
  else:
    try:
      body
    except NflThrow as e:
      if e.tag != tagName or not (e of NflThrowVal[typeof(body)]):
        raise
      NflThrowVal[typeof(body)](e).value

template nflInitarg*(name: string) {.pragma.}
  ## The field pragma `defclass` attaches to a slot carrying an `:initarg`
  ## (#85) — `(name Type :initarg :nom)` emits the object field as
  ## `name {.nflInitarg: "nom".}: Type`. `nflMakeInstance` reads this pragma
  ## back off the field via `getImpl` (not `getTypeImpl`, which normalizes
  ## a type and has historically dropped field pragmas) to map an external
  ## initarg name onto its field, including across an inherited slot — the
  ## visibility a macro-expand-time `defclass`/`make-instance` pair can't
  ## have, since they're separate macro invocations over separate classes.

proc nflInitargPragmaValue(entry: NimNode): tuple[ok: bool, name: string] =
  ## Matches one entry of a field's pragma list against `nflInitarg: "x"`.
  ## A single-argument custom pragma can be represented either as
  ## `nnkExprColonExpr(nflInitarg, strLit)` or `nnkCall(nflInitarg, strLit)`,
  ## and its head may be a resolved `nnkSym` rather than a bare `nnkIdent`
  ## (the type came back through `getImpl`, already partially resolved) —
  ## `eqIdent` compares by spelling regardless of which.
  if entry.kind in {nnkExprColonExpr, nnkCall} and entry.len == 2 and
      entry[0].eqIdent("nflInitarg") and entry[1].kind == nnkStrLit:
    (true, entry[1].strVal)
  else:
    (false, "")

proc nflWalkRecList(recList: NimNode; fields: var seq[string]; initargs: var seq[(string, string)]) =
  ## Collects field names and `nflInitarg`-tagged initargs from one
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
            let (ok, initarg) = nflInitargPragmaValue(entry)
            if ok:
              # The pragma carries the keyword's own text, colon included
              # (defclass's nfl-slot-field has no substring primitive to
              # strip it with) — stripped here instead, once, on the Nim
              # side where slicing is trivial.
              let stripped = if initarg.startsWith(":"): initarg[1 .. ^1] else: initarg
              initargs.add (stripped, nameNode[0].strVal)
        else:
          fields.add nameNode.strVal
    of nnkRecCase:
      nflWalkRecList(newTree(nnkRecList, field[0]), fields, initargs)
      for branch in field[1 .. ^1]:
        nflWalkRecList(branch[^1], fields, initargs)
    else:
      discard

proc nflCollectClassShape(typeSym: NimNode): tuple[fields: seq[string], initargs: seq[(string, string)]] =
  ## Walks `typeSym`'s definition — through `ref`/`ptr` and `type X = Y`
  ## aliasing, and up the `nnkOfInherit` chain to `RootObj`/`object` — and
  ## collects every field name (`fields`) and every `(initarg, fieldName)`
  ## pair recorded via `nflInitarg` (`initargs`), across the whole
  ## inheritance chain. A `case` object's discriminator and per-branch
  ## fields are walked too, so `nflMakeInstance` works the same as `new`
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
    nflWalkRecList(typeNode[2], result.fields, result.initargs)
    if parentSym == nil or parentSym.eqIdent("RootObj"):
      break
    cur = parentSym

macro nflMakeInstance*(T: typedesc; args: varargs[untyped]): untyped =
  ## Implements `make-instance` (#85): builds the same `nnkObjConstr` as
  ## `new` (backend.nim's `emitNew`), after resolving each initializer's
  ## name against `T`'s fields and `:initarg`-tagged fields across its
  ## whole inheritance chain (`nflCollectClassShape`) — visibility a
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
  let shape = nflCollectClassShape(typeSym)
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
