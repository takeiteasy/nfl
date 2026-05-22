# Nimp

Nimp is a Lisp-inspired processor for Nim. Nimp code is written in s-expressions and will compile to Nim AST through Nim macros.

The project was formerly named `nil` ("Nim Implementation of Lisp"), but v2 is renamed because `nil` is a Nim keyword and is awkward as a package/module name.

## Usage

Compile, run, or check `.nimp` files with the Nimp CLI:

```sh
nimp check examples/simple.nimp
nimp run examples/simple.nimp
nimp compile examples/simple.nimp
```

Do not pass `.nimp` files directly to `nim c`. Nim will parse them as Nim source before Nimp can run. For embedding from Nim, use `nimpModule(staticRead("file.nimp"))` from `nimp/compiler`.

## Interop

Nimp imports Nim modules directly and calls Nim procs without a wrapper layer. See `examples/interop.nimp` for a small program that uses `std/strutils`, `std/os`, and `std/math`, defines Nim-callable procs with typed parameters and return annotations, uses a typed local binding with `((name Type) value)`, and calls escaped Nim symbols such as `|[]|`.

## LICENSE
```
Nimp

Copyright (C) 2025 George Watson

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
```
