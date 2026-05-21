# Nimp Restart Roadmap

This document describes a restart path for Nimp as a serious small Lisp-inspired processor for Nim. The old `nil` name stood for "Nim Implementation of Lisp", but `nil` is a Nim keyword and is awkward as a package, module, and CLI name. Nimp keeps the Nim/Lisp lineage while avoiding keyword collisions.

The goal is not to build a generic Lisp interpreter. The goal is a Hy-inspired Lisp that feels native to Nim, compiles to Nim AST, has easy host interop, and keeps the compiler core small enough to reason about.

## Product Direction

Nimp should be:

1. A small Lisp syntax for writing Nim programs.
2. Easy to embed in Nim projects through macros.
3. Easy to run as `.nimp` files through a CLI wrapper.
4. Strongly biased toward Nim interop instead of a boxed dynamic runtime.
5. Built around a minimal compiler core and a larger stdlib written in Nimp.

Nimp should not try to be:

1. A full Common Lisp clone.
2. A full Scheme clone.
3. A separate runtime VM.
4. A string-to-Nim transpiler with ad hoc syntax templates.
5. Perfectly backward-compatible with the current proof of concept.

## Design Principles

1. Use one compiler pipeline: source text to Nimp syntax tree to expanded Nimp syntax tree to lowered IR to Nim `NimNode`.
2. Treat generated Nim source as a debug view, not as the compiler's source of truth.
3. Keep host interop easy: calling Nim code should be ordinary, not an FFI ceremony.
4. Keep compiler builtins small; prefer stdlib macros and functions when a feature can be written in Nimp.
5. Preserve source locations from the reader all the way to generated Nim nodes.
6. Make semantics explicit before adding convenience features.
7. Prefer native Nim values at runtime instead of a universal Lisp `Atom` object.
8. Make macro expansion operate on syntax data, not generated Nim text.

## Reference Influence

The `building-lisp` reference is useful for deciding where the core boundary should be. Its C header keeps primitive concepts small: reader, printer, evaluator, environment, cons/data operations, and a compact builtin set such as `car`, `cdr`, `cons`, `eq`, pair checks, and primitive numeric comparisons.

Its `library.lisp` then builds most conveniences in Lisp itself: `append`, `foldl`, `foldr`, `list`, `map`, quasiquote, `and`, `begin`, `cond`, `let`, `or`, `when`, `unless`, numeric wrappers, list helpers, and predicates.

For Nimp, the lesson is the boundary, not the exact runtime model. Because Nimp targets Nim, v2 should avoid copying a boxed interpreter runtime. Use the small-core idea, but compile to native Nim constructs.

## Proposed Compiler Pipeline

```text
source.nimp
  -> reader / lexer
  -> surface syntax tree with source spans
  -> macro expansion over syntax objects
  -> normalized core syntax
  -> semantic lowering
  -> NimNode backend
  -> Nim compiler
```

### Reader

The reader should produce syntax objects, not raw strings and not Nim nodes.

Initial reader forms:

1. Symbols.
2. Integers and floats.
3. Strings with well-defined escapes.
4. Booleans.
5. `nil`.
6. Lists using `(...)`.
7. Vectors or sequence literals using `[...]` if desired.
8. Quote forms: apostrophe quote, quasiquote, unquote, and unquote-splicing.
9. Line comments and block comments.

Every syntax object should carry:

1. File path or virtual source name.
2. Start line and column.
3. End line and column.
4. Original spelling for symbols when useful.

### Syntax Data

Use a dedicated syntax type for compile-time code representation.

Suggested shape:

```nim
type
  Span* = object
    file*: string
    line*, col*: int
    endLine*, endCol*: int

  SyntaxKind* = enum
    sxNil, sxBool, sxInt, sxFloat, sxString, sxSymbol,
    sxList, sxVector

  Syntax* = ref object
    span*: Span
    case kind*: SyntaxKind
    of sxNil: discard
    of sxBool: boolVal*: bool
    of sxInt: intVal*: BiggestInt
    of sxFloat: floatVal*: BiggestFloat
    of sxString: strVal*: string
    of sxSymbol: sym*: string
    of sxList, sxVector: items*: seq[Syntax]
```

Do not store compiler decisions directly on reader nodes. Use separate normalized/lowered nodes once expansion starts.

### Macro Expansion

Macros should consume and return Nimp syntax objects. They should not concatenate Nim source strings.

Recommended initial model:

