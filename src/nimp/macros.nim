import std/options
import std/tables

import ./diagnostics
import ./syntax

type
  MacroOptParam* = object
    name*: string
    default*: Option[Syntax]

  MacroKeyParam* = object
    keyword*: string        # matched against :keyword at call site (without leading :)
    local*: string          # local binding name in macro body
    default*: Option[Syntax]

  MacroDef* = object
    name*: string
    params*: seq[string]           # required positional params
    optParams*: seq[MacroOptParam] # &optional params
    restParam*: string             # &rest or dotted-pair rest (empty if none)
    bodyParam*: string             # &body (empty if none)
    keyParams*: seq[MacroKeyParam] # &key params
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
