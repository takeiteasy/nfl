## Nimp Progress

This roadmap starts from the post-Milestone-7 baseline. Reader, expansion,
lowering, NimNode backend emission, diagnostics, core macros, imports, procs,
field/method access, indexing, typed locals, typed proc parameters, runtime
quote, and example/test coverage are already in place.

The next phase is about making Nimp practical for ordinary Nim library and
application code without adding a raw Nim source escape hatch. New features
should keep using the v2 pipeline:

```text
source text
  -> Nimp syntax tree
  -> macro expansion over syntax objects
  -> lowering and validation
  -> Nim `NimNode` backend
```

Generated Nim source is only a debug view. The backend should continue to build
Nim AST directly with `macros`.

## Design Rules

1. Keep the compiler core small.
2. Prefer Nimp macros or stdlib helpers when a feature does not require special
   Nim AST forms.
3. Preserve source locations from reader through generated Nim nodes where
   possible.
4. Keep macro expansion over Nimp syntax data, not generated Nim text.
5. Keep host interop direct and Nim-native.
6. Avoid a broad raw Nim escape hatch unless repeated concrete interop gaps show
   that narrower wrappers are not enough.
7. Add focused tests for every new special form.
8. Add or update a `.nimp` example for every user-facing feature that can be
   demonstrated without large scaffolding.

## Current Surface Commitments

- Function literals: `do`
- Sequential execution: `block`
- Top-level definitions: `define`
- Compile-time macros: `defmacro`
- Immutable locals: `let`
- Mutable locals: `var`
- Mutation: `set!`
- Imports: `import`
- Top-level Nim-callable procedures: `proc`
- Field/method access: `(. value field)`, `(. value method arg...)`, dotted
  symbols such as `value.field` and `(value.method arg...)`
- Indexing/slicing: `(at xs i)`, `(slice xs start stop)`, and escaped Nim
  operators such as `(|[]| xs i)`

Do not add `fn`, `lambda`, or `def` aliases unless explicitly requested.
