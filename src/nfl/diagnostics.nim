import std/strformat

import ./syntax

type
  DiagnosticSeverity* = enum
    dsError

  Diagnostic* = object
    severity*: DiagnosticSeverity
    span*: Span
    message*: string

  ReaderError* = object of CatchableError
    diagnostic*: Diagnostic
    incomplete*: bool
      ## True when the error is purely "ran out of input while inside an
      ## open form" (unterminated list/vector/string/escaped symbol/block
      ## comment/pragma, or EOF while `readForm` still expects a form) —
      ## as opposed to a form that is syntactically finished but wrong. The
      ## REPL (`repl.nim`) uses this to distinguish "keep reading more
      ## lines" from "this input is actually broken."

  CompilerError* = object of CatchableError
    diagnostic*: Diagnostic

proc `$`*(diagnostic: Diagnostic): string =
  let file = if diagnostic.span.file.len == 0: "<input>" else: diagnostic.span.file
  fmt"{file}:{diagnostic.span.line}:{diagnostic.span.col}: {diagnostic.message}"

proc error*(span: Span; message: string): Diagnostic =
  Diagnostic(severity: dsError, span: span, message: message)

proc raiseReaderError*(span: Span; message: string; incomplete = false) {.noreturn.} =
  let diagnostic = error(span, message)
  var err = newException(ReaderError, $diagnostic)
  err.diagnostic = diagnostic
  err.incomplete = incomplete
  raise err

proc raiseCompilerError*(span: Span; message: string) {.noreturn.} =
  let diagnostic = error(span, message)
  var err = newException(CompilerError, $diagnostic)
  err.diagnostic = diagnostic
  raise err
