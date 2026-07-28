# Macro System

NFL macros are compile-time transformations that operate on s-expressions. They are defined with `defmacro` and expand before lowering to Nim AST.

## Defining macros

```lisp
(defmacro name (params...) body...)
```

The parameters receive unevaluated s-expressions. The body should return a new s-expression (usually via quasiquote) that replaces the macro call site.

```lisp
(defmacro swap! (a b)
  `(let ((tmp ,a))
     (set! ,a ,b)
     (set! ,b tmp)))
```

## Variadic parameters

Use `&rest` to collect remaining arguments into a list, and `&body` as an alias:

```lisp
(defmacro my-when (test &body body)
  `(if ,test (block ,@body) nil))

(defmacro log (&rest args)
  `(echo ,@args))
```

## Quasiquote

Quasiquote (`` ` ``) produces a template; `,` unquotes a single expression and `,@` splices a list:

```lisp
(defmacro unless (test &body body)
  `(if ,test nil (block ,@body)))

(defmacro and (&rest args)
  (if (nil? args)
      true
      `(if ,(first args) (and ,@(rest args)) false)))
```

## Macro introspection

Inside a macro body these predicates are available:

| Form | Meaning |
|------|---------|
| `(nil? x)` | x is nil / empty list |
| `(symbol? x)` | x is a symbol |
| `(list? x)` | x is a list |
| `(first x)` | first element |
| `(rest x)` | tail (all but first) |
| `(gensym "prefix")` | generate a unique symbol |
| `(macro-error "msg")` | abort expansion with an error |

## Hygiene

A quasiquoted template's own `let`, `var` (local binding form), `do`, and
`for` bindings are renamed automatically — the macro's local variables
can't be accidentally captured by, or capture, identically-named symbols
the caller passes in:

```lisp
(defmacro add-one (a)
  `(let ((tmp 1)) (+ tmp ,a)))

(let ((tmp 100))
  (add-one tmp))    ; -> 101, not 2 — the macro's tmp and the caller's tmp
                     ; are distinct bindings, even though ,a substitutes
                     ; the caller's own tmp directly into the macro's body.
```

This covers a binding target that is a literal symbol or a typed
`(name type)` pair. It does **not** cover:

- a binding target that is itself unquoted (`,name`) — a name the macro
  computes at expansion time is the macro author's own symbol and is left
  as-is (this is how the preamble's `let*` and `as->` work);
- a [destructuring](language-reference.md#destructuring) vector-pattern
  target — left unrenamed for now.

### `(unhygienic sym)` — intentional capture

Wrapping a binding target in `unhygienic` opts it out of renaming — the
escape hatch for anaphoric macros, where the macro deliberately introduces
a name for the caller's body to reference:

```lisp
(defmacro with-it (test &body body)
  `(let (((unhygienic it) ,test))
     (block ,@body)))

(with-it 41 (+ it 1))    ; -> 42 — `it` is visible to the caller's body.
```

`unhygienic` is only valid wrapping a binding target inside a quasiquote
template; using it anywhere else is an error.

### `gensym` — manual hygiene

`gensym` generates a fresh symbol that cannot clash with user code. It
remains useful for a binding introduced without going through `let`/`var`/
`do`/`for` — or any name the automatic pass doesn't cover, such as a
computed (unquoted) binding name:

```lisp
(defmacro or (&rest args)
  (if (nil? (rest args))
      (first args)
      (let ((v (gensym "or")))
        `(let ((,v ,(first args)))
           (if ,v ,v (or ,@(rest args)))))))
```

See `examples/hygiene.nfl` for a runnable demonstration of all three.

## Preamble macros

The NFL preamble (`src/nfl/preamble.nfl`) is loaded before every file and provides:

| Macro | Expands to |
|-------|-----------|
| `(when test body...)` | `(if test (block body...) nil)` |
| `(unless test body...)` | `(if test nil (block body...))` |
| `(and args...)` | short-circuit `if` chain |
| `(or args...)` | short-circuit `if` chain with `gensym` |
| `(cond clauses...)` | nested `if` chain |
| `(let* bindings body...)` | nested `let` |
| `(first items)` | `(at items 0)` |
| `(rest items)` | `(slice items 1 (- (. items len) 1))` |
| `(empty? items)` | `(== (. items len) 0)` |
| `(append left right)` | `(& left right)` |
| `(map items op)` | `(nflSeqMap items op)` |
| `(filter items pred)` | `(nflSeqFilter items pred)` |
| `(foldl items init op)` | `(nflSeqFoldl items init op)` |
| `(foldr items init op)` | `(nflSeqFoldr items init op)` |
| `(-> v forms...)` | thread-first pipeline |
| `(->> v forms...)` | thread-last pipeline |
| `(as-> v name forms...)` | named threading |

## Example: user-defined macro

```lisp
(defmacro log-when (label test . body)
  `(when ,test
     (echo ,label)
     ,@body))

(log-when "branch taken" true
  (echo "form one")
  (echo "form two"))
```

See `examples/macros.nfl` for more examples including `cond` and boolean short-circuit usage.
