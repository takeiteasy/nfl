# `lfn repl`

`lfn repl` is a first interactive front end for LFN. It is **not** an
interpreter: every input you type is added to a session transcript, and the
*whole transcript* is written out as an LFN source file and compiled with an
actual `nim c`, then the resulting binary is run. There's no separate
evaluator with its own semantics to drift from the compiled language — what
happens in the REPL is exactly what `lfn run` would do on the same source.

```sh
lfn repl                  # start an empty session
lfn repl mylib.lfn        # preload mylib.lfn as the first transcript entry
lfn repl --no-core        # skip auto-loading the preamble (when/unless/cond/…)
```

## The replay model

Each input you enter becomes one transcript **entry**. On every new input,
`lfn repl`:

1. Reads it (across multiple lines if needed — see "Multi-line input" below).
2. Classifies it: does it *declare* something (`var`, `proc`, `type`, `defmacro`,
   …) or does it *produce a value*? A declaration prints nothing; a value
   expression's result is printed once, the same way regardless of type
   (`$` where available, falling back to `repr`; strings and chars are
   `repr`'d/quoted so `"1"` and `1` print distinguishably). A void
   expression — an assignment, a loop, `discard`, … — runs for its effect
   and prints nothing, same as a declaration.
3. Recompiles and reruns the **entire** transcript (the new entry included).
4. Prints only the *new* output — whatever the fresh run produced beyond
   what the previous run already printed.

This means side effects replay: an `(echo …)` from three inputs ago runs
again on every subsequent input, but since only new output is printed, you
never see it twice. It also means mutation is observed correctly:

```
lfn> (var x 1)
lfn> x
1
lfn> (set! x 2)
lfn> x
2
```

A failed input (a reader error, a macro-expansion error, a `nim` compile
error, or the compiled program exiting non-zero) leaves the session exactly
as it was — nothing is added, nothing already printed changes.

## Redefinition

Entering a `var`, `const`, `proc`, `template`, `iterator`, `type`, `method`,
`func`, `converter`, `defmacro`, or `defmacro-proc` for a name that's already
in the session **replaces** the earlier entry of the same name, in place
(not appended at the end) — so a redefined `defmacro` still comes before any
earlier entry that calls it once the transcript is replayed. Overloads are
replaced by name, not by parameter signature: redefining `proc f(x: int)`
also removes an unrelated `proc f(x: string)` from an earlier input.

```
lfn> (proc greet () (: string) "hi")
lfn> (greet)
"hi"
lfn> (proc greet () (: string) "hello")
"hello"
lfn> (greet)
"hello"
```

Because the whole transcript is replayed on every input, a redefinition
changes what the *earlier* `(greet)` call now produces too — it's the same
`(greet)` text, replayed fresh against the new `greet`. Since output is only
diffed against the previous run, that earlier call's new result shows up
once, right after the redefinition itself (before you've even typed the
second `(greet)`), and then again — correctly — when you do. This is an
inherent consequence of full replay, not a bug: the transcript genuinely did
just re-run with new semantics.

### `defvar` vs `defparameter`

`defvar` and `defparameter` (see [macros.md](macros.md)) expand identically
outside the REPL — both are plain `var` aliases. Their Common Lisp
distinction only becomes observable when the same name is entered a second
time, which is exactly the REPL's redefinition case above:

- **`defvar`** is idempotent: re-entering `(defvar x …)` for a name that's
  already bound is a no-op — the existing value survives, and the session
  isn't even recompiled.
- **`defparameter`** (and plain `var`) always reset the name to the new
  value, like any other redefinition.

```
lfn> (defvar x 1)
lfn> (defvar x 999)
lfn> x
1
lfn> (defparameter x 999)
lfn> x
999
```

## Multi-line input

If a form is left open at the end of a line (an unterminated list, string,
`|...|` symbol, block comment, or pragma clause), `lfn repl` keeps reading
further lines — with a `  ... ` continuation prompt — until it closes. A
blank line or a comment-only line is ignored and re-prompts from scratch,
rather than being treated as a continuation.

An input may contain more than one top-level form (e.g. two forms typed on
one line); such an entry is never wrapped for value printing, even if its
last form would otherwise be printable — it's evaluated purely for effect.

## REPL commands

A line whose first non-whitespace character is `:` is read as a command,
not LFN source (mid-form, `:name` is still an ordinary `block`/`break-from`
label, as elsewhere in LFN — this only applies to the very first line of a
fresh entry):

| Command | Effect |
|---|---|
| `:help` | List these commands. |
| `:quit`, `:exit` | Exit the REPL (so does Ctrl-D / EOF). |
| `:transcript` | Print the accumulated session source. |
| `:reset` | Clear the session and start over. |

## Diagnostics

Every diagnostic — reader errors, macro-expansion errors, `nim` type errors,
undeclared-identifier errors — is reported against `<repl:N>`, the `N`-th
transcript entry, at the line/column *within that entry*, never against the
generated `session.lfn` or `wrapper.nim` Nim sees on disk:

```
lfn> (var z (+ 1 "bad"))
<repl:1>(1, 9) Error: type mismatch
...
```

A secondary Nim "instantiation from here" trace line pointing at the
`lfnReplShow`/`lfnStmt` wrapper machinery itself (rather than at your input)
may still show the raw temp-file path — that's an inherent side effect of
those being real generated wrapper lines, not your source.

## Known limitations

- **No incremental compilation.** Every input triggers a full `nim c` over
  the whole transcript so far; a long session gets slower per input. A
  shared `nim` compiler cache directory keeps this from re-compiling
  `lfn/compiler` and the preamble from scratch each launch, but the
  session's own growing source is always compiled whole. Incremental
  strategies are tracked as a follow-up.
- **Output diffing is a simple string-prefix check.** If a redefinition (or
  any other change) makes an *earlier* part of the transcript produce
  different output than last time, the new run's output no longer starts
  with the previous run's, and the whole thing is printed again rather than
  just the "new" part — see the redefinition note above.
- **A preloaded file is one entry, not one per form.** `lfn repl file.lfn`
  adds the whole file as a single transcript entry; a later individual
  input can still redefine any name it declares, but you can't
  individually redefine one declaration from inside the preloaded file
  without also re-adding the rest of it.
