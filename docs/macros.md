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

## `gensym` — hygienic macros

`gensym` generates a fresh symbol that cannot clash with user code:

```lisp
(defmacro or (&rest args)
  (if (nil? (rest args))
      (first args)
      (let ((v (gensym "or")))
        `(let ((,v ,(first args)))
           (if ,v ,v (or ,@(rest args)))))))
```

See `examples/hygiene.nfl` for a runnable demonstration.

## Preamble macros

The NFL preamble (`src/nfl/preamble.nfl`) is loaded before every file and provides:

| Macro | Expands to |
|-------|-----------|
| `(when test body...)` | `(if test (block body...) nil)` |
| `(unless test body...)` | `(if test nil (block body...))` |
| `(defconstant name value)` | `(const name value)` |
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
