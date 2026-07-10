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

### `defvar` — module-level binding

```lisp
(defvar name value)
(defvar (name type) value)    ; with type annotation
(defvar name {.pragma.} value)
```

### `var` — local mutable binding

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
(defconstant name value)       ; alias for const
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
(defvar double
  (do ((n int)) (: int)
    (* n 2)))
```

## Types

### `type` — type declaration

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

### `new` — object construction

```lisp
(new TypeName
  (field1 value1)
  (field2 value2))
```

```lisp
(defvar p (new Person
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
