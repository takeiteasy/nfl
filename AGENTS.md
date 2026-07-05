# NFL — Nim Flavoured Lisp — AGENTS.md

## Project Overview

NFL (Nim Flavoured Lisp) is a Lisp-inspired processor for Nim. The old name was `nil` ("Nim Implementation of Lisp"), then `nimp` (v2); v3 is renamed to NFL to better reflect the project's identity. The v1 proof of concept is kept under `legacy/` on `master` and on the `old` branch for reference only. New implementation work should not depend on the v1 string emitter.

## Architecture Direction

- Pipeline: source text to NFL syntax tree to expanded syntax tree to lowered IR to Nim `NimNode`.
- Backend: build Nim AST directly with `macros`; generated Nim source is only a debug view.
- Interop: direct Nim calls should feel ordinary, not like an FFI layer.
- Runtime: prefer native Nim values; runtime lists are Nim `seq[T]`.
- Truthiness: only `nil` and `false` are falsey; empty sequences are truthy.

## Current Layout

```text
src/
  nfl/
    syntax.nim          # Syntax objects and spans
    diagnostics.nim     # Structured reader/compiler diagnostics
    reader.nim          # Reader/parser
tests/
  test_reader.nim
TICKETS tracked at https://todo.sr.ht/~takeiteasy/nfl
```

## Surface Syntax Decisions

- Function literals: `do`
- Sequential execution: `block`
- Top-level mutable variable (set only if unbound): `defvar`
- Top-level mutable variable (always set): `defparameter`
- Macros: `defmacro`
- Immutable locals: `let`
- Mutable locals: `var`
- Mutation: `set!`
- Compile-time constant (module-only): `const` / `defconstant` (alias)
- Do not add `fn`, `lambda`, or `def` aliases unless explicitly requested.
- `define` is removed; use `defvar` or `defparameter`.

## Macro Lambda List Markers

Macro parameter lists (`defmacro`) support the Common Lisp lambda list subset:

- `&optional` — optional positional params; each entry is a symbol or `(name default)`
- `&rest` — collects remaining positional args as a list
- `&body` — like `&rest` but signals the args are code forms (preferred in body-taking macros)
- `&key` — keyword params matched by `:keyword` at call sites; entries are a symbol, `(name default)`, or `((:keyword local) default)` for renaming

The dotted-pair rest form `(req . rest)` remains valid and is equivalent to `&rest`.

Deferred (not yet implemented): `&allow-other-keys`, `&aux`.

## Reader Conventions

- Source extension for NFL examples and tests is `.nfl`.
- The literal `nil` remains part of the language.
- Line comments use `;`.
- Block comments use `#| ... |#`.
- Quote forms are `'`, backtick quasiquote, `,` unquote, and `,@` unquote-splicing.
- Every parsed syntax node should carry a source span.

## Development

Run tests with:

```bash
nimble test
```

When adding or completing language features, keep tickets on the sr.ht tracker up to date. Add or update at least one focused `.nfl` example under `examples/` when the feature is user-facing and can be demonstrated without large scaffolding.

## Design Principles

1. Keep the compiler core small.
2. Prefer stdlib macros/functions when a feature can be written in NFL.
3. Preserve source locations from reader through generated Nim nodes where possible.
4. Keep macro expansion over syntax data, not generated Nim text.
5. Keep host interop direct and Nim-native.
