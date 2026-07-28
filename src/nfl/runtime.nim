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
