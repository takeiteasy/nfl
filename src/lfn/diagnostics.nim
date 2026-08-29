## Shared diagnostic type and error-raising helpers used across the reader,
## expander, lowerer, and backend, so all LFN-level errors carry a `Span`
## and format consistently regardless of which pass raised them.

import std/strformat

import ./syntax

type
  DiagnosticSeverity* = enum
    dsError

  Diagnostic* = object
    ## A single reported problem: severity, source location, and message.
    severity*: DiagnosticSeverity
    span*: Span
    message*: string

  ReaderError* = object of CatchableError
    ## Raised by `reader.nim` for a syntactically malformed source form.
    diagnostic*: Diagnostic
    incomplete*: bool
      ## True when the error is purely "ran out of input while inside an
      ## open form" (unterminated list/vector/string/escaped symbol/block
      ## comment/pragma, or EOF while `readForm` still expects a form) —
      ## as opposed to a form that is syntactically finished but wrong. The
      ## REPL (`repl.nim`) uses this to distinguish "keep reading more
      ## lines" from "this input is actually broken."

  CompilerError* = object of CatchableError
    ## Raised by the expander, lowerer, or backend for a form that reads
    ## fine but is invalid once macro-expanded (e.g. wrong arity, a
    ## circular import, an unresolvable reference).
    diagnostic*: Diagnostic

proc `$`*(diagnostic: Diagnostic): string =
  ## Formats as `file:line:col: message`, using `<input>` for the file
  ## when `span.file` is empty (e.g. REPL input not backed by a real file).
  let file = if diagnostic.span.file.len == 0: "<input>" else: diagnostic.span.file
  fmt"{file}:{diagnostic.span.line}:{diagnostic.span.col}: {diagnostic.message}"

proc error*(span: Span; message: string): Diagnostic =
  ## Builds a `dsError`-severity diagnostic at `span`.
  Diagnostic(severity: dsError, span: span, message: message)

proc raiseReaderError*(span: Span; message: string; incomplete = false) {.noreturn.} =
  ## Raises a `ReaderError` at `span`. Set `incomplete` when the failure
  ## is only "ran out of input", not a malformed form (see `ReaderError`).
  let diagnostic = error(span, message)
  var err = newException(ReaderError, $diagnostic)
  err.diagnostic = diagnostic
  err.incomplete = incomplete
  raise err

proc raiseCompilerError*(span: Span; message: string) {.noreturn.} =
  ## Raises a `CompilerError` at `span`.
  let diagnostic = error(span, message)
  var err = newException(CompilerError, $diagnostic)
  err.diagnostic = diagnostic
  raise err
