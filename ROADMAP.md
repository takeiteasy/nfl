# Nimp Roadmap

## `defvar` / `defparameter` Semantics Note

Both forms declare a top-level mutable binding (emits Nim `var`). In the compiled backend they behave identically — module-level initialisation runs once, so there is no prior binding to test. The distinction becomes observable in a REPL:

- `defvar` — sets the variable only if it is not already bound (idempotent re-evaluation).
- `defparameter` — always resets the variable (use for configuration that should update on reload).

Until a REPL exists, choose `defvar` for module-level state and `defparameter` for configuration parameters as a documentation convention.

## Milestone 8: Serious-Language Features

Milestone 8 should turn Nimp from a stable core into a language that can define
normal Nim-facing APIs. The highest-value work is the missing declaration and
control-flow surface around Nim interop.

### 1. Type Declarations **Partial**

Add a Nimp wrapper for Nim `type` sections.

Initial supported forms:

```lisp
(type Name ExistingType)

(type Name
  (object
    (field Type)
    ...))

(type Name
  (enum
    value
    ...))
```

Later supported forms:

```lisp
(type Name
  (tuple
    (field Type)
    ...))

(type Name
  (distinct BaseType))

(type Name
  (ref object
    (field Type)
    ...))
```

Tasks:

- [x] Decide the exact syntax for object, ref object, tuple, enum, distinct,
      and aliases.
- [x] Add lowering validation for `type` at module/statement scope.
- [x] Emit Nim `nnkTypeSection` / `nnkTypeDef` nodes directly.
- [x] Preserve source locations on the type name and field/type nodes where the
      macros API allows it.
- [x] Add negative diagnostics for malformed type definitions, duplicate fields
      where practical, and invalid field/type positions.
- [x] Add backend tests for aliases, objects, and enums.
- [x] Add a focused `.nimp` example for defining and using a Nim object.

Definition of done:

- [x] A Nimp file can define a Nim object type.
- [x] A Nimp file can define a Nim enum type.
- [x] A Nim file can import/use a type emitted from Nimp.
- [x] `nimble test` covers success and failure paths.

### Deferred tasks

Implemented initial forms: aliases, objects, and enums. Tuple, distinct, and
ref object syntax is reserved and currently produces explicit "not implemented
yet" diagnostics. Export markers are supported narrowly for type declarations
and object fields so Nim modules can import Nimp-emitted types. Enum values use
Nim's normal behavior: exporting the enum type exports its values. General
exported procs/definitions remain part of the export-marker milestone.

### 2. Named Arguments And Object Construction **Partial**

Object declarations are only useful if values can be constructed ergonomically.

Chosen object construction syntax:

```lisp
(new Person
  (name "Ada")
  (age 36))
```

Tasks:

- [x] Decide whether named arguments are represented as `name:` symbols, field
      pairs, or a dedicated construction form.
- [x] Support Nim named arguments for ordinary calls if the chosen syntax
      generalizes cleanly.
- [x] Support object construction for Nimp-defined and imported Nim object
      types.
- [x] Add diagnostics for malformed named arguments and duplicate fields.
- [x] Add tests that construct an object, read fields, and pass the object to a
      typed proc.

Definition of done:

- [x] A Nimp-defined object can be constructed and used without writing Nim code.
- [x] Named argument source locations point back to the `.nimp` file on errors.

Ordinary calls use `(: name value)` for named arguments, which avoids the
ambiguity between a named argument and a positional nested call expression.

### 3. Export Marker And Visibility

Nimp needs a way to emit Nim public symbols such as `Name*`, `field*`, and
`procName*`.

Candidate syntax:

```lisp
(proc greet* ((name string)) (: string)
  ...)

(type Person*
  (object
    (name* string)
    (age int)))
```

Tasks:

- [ ] Decide whether `*` is part of the symbol name or represented by metadata.
- [ ] Support exported procs, types, enum values, object fields, constants, and
      top-level definitions where Nim allows them.
- [ ] Keep exported-name handling compatible with hygiene metadata.
- [ ] Add tests proving Nim code can import public declarations from a Nimp
      module.

Definition of done:

- [ ] Nimp can emit a public Nim-facing API from a `.nimp` file.
- [ ] Private symbols remain private by default.

### 4. Pragmas