1. `defmacro` defines compile-time Nimp functions that receive unevaluated syntax arguments.
2. Macro return values are syntax objects.
3. `quote`, `quasiquote`, `unquote`, and `unquote-splicing` are expander features.
4. `gensym` returns hygienic syntax symbols with stable printable names and hidden identity.
5. Macro expansion is deterministic and ordered.

Important design choice:

Macro-time computation should be intentionally scoped. It can have its own syntax-manipulation prelude, but it should not pretend every runtime Nim value or runtime Nimp function is available at compile time.

The macro-time API should start small:

1. `syntax?`
2. `symbol?`
3. `list?`
4. `nil?`
5. `first`
6. `rest`
7. `cons`
8. `list`
9. `append`
10. `syntax->datum`
11. `datum->syntax`
12. `gensym`
13. `macro-error`

### Normalized Core Syntax

After macro expansion, lower surface conveniences into a small core. This is where `define-proc`, `when`, `cond`, threading macros, destructuring, and pattern matching should disappear.

Suggested compiler core forms:

1. `quote`
2. `if`
3. `begin`
4. `lambda`
5. `let`
6. `var`
7. `set!`
8. `define`
9. `import`
10. `call`
11. `host-field` or equivalent host access form

Everything else should initially be a macro or stdlib function.

### Semantic Lowering

Lower normalized syntax into an internal IR before emitting Nim nodes. This gives the compiler a place to resolve names, classify definitions, allocate temporaries, preserve spans, and enforce rules.

The lowering pass should decide:

1. Whether a symbol is local, imported, generated, or unresolved Nim host code.
2. Whether a binding is immutable or mutable.
3. Whether a form is an expression, statement, or definition.
4. Whether a temporary needs `genSym`.
5. Whether a condition needs truthiness conversion.
6. Whether source spans should be attached to emitted Nim nodes.

### NimNode Backend

The backend should build Nim AST directly with the `macros` module.

Rules:

1. No generated Nim source strings in the main backend.
2. Use `genSym` for compiler temporaries.
3. Use `copyLineInfo` or equivalent line-info APIs where possible.
4. Prefer real Nim identifiers and calls over `parseExpr` or `parseStmt`.
5. Allow a debug printer, but do not use printed code as an intermediate representation.

The backend should support both inline and file-based entry points.

Inline Nim usage:

```nim
import nimp/compiler

let x = nimpExpr"(+ 1 2)"
```

CLI usage can generate a tiny Nim wrapper instead of generating a full Nim source translation:

```nim
import nimp/compiler

nimpModule(staticRead("program.nimp"))
```

That keeps the real backend as `NimNode` while still allowing `nimp run file.nimp` and `nimp compile file.nimp`.

## Language Semantics To Decide Early

These decisions should happen before building a large stdlib.

### Runtime Data Model

Decision:

1. Runtime code should use native Nim values.
2. Runtime lists lower to Nim `seq[T]`.
3. Compile-time syntax lists should be separate from runtime sequences.
4. Avoid a universal boxed `Atom` runtime unless an interpreter mode becomes a separate goal.

This keeps host interop easy and lets Nim's type checker remain useful.

### `nil` And Truthiness

This needs an explicit rule because Nim is statically typed and Lisp truthiness is dynamic.

Decision:

1. `nil` is false and lowers to Nim `nil` only when the target type can accept it; otherwise it is a compile-time error.
2. `false` is false.
3. Empty sequences are truthy; sequence emptiness should be tested explicitly.
4. Conditions accept Nim `bool` expressions and nil-able values that the compiler can explicitly compare against `nil`.
5. The compiler should not add a broad Lisp-style `truthy` protocol unless a later milestone reopens this decision.

This keeps condition semantics close to Nim while preserving `nil` as the only non-boolean falsey value.

Macro-time conditionals follow the same truthiness rule over syntax values: only syntax `nil` and syntax `false` are falsey. Empty syntax lists and vectors are truthy. Macro code that needs to test for an empty rest argument list should use the macro-time structural predicate `nil?`, not rely on conditional truthiness.

### Surface Names

Decision:

1. Core function literals use `lambda`.
2. Sequential execution uses `begin`.
3. Top-level definitions use `define`.
4. Compile-time macros use `defmacro`.
5. Local immutable bindings use `let`.
6. Local mutable bindings use `var`.
7. Mutation uses `set!`.
8. Short aliases such as `fn`, `do`, and `def` are not part of the initial language surface.

### Bindings And Mutation

Recommendation:

