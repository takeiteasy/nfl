# Nim Interop

NFL has full access to the Nim standard library and any Nim package. Everything you can write in Nim is reachable from NFL.

## Importing Nim modules

```lisp
(import std/strutils)
(import std/os)
(import std/math)
```

After importing, all exported symbols are available by name:

```lisp
(import std/strutils)
(echo (toUpperAscii "hello"))   ; HELLO
```

## Calling Nim procedures

Nim procedures are called with the same `(name args...)` syntax as NFL procedures:

```lisp
(import std/math)
(echo (sqrt 2.0))
(echo (pow 2.0 10.0))
```

## Dot notation — field access and method calls

`(. object field)` accesses a field or calls a UFCS method:

```lisp
(. seq len)             ; seq.len
(. str toUpperAscii)    ; str.toUpperAscii()  (UFCS)
(. obj pairs)           ; obj.pairs
```

Chained access:

```lisp
(. (. obj inner) field)
```

Or use the shorthand dot syntax directly on symbols where Nim allows it:

```lisp
(echo quoted.kind)      ; NimNode field access
```

## Named (keyword) arguments

Use `(: name value)` to pass a named argument:

```lisp
(proc personAge ((p Person)) (: int)
  (. p age))

(echo (personAge (: p myPerson)))
```

## Type annotations

Type annotations use `(: type)` in return position and `(name type)` pairs in parameter lists:

```lisp
(proc shout ((name string)) (: string)
  (toUpperAscii name))
```

Local bindings can be typed with `(name type)` inside `var` / `let`:

```lisp
(var (((count int) 0))
  (echo count))
```

Module-level `var` declarations can be typed too, and the value is optional
(the variable is zero-initialized when omitted):

```lisp
(var (limit int) 100)
(var (buf int))
```

## Exports

Append `*` to a name to export it from the compiled module, making it accessible from Nim:

```lisp
(proc doubled* ((x int)) (: int)
  (* x 2))

(const maxItems* 100)

(type Point*
  (object
    (x int)
    (y int)))
```

## Arrays

Use `(@  ...)` to create a Nim array (fixed-size) rather than a `seq`:

```lisp
(var arr (@ [1 2 3]))
```

## Bracket operator

`(|[]| collection index)` maps to Nim's `[]` operator:

```lisp
(var names (@ ["a" "b" "c"]))
(echo (|[]| names 1))    ; b
```

## Pragmas

Pragmas annotate declarations with Nim compiler hints. They are written as `{.name.}` or `{.name: value.}` and placed immediately after the declaration name.

### Marker pragmas (no argument)

```lisp
(proc addFast {.inline.} ((x int) (y int)) (: int)
  (+ x y))

(proc purePlus {.inline, noSideEffect.} ((x int) (y int)) (: int)
  (+ x y))
```

### Value pragmas (key: value)

```lisp
(proc safeAdd {.raises: [].} ((x int) (y int)) (: int)
  (+ x y))

(proc oldDouble {.deprecated: "use doubled instead".} ((x int)) (: int)
  (* x 2))
```

### Mixed pragmas

```lisp
(proc fastSafe {.inline, raises: [].} ((x int) (y int)) (: int)
  (+ x y))
```

### Pragmas on other declarations

```lisp
(type Point {.bycopy.}
  (object (x int) (y int)))

(var counter {.used.} 0)
(const maxItems {.used.} 100)
```

A pragma also composes with a typed name, with or without a value:

```lisp
(var (flag int) {.volatile.})
(var (flag int) {.volatile.} 42)
```

A pragma can annotate individual bindings inside a `var`/`const` section too,
including a value-less typed binding:

```lisp
(var (((flag int) {.volatile.})           ; zero-initialized, pragma-annotated
      ((counter int) {.used.} 0)))        ; pragma-annotated, with a value
```

### Local binding pragmas

```lisp
(let ((x {.used.} 10))
  x)

(let (((n int) {.used.} 5))
  n)
```

See `examples/pragmas.nfl` for a complete runnable demonstration.

## NFL-defined templates and iterators from Nim

When you export an NFL-defined template or iterator (with `*`), it is a real Nim symbol and can be called from Nim code that imports the compiled module, exactly like a hand-written Nim template or iterator.

```lisp
; In myfuncs.nfl — these are exported Nim symbols.
(template square* ((x int)) (: int)
  (* x x))

(iterator upTo* ((n int)) (: int)
  (for (i (.. 0 (- n 1)))
    (yield i)))
```

From Nim:

```nim
# myapp.nim
import myfuncs

echo square(5)          # 25
for x in upTo(3):
  echo x                # 0 1 2
```

Templates and iterators support the same pragma and generic (`[T]`) annotations
as `proc` — as do `func` and `converter`:

```lisp
(template square* {.inline.} ((x int)) (: int) (* x x))
(iterator upTo* [T] ((n T)) (: T) (yield n))
(func identity* [T] ((x T)) (: T) x)
```

## Full interop example

```lisp
(import std/strutils)
(import std/os)
(import std/math)

(proc shout ((name string)) (: string)
  (name.toUpperAscii))

(proc hypotenuse ((a float) (b float)) (: float)
  (sqrt (+ (* a a) (* b b))))

(var currentDir (getCurrentDir))
(echo (shout (lastPathPart currentDir)))
(echo (hypotenuse 3.0 4.0))
```