Nim pragmas are required for serious interop: export behavior, effects,
calling conventions, inline/noinline, deprecation, compile-time behavior, and
library-specific annotations.

Candidate syntax:

```lisp
(proc addOne {.inline.} ((x int)) (: int)
  (+ x 1))

(type Person {.bycopy.}
  (object
    (name string)))
```

Tasks:

- [ ] Decide a pragma syntax that works on `proc`, `type`, fields,
      `const`/`let`/`var`, and later `template`/`iterator`.
- [ ] Emit pragma nodes directly.
- [ ] Support simple marker pragmas first.
- [ ] Add value pragmas only when a concrete example requires them.
- [ ] Add diagnostics for pragmas in invalid positions.

Definition of done:

- [ ] Nimp can attach at least marker pragmas to procs and types.
- [ ] Pragmas compose with export markers and generics.

### 5. Const Declarations

Add top-level and local `const` where Nim requires compile-time constants.

Candidate syntax:

```lisp
(const answer 42)
(const greeting "hello")
```

Tasks:

- [ ] Decide whether `const` is module-only initially or also allowed in local
      statement positions.
- [ ] Add lowering validation and backend emission for `nnkConstSection`.
- [ ] Support optional type annotations if they share the existing binding
      syntax.
- [ ] Add tests distinguishing `const` from `defvar`/`defparameter`/`let`.

Definition of done:

- [ ] A Nimp file can define Nim constants usable from Nim and Nimp code.

### 6. Generic Declarations

Calling Nim generics is already possible when Nim can infer types. Defining
generic Nimp declarations needs explicit syntax.

Candidate syntax:

```lisp
(proc identity [T] ((x T)) (: T)
  x)

(type Box [T]
  (object
    (value T)))
```

Tasks:

- [ ] Decide generic parameter syntax for `proc`, `type`, `template`, and
      `iterator`.
- [ ] Support simple type parameters first.
- [ ] Defer constraints, concepts, static params, and typedesc params until
      examples require them.
- [ ] Add tests for generic procs and generic object types.

Definition of done:

- [ ] Nimp can define and call a generic proc.
- [ ] Nimp can define and instantiate a generic object type.

### 7. For Loops

Add Nim-native `for` loops for ranges, sequences, iterators, and pair
iteration.

Candidate syntax:

```lisp
(for (x xs)
  (echo x))

(for ((i x) xs)
  (echo i ": " x))
```

Tasks:

- [ ] Decide binding syntax for single and tuple iteration.
- [ ] Validate loop bindings in lowering.
- [ ] Emit Nim `for` statements.
- [ ] Decide expression behavior: statement-only initially, or block expression
      returning `nil`.
- [ ] Add tests for sequences, ranges, and custom iterators once iterators
      exist.

Definition of done:

- [ ] Nimp can iterate over ordinary Nim iterables.
- [ ] Loop variables are scoped correctly and cannot be mutated with `set!`
      unless explicitly introduced as mutable by a later design.

### 8. Case Expressions And Statements

Nim `case` is a practical control-flow feature separate from future pattern
matching.

Candidate syntax:

```lisp
(case value
  (of 0 "zero")
  (of 1 "one")
  (else "many"))
```

Tasks:

- [ ] Decide whether `case` is expression-capable, statement-capable, or both.
- [ ] Support simple literal `of` branches first.
- [ ] Add range and multi-value branches if they map cleanly to Nim AST.
- [ ] Keep full pattern matching as a separate feature.
- [ ] Add tests for branch typing and source diagnostics.

Definition of done:

- [ ] Nimp can emit ordinary Nim `case` forms with `of` and `else` branches.

### 9. Error Handling

Add wrappers for Nim exception handling.

Candidate syntax:

```lisp
(raise (newException ValueError "bad value"))

(try
  riskyCall
  (except ValueError
    (echo "bad value"))
  (finally
    cleanup))
```

Tasks:

- [ ] Add `raise`.
- [ ] Add `try` with `except` and `finally`.
- [ ] Support typed exception bindings if needed by examples.
- [ ] Decide expression vs statement behavior.
- [ ] Add tests for successful path, caught exception, uncaught exception, and
      malformed handlers.

Definition of done:

- [ ] Nimp can call Nim APIs that require ordinary exception handling.

### 10. Tail Recursion

