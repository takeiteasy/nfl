type
  NimpDatumKind* = enum
    ndNil, ndBool, ndInt, ndFloat, ndString, ndSymbol, ndList, ndVector

  NimpDatum* = ref object
    case kind*: NimpDatumKind
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
      items*: seq[NimpDatum]

proc nimpNilDatum*(): NimpDatum =
  NimpDatum(kind: ndNil)

proc nimpBoolDatum*(value: bool): NimpDatum =
  NimpDatum(kind: ndBool, boolVal: value)

proc nimpIntDatum*(value: BiggestInt): NimpDatum =
  NimpDatum(kind: ndInt, intVal: value)

proc nimpFloatDatum*(value: BiggestFloat): NimpDatum =
  NimpDatum(kind: ndFloat, floatVal: value)

proc nimpStringDatum*(value: string): NimpDatum =
  NimpDatum(kind: ndString, strVal: value)

proc nimpSymbolDatum*(value: string): NimpDatum =
  NimpDatum(kind: ndSymbol, sym: value)

proc nimpListDatum*(items: varargs[NimpDatum]): NimpDatum =
  NimpDatum(kind: ndList, items: @items)

proc nimpVectorDatum*(items: varargs[NimpDatum]): NimpDatum =
  NimpDatum(kind: ndVector, items: @items)

template nimpStmt*(body: untyped) =
  when compiles(block:
    discard body):
    discard body
  else:
    body

proc nimpSeqMap*[T, U](items: openArray[T]; op: proc(item: T): U {.nimcall.}): seq[U] =
  for item in items:
    result.add op(item)

proc nimpSeqMap*[T, U](items: openArray[T]; op: proc(item: T): U {.closure.}): seq[U] =
  for item in items:
    result.add op(item)

proc nimpSeqFilter*[T](items: openArray[T]; pred: proc(item: T): bool {.nimcall.}): seq[T] =
  for item in items:
    if pred(item):
      result.add item

proc nimpSeqFilter*[T](items: openArray[T]; pred: proc(item: T): bool {.closure.}): seq[T] =
  for item in items:
    if pred(item):
      result.add item

proc nimpSeqFoldl*[T, U](items: openArray[T]; initial: U; op: proc(acc: U; item: T): U {.nimcall.}): U =
  result = initial
  for item in items:
    result = op(result, item)

proc nimpSeqFoldl*[T, U](items: openArray[T]; initial: U; op: proc(acc: U; item: T): U {.closure.}): U =
  result = initial
  for item in items:
    result = op(result, item)

proc nimpSeqFoldr*[T, U](items: openArray[T]; initial: U; op: proc(item: T; acc: U): U {.nimcall.}): U =
  result = initial
  for i in countdown(items.high, 0):
    result = op(items[i], result)

proc nimpSeqFoldr*[T, U](items: openArray[T]; initial: U; op: proc(item: T; acc: U): U {.closure.}): U =
  result = initial
  for i in countdown(items.high, 0):
    result = op(items[i], result)
