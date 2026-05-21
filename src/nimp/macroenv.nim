import std/tables

import ./diagnostics
import ./syntax

type
  MacroDef* = object
    name*: string
    params*: seq[string]
    restParam*: string
    body*: seq[Syntax]
    span*: Span

  MacroEnv* = ref object
    macros*: Table[string, MacroDef]
    gensymCounter*: int

proc newMacroEnv*(): MacroEnv =
  MacroEnv(macros: initTable[string, MacroDef](), gensymCounter: 0)

proc hasMacro*(env: MacroEnv; name: string): bool =
  env.macros.hasKey(name)

proc getMacro*(env: MacroEnv; name: string): MacroDef =
  env.macros[name]

proc defineMacro*(env: MacroEnv; def: MacroDef) =
  if env.macros.hasKey(def.name):
    raiseCompilerError(def.span, "duplicate macro definition: " & def.name)
  env.macros[def.name] = def

proc gensym*(env: MacroEnv; hint: string; span: Span): Syntax =
  inc env.gensymCounter
  let prefix = if hint.len == 0: "g" else: hint
  newSymbol(prefix & "__gensym" & $env.gensymCounter, span, env.gensymCounter)
