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

A required parameter may also be a destructuring [vector
pattern](language-reference.md#destructuring): it destructures the
*argument's syntax form* (not a runtime value) at expansion time, so the
call-site argument must literally be a list/vector of matching shape.
Object patterns aren't supported here — there's no value to dot-access at
expansion time, only syntax.

```lisp
(defmacro swap ([a b])
  `(list ,b ,a))

(swap (1 2))    ; -> (list 2 1)
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

## Macro-time vocabulary

Inside a macro (or [`defmacro-proc`](#defmacro-proc-compile-time-procedures))
body, these operate on *syntax* — s-expression values, not the runtime
values they'll eventually evaluate to:

### Introspection

| Form | Meaning |
|------|---------|
| `(syntax? x)` | always `true` (evaluates `x` for its side effects/errors) |
| `(nil? x)` | x is nil / empty list / empty vector |
| `(symbol? x)` | x is a symbol |
| `(list? x)` | x is a list |
| `(first x)` | first element of a list/vector (`nil` if empty) |
| `(rest x)` | tail of a list/vector (all but first) |
| `(cons head tail)` | prepends `head` onto list `tail` |
| `(list args...)` | builds a list from evaluated `args` |
| `(append lists...)` | concatenates lists/vectors into one list |
| `(syntax->datum x)`, `(datum->syntax x)` | identity (syntax *is* the datum at expansion time) |
| `(gensym ["prefix"])` | generate a unique symbol |
| `(macro-error "msg")` | abort expansion with an error |

### Arithmetic

`+`, `-`, `*`, `/`, `div`, `mod` — variadic where natural (`-` and `/` also
accept a single argument, negating/reciprocating). Numeric args may be
`sxInt` or `sxFloat`; the result is a float if any argument is, except `/`,
which always yields a float, and `div`/`mod`, which require integers.
Division by zero is a `macro-error`, not a runtime trap.

### Comparison

`<`, `<=`, `>`, `>=` chain across any number of numeric arguments (like
`(< a b c)` meaning `a < b < c`). `not` negates truthiness.

`=`/`/=` are **purely structural** — a thin wrapper over syntax equality,
with no numeric coercion: `(= 1 1.0)` is `false`, same as `(= '(1) '(1.0))`.
Use `<`/`>` for cross-kind numeric comparison instead.

### Lists

| Form | Meaning |
|------|---------|
| `(nth x i)` | element at index `i` (`nil` if out of range) |
| `(length x)` | element count of a list/vector |
| `(reverse x)` | reversed list |
| `(member v x)` | `true`/`false` — is `v` structurally present in `x`? |

### Symbol / string

`(symbol->string sym)`, `(string->symbol str)`, `(string-append strs...)`
(variadic).

### Shadowing note

`first`/`rest`/`append`/`length`/`reverse` also exist as [preamble
macros](#preamble-macros) that expand to *runtime* sequence operations
(`at`, `slice`, `nflReversed`, …). The two never collide: inside a macro or
`defmacro-proc` *body*, a call to one of these names always resolves to the
builtin above, operating on syntax. Inside a **quasiquoted template**, the
same call is left as literal, unexpanded syntax — it's the *preamble
macro* that later expands it, once the template's output is spliced back
into the program and re-macroexpanded. This asymmetry is what makes `and`/
`or`/`cond` (which call the builtins during their own expansion, but emit
templates using `if`/`block`) work at all.

## `defmacro-proc` — compile-time procedures

`defmacro-proc` defines a *compile-time procedure*: a named, callable helper
evaluated like a regular procedure (call-by-value — every argument is
evaluated before binding) rather than expanded like a macro. It exists for
computation a macro body needs but can't express as a single expansion step
— an accumulator, a search over macro arguments, a recursive helper — without
burning one of `defmacro`'s expansion-depth levels per iteration:

```lisp
(defmacro-proc plist-get (plist key)
  (if (nil? plist)
      nil
      (if (= (first plist) key)
          (nth plist 1)
          (plist-get (rest (rest plist)) key))))
```

A `defmacro-proc` is only callable from *within* another macro or
`defmacro-proc` body (i.e. anywhere `evalMacroExpr` runs) — not as a
standalone top-level form, the way a `defmacro` call is.

Differences from `defmacro`:

- **Call-by-value.** Arguments are evaluated in the caller's scope before
  binding, then bound positionally — there is no `&key` support, since an
  *evaluated* argument can itself be a keyword symbol (e.g. `':accessor`
  passed as a plain value), which would otherwise be misread as the start of
  a keyword section.
- **Its own recursion limit**, separate from `defmacro`'s expansion-depth
  counter (which only counts macro *expansions*, not this kind of
  in-evaluator recursion): a `defmacro-proc` chain deeper than the limit
  raises `"macro-time procedure recursion depth exceeded"` instead of
  overflowing the underlying Nim call stack.
- **Cannot shadow** a macro-time special form (`quote`, `quasiquote`, `if`,
  `block`, `let`, `break-from`) or builtin (the tables above) — doing so is
  a definition-time error, since either would otherwise make the shadowed
  name silently unreachable.

See `examples/macro-procs.nfl` for a runnable demonstration.

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

This covers a binding target that is a literal symbol, a typed
`(name type)` pair, or a [destructuring](language-reference.md#destructuring)
pattern (every name the pattern binds gets its own renamed identity). It
does **not** cover a binding target that is itself unquoted (`,name`) — a
name the macro computes at expansion time is the macro author's own symbol
and is left as-is (this is how the preamble's `let*` and `as->` work).

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
| `(progn body...)` | `(block body...)` |
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

### CL-style declaration aliases

Plain aliases onto the canonical Nim-focused declaration forms, for readers
who'd rather see a `def...` prefix:

| Macro | Expands to |
|-------|-----------|
| `(defproc name args...)`, `(defun name args...)` | `(proc name args...)` |
| `(defvar name args...)` | `(var name args...)` |
| `(defconst name args...)`, `(defconstant name args...)` | `(const name args...)` |
| `(deftype name args...)` | `(type name args...)` |
| `(deftemplate name args...)` | `(template name args...)` |
| `(defiterator name args...)` | `(iterator name args...)` |
| `(defmethod name args...)` | `(method name args...)` |
| `(deffunc name args...)` | `(func name args...)` |
| `(defconverter name args...)` | `(converter name args...)` |

### CL-style sequence functions

Argument order follows the rest of the preamble (items first, as with
`map`/`filter`/`foldl` above), not CL's own order. `position` returns `-1`
when not found (Nim's own sentinel), not CL's `nil`. `n` and `fill` are both
required in `make-array` — NFL has no call-site syntax for a bare type
argument, so the fill value is what tells Nim the array's element type.

| Macro | Expands to |
|-------|-----------|
| `(make-array n fill)` | `(nflMakeArray n fill)` |
| `(length items)` | `(. items len)` |
| `(reverse items)` | `(nflReversed items)` |
| `(sort items)` | `(nflSorted items)` |
| `(mapcar items op)` | `(nflSeqMap items op)` |
| `(reduce items init op)` | `(nflSeqFoldl items init op)` |
| `(remove-if items pred)` | `(nflSeqRemoveIf items pred)` |
| `(remove-if-not items pred)` | `(nflSeqFilter items pred)` |
| `(count-if items pred)` | `(nflSeqCount items pred)` |
| `(some items pred)` | `(nflSeqAny items pred)` |
| `(every items pred)` | `(nflSeqEvery items pred)` |
| `(position items value)` | `(nflSeqPosition items value)` |
| `(elt items i)`, `(aref items i)` | `(at items i)` |
| `(subseq items start [end])` | `(slice items start end-1)` (exclusive end, CL-style) |

### CLOS-lite

`(defclass name (superclass?) ((slot-name Type slot-options...)...))` and
`(make-instance ClassName (slot value)...)` — see [CLOS-lite
classes](language-reference.md#clos-lite-classes-preamble) for the full
picture, including what's deliberately left out.

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