Nimp should not assume Nim or the selected C/C++/JS backend guarantees tail-call
optimization. If Nimp wants stack-safe recursive style, it needs an explicit
compiler transform.

Initial scope:

- Direct self-tail-recursive `proc` definitions only.
- No mutual recursion.
- No higher-order calls through proc values.
- No general continuation-passing or trampoline transform.

Tasks:

- [ ] Decide whether Nimp guarantees self-tail recursion optimization or only
      offers it behind an explicit pragma/form.
- [ ] Detect direct self-tail calls in `proc` bodies.
- [ ] Prove the call is in tail position across `if`, `block`, `case`, and
      other expression forms that can return a value.
- [ ] Rewrite eligible procs to Nim loops with mutable parameter temporaries.
- [ ] Preserve source locations enough that errors in the rewritten body still
      point back to useful `.nimp` locations.
- [ ] Emit diagnostics or warnings for forms that request tail recursion but
      cannot be optimized.
- [ ] Add tests for successful optimization, non-tail recursive calls, recursion
      through lambdas/proc values, and stack-safe large inputs.

Definition of done:

- [ ] A direct self-tail-recursive Nimp `proc` can run on large inputs without
      growing the call stack.
- [ ] Unsupported recursive patterns are either left alone or rejected according
      to the chosen guarantee.

### 11. Template Definitions

Nimp macros are Nimp compile-time macros. Nim templates are a separate interop
feature and should be wrapped when real examples need zero-cost Nim-side
abstraction.

Candidate syntax:

```lisp
(template withLog ((label string) body)
  ...)
```

Tasks:

- [ ] Decide how template parameters differ from proc parameters.
- [ ] Decide whether untyped/typed/template/body parameters need explicit
      syntax.
- [ ] Emit Nim `template` definitions.
- [ ] Add examples that show why a Nimp macro is not sufficient.

Definition of done:

- [ ] A Nimp-defined Nim template can be used from Nim and Nimp code.

### 12. Iterator Definitions

Add Nim-native iterator definitions when `for` loop support or interop examples
need them.

Candidate syntax:

```lisp
(iterator countdown ((start int)) (: int)
  ...)
```

Tasks:

- [ ] Decide syntax for `iterator`.
- [ ] Add `yield`.
- [ ] Emit Nim iterator definitions.
- [ ] Add tests using the iterator from Nimp `for` and Nim code.

Definition of done:

- [ ] Nimp can define a Nim iterator and consume it from `for`.

### 13. Converter Definitions

Converters are useful for some Nim APIs but affect type-directed implicit
conversion. Treat them as advanced interop and defer until a real use case
appears.

Candidate syntax:

```lisp
(converter toName ((value string)) (: Name)
  ...)
```

Tasks:

- [ ] Decide whether converters should be allowed by default or gated by a
      clearly named form.
- [ ] Emit Nim converter definitions.
- [ ] Add tests that prove intended conversions work and unintended ambiguous
      conversions produce useful diagnostics.

Definition of done:

- [ ] Nimp can define a Nim converter for a concrete interop example.

### 14. Nimp Module System

Imports currently target Nim modules. Nimp needs package/module conventions for
larger codebases.

Tasks:

- [ ] Decide `.nimp` module discovery and output layout.
- [ ] Decide how Nimp modules expose Nim modules.
- [ ] Support importing another `.nimp` file from Nimp.
- [ ] Preserve macro visibility rules across files.
- [ ] Add cycle diagnostics.
- [ ] Add CLI tests for multi-file projects.

Definition of done:

- [ ] A Nimp project can be split across multiple `.nimp` files.
- [ ] Nim can import compiled Nimp modules through predictable paths.

### 15. Hygiene Beyond Basic Gensym

Current hygiene support prevents forged name collisions through hidden
`hygieneId` values mapped to Nim `genSym`. Full lexical hygiene remains open.

Tasks:

- [ ] Define syntax context/scopes for introduced and captured identifiers.
- [ ] Decide controlled capture APIs.
- [ ] Preserve hygiene metadata through quote/quasiquote where appropriate.
- [ ] Add tests for introduced identifiers, intentional capture, nested macros,
      and imported macros.

Definition of done:

- [ ] Macro-introduced bindings do not accidentally capture or get captured.
- [ ] Intentional capture is explicit and test-covered.

### 16. Destructuring

