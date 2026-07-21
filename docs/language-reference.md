# Language Reference

## Literals

| Form | Type |
|------|------|
| `42` | integer |
| `3.14` | float |
| `"hello"` | string |
| `true` / `false` | bool |
| `nil` | nil / void |
| `[1 2 3]` | sequence |
| `'form` | quoted form |

## Comments

```lisp
; single-line comment
```

## Variables

### `var` — module-level declaration or local mutable binding

`var` is two grammars distinguished by shape. A bare name or a flat
`(name type)` pair is a module/statement-level declaration:

```lisp
(var name value)
(var (name type) value)    ; with explicit type annotation and value
(var (name type))          ; type annotation only — Nim zero-initializes
(var name {.pragma.} value)
```

A value is required when no type annotation is given.

A parenthesized list of bindings followed by a body is the local
mutable-binding form (like `let`, but mutable):

```lisp
(var ((name value)) body...)
(var (((name type) value)) body...)
```

Multiple bindings in one `var`:

```lisp
(var ((a 1) (b 2))
  (echo (+ a b)))
```

### `let` — local immutable binding

```lisp
(let ((name value)) body...)
(let (((name type) value)) body...)
(let ((name {.pragma.} value)) body...)
```

### `set!` — mutation

```lisp
(set! name new-value)
```

## Constants

```lisp
(const name value)
(const name* value)            ; exported
(const (name type) value)      ; with type annotation
```

## Procedures

### `proc` — named procedure

```lisp
(proc name (params...) (: return-type)
  body...)

(proc name {.pragma.} (params...) (: return-type)
  body...)

(proc name* (params...) (: return-type)  ; exported
  body...)
```

Each parameter is `(name type)`:

```lisp
(proc add ((a int) (b int)) (: int)
  (+ a b))
```

Omit the return type for void procedures:

```lisp
(proc greet ((name string))
  (echo "Hello, " name))
```

### `do` — anonymous procedure

```lisp
(do (params...) (: return-type)
  body...)
```

```lisp
(var double
  (do ((n int)) (: int)
    (* n 2)))
```

### `template` — Nim template definition

Defines a zero-cost compile-time template. Templates expand inline at the call site with no runtime overhead.

```lisp
(template name (params...) (: return-type)
  body...)

(template name* (params...) ...)  ; exported
(template name {.pragma.} (params...) ...)
```

Parameters follow the same `(name type)` form as `proc`. A bare symbol parameter (no type) becomes an `untyped` template parameter in Nim:

```lisp
; Typed parameter
(template square ((x int)) (: int)
  (* x x))

; Untyped parameter — accepts any expression
(template twice (expr)
  (block expr expr))

; With logging prefix
(template withLog ((label string) body)
  (block
    (echo ">>> " label)
    body
    (echo "<<< " label)))
```

The return type annotation `(: type)` is optional; omit it for void templates.

### `iterator` — Nim iterator definition

Defines a Nim inline iterator. Iterators are consumed by `for` loops and must have an explicit return type `(: elem-type)`.

```lisp
(iterator name ((param type) ...) (: yield-type)
  body...)

(iterator name* ((param type) ...) (: yield-type) ...)  ; exported
(iterator name {.pragma.} ((param type) ...) (: yield-type) ...)
```

Use `yield` inside the body to produce values:

```lisp
(iterator upTo ((n int)) (: int)
  (for (i (.. 0 (- n 1)))
    (yield i)))

(for (x (upTo 5))
  (echo x))    ; prints 0 1 2 3 4
```

### `yield` — produce an iterator value

```lisp
(yield expr)
```

### `method` — dynamic dispatch

