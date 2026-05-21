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

  CompilerError* = object of CatchableError
    diagnostic*: Diagnostic

proc `$`*(diagnostic: Diagnostic): string =
  let file = if diagnostic.span.file.len == 0: "<input>" else: diagnostic.span.file
  fmt"{file}:{diagnostic.span.line}:{diagnostic.span.col}: {diagnostic.message}"

proc error*(span: Span; message: string): Diagnostic =
  Diagnostic(severity: dsError, span: span, message: message)

proc raiseReaderError*(span: Span; message: string) {.noreturn.} =
  let diagnostic = error(span, message)
  var err = newException(ReaderError, $diagnostic)
  err.diagnostic = diagnostic
  raise err

proc raiseCompilerError*(span: Span; message: string) {.noreturn.} =
  let diagnostic = error(span, message)
  var err = newException(CompilerError, $diagnostic)
  err.diagnostic = diagnostic
  raise err