Add destructuring after the binding model is stable enough to support it
consistently.

Targets:

- `let`
- `var`
- `do`
- `proc` parameters if it can map cleanly to Nim
- macro parameters

Tasks:

- [ ] Decide destructuring syntax for lists, tuples, objects, and rest values.
- [ ] Add lowering validation and diagnostics.
- [ ] Decide whether destructuring is a core lowering feature or macro-expanded
      into simpler bindings.
- [ ] Add tests for success, arity mismatch, and nested destructuring.

Definition of done:

- [ ] Common destructuring works in locals and macro parameters.

### 17. Pattern Matching

Pattern matching is separate from Nim `case`. It should likely build on
destructuring and type declarations.

Tasks:

- [ ] Define pattern syntax.
- [ ] Decide supported pattern kinds: literals, symbols, tuples, objects,
      enums, guards, and wildcards.
- [ ] Decide whether matching lowers to Nim `case`, `if`, or helper procs.
- [ ] Add exhaustiveness only if it can be done without excessive compiler
      complexity.
- [ ] Add tests and examples for enums and object variants.

Definition of done:

- [ ] Nimp has useful pattern matching without compromising direct Nim interop.

### 18. REPL

A first REPL can be backed by temporary Nim compilation.

Tasks:

- [ ] Keep a session transcript of successful forms.
- [ ] Generate and compile a temporary Nim wrapper per input.
- [ ] Preserve previous definitions across inputs.
- [ ] Separate declaration forms from value expressions.
- [ ] Print expression values consistently.
- [ ] Keep failed inputs from corrupting the session.

Definition of done:

- [ ] Users can evaluate expressions and definitions interactively.
- [ ] Diagnostics point back to the REPL input.

### 19. Formatter

Add a formatter once syntax conventions are stable enough.

Tasks:

- [ ] Define canonical formatting for lists, vectors, quote forms, bindings,
      declarations, and comments.
- [ ] Preserve comments.
- [ ] Add idempotence tests.
- [ ] Add a CLI command.

Definition of done:

- [ ] Running the formatter twice produces identical output.

### 20. Macro Expansion Viewer

The CLI already has basic `macroexpand`. Expand it into a more useful viewer
only after macro and module semantics settle.

Tasks:

- [ ] Add optional per-phase output.
- [ ] Add source span display.
- [ ] Add imported macro/module visibility information.
- [ ] Add golden tests for viewer output.

Definition of done:

- [ ] Macro debugging is practical without reading compiler internals.

### 21. Language Server Basics

Language-server work should follow stable syntax, modules, and diagnostics.

Tasks:

- [ ] Parse files incrementally enough for editor feedback.
- [ ] Surface reader/lowering/macro diagnostics.
- [ ] Add go-to definition for local bindings and top-level declarations.
- [ ] Add hover for known bindings and generated Nim-facing declarations.
- [ ] Add completion for local names and imported modules where practical.

Definition of done:

- [ ] Editing `.nimp` files has basic diagnostics and navigation.

### 22. Package Layout Conventions

Define how real Nimp projects should be organized.

Tasks:

- [ ] Decide source directories and generated Nim output layout.
- [ ] Decide how `std/core.nimp` and user prelude code are located.
- [ ] Document examples for library and application projects.
- [ ] Add CLI tests for package-shaped fixtures.

Definition of done:

- [ ] A new project has a documented layout that works with `nimble test` and
      ordinary Nim imports.

## Suggested Priority

1. Type declarations.
2. Named arguments and object construction.
3. Export markers and pragmas.
4. Const declarations.
5. Generic declarations.
6. For loops.
7. Case.
8. Error handling.
9. Tail recursion.
10. Template and iterator definitions.
11. Module system.
12. Hygiene, destructuring, and pattern matching.
13. REPL, formatter, macro viewer, language server, and package conventions.

This order prioritizes the features needed to define useful Nim-facing APIs
from Nimp before investing in larger tooling.

## Testing Expectations

Every implemented feature should include:

- Reader tests only when new tokenization or quote behavior is introduced.
- Lowering tests for malformed syntax and scope/mutability rules.
- Backend tests for emitted Nim behavior.
- CLI tests when diagnostics, file output, module layout, or examples are
  affected.
- At least one focused `.nimp` example when the feature is user-facing.

Run the full suite with:

```bash
nimble test
```
