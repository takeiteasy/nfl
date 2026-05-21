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