See the [Types → method](#method--method-definition) section above.

Valid only inside an `iterator` body. Nim's compiler enforces this restriction.

## Types

### `type` — type declaration

**Object type:**

```lisp
(type Name
  (object
    (field1 type1)
    (field2 type2)))
```

With export and pragmas:

```lisp
(type Name* {.bycopy.}
  (object
    (field type)))
```

**Object inheritance** — the `(of Base)` clause immediately after `object` declares a base type:

```lisp
(type Animal (ref (object (of RootObj) (name string))))
(type Dog    (ref (object (of Animal))))
```

**Distinct type** — a newtype wrapper that prevents accidental mixing:

```lisp
(type Metres (distinct float))
(proc toMetres ((x float)) (: Metres) (Metres x))
```

**Tuple type** — a structural named-field record:

```lisp
(type Point (tuple (x float) (y float)))
(proc getX ((p Point)) (: float) (. p x))
```

> Named tuples are constructed on the Nim side: `Point(x: 1.0, y: 2.0)`.

**Ref object** — heap-allocated object managed by the garbage collector:

```lisp
(type Node (ref (object (val int))))
(proc mkNode ((v int)) (: Node) (new Node (val v)))
```

The `(ref ...)` form composes with any type body, including inherited objects:

```lisp
(type Base (ref (object (of RootObj) (x int))))
```

### `method` — method definition

Defines a Nim method with dynamic dispatch via the vtable. The syntax is identical to `proc`. Tag the base-type overload with `{.base.}`:

```lisp
(method speak {.base.} ((a Animal)) (: string) "...")
(method speak ((d Dog)) (: string) "woof")
```

Dispatch is determined at runtime by the concrete type:

```lisp
(var base (toAnimal dog))
(echo (speak base))  ; → "woof"
```

### `new` — object construction

```lisp
(new TypeName
  (field1 value1)
  (field2 value2))
```

```lisp
(var p (new Person
  (name "Ada")
  (age  36)))
```

## Control flow

### `if`

```lisp
(if condition then-expr else-expr)
```

### `when` / `unless` (preamble macros)

```lisp
(when condition body...)
(unless condition body...)
```

### `cond` (preamble macro)

```lisp
(cond
  (test1 body1...)
  (test2 body2...)
  ...)
```

### `case`

```lisp
(case value
  (of val1 body1...)
  (of val2 body2...)
  (else body...))
```

### `block`

```lisp
(block body...)
```

Evaluates multiple forms and returns the last value.

## Loops

### `for`

Single variable over a sequence or range:

```lisp
(for (x collection) body...)
(for (i (.. 0 9)) body...)
```

Multi-variable (e.g. index + value via `pairs`):

```lisp
(for ((idx val) (. seq pairs)) body...)
```

### `while`

```lisp
(while condition body...)
```

### `break` and `continue`

`(break)` exits the innermost loop. `(continue)` skips the rest of the current iteration:

```lisp
(while true
  (if (>= i limit) (break) nil)
  (set! i (+ i 1)))

(while (< k 10)
  (set! k (+ k 1))
  (if (== 0 (mod k 2)) (continue) nil)
  (echo "odd: " k))
```

## Control flow — early exit

### `return`

`(return expr)` exits the enclosing procedure with a value. `(return)` returns void:

```lisp
(proc clamp ((n int) (lo int) (hi int)) (: int)
  (if (< n lo) (return lo) nil)
  (if (> n hi) (return hi) nil)
  n)
```

### `discard`

`(discard expr)` discards the result of an expression, suppressing unused-result warnings. `(discard)` is a bare empty discard:

```lisp
(discard (sideEffect))
(discard)
```

## Error handling

```lisp
(try
  body...
  (except ExceptionType fallback-value)
  (except (e ExceptionType) (. e msg))
  (finally cleanup...))
```

Raise an exception:

```lisp
(raise (newException ValueError "message"))
```

## Sequences and collections

```lisp
[1 2 3]                        ; sequence literal
(@ [1 2 3])                    ; array literal
(at seq index)                 ; index access
(|[]| seq index)               ; bracket operator
(slice seq start end)          ; subsequence
(& seq1 seq2)                  ; concatenation
(. seq len)                    ; length field
```

Preamble helpers:

```lisp
(first items)                  ; items[0]
(rest items)                   ; items[1..]
(empty? items)                 ; len == 0
(append left right)            ; concatenation
(map items op)
(filter items pred)
(foldl items initial op)
(foldr items initial op)
```

## Imports

```lisp
(import std/strutils)
(import std/os)
```

## Threading macros (preamble)

```lisp
(-> value form1 form2 ...)     ; thread first
(->> value form1 form2 ...)    ; thread last
(as-> value name form1 ...)    ; thread with name
```

`->` inserts `value` as the first argument of each form:

```lisp
(-> "hello" toUpperAscii (echo))
; equivalent to (echo (toUpperAscii "hello"))
```

## Quoting

```lisp
'form                          ; quote
`form                          ; quasiquote
,expr                          ; unquote
,@expr                         ; unquote-splicing
```

## Operators

NFL uses standard infix operators in prefix position:

```lisp
(+ a b)   (- a b)   (* a b)   (/ a b)   (div a b)
(== a b)  (!= a b)  (< a b)   (<= a b)  (> a b)  (>= a b)
(and a b) (or a b)  (not a)
(.. a b)            ; range
```