1. `let` creates immutable local bindings.
2. `var` creates mutable local bindings.
3. `set!` only works on mutable bindings.
4. `define` creates immutable top-level definitions by default.
5. A separate `defvar` can exist if mutable globals are needed.

This maps cleanly to Nim and avoids guessing whether a binding may be mutated later.

### Macro Visibility

Recommendation:

1. Macros are visible after their definition in file order.
2. Forward macro references are not allowed initially.
3. `import`ed macro modules are available after import.
4. A later module system can add explicit compile-time imports.

This avoids the current whole-file pre-scan behavior where later macros can affect earlier forms.

### Host Interop

Host interop is a core product feature.

Initial interop should support:

1. Calling Nim procs by symbol: `(echo "hello")`.
2. Calling Nim operators: `(+ a b)`, `(< a b)`, `(== a b)`.
3. Importing Nim modules: `(import std/strutils)`.
4. Referencing Nim types in annotations: `(lambda ((x int)) x)`.
5. Accessing fields and methods through a small, documented syntax.
6. Letting Nim infer types unless Nimp syntax supplies annotations.

Do not add wrappers for every Nim stdlib function. Direct interop is the wrapper.

## Minimal Core And Stdlib Split

### Compiler Core

Keep the compiler responsible for syntax, scope, macro expansion, host interop, and Nim AST emission.

Core special forms should be limited to forms that cannot be expressed as Nimp code:

1. `quote`
2. `if`
3. `begin`
4. `lambda`
5. `let`
6. `var`
7. `set!`
8. `define`
9. `defmacro`
10. `import`

Core host lowering should handle:

1. Nim calls.
2. Nim operators.
3. Nim field/method access.
4. Nim type annotations.

### Stdlib In Nimp

The stdlib should provide convenience and language feel.

Good early stdlib candidates:

1. `define-proc`
2. `when`
3. `unless`
4. `cond`
5. `and`
6. `or`
7. `let*`
8. `->`
9. `->>`
10. `as->`
11. `list`
12. `append`
13. `map`
14. `filter`
15. `foldl`
16. `foldr`
17. `reduce`
18. `first`
19. `rest`
20. `empty?`
21. `some?`
22. `every?`
23. `identity`

Do not move a stdlib feature into the compiler just because it is convenient. Move it only if it needs syntax, scope, source locations, host interop, or impossible Nim AST generation.

## Proposed Repository Layout

The restart lives in `src/nimp`. The v1 `nil` proof of concept was removed from this branch after the rewrite direction was established; use historical git revisions if v1 reference material is needed.

```text
src/
  nimp/
    syntax.nim          # Syntax objects and spans
    reader.nim          # Reader/parser
    diagnostics.nim     # Structured errors
    expand.nim          # Macro expansion
    macroenv.nim        # Compile-time macro environment
    lower.nim           # Syntax to core/lowered IR
    nimbackend.nim      # IR to NimNode
    runtime.nim         # Tiny runtime helpers
    compiler.nim        # Public compile APIs and macros
    cli.nim             # CLI implementation, installed as `nimp`
std/
  core.nimp             # Minimal Nimp stdlib loaded by default
  syntax.nimp           # Macro-time syntax helpers
tests/
  reader/
  expand/
  compile/
  cli/
examples/
```

No legacy string emitter is retained in-tree; new implementation work must continue to use the v2 reader, expander, lowering, and NimNode backend path.

## Milestones

### Milestone 0: Lock The Direction

Deliverables:

1. Decide syntax names for `fn`, `do`, `def`, `defmacro`, `let`, `var`, and `set!`.
2. Decide runtime `nil` and truthiness semantics.
3. Decide whether runtime lists are Nim `seq`, cons cells, or both.
4. Decide whether v2 lives in `src/nimp` while v1 remains as legacy. Answered: v2 lives in `src/nimp`; v1 legacy code has been removed from this branch.
5. Write one page of language semantics before implementation grows.

Definition of done:

1. `ROADMAP.md` has been accepted as the restart plan.
2. Open questions above are answered or explicitly deferred.

### Milestone 1: Reader And Syntax Objects

Status: completed.

Deliverables:

1. [x] New syntax object model with source spans.
2. [x] Reader for literals, lists, vectors, quote forms, and comments.
3. [x] Structured diagnostic type with file, line, column, and message.
4. [x] Unit tests for valid syntax.
5. [x] Unit tests for malformed syntax.

Definition of done:

