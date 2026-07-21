# Getting Started

## Prerequisites

- **Nim >= 2.2.4** — install via [choosenim](https://github.com/dom96/choosenim) or your package manager
- **nimble** — bundled with Nim

## Installation

Clone the repository and build the CLI:

```sh
git clone https://todo.sr.ht/~takeiteasy/nfl
cd nfl
nimble build
```

This produces `bin/nfl`. Add it to your `PATH` or invoke it directly.

## First program

Create `hello.nfl`:

```lisp
(echo "Hello, NFL!")
```

Compile and run:

```sh
nfl compile hello.nfl
./hello
# Hello, NFL!
```

To type-check without producing a binary:

```sh
nfl check hello.nfl
```

## Core concepts

### S-expressions

NFL is written as s-expressions — parenthesised lists where the first element is the operator or procedure name:

```lisp
(echo "hello")          ; call echo with one argument
(+ 1 2)                 ; addition
(if condition a b)      ; if expression
```

Semicolons start line comments.

### Variables

`var` binds a name at module scope:

```lisp
(var x 42)
(var greeting "hello")
```

`var` with a parenthesized binding list and a body instead creates a local
mutable variable scoped to that body:

```lisp
(var ((count 0))
  (set! count (+ count 1))
  (echo count))
```

`let` creates an immutable local binding:

```lisp
(let ((x 10))
  (echo x))
```

Type annotations use the `(name type)` pair form:

```lisp
(var (((count int) 0))
  (echo count))
```

Module-level `var` declarations can also be typed, and the value can be
omitted (the variable is then zero-initialized):

```lisp
(var (limit int) 100)
(var (buf int))          ; zero-initialized
```

A binding list with no body declares several module-level variables at once,
reusing the same binding-list syntax as the local mutable-binding form above:

```lisp
(var (((width int) 640)
      ((height int) 480)))
```

`const` supports the same multi-binding form:

```lisp
(const ((pi 3.14159)
        (e 2.71828)))
```

### Procedures

`proc` declares a typed procedure:

```lisp
(proc add ((a int) (b int)) (: int)
  (+ a b))

(echo (add 3 4))   ; 7
```

`do` defines an anonymous procedure (lambda):

```lisp
(var double
  (do ((n int)) (: int)
    (* n 2)))

(echo (double 5))  ; 10
```

### Control flow

```lisp
(if condition
  (echo "yes")
  (echo "no"))

(when condition
  (echo "only when true"))

(cond
  (false (echo "skipped"))
  (true  (echo "selected")))
```

### Sequences

Square brackets construct sequences:

```lisp
(var nums [1 2 3 4 5])
(echo (at nums 0))        ; 1
(echo (. nums len))       ; 5
```

### For loops

```lisp
(for (n [1 2 3])
  (echo n))

(for (i (.. 0 4))         ; range 0..4
  (echo i))
```

### Imports

Use Nim's standard library directly:

```lisp
(import std/strutils)
(import std/os)

(echo (toUpperAscii "hello"))
```

## Next steps

- [Language Reference](language-reference.md) — complete coverage of all forms
- [Macro System](macros.md) — `defmacro`, quasiquote, and the built-in preamble macros
- [Nim Interop](nim-interop.md) — dot notation, type annotations, exports, pragmas
- Browse the `examples/` directory for runnable programs
