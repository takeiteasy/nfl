# Lisp Flavoured Nim

**LFN** is a Lisp dialect that compiles to Nim. It processes s-expressions into Nim AST via macros, giving you Lisp syntax with full access to the Nim ecosystem and type system. Inspired by [Hylang](https://hylang.org/). Docs are hosted [here](https://takeiteasy.github.io/lfn/), and release builds are [here](https://github.com/takeiteasy/lfn/tags).

## Quick example

```lisp
(import std/strutils)

(proc greet ((name string)) (: string)
  (toUpperAscii name))

(echo (greet "lfn"))
```

Compile and run:

```sh
lfn compile hello.lfn && ./hello
# LFN
```

## Building

Requires **Nim >= 2.2.4**.

```sh
nimble build
```

This produces a `bin/lfn` binary. To run it against a file:

```sh
lfn check   file.lfn   # type-check only
lfn compile file.lfn   # compile to binary
```

## Documentation

- [Getting Started](man/getting-started.md) — installation, first program, core concepts
- [Language Reference](man/language-reference.md) — all language forms
- [Macro System](man/macros.md) — writing and using macros
- [Nim Interop](man/nim-interop.md) — calling Nim stdlib, dot notation, exports, pragmas
- [CLI Reference](man/cli.md) — every `lfn` subcommand and flag
- [The REPL](man/repl.md) — `lfn repl`'s interactive session model
- [Package Layout](man/package-layout.md) — organizing application and library projects
- API documentation is generated from source via `nimble docs` (see [man/api.md](man/api.md)) into `docs/`, served via GitHub Pages
- [Changelog](CHANGELOG.md) — notable changes per release

## Examples

The `examples/` directory contains runnable `.lfn` programs covering types, loops, error handling, macros, pragmas, and Nim interop.

## License

```
LFN — Lisp Flavoured Nim
Copyright (C) 2025 George Watson

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
```
