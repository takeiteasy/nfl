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

### Section declarations

A `var` or `const` whose bindings are a *list of bindings* and has no
body — as opposed to the single-declaration form above, or the
mutable-binding-with-body form below — declares several names together at
module/statement scope:

```lisp
(var ((a 1) (b 2)))
(const ((pi 3.14159) (e 2.71828)))
```

It's distinguished from the local mutable-binding form purely by shape:
no body follows the bindings list. Each binding is one of:

```lisp
(target)                      ; type annotation only (var; zero-initialized)
(target value)
(target {.pragma.})            ; type annotation only, with a pragma
(target {.pragma.} value)
```

`target` is a bare symbol, a typed `(name type)` pair, or a
[destructuring pattern](#destructuring). A value may be omitted only for
`var`, and only when the target carries an explicit type (Nim
zero-initializes it) — `const` always requires a value, and a
destructuring-pattern target never carries a type, so it always requires
a value too:

```lisp
(var (((count int)) ((total int))))   ; zero-initialized
(var (([a b] pair)))                   ; destructuring — requires a value
(const (([a b] pair)))
```

### `let` — local immutable binding

```lisp
(let ((name value)) body...)
(let (((name type) value)) body...)
(let ((name {.pragma.} value)) body...)
```

### Destructuring

A binding target may be a pattern that destructures a value instead of
binding it whole — positional (by index) or by object field. This works
anywhere a name is bound: `let`, `var` (both the local form and the
module-level section form), `const` sections, `do`/`proc`/`template`/
`iterator`/etc. parameters, and required macro parameters.

A **vector pattern** destructures a tuple or indexable value by position:

```lisp
(let (([a b] pair)) (+ a b))            ; positional bind
(let (([head & rest] xs)) ...)          ; & captures the remaining slice
(let (([a [b c]] nested)) ...)          ; nested patterns
(let (([_ b] pair)) b)                  ; _ discards a position
```

At most one `& rest` capture is allowed per pattern, and it must be the
last two elements. Arity mismatches are not diagnosed by NFL: for a tuple
value, a pattern with too many/few elements is a Nim compile error; for a
seq or array, an out-of-range index is a runtime error.

An **object pattern** destructures by field name — a vector whose first
element is a `:field` keyword:

```lisp
(let (([:name n :age a] person)) (+ a 1))   ; explicit target per field
(let (([:name :age] person)) (& name ($ age)))  ; shorthand — binds name/age
(let (([a [:name n]] pair)) n)               ; nests inside a vector pattern
```

A bare `:field` key with no following target is shorthand for binding a
variable named after the field; explicit and shorthand keys may be mixed.
There is no `&` rest capture for object patterns.

`var` with a destructuring target makes every bound name mutable:

```lisp
(var (([a b] pair)) (set! a (+ a 1)) a)
```

A `var`/`const` [section](#section-declarations) binding may also
destructure — every name the pattern binds is declared, and (matching a
section's usual rules) the binding always requires a value since a
pattern never carries a type:

```lisp
(var (([a b] pair)))
(const (([a b] pair)))
```

A destructured `do`/`proc`/`template`/`iterator`/`method`/`func`/`converter`
parameter must carry an explicit type — the pattern itself has nowhere to
put one:

```lisp
(proc distance (([x y] Point)) (: float)
  (sqrt (+ (* x x) (* y y))))
```

A required macro parameter may also be a pattern — it destructures the
*argument's syntax form* at expansion time (not a runtime value), so the
argument must literally be a list/vector of matching shape:

```lisp
(defmacro swap ([a b]) `(list ,b ,a))
(swap (1 2))    ; -> (list 2 1)
```

Object patterns are not supported for macro parameters (there is no value
to dot-access at expansion time — only syntax).

### `set!` — mutation

```lisp
(set! name new-value)
```

`name` must resolve to a `var`-bound local (a plain `let` binding is
immutable and `set!` on it is a compile error).

`set!` also assigns through a *place* — an object field, a sequence/array
index, a slice, or an accessor call — rather than only a plain symbol:

```lisp
(set! (. obj field) new-value)      ; object field
(set! (at seq index) new-value)     ; sequence/array element
(set! (slice seq a b) new-values)   ; sub-range
(set! (getter obj) new-value)       ; accessor call — see below
```

Unlike the plain-symbol form, a place target has no mutability requirement
of its own: `(let ((rex (make-instance Dog ...))) (set! (. rex name) "Rex"))`
is legal, because reassigning a `ref object`'s field doesn't rebind the
`let`. Whether a place is actually assignable (e.g. `(at s i)` on a
`let`-bound `seq`) is checked by the underlying Nim compiler, the same as
any other Nim assignment.

The last form, `(set! (getter obj) new-value)`, assigns through an
*accessor call*: `getter` must be a plain identifier, and NFL emits a call
to the setter proc named `getter=` — Nim's convention for a settable
property. This is how `defclass`'s generated `:accessor` setters are used
(see [CLOS-lite classes](#clos-lite-classes-preamble)); it works for any
`ident=` proc, not just generated ones (see the `proc` section below).

## Constants

```lisp
(const name value)
(const name* value)            ; exported
(const (name type) value)      ; with type annotation
```

Multiple constants can be declared together — see [Section
declarations](#section-declarations).

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

A parameter may carry a trailing default value, `(name type default)` —
supplied when a call omits the argument:

```lisp
(proc greet ((name string "world")) (: string)
  (& "hi " name))

(greet)        ; "hi world"
(greet "Ada")  ; "hi Ada"
```

A default expression may reference an earlier parameter in the same list,
and, unlike an [object field default](#type--type-declaration), carries no
compile-time-evaluable restriction — any expression is allowed. NFL does not
require defaulted parameters to come last; Nim itself permits a defaulted
parameter before a non-defaulted one (call it with a named argument). A
destructured parameter (`([a b] Point)`) may not carry a default.

This applies to `proc`, `func`, `method`, and `converter` parameters, and to
`do` (anonymous procedure) parameters — **except** that a `do` parameter's
default may not reference an earlier parameter; see [`do` —
anonymous procedure](#do--anonymous-procedure) for why, and use `proc`
instead if a call site needs that.

### Operator proc names

A `proc` (or `method`/`func`/`converter`/`template`/`iterator`) name may be
an operator instead of a plain identifier — the reader's `|…|`
escaped-symbol syntax reads a name containing operator characters, and bare
operator names that don't collide with reader delimiters (`+`, `-`, `<=`,
`<=>`, …) read unescaped:

```lisp
(type MyInt (distinct int))

(proc |+| ((a MyInt) (b MyInt)) (: MyInt)
  (MyInt (+ (int a) (int b))))
```

The defined operator can be called like any proc from NFL (`(+ x y)`) and
infix from plain Nim (`x + y`).

A trailing `*` still marks a proc as exported, but for an operator name it
is ambiguous with the operator itself — `*` both an operator character and
the export marker. The rule: the marker only applies when stripping it
leaves a *nonempty* operator name.

The `|…|` escaped-symbol syntax suppresses this rule entirely — inside
`|…|` a trailing `*` is always part of the name, never an export marker.
This is how an otherwise-inexpressible unexported name is written, at the
cost of also being able to write an unexported name with a trailing `*`
that differs in meaning from its unescaped form:

| Name    | Meaning                       |
|---------|-------------------------------|
| `\|+\|`   | operator `+`, unexported      |
| `+*`    | operator `+`, exported        |
| `\|*\|`   | operator `*`, unexported      |
| `**`    | operator `*`, exported        |
| `\|**\|`  | operator `**`, unexported     |
| `***`   | operator `**`, exported       |
| `\|+*\|`  | operator `+*`, unexported (a different name from unescaped `+*`, which is exported `+`) |

### Setter proc names

A `proc` name may also be `ident=` — a plain identifier followed by `=`,
Nim's convention for a settable property:

```lisp
(proc animalName ((self Animal)) (: string) (. self name))
(proc animalName= ((self Animal) (v string)) (set! (. self name) v))
```

This makes `(set! (animalName a) "Rex")` compile to a call on
`animalName=` — see [`set!`](#set-mutation) above. `defclass`'s `:accessor`
option generates exactly this pair (see [CLOS-lite
classes](#clos-lite-classes-preamble)).

### `func` — side-effect-free procedure

Identical syntax to `proc`, but the body must not perform side effects
(Nim's `{.noSideEffect.}` restriction applies):

```lisp
(func double ((x int)) (: int)
  (* x 2))

(func identity* [T] ((x T)) (: T)  ; generic and exported, same as proc
  x)
```

### `converter` — implicit type conversion

Defines a Nim converter: a named conversion from one type to another. A
converter must declare exactly one parameter and an explicit return (target)
type:

```lisp
(converter toFloat ((x int)) (: float)
  (float x))
```

The converter applies implicitly wherever the target type is expected, just
like in plain Nim — no explicit call is needed:

```lisp
(proc takesFloat ((f float)) (: float) f)

(echo (takesFloat 3))         ; 3.0 — `int` converted to `float` implicitly
(echo (+ (toFloat 3) 0.5))    ; 3.5 — explicit call still works too
```

### Implicit `result`

Any `proc`, `func`, `method`, `converter`, or `do` with a return type gets a mutable `result` variable, initialised to the type's default value. Assign to it with `set!` and it is returned automatically when the body falls through — no explicit `return` required:

```lisp
(proc sumTo ((n int)) (: int)
  (set! result 0)
  (for (i (.. 1 n))
    (set! result (+ result i))))
```

`result` is not available in `template` or `iterator` bodies, and a proc (or `do`) without a return type has no `result` binding — `set!`ing it there is an error.

Avoid ending a body with a bare `result` read once it has been assigned earlier — Nim rejects that as a redundant expression. Either let the body fall through on an assignment (as above), or return explicitly with `(return result)`.

### Generics

`proc`, `func`, `method`, `template`, `iterator`, `converter`, and `type` all
accept an optional `[T ...]` generic-parameter vector immediately after the
name, before any pragma clause or parameter list:

```lisp
(proc identity [T] ((x T)) (: T)
  x)

(proc pickFst [T U] ((a T) (b U)) (: T)
  a)
```

Generic parameters are plain symbols with no constraints or defaults. A
generic type can be referenced in parameter or return position with the same
`[Name T]` bracket syntax used to declare it:

```lisp
(type Box [T]
  (object
    (value T)))

(proc unbox [T] ((b [Box T])) (: T)
  (. b value))

(var intBox (new [Box int] (value 42)))
```

Calls are usually resolved by inference (`(identity 99)`); explicit
instantiation uses the same `[Name T]` bracket form as a type reference.

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

The `(: return-type)` clause is optional, immediately following the
parameter list. A `do` with one gets the same implicit mutable `result`
binding as a typed `proc` (see [Implicit `result`](#implicit-result)); a `do`
with no return type has no `result` and infers its type from usage, same as
any other Nim `auto`-typed anonymous proc:

```lisp
(var sumTo
  (do ((n int)) (: int)
    (set! result 0)
    (set! result (+ result n))
    (return result)))
```

Unlike `proc`, `do` takes no pragma clause and no `[T ...]` generic-params
vector.

A parameter default may not reference an earlier parameter in the same
list — `(do ((a int) (b int a)) …)` is a compile-time error. This is
different from `proc`, where it's allowed (see [Procedures](#procedures)):
a `do` is essentially always called through a proc-typed value (it has no
name to call directly), and Nim's compiler resolves such a default
incorrectly once the call goes through a proc value rather than a named
`proc` symbol, producing a broken C-level reference at the call site. There
is no NFL-level workaround; use `proc` (and call it by name) if the default
needs to reference an earlier parameter.

### `template` — Nim template definition

Defines a zero-cost compile-time template. Templates expand inline at the call site with no runtime overhead.

```lisp
(template name (params...) (: return-type)
  body...)

(template name* (params...) ...)  ; exported
(template name {.pragma.} (params...) ...)
(template name [T] (params...) ...)  ; generic — see Generics above
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
(iterator name [T] ((param type) ...) (: yield-type) ...)  ; generic — see Generics above
```

Use `yield` inside the body to produce values:

```lisp
(iterator upTo ((n int)) (: int)
  (for (i (.. 0 (- n 1)))
    (yield i)))

(for (x (upTo 5))
  (echo x))    ; prints 0 1 2 3 4
```

A generic iterator follows the same `[T]` pattern as `proc`:

```lisp
(iterator repeat [T] ((x T) (n int)) (: T)
  (for (i (.. 1 n))
    (yield x)))

(for (s (repeat "hi" 3))
  (echo s))    ; prints "hi" three times
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

**Object field defaults** — a trailing default value, `(field type
default)` (or `(field {.pragma.} type default)` alongside a field pragma),
fills the field when a constructor call (`new`/`make-instance`) omits it; an
explicit value still overrides it:

```lisp
(type Config
  (object
    (host string "localhost")
    (port int 8080)))

(new Config)             ; host: "localhost", port: 8080
(new Config (port 9090)) ; host: "localhost", port: 9090
```

A field default must be a **compile-time-evaluable** Nim expression — a
literal, another compile-time constant, or a call to a proc Nim can evaluate
at compile time. This is a Nim restriction on object-field defaults, not an
NFL one, so it isn't checked at the NFL level; a violation surfaces as a Nim
compile error. A [parameter default](#proc--named-procedure) carries no such
restriction. The `case` discriminator can also carry a default — see below.

**Object inheritance** — the `(of Base)` clause immediately after `object` declares a base type:

```lisp
(type Animal (ref (object (of RootObj) (name string))))
(type Dog    (ref (object (of Animal))))
```

**Case object (variant record)** — a `case`-discriminated object, mirroring
Nim's own variant records:

```lisp
(type ShapeKind (enum skCircle skRect skPoint))

(type Shape
  (object
    (id int)
    (case kind ShapeKind)
    (of skCircle (radius float))
    (of [skRect skSquare] (width float) (height float))
    (of skPoint)
    (else (extra string))))
```

`case`/`of` clauses live inline in the object body, at the same list level as
plain fields: zero or more ordinary `(name Type)` fields, then exactly one
`(case discriminator Type)` clause — optionally `(case discriminator Type
default)`, subject to the same compile-time-evaluable restriction as a plain
field default — then one or more branches running to the end of the body. A branch is `(of tag field…)`, `(of [tag1 tag2 …] field…)`
— multiple tags sharing one branch — or a final `(else field…)`; a branch
with no fields (`(of skPoint)`) is valid and lowers to Nim's `discard` in
that branch. `of`/`else` appearing anywhere before a `case` clause, a second
`case` clause in the same body, or a plain field *after* the branches, are
all lowering errors — the layout is fixed, unlike Nim's own more permissive
record grammar.

Composes with everything else `object` supports: `(ref (object … (case …)
…))`, `(of Base)` inheritance, an exported discriminator (`(case kind*
ShapeKind)`), and field pragmas. Construct one with `new` like any other
object, setting the discriminator alongside the branch's own fields:

```lisp
(new Shape (id 1) (kind skCircle) (radius 2.0))
```

Reading or setting a field that doesn't belong to the value's current branch
is a runtime `FieldDefect`, exactly as in Nim.

**Distinct type** — a newtype wrapper that prevents accidental mixing:

```lisp
(type Metres (distinct float))
(proc toMetres ((x float)) (: Metres) (Metres x))
```

**Enum type** — an ordinal type over a fixed set of labels:

```lisp
(type Colour (enum Red Green Blue))
```

Ordinals are implicit (`Red` is 0, `Green` is 1, …) unless overridden with a
`(Name value)` pair, which mirrors how object fields already pair a name with a
type:

```lisp
(type ErrCode
  (enum (Ok 0) (NotFound 404) (ServerError 500)))
```

Plain symbols and `(Name value)` pairs can mix freely; a label with no explicit
value continues from the previous ordinal:

```lisp
(type HttpStatus
  (enum (Ok 200) Created (NotFound 404)))  ; Created is 201
```

A value can be any expression Nim accepts in enum position — an integer or
string literal, or a named constant — not only a bare integer. Nim rejects
duplicate values at compile time.

**Tuple type** — a structural named-field record:

```lisp
(type Point (tuple (x float) (y float)))
(proc getX ((p Point)) (: float) (. p x))
```

> Construct one with `tuple-new` — see [`tuple-new`](#tuple-new--named-tuple-construction) below.

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

See also [CLOS-lite classes](#clos-lite-classes-preamble) for a
`defclass`/`method` combination that generates the `(of Base)` inheritance
clause and field accessors for you.

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

`new` is for object types (`(object …)`, `(ref (object …))`) — see `tuple-new`
below for named tuples. [`make-instance`](#clos-lite-classes-preamble) builds
the same construction for a `defclass`-declared type, but — unlike `new` —
as a Nim macro that also resolves each slot's `:initarg`, inherited or not.

### `tuple-new` — named tuple construction

```lisp
(type Point2D (tuple (x float) (y float)))

(tuple-new Point2D (x 1.0) (y 2.0))    ; -> Point2D((x: 1.0, y: 2.0))
```

Constructs a value of a named tuple type by field, mirroring `new`'s
`(field value)` shape. At least one field is required. `tuple-new` is
tuples-only: Nim does not accept a tuple literal where an object type is
expected, so an object type still goes through `new`.

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

An `of` branch's value form can also be a parenthesized list of values, a
range, or a mix of both:

```lisp
(case n
  (of (1 3 5 7 9) "odd digit")       ; multi-value -> of 1, 3, 5, 7, 9:
  (of (.. 10 99) "two digits")       ; range       -> of 10..99:
  (of (0 (.. 20 29) 100) "mixed")    ; mixed       -> of 0, 20..29, 100:
  (else "other"))
```

### `match`

Structural pattern matching, separate from `case`: `case` matches a value
against literals/ranges, `match` additionally destructures and binds.

```lisp
(match shape
  (0                "zero")                 ; literal
  ('Red             "stop")                 ; 'sym — equality (enum labels, consts)
  ([h & t] :when (> h 10)  "big head")      ; vector pattern (#12) + guard
  (n                (* n 2))                ; bare symbol — binds
  (_                "other"))               ; wildcard
```

Pattern kinds:

- a literal (`nil`/`true`/`false`/int/float/string) matches by equality
- `_` matches anything and binds nothing
- any other bare symbol matches anything and binds the scrutinee to that name
- `'sym` (the reader's quote sugar) matches by equality against the symbol
  `sym` — for an enum label or a module-level const
- a positional vector pattern (`[a b]`, `[head & rest]`, nested) destructures
  like a `let`/`var` [destructuring pattern](#destructuring)
- an object pattern (`[:field target?...]`) tests and destructures by field
  name — each field's target is itself a full match pattern (unlike a
  destructuring object pattern, whose targets only ever bind), so a field can
  be tested with a literal, `'sym`, a nested pattern, or bound with a bare
  symbol / `_` / the bare-key shorthand (`[:name]` binds `name`). This is how
  a `case object`'s discriminant is matched — it's just another field:
  `([:kind 'skCircle :radius r] ...)`
- `(of Type)` / `(of Type pattern)` tests the scrutinee's runtime type via
  Nim's `of` — for `ref object of Base` inheritance, including CLOS-lite
  `defclass` hierarchies — and, if given, matches `pattern` against a
  `Type(...)` downcast so subclass-only fields resolve:
  `((of Circle [:radius r]) ...)`

```lisp
(defclass Circle (Shape) ((radius float)))
(defclass Rect (Shape) ((width float) (height float)))

(match shape
  ((of Circle [:radius r])        (* pi (* r r)))
  ((of Rect [:width w :height h]) (* w h))
  (_                               0.0))
```

A clause may carry a guard, recognized positionally right after the
pattern: `(PATTERN :when guard-expr body…)`. The guard can reference names
the pattern just bound, including a field bound under `(of Type pattern)`.

If no clause matches, `match` raises `ValueError` at runtime — there is no
static exhaustiveness check; see the tracker.

### `block`

```lisp
(block body...)
(block :name body...)
```

Evaluates multiple forms and returns the last value. Giving it a `:name`
label lets a nested `break-from` exit it early with a value — see
[`break-from`](#break-from) below.

### `progn` (preamble macro)

```lisp
(progn body...)
```

An alias for the unlabelled form of `block`: evaluates multiple forms and
returns the last value. Provided for CL familiarity — `progn` and `block`
(without a `:name` label) are otherwise identical.

### `prog1` / `prog2`

```lisp
(prog1 first-expr rest...)         ; returns first-expr's value
(prog2 first-expr second-expr rest...)  ; returns second-expr's value
```

Evaluate every form in order for side effect, like `block`, but return a
specific *non-last* form's value instead of the last one — useful for the
"capture the old value, then mutate, then hand back what was captured"
idiom without a manual temp binding:

```lisp
(proc popFirst ((xs [seq int])) (: int)
  (var ((ys xs))
    (prog1
      (at ys 0)
      (set! ys (slice ys 1 (- (. ys len) 1))))))
```

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

An optional `:name` label right after `for` — before the binding clause —
lets a `break`/`continue` in a nested loop target this loop directly:

```lisp
(for :outer (x xs) body...)
```

### `while`

```lisp
(while condition body...)
```

An optional `:name` label right after `while` — before the condition —
labels the loop the same way `for` does:

```lisp
(while :outer condition body...)
```

### `break` and `continue`

`(break)` exits the innermost loop. `(continue)` skips the rest of the
current iteration:

```lisp
(while true
  (if (>= i limit) (break) nil)
  (set! i (+ i 1)))

(while (< k 10)
  (set! k (+ k 1))
  (if (== 0 (mod k 2)) (continue) nil)
  (echo "odd: " k))
```

Either can take an optional `:name` label naming an enclosing labelled
loop (`for`/`while`), letting a nested loop break out of — or restart — an
*outer* loop directly, rather than only ever affecting the loop it's
lexically inside:

```lisp
(while :outer (< i n)
  (while (< j n)
    (if (bad? i j) (break :outer) nil)
    (if (skip? i j) (continue :outer) nil)
    ...))
```

`:name` must refer to an enclosing labelled `for`/`while` in the same
routine — it cannot cross a `proc`/`method`/`func`/`converter`/`template`/
`iterator`/`do` boundary, name an enclosing named `block` instead of a loop
(that's what [`break-from`](#break-from) is for), or reference a name that
is out of scope; any of those is a lowering error. When an inner loop reuses
an outer loop's label, the inner one shadows it — a `(break :name)` /
`(continue :name)` inside the inner loop binds to the inner loop, not the
outer one.

`(continue :name)` compiles to a `break` out of a hidden per-iteration
block wrapped around the target loop's body — Nim itself has no labelled
`continue` — but behaves exactly like restarting that loop's own condition
check.

## Control flow — early exit

### `return`

`(return expr)` exits the enclosing procedure with a value. `(return)` returns void:

```lisp
(proc clamp ((n int) (lo int) (hi int)) (: int)
  (if (< n lo) (return lo) nil)
  (if (> n hi) (return hi) nil)
  n)
```

The implicit `result` variable (see [Implicit `result`](#implicit-result)) is an alternative to explicit `return`: assign to `result` and let the body fall through instead of returning a value directly.

### `break-from`

`(break-from :name expr)` exits the enclosing `(block :name ...)` early with
a value; `(break-from :name)` exits it with no value. Unlike bare `break`,
which only ever exits the innermost loop, `break-from` can name *which*
enclosing block to exit — including one that wraps a loop, letting you
break out of a search with the found value in one step. `break-from` only
ever targets a named `block`; to name a *loop* instead, use `(break :name)`
or `(continue :name)` (see [break and continue](#break-and-continue) above).

```lisp
(proc findFirstOver ((xs [seq int]) (limit int)) (: int)
  (block :search
    (for (x xs)
      (if (> x limit) (break-from :search x) nil))
    -1))
```

`:name` must refer to a `block` that lexically encloses the `break-from` —
it cannot cross a `proc`/`method`/`func`/`converter`/`template`/`iterator`/`do`
boundary, and referencing a name that is out of scope (or was never
declared) is a lowering error. `break-from` is not supported inside a macro
body (the compile-time macro evaluator does not implement non-local exit);
a plain `(block :name ...)` there is still fine and evaluates like an
anonymous block.

A named block's value type is inferred from its own ordinary fallthrough
tail — the same expression the block would evaluate to if no `break-from`
were ever taken (or, if the tail itself is an unconditional `break-from`
with a value and there's no other fallthrough, from that value). A
`break-from` value that doesn't match the block's type is a regular Nim
type-mismatch error at the point it's assigned.

### `catch` / `throw`

`(catch :tag body…)` / `(throw :tag value)` is the dynamic-extent counterpart
to `block`/`break-from`: where `break-from` can only exit a `block` that
*lexically* encloses it — and cannot cross a `proc`/`method`/`func`/
`converter`/`template`/`iterator`/`do` boundary — `throw` unwinds across any
number of proc calls to the nearest enclosing `catch` with a matching tag,
resolved at runtime rather than at compile time:

```lisp
(proc search ((node Tree) (target int))
  (if (== (. node value) target) (throw :found node) (echo "keep looking")))

(proc findNode ((root Tree) (target int)) (: Tree)
  (catch :found
    (search root target)
    nil))
```

`search` can call itself arbitrarily deep — `throw :found` unwinds straight
back to the `catch :found` in `findNode` no matter how many stack frames of
`search` are in between, which `break-from` cannot do (its label goes out of
scope the moment `search` is entered, since that's a new proc body).

Unlike `break-from`, `throw` always requires a value — there is no valueless
`(throw :tag)` — since a `catch`'s value type is inferred from its own body
(the same way a named `block`'s is), and a valueless throw reaching a
value-producing catch would have nothing to unify that type against.

Tag matching is by name (the label text after the leading `:`), not by
lexical identity — a `throw` written inside a macro expansion can still reach
a `catch` written in ordinary code with the same tag spelling. If no
enclosing `catch` matches, the throw propagates like any other uncaught
exception. A `throw` whose value type doesn't match the type already
established by its `catch`'s own body is not converted — it propagates past
that `catch` to be handled (or not) further up the call stack.

### `discard`

`(discard expr)` discards the result of an expression, suppressing unused-result warnings. `(discard)` is a bare empty discard:

```lisp
(discard (sideEffect))
(discard)
```

## Error handling

### `try`

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

### `defer`

`(defer body...)` schedules `body` to run when the enclosing `proc`/`method`/
`template`/`iterator`/`block` scope exits — whether it exits normally, via
`return`, or because an exception propagates out of it. It is the ergonomic
alternative to a `try`/`finally` wrapping the whole body, and is well suited
to resource cleanup (closing a file handle, releasing a lock):

```lisp
(proc withFile ((path string)) (: string)
  (var ((handle (open path)))
    (defer (close handle))
    (handle.readAll)))
```

`defer` is statement-only (it cannot appear inside an expression) but may be
the last form in a body — the example above puts it in the middle, but
`(proc f () (setup) (defer (cleanup)))` also works. `defer` is not allowed at
module top level; Nim itself does not support scheduling cleanup for a whole
module, so use it inside a `proc` or `block`.

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

### CL-style sequence functions (preamble)

CL-named counterparts to the helpers above, plus a few new operations
(`make-array`, `sort`, `reverse`, `count-if`, `some`, `every`, `position`).
Argument order follows this preamble's own convention — items first — even
where CL itself puts the predicate first (`some`/`every`); this isn't
literal CL syntax, just CL-flavoured naming over it (see [CL-style
declaration spellings](#cl-style-declaration-spellings-preamble) above for
the same idea applied to `proc`/`var`/etc.):

```lisp
(make-array n fill)             ; a length-n seq filled with `fill` — unlike
                                 ; CL, both arguments are required: Nim can
                                 ; only infer the element type from an actual
                                 ; value, and NFL has no call-site syntax for
                                 ; a bare type argument instead
(length items)                  ; same as (. items len)
(reverse items)
(sort items)                    ; returns a new sorted seq (non-destructive)
(mapcar items op)                ; alias for (map items op)
(reduce items initial op)        ; alias for (foldl items initial op)
(remove-if items pred)           ; drops elements satisfying pred
(remove-if-not items pred)       ; alias for (filter items pred)
(count-if items pred)
(some items pred)                ; true if any element satisfies pred
(every items pred)                ; true if all elements satisfy pred
(position items value)           ; index of the first equal element, or -1
                                  ; when absent — Nim's own sentinel, not
                                  ; CL's nil, since a generic element type
                                  ; has no nil-like value to return instead
(elt items i)                    ; alias for (at items i)
(aref items i)                   ; alias for (at items i)
(subseq items start end)         ; like (slice items start (- end 1)) —
(subseq items start)             ; CL's end is exclusive, unlike slice's own
                                  ; inclusive end, and defaults to the
                                  ; sequence's length when omitted
```

## Imports

```lisp
(import std/strutils)
(import std/os)
```

`(import ./path.nfl)` inline-includes another NFL source file instead — see
[Splitting a project across multiple .nfl files](nim-interop.md#splitting-a-project-across-multiple-nfl-files).

## Selective imports

```lisp
(from std/strutils import toUpperAscii toLowerAscii)
(from std/math import (except sqrt))
```

See [Selective imports](nim-interop.md#selective-imports) for details.

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

## CL-style declaration spellings (preamble)

Alternate `def...`-prefixed spellings of the Nim declaration forms, for
readers who'd rather see Common Lisp-style names. These are plain macro
aliases — each just forwards its arguments unchanged to the form it
stands in for — not the canonical syntax; the language's own surface
syntax stays Nim-focused, and the reference above uses the Nim names
throughout.

| Alias | Expands to |
|-------|------------|
| `(defproc name ...)` / `(defun name ...)` | `(proc name ...)` |
| `(defvar name ...)` | `(var name ...)` |
| `(defconst name value)` / `(defconstant name value)` | `(const name value)` |
| `(deftype name ...)` | `(type name ...)` |
| `(deftemplate name ...)` | `(template name ...)` |
| `(defiterator name ...)` | `(iterator name ...)` |
| `(defmethod name ...)` | `(method name ...)` |
| `(deffunc name ...)` | `(func name ...)` |
| `(defconverter name ...)` | `(converter name ...)` |

`defun` and `defconstant` are extra synonyms for `defproc` and `defconst`
respectively, matching Common Lisp's own names for "define a function"
and "define a constant"; the rest (`template`/`iterator`/`func`/
`converter` have no CL equivalent, and `var`/`type`/`method` already
match CL's own names) just take a mechanical `def` prefix.

```lisp
(defun square ((x int)) (: int) (* x x))
(defconstant pi 3.14159)
```

## CLOS-lite classes (preamble)

A CL-flavoured `defclass`/`make-instance` layer over the [`type`/`ref`/
`object`](#types), [`new`](#new--object-construction), and
[`method`](#method--method-definition) forms above, for readers who'd
rather see CLOS-style class syntax. `defclass` is a plain macro — it
expands to a `type` declaration plus one or two accessor `proc`s per named
slot option. `make-instance` is a Nim macro (`nflMakeInstance`, in
`runtime.nim`): unlike `defclass`, it runs at Nim semcheck time, when a
class's whole `of` inheritance chain — and every ancestor's `:initarg`
pragmas — is visible, which lets it resolve an initializer against an
inherited slot that a macro-expand-time `defclass` invocation can't itself
see:

```lisp
(defclass Animal ()
  ((name string :accessor animalName)))

(defclass Dog (Animal)
  ((breed string :reader dogBreed :initform "mutt")))

(method speak {.base.} ((a Animal)) (: string) "...")
(method speak ((d Dog)) (: string) "woof")

(var rex (make-instance Dog (name "Rex") (breed "corgi")))
(echo (animalName rex) " says " (speak rex))    ; -> "Rex says woof"

(set! (animalName rex) "Fido")                  ; :accessor is settable too

(var stray (make-instance Dog (name "Stray")))  ; breed defaults to "mutt"
```

A slot is `(name Type option...)`; a bare `(name Type)` is a plain field
with no generated accessor. `:accessor` generates a getter *and* a setter
(`animalName` and `animalName=`, so `(set! (animalName rex) "Fido")` works —
see [`set!`](#set-mutation)); `:reader` generates a getter only. Either
value becomes a real Nim `proc` name, so unlike a `defclass` name itself
(compile-time only), it must be a plain identifier: `animalName`, not
`animal-name`.

`:initform` gives a slot a default value, used when `make-instance` omits
it — it lowers directly into the [object field
default](#type--type-declaration) `defclass` generates, so it carries the
same compile-time-evaluable restriction:

```lisp
(defclass Cat (Animal)
  ((sound string :reader catSound :initform "meow")))

(make-instance Cat (name "Whiskers"))  ; sound defaults to "meow"
```

A slot may combine `:initform` with `:accessor`/`:reader`; at most one
`:initform` per slot.

`:initarg` gives a slot a distinct external initializer name, for a
`make-instance` call site that doesn't want to spell out the field itself:

```lisp
(defclass Animal ()
  ((name string :accessor animalName :initarg :nom)))

(defclass Dog (Animal)
  ((breed string :reader dogBreed :initarg :kind)))

(make-instance Dog (nom "Fido") (kind "corgi"))   ; via each slot's :initarg
(make-instance Dog (name "Fido") (breed "corgi")) ; the field name still works
```

An `:initarg` is an alias, not a rename — a slot's own field name keeps
working alongside it, initarg'd or not. It resolves across inheritance too:
`Dog`'s `make-instance` call above reaches `name`'s `:nom` even though
`defclass Dog` never sees `Animal`'s slots at its own expansion time,
because `nflMakeInstance` reads the `:initarg` back off `Animal`'s Nim type
definition, at Nim semcheck time, when `Dog`'s whole inheritance chain is
resolved. Its value is conventionally keyword-shaped (`:nom`), matching
`:accessor`/`:reader`/`:initform`'s own keys, but any symbol works — unlike
`:accessor`/`:reader`, it never becomes a proc name, so it carries none of
their plain-Nim-identifier restriction. A slot may combine `:initarg` with
`:accessor`/`:reader`/`:initform`; at most one `:initarg` per slot.

The superclass list is `()` (→ inherits `RootObj`, so the class is
dispatchable from the start) or a single `(Parent)` — `defclass` supports
single inheritance only; multiple superclasses are a `macro-error`. Classes
are always `ref object`, since that's what `method` dispatch and `RootObj`
inheritance both require.

Deliberately out of scope for now (tracked separately): a `defmethod`
distinct from the plain [`method` alias](#cl-style-declaration-spellings-preamble)
above — CLOS-lite adds no dispatch mechanism of its own. See
`examples/clos.nfl` for a runnable demonstration.

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

To define your own operator for a custom type, see
[Operator proc names](#operator-proc-names).
