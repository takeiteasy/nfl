# nil Code Review Report

> Review of the `nil` Lisp-to-Nim transpiler (commit at time of review).
> Status: Two immediate compilation bugs were fixed during review (indentation error + unreachable code after `raise`). All tests and examples pass.

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture: The Fundamental Problem](#architecture-the-fundamental-problem)
3. [String-Based Code Generation is Extremely Brittle](#string-based-code-generation-is-extremely-brittle)
4. [The `lisp` Macro Compiles Strings at Compile-Time](#the-lisp-macro-compiles-strings-at-compile-time)
5. [Environment Implementation](#environment-implementation)
6. [evalSexp Re-evaluates Arguments Repeatedly](#evalsexp-re-evaluates-arguments-repeatedly)
7. [Parser Issues](#parser-issues)
8. [Macro System Design Flaws](#macro-system-design-flaws)
9. [Type System and `auto`](#type-system-and-auto)
10. [Missing Features / Sharp Edges](#missing-features--sharp-edges)
11. [Specific Code Smells](#specific-code-smells)
12. [Testing Gaps](#testing-gaps)
13. [Recommended Priorities](#recommended-priorities)

---

## Executive Summary

`nil` is a clever proof-of-concept: a Lisp dialect that transpiles to Nim via compile-time macros, with direct Nim interop and a full macro system (`defmacro`, quasiquote, unquote). However, its **string-based code generation** and **dual execution paths** (a macro evaluator vs. a code emitter) are the root causes of its instability. The most impactful improvement would be to **emit Nim AST (`NimNode`) directly** instead of concatenating strings, and to **unify macro expansion and code generation** onto a single AST representation.

---

## Architecture: The Fundamental Problem

`nil` has two parallel execution paths that share a parser but diverge completely afterward:

- **Macro evaluator** (`evalSexp`): An interpreter that runs at compile-time to expand macros. It maintains its own environment (`Env`), closures (`skClosure`), and implements its own semantics for `if`, `let`, `lambda`, `+`, etc.
- **Code emitter** (`emitExpr`): A string generator that produces Nim source code for everything else.

### Why this is dangerous

These two paths have **different semantics**. The macro evaluator is essentially a second Lisp interpreter embedded inside the transpiler. Any bug or inconsistency between `evalSexp` and `emitExpr` means macros see a different language than the generated code.

**Example**: `evalSexp` implements `list?` as:
```nim
if val.kind == skList or val.kind == skNil:
```

But `emitListPred` emits:
```nim
"compiles(" & expr & "[0])"
```

These are completely different checks. A macro using `list?` at compile-time gets correct behavior, but the emitted Nim code relies on whether `expr[0]` compiles -- which fails for strings, options, etc. in confusing ways.

### Better strategy

Unify on a single representation. Either:
- **Emit Nim AST directly** using Nim's `macros` API instead of strings. This eliminates string-quoting/indentation bugs entirely and gives you Nim's type checker for free.
- **Or** make the macro evaluator the *only* execution path and have it produce Nim AST nodes instead of `Sexp` values. Macros would then return AST directly.

---

## String-Based Code Generation is Extremely Brittle

`emitExpr` builds Nim code by concatenating strings. This is the source of most stability risks:

### Indentation and quoting bugs

Line 1319 (now fixed) had broken indentation plus an extra `"` at the end of a string literal:
```nim
# BEFORE (broken)
      return "(" & emitExpr(n.list[2]) & "[" & emitExpr(n.list[1]) & "])""

# AFTER (fixed)
      return "(" & emitExpr(n.list[2]) & "[" & emitExpr(n.list[1]) & "])"
```

String templating makes this trivial to do and hard to catch.

### No hygiene for generated names

```nim
proc emitComparisonChain(...):
  blockStr.add "  let x" & $i & " = " ...
```

If a nil program defines its own `x1`, the generated code shadows it.

### `asCond` and `forceValue` are hacks

```nim
proc forceValue(n: Sexp): string =
  result = emitExpr(n)
  if opName(n) in ["echo", "println", "stdout.write", "stderr.write"]:
    result = "(" & result & "; 0)"
```

This hardcodes specific procedures to work around Nim's `discard` checker. Any other `void` procedure from Nim's stdlib will cause a compile error when used in a non-final position. This doesn't scale.

### `emitReverse` generates a full block with temp variables

This could just emit `reversed(list)` using Nim's `algorithm.reversed`.

### Better strategy

Use Nim's `macros` API to build `NimNode` AST directly. You get:
- Proper scoping and hygiene via `genSym`
- No string escaping/indentation issues
- Nim's parser validates your output for free

---

## The `lisp` Macro Compiles Strings at Compile-Time

```nim
macro lisp*(body: string): untyped =
  ...
  let src = emitExpr(expanded)
  stmts.add parseStmt(src)
```

You generate a string, then call `parseStmt` on it. This means:
1. String must be valid Nim syntax (see brittleness above)
2. Error locations in the macro are meaningless to the user -- they point into generated string code, not the original Lisp
3. `parseStmt` can fail with cryptic Nim errors for valid Lisp

### Better strategy

Build `NimNode` directly in `emitExpr` (renamed to `toNimAst`). No `parseStmt` needed, and you can attach line info from the Lisp parser to the Nim nodes for decent error messages.

---

## Environment Implementation

The macro evaluator uses a linked-list environment:

```nim
type
  EnvBinding = object
    name: string
    entry: EnvEntry
    next: ref EnvBinding
  Env = ref object
    head: ref EnvBinding
    parent: Env
```

Variable lookup is a linear scan through a linked list. Macro expansion that builds large environments (e.g., `let*` with many bindings) degrades to O(n^2). The cycle detection (`envCount > 1000`) is a band-aid that shouldn't be needed.

### Better strategy

Use `Table[string, EnvEntry]` for each scope frame. Lookup becomes O(1) average case, and you don't need cycle detection hacks.

---

## evalSexp Re-evaluates Arguments Repeatedly

In the macro evaluator, `evalSexp` evaluates arguments inline every time they're used:

```nim
of "-":
  let first = evalSexp(sexp.list[1], env, macros)
  ...
  for i in 2..<sexp.list.len:
    if evalSexp(sexp.list[i], env, macros).kind == skFloat:
```

For operators like `-` with type detection, `sexp.list[i]` is evaluated **twice** -- once to check if it's a float, once to get the value. Side effects (if nil had them in macros) would execute twice.

### Fix

Evaluate all arguments to a `seq[Sexp]` first, then process.

---

## Parser Issues

### No negative number support
`-5` is parsed as symbol `-` followed by number `5`. This makes `(- 5)` in the REPL fail because it sees a unary minus call with missing args.

### `parseError` uses `ref ValueError` -- should be a dedicated exception
```nim
proc parseError(loc: SourceLoc, msg: string): ref ValueError =
  var e: ref ValueError
  new(e)
  e.msg = ...
  return e
```

Creating a `ref` exception and returning it is unusual. Better:
```nim
type LispError = object of ValueError
  loc: SourceLoc

proc raiseParseError(loc: SourceLoc, msg: string) {.noreturn.} =
  raise (ref LispError)(msg: "line " & $loc.line & ":" & $loc.col & ": " & msg)
```

### Quote handling mutates the parsed node
```nim
elif p.s[p.i] == '\'':
  ...
  if quoted.kind == skList:
    quoted.isQuoted = true
  return quoted
```

This mutates the child node in-place. If the same list is referenced elsewhere (e.g., in macro expansion), you get unexpected sharing bugs.

### No reader macros or dispatch macros
Only `#|` for block comments. No `#(`, `#[`, etc. This limits extensibility.

---

## Macro System Design Flaws

### `defmacro` is evaluated during `collectMacros`, not during normal expansion

Macros are collected by scanning the top-level forms. If a `defmacro` appears inside a `let` or `lambda`, it's silently ignored by `collectMacros` but not by `evalSexp`. This is inconsistent.

### Macro expansion is eager and single-pass

```nim
let fileMacros = collectMacros(sexps)
let macros = mergeMacroEnvs(stdMacros, fileMacros)
for sexp in sexps:
  let expanded = expandMacros(sexp, macros)
```

Macros defined in the file are available to all forms, including those *before* the definition. This is unusual -- Scheme and CL typically don't allow forward-referencing macros unless you structure your compilation units that way. Worse, a macro defined on line 10 that redefines a stdlib macro will affect line 5.

### `evalSexp` for macros implements `if`, `let`, etc. differently than emitted code

As noted in the Architecture section, the macro evaluator is a parallel implementation. The `cond` macro in `std.nil` expands to nested `if`s, which the macro evaluator evaluates using its own `if` semantics. If those semantics drift from emitted `if` semantics, you get macro bugs that are impossible to debug.

### `gensym` is global and unsafe

```nim
var gensymCounter*: int = 0
proc gensym*(prefix: string = "g"): string =
  inc(gensymCounter)
  prefix & $gensymCounter
```

This is a global counter. In Nim, macro execution at compile-time is cached and may run multiple times across modules. Two different `nil` files using `gensym` can collide. Nim's `genSym` in the `macros` module exists exactly for this reason and generates truly unique symbols scoped to the macro invocation.

---

## Type System and `auto`

Generated code uses `auto` for almost everything:
```nim
proc caar*(x: auto): auto =
proc foldl*(f: auto, init: auto, lst: auto): auto =
```

This works for simple cases but breaks down quickly:
- Nim's `auto` return type inference has limits with recursion (`foldl`, `range`, etc. may fail with complex types)
- No way to annotate types in nil beyond simple param types
- `identity` returning `auto` causes issues when passed to higher-order functions expecting specific types
- The `apply` template in `runtimeHelpers` only handles single-argument functions: `f(args[0])`

---

## Missing Features / Sharp Edges

| Issue | Details |
|-------|---------|
| No explicit `begin`/`progn` at top level | `(define x 1) (define y 2)` works, but it's implicit via `emitBody` |
| `set!` mutates `let` bindings but `let` in Nim is immutable | `emitDefine` generates `let name = ...`, and `emitSet` generates `name = val`. This is a **bug**: `let` variables in Nim cannot be reassigned. `set!` will fail at the Nim compilation stage. |
| `length` on `nil` | `evalSexp` says `if lst.kind != skList: raise ...`, but `skNil` is a separate kind. `(length nil)` fails in macro evaluator but emits `(@[].len)` for nil in code gen. More inconsistency. |
| No tail-call optimization | Recursive `foldl`, `range`, etc. will blow the stack |
| `cdr` of empty list | Emits `list[1..^1]` which is `@[]`, but macro evaluator returns `Sexp(kind: skList, list: @[])`. OK, but inconsistent with `skNil` |

---

## Specific Code Smells

### `isDefine` is declared but defined later
Forward declaration without need -- Nim allows out-of-order definitions.

### `opName` doesn't check for nil
```nim
proc opName(n: Sexp): string =
  if n.kind == skList and n.list.len > 0 and n.list[0].kind == skSymbol:
    return n.list[0].symbol
  return ""
```
OK in practice, but `forceValue` calls this on arbitrary expressions.

### `emitBody` has special logic for `echo` last expressions
```nim
if opName(lastExpr) in ["echo", "println", "stdout.write", "stderr.write"]:
  body.add forceValue(lastExpr) & "\n"
else:
  body.add emitExpr(lastExpr) & "\n"
```

This hardcodes specific side-effecting procedures. It should instead check if the expression's Nim type is `void`, which is impossible with string emission.

### `loadStdlibMacros` hardcodes a path mismatch
```nim
let stdPath = currentSourcePath().parentDir() / "std" / "nilpkg.nil"
```

The repo has `std/nilpkg.nil` but `AGENTS.md` says `std/std.nil`. This path inconsistency is confusing and fragile (relies on `currentSourcePath()`).

### `runtimeHelpers` is a constant string containing a template
```nim
const runtimeHelpers* = """
template apply(f: untyped, args: untyped): untyped =
  f(args[0])
"""
```

This is injected into transpiled output. But `apply` only works for single-argument functions, and the template is implicitly redefined in every compilation unit (causing warnings).

---

## Testing Gaps

The tests cover basic features well, but miss:
- Error cases (unbalanced parens, undefined variables, wrong arg counts)
- Interaction between macros and the type system
- `set!` with `let` (will this actually compile in standalone files?)
- Large recursive programs (stack overflow)
- Edge cases: `car` of empty list, `cdr` of `nil`, etc.
- The REPL has no tests at all

---

## Recommended Priorities

| Priority | Issue | Strategy |
|----------|-------|----------|
| **P0** | String-based code gen | **Emit `NimNode` AST directly** using the `macros` module. This is the single biggest improvement. |
| **P0** | Dual eval/emit semantics | Make macro evaluation operate on the same AST representation that code gen uses. Macros should return AST nodes, not `Sexp` values that need a second interpreter. |
| **P1** | Environment linked list | Replace with `Table[string, EnvEntry]` per scope frame. |
| **P1** | `gensym` collisions | Use Nim's `genSym` from the `macros` module instead of a global counter. |
| **P1** | `set!` vs Nim `let` | Either generate `var` for all bindings, or track mutability and use `var` only when `set!` is used. |
| **P2** | Parser mutations | Make parsing fully functional (no in-place mutation of child nodes). |
| **P2** | `apply` template | Generalize to arbitrary arity using `macro apply` or Nim's `unpack` / `call` macros. |
| **P2** | Error locations | Attach Lisp source locations to Nim AST nodes so compile errors point to Lisp code. |
| **P3** | Tail-call optimization | Implement trampolining or loop conversion for self-recursive tail calls. |

---

## Conclusion

`nil` is a neat proof-of-concept and the macro system is genuinely impressive for its size. But the string-emission architecture is holding it back -- switching to `NimNode` AST construction would fix the majority of stability issues at once and make the codebase much more maintainable. The two immediate bugs fixed during this review (indentation and unreachable code) are symptomatic of the deeper structural issues.