1. [x] Reader tests do not invoke the Nim compiler.
2. [x] Every parsed node has a source span.
3. [x] Unterminated strings, unbalanced delimiters, and invalid quote forms produce clear errors.

### Milestone 2: NimNode Backend MVP

Status: MVP completed. Minimal lowering and mutability validation are complete; remaining semantic polish is deferred below.

Deliverables:

1. [x] A `nimpExpr` Nim macro that accepts a static string and returns `NimNode`.
2. [x] Emission for literals, symbols, calls, `if`, `begin`, `let`, `var`, `set!`, `lambda`, and `define`.
3. [x] Basic Nim operator calls.
4. [x] Basic imports.
5. [x] Runtime helper module for `truthy` if that design is chosen. Not needed for the MVP because conditions currently lower to Nim expressions directly.

Definition of done:

1. [x] Inline examples compile without `parseStmt` or generated source strings.
2. [x] `(+ 1 2)` works.
3. [x] `(if true 1 2)` works.
4. [x] `(let ((x 1)) (+ x 2))` works.
5. [x] `(lambda ((x int)) (+ x 1))` works.
6. [x] `(import std/strutils)` plus a direct Nim call works.

Deferred tasks:

1. [x] Attach `.nimp` source line information to emitted Nim nodes where the Nim macros API allows it.
2. [x] Add a proper semantic lowering pass before the backend grows much larger. Current implementation is a minimal validation/normalization boundary in `lower.nim`; it preserves syntax shape for the backend.
3. [x] Enforce that `set!` only mutates bindings introduced by `var`.
4. [x] Decide target-type handling for `nil`. Current M7 baseline emits Nim `nil` with `.nimp` line information and lets Nim reject invalid target contexts; richer Nimp-side type diagnostics are deferred until there is a concrete need.
5. [x] Add backend support for quoted syntax only after the macro/quote design is implemented.
6. [x] Add field/method host interop syntax in the interop milestone.

### Milestone 3: CLI Wrapper

Status: completed. Basic `.nimp` diagnostics work for reader, lowering, macro, and backend/type errors. Nimble metadata installs a user-facing `nimp` executable, `compile` writes stable outputs next to input files, successful commands clean temporary wrapper directories, and failed commands preserve the wrapper path for debugging.

Deliverables:

1. [x] `nimp run file.nimp`.
2. [x] `nimp compile file.nimp`.
3. [x] `nimp check file.nimp`.
4. [x] Temporary wrapper generation using the compile-time `nimpModule(staticRead(...))` path.
5. [x] Correct shell/path handling for spaces and special characters.

Definition of done:

1. [x] The CLI and inline macro use the same compiler code path.
2. [x] The CLI does not use a separate string transpiler as the authoritative backend.
3. [x] CLI errors point at `.nimp` source locations where possible.

Deferred tasks:

1. [x] Improve generated Nim diagnostics so backend/type errors consistently point at `.nimp` source locations, not only the temporary wrapper.
2. [x] Add Nimble installation metadata for a user-facing `nimp` executable.
3. [x] Choose stable output paths for `nimp compile` instead of leaving binaries in the temporary wrapper directory. Current behavior writes beside the input path with the `.nimp` extension removed.
4. [x] Clean up temporary wrapper directories after successful commands, while preserving enough information for debugging failures.
5. [x] Add explicit CLI tests for compile output behavior. `.nimp` error reporting tests are in place for reader, lowering, macro, and Nim type errors.
6. [x] Document that `.nimp` files enter through the `nimp` CLI or `nimpModule(staticRead(...))`, not by passing `.nimp` files directly to `nim c`.

### Milestone 4: Macro System MVP

Status: MVP completed. Macro expansion, ordinary `defmacro`, rest parameters, quasiquote, hygienic `gensym` identity, diagnostics, macro-time truthiness, and expansion tests are in place; runtime quoted syntax is deferred to a later milestone.

Deliverables:

1. [x] `quote` and `quasiquote` syntax expansion.
2. [x] `defmacro` with ordinary fixed parameters.
3. [x] Rest parameters for macros.
4. [x] `gensym`.
5. [x] Macro expansion tests that inspect expanded syntax.
6. [x] A macro-time syntax helper prelude.

Definition of done:

1. [x] `when`, `unless`, `cond`, `and`, and `or` can be implemented as Nimp macros.
2. [x] Macro expansion does not generate Nim strings.
3. [x] Macro errors report the macro call site and useful expansion context.

Deferred tasks:

1. [x] Add deeper hygienic macro metadata beyond stable `gensym` names.
2. [x] Implement runtime `quote` as public datum values, separate from compiler `Syntax`. Runtime quoted values should preserve literal structure and symbol names, but not spans or hygiene metadata. Keep runtime quasiquote/unquote deferred until there is a concrete use case.
3. [x] Add more negative expansion tests for invalid `unquote`, invalid `unquote-splicing`, malformed macro parameter lists, and expansion recursion limits.
4. [x] Add a simple `macroexpand` CLI command that reads a `.nimp` file, runs reader and macro expansion with normal core autoload behavior, and prints expanded Nimp syntax using the existing syntax renderer. Support `--no-core`; defer richer interactive viewers/debug printers until diagnostics tooling grows.

### Milestone 5: Bootstrap Stdlib

Status: mostly completed. `std/core.nimp` is autoloaded by default, a CLI opt-out exists, the first macro library is implemented, core sequence helpers are available, and Nimp-authored stdlib tests are in place. Numeric wrappers are not needed for the initial stdlib; direct Nim operator/proc calls are the baseline.

Deliverables:

1. [x] `std/core.nimp` loaded by default or by explicit prelude import. Implemented as default autoload with `autoloadCore = false` and CLI `--no-core` opt-outs.
2. [x] Core macro library: `define-proc`, `when`, `unless`, `cond`, `and`, `or`, `let*`, threading macros.
3. [x] Core sequence helpers: `first`, `rest`, `empty?`, `append`, `map`, `filter`, `foldl`, `foldr`.
4. [x] Numeric convenience wrappers if needed. Decision: not needed initially; use direct Nim operators and procs.
5. [x] Stdlib tests written in Nimp.

Definition of done:

1. [x] Most language convenience lives in `std/core.nimp`, not Nim compiler code.
2. [x] Stdlib tests compile through the same NimNode backend as user programs.
3. [x] No generated stdlib Nim file is checked in unless a freshness test enforces it.

Deferred tasks:

1. [x] Implement initial runtime sequence helpers once the surface spelling for names such as `empty?` and direct Nim interop for indexing/slicing are settled. Current indexing forms are `(at xs i)` and `(slice xs start stop)`.
2. [x] Add Nimp-authored stdlib tests under a dedicated stdlib test layer instead of only Nim tests that exercise autoloaded macros.
3. [x] Decide whether numeric wrappers are needed or whether direct Nim operator/proc calls are sufficient for the initial stdlib. Direct calls are sufficient.
4. [ ] Add an explicit prelude import form only if a concrete need appears; default autoload with `--no-core` is the current behavior.

### Milestone 6: Interop Polish

Status: partially completed. Import syntax already exists; field/method access, dotted symbols, indexing/slicing, typed top-level proc definitions, and direct Nim-callable procs have initial support. No advanced escape hatch is needed initially. Stable examples and broader interop coverage remain deferred.

Deliverables:

1. [x] Stable import syntax.
2. [x] Stable field/method access syntax. Supports both `(. value field)` / `(. value method arg...)` and dotted symbols such as `value.field` / `(value.method arg...)`.
3. [ ] Type annotation syntax for parameters, return types, and local declarations. Parameter annotations and `define-proc` return annotations are supported; local declaration annotations remain deferred.
4. [x] Generic Nim proc calls where Nim can infer types.
5. [x] Escape hatch for advanced Nim interop only if needed. Decision: do not add one before a real interop gap appears.

Definition of done:

1. A Nimp file can use at least three Nim stdlib modules directly.
2. [x] A Nimp file can define a Nim-callable proc with typed parameters.
3. [x] A Nim file can call a proc defined in Nimp.
4. Interop examples are small and documented.

Deferred tasks:

1. [ ] Add local declaration type annotations.
2. [ ] Add documented interop examples using multiple Nim stdlib modules.
3. [x] Decide whether advanced interop needs an explicit escape hatch. Current answer: no explicit escape hatch before M7.
4. [ ] Revisit indexing surface if escaped identifiers are added later; `[]` cannot currently be a symbol because square brackets are vector delimiters.

### Milestone 7: Stability And Diagnostics

Status: partially completed. Source-line preservation and first CLI diagnostics coverage are in place; broader negative coverage and example/std tests remain deferred.

Deliverables:

1. [x] Negative tests for parse errors, macro errors, type errors, unknown symbols, bad arity, and mutation errors. Parse, macro, type, and mutation coverage exists; unknown symbol and bad arity coverage still needs to be rounded out.
2. Golden expansion tests for macros.
3. Compile/run tests for examples.
4. [x] Source-line preservation in generated Nim nodes where possible.
5. No repeated helper redefinition warnings.

Definition of done:

1. `nimble test` covers reader, expander, backend, CLI, stdlib, and examples.
2. Common user mistakes produce Nimp-facing diagnostics.
3. Generated temporary names cannot collide with user names.

### Milestone 8: Serious-Language Features

These should come after the core is stable.

Candidate features:

1. Hygienic macro metadata beyond basic `gensym`.
2. Destructuring in `let`, `lambda`, and macro parameters.
3. Pattern matching.
4. Module system for Nimp files.
5. REPL backed by temporary Nim compilation.
6. Formatter.
7. Macro expansion viewer.
8. Language server basics.
9. Package layout conventions.
10. Deeper Nim compiler integration for direct `nim c file.nimp` workflows, if Nim exposes a robust hook for non-Nim project source files.

## Testing Strategy

Use multiple test layers instead of relying only on compile/run examples.

Reader tests:

1. Input string to syntax tree.
2. Source spans.
3. Error cases.

Expansion tests:

1. Macro input to expanded syntax.
2. Hygiene behavior.
3. Macro errors.

Backend tests:

1. Syntax to NimNode shape where practical.
2. Compile success for valid programs.
3. Compile failure with useful errors for invalid programs.

Interop tests:

1. Nim stdlib imports.
2. Nim operators.
3. Typed Nim procs defined from Nimp.
4. Nim code calling Nimp-defined procs.

CLI tests:

1. `nimp run`.
2. `nimp compile`.
3. File paths with spaces.
4. Error reporting from real files.

Stdlib tests:

1. Macros.
2. Sequence functions.
3. Numeric helpers.
4. Edge cases such as empty sequences.

## Compatibility Strategy

Do not promise v1 compatibility. The v1 implementation has been removed from the active tree, and compatibility should only be added later for specific, justified cases.

Useful things to keep from v1:

1. The examples as inspiration.
2. The macro examples as acceptance tests after syntax updates.
3. The idea of direct Nim calls.
4. The desire for a small compiler core.

Things to leave behind:

1. String-based code generation as the main backend.
2. Whole-file macro precollection.
3. Silent stdlib macro loading failures.
4. Checked-in generated Nim files without freshness tests.
5. Treating generated Nim source as the only meaningful compiler output.

## Open Questions

These early architecture questions are now answered for the M7 baseline. Reopen them only with a concrete implementation pressure or user-facing problem.

1. Answered: runtime lists are Nim `seq[T]`.
2. Answered: only `nil` and `false` are falsey; empty sequences are truthy.
3. Answered: `nil` lowers to Nim `nil` only where the target type can accept it; otherwise it is a compile-time error.
4. Answered: the default prelude is automatic through `std/core.nimp`, with `autoloadCore = false` and CLI `--no-core` opt-outs.
5. Answered: `defmacro` is available in ordinary files by default, visible after its definition in file order.
6. Answered: canonical field/method access uses `(. value field)` and `(. value method arg...)`; dotted symbols such as `value.field` and `(value.method arg...)` are supported as ergonomic syntax.
7. Answered: the language uses `lambda` and `define`, without initial `fn`/`def` aliases.
8. Answered: mutation is explicit with `var`; `let` remains immutable.

## Recommended First Implementation Slice

The first slice should be deliberately small:

```lisp
(import std/strutils)

(define greet
  (lambda ((name string))
    (echo (toUpperAscii name))))

(greet "nimp")
```

This slice proves:

1. Reader works.
2. `NimNode` backend works.
3. Imports work.
4. Typed functions work.
5. Direct Nim calls work.
6. CLI wrapper can compile a `.nimp` file.

After that, add `defmacro` and implement `when` in Nimp:

```lisp
(defmacro when (test . body)
  `(if ,test (begin ,@body) nil))
```

That proves the language can grow from its own stdlib instead of the compiler becoming a large pile of special cases.

## Success Criteria

The restart is on the right path when:

1. The core compiler has fewer special cases than v1.
2. Most conveniences are implemented in Nimp, not Nim.
3. Inline use and CLI use share the same AST backend.
4. Macro expansion never depends on generated Nim strings.
5. Errors point to Nimp source locations.
6. Nim interop feels direct enough that wrapper functions are rare.
7. The test suite catches semantic drift before users do.
