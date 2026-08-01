## Macro definitions and the environment (`MacroEnv`) they're registered in,
## shared by the macro expander (`expand.nim`) — parameter shapes for
## `&optional`/`&rest`/`&body`/`&key`, gensym/hygiene id allocation, and the
## import-cycle tracking used while inlining `.nfl` files.

import std/options
import std/sets
import std/tables

import ./diagnostics
import ./syntax

type
  MacroOptParam* = object   ## An `&optional` macro parameter.
    name*: string
    default*: Option[Syntax]

  MacroKeyParam* = object   ## A `&key` macro parameter.
    keyword*: string        # matched against :keyword at call site (without leading :)
    local*: string          # local binding name in macro body
    default*: Option[Syntax]

  MacroDef* = object        ## A single macro's parameter shape and body.
    name*: string
    params*: seq[Syntax]           # required positional params — a bare
                                    # symbol, or (#47) a destructuring
                                    # pattern (`sxVector`) matched against
                                    # the argument's syntax form
    optParams*: seq[MacroOptParam] # &optional params
    restParam*: string             # &rest or dotted-pair rest (empty if none)
    bodyParam*: string             # &body (empty if none)
    keyParams*: seq[MacroKeyParam] # &key params
    body*: seq[Syntax]
    span*: Span

  MacroEnv* = ref object   ## Expansion-time state: registered macros, gensym
                           ## counter, and import-cycle tracking.
    macros*: Table[string, MacroDef]
    gensymCounter*: int
    includedFiles*: HashSet[string]  ## resolved paths of .nfl files already
                                      ## inlined (#10) — a second `(import
                                      ## ...)` of the same file is a no-op so
                                      ## diamond imports don't duplicate decls
    includingStack*: seq[string]     ## resolved paths currently being
                                      ## inlined, in inclusion order — used to
                                      ## detect and report circular imports

proc newMacroEnv*(): MacroEnv =
  ## Creates an empty `MacroEnv` ready for expansion.
  MacroEnv(macros: initTable[string, MacroDef](), gensymCounter: 0,
           includedFiles: initHashSet[string](), includingStack: @[])

proc hasMacro*(env: MacroEnv; name: string): bool =
  ## True if a macro named `name` is registered in `env`.
  env.macros.hasKey(name)

proc getMacro*(env: MacroEnv; name: string): MacroDef =
  ## Looks up the macro named `name`; raises `KeyError` if absent — callers
  ## should check `hasMacro` first.
  env.macros[name]

proc defineMacro*(env: MacroEnv; def: MacroDef) =
  ## Registers `def` in `env`; raises `CompilerError` if a macro with the
  ## same name is already defined.
  if env.macros.hasKey(def.name):
    raiseCompilerError(def.span, "duplicate macro definition: " & def.name)
  env.macros[def.name] = def

proc gensym*(env: MacroEnv; hint: string; span: Span): Syntax =
  ## Allocates a fresh, guaranteed-unique symbol prefixed with `hint` (or
  ## `"g"` if empty), for use in macro-generated code.
  inc env.gensymCounter
  let prefix = if hint.len == 0: "g" else: hint
  newSymbol(prefix & "__gensym" & $env.gensymCounter, span, env.gensymCounter)

proc newHygienicId*(env: MacroEnv): int =
  ## Allocates a fresh hygieneId for the automatic template-hygiene rename
  ## pass (#11) — shares `gensymCounter` with explicit `gensym` calls so
  ## both mechanisms draw from the same id space; backend.nim's
  ## `hygienicSymbols` table treats an id as opaque regardless of which
  ## produced it.
  inc env.gensymCounter
  env.gensymCounter
