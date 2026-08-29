## The `lfn repl` session engine (#14) — an interactive read/expand/compile/
## run loop backed by an actual `nim c` per accepted input, rather than any
## kind of interpreter. See `man/repl.md` for the user-facing model this
## implements: full-session replay (every accepted input is kept in a
## transcript and the whole transcript is recompiled and re-run on each new
## input, with only the newly produced output printed), name-keyed
## redefinition (a new `var`/`proc`/`type`/`defmacro`/… replaces an earlier
## one of the same name in place), and CL-style `defvar` (idempotent: a
## re-entered `defvar` for an already-bound name is skipped outright).

import std/os
import std/osproc
import std/streams
import std/strutils

import ./diagnostics
import ./expand
import ./macros
import ./reader
import ./stdlib
import ./synforms
import ./syntax

type
  EntryKind = enum
    ekOrdinary   ## anything else — replaces an earlier same-named entry.
    ekDefvar     ## a raw `(defvar name …)` form — see `tryAddInput`.
    ekMacroDef   ## a raw `(defmacro …)`/`(defmacro-proc …)` form — its own
                 ## name comes from the form directly, not `declaredNames`,
                 ## since a consumed macro definition never appears in the
                 ## *expanded* forms `declaredNames` would otherwise walk.

  ReplEntry = object
    source: string       ## Raw text as typed/loaded, verbatim, no trailing
                          ## newline.
    rawForms: seq[Syntax] ## `readAll(source, …)` — replayed through a fresh
                          ## `MacroEnv` on every subsequent input so macro
                          ## definitions accumulate the same way a real
                          ## `lfn check` over the whole transcript would.
    names: seq[string]   ## Every name this entry declares/redefines —
                          ## `declaredNames` on its expanded forms, or (for
                          ## `ekMacroDef`) the macro's own name.
    printable: bool      ## Wrap in `lfnReplShow` when embedding into
                          ## `session.lfn` — true only when the entry
                          ## expanded to exactly one non-declaration form.
    kind: EntryKind

  EntryOffset = object
    startLine, endLine: int  ## 1-based line range in `session.lfn` this
                              ## entry's own text occupies (its `lfnReplShow`
                              ## wrapper lines, if any, are excluded).
    entryIdx: int             ## Index into the transcript being compiled.

  ReplSession* = object
    entries: seq[ReplEntry]
    dir: string           ## One temp dir for the whole session — holds
                           ## `session.lfn`, `wrapper.nim`, and the compiled
                           ## binary; reused across inputs (unlike
                           ## `cli.nim`'s per-call `tempBuildDir`) so a
                           ## shared nimcache actually speeds up successive
                           ## compiles.
    importDir: string     ## `getCurrentDir()` at session start — passed as
                           ## `expandModule`'s `currentDir` so a relative
                           ## `(import ./helpers.lfn)` resolves against
                           ## where `lfn repl` was launched, not against the
                           ## session's temp dir (see module doc).
    autoloadCore: bool
    lastOutput: string     ## Captured stdout+stderr of the last successful
                           ## run — a fresh run's output is diffed against
                           ## this so only the new suffix gets printed.

  AddOutcome* = enum
    aoAdded        ## Compiled, ran, and committed; `message` is any new
                   ## program output to print (may be empty).
    aoSkippedDefvar ## A `defvar` re-entered for an already-bound name —
                    ## intentionally a no-op; `message` is empty.
    aoBlank        ## The input was empty / comments only; nothing to do.
    aoError        ## Reader, macro-expansion, compile, or runtime error;
                   ## `message` is the diagnostic to show. The session is
                   ## unchanged (transactional — see the module doc).

  AddResult* = object
    outcome*: AddOutcome
    message*: string

const replFileLabel = "<repl>"
  ## The label used for reader/macro-expansion errors, which run against an
  ## entry's own isolated text (see `tryAddInput`) — so its line numbers are
  ## already entry-relative and need no rewriting, unlike the Nim compiler's
  ## own diagnostics, which run against the concatenated `session.lfn` on
  ## disk and are rewritten by `rewriteDiagnostics`.

proc initSession*(autoloadCore = true): ReplSession =
  ## Starts a new session: one temp dir for its `session.lfn`/`wrapper.nim`/
  ## binary (removed by `closeSession`), plus a *stable, shared* nimcache
  ## dir reused across every `lfn repl` process (not per-session) so
  ## `lfn/compiler` and the preamble aren't recompiled from scratch on every
  ## launch — only `session.lfn`'s own accumulated content forces a
  ## recompile each input.
  result.dir = getTempDir() / ("lfn-repl-" & $getCurrentProcessId())
  createDir(result.dir)
  # `expandFilename` resolves symlinks (realpath) — needed because on macOS
  # `getTempDir()` returns a `/var/...` path while the Nim compiler reports
  # diagnostics against the realpath'd `/private/var/...` it actually opened,
  # so `rewriteDiagnostics`'s plain substring match on `sessionPath` would
  # otherwise silently fail to match at the start of the path (worse: it can
  # match *mid-string*, e.g. right after a "/private" prefix, producing a
  # mangled half-rewritten line instead of either a clean rewrite or a clean
  # pass-through).
  result.dir = expandFilename(result.dir)
  result.importDir = getCurrentDir()
  result.autoloadCore = autoloadCore

proc closeSession*(session: ReplSession) =
  ## Removes the session's per-session temp dir. Never removes the shared
  ## nimcache dir (`sharedNimcacheDir`) — that's meant to outlive any one
  ## session.
  if session.dir.len > 0 and dirExists(session.dir):
    removeDir(session.dir)

proc sharedNimcacheDir(): string =
  getTempDir() / "lfn-repl-cache"

proc transcriptText*(session: ReplSession): string =
  ## The whole accepted session, as LFN source — what `:transcript` prints.
  for e in session.entries:
    result.add e.source
    result.add "\n"

# ---------------------------------------------------------------------------
# Reading input a line at a time, deciding when a form is complete
# ---------------------------------------------------------------------------

type ReadOutcome* = enum
  ## What `readEntry` produced for one prompt/continuation cycle.
  roForm     ## `source`/`forms` hold one or more complete top-level forms.
  roBlank    ## Input was empty or comments-only; nothing to evaluate.
  roError    ## A genuine (non-`incomplete`) reader error; `message` is set.
  roEof      ## End of input (Ctrl-D) with no pending partial entry.

type ReadResult* = object
  ## The result of `readEntry`. For a `:command` line (`roForm` with
  ## `forms.len == 0`), `source` is the trimmed command text; otherwise
  ## `source` is the raw, possibly multi-line, entry text.
  outcome*: ReadOutcome
  source*: string
  forms*: seq[Syntax]
  message*: string

proc readEntry*(readLine: proc (prompt: string; line: var string): bool {.closure.};
                 prompt, continuePrompt: string): ReadResult =
  ## Reads lines (via `readLine` — `std/rdstdin`'s `readLineFromStdin` in
  ## `cli.nim`, a plain stub in tests) until they form a complete top-level
  ## input, prompting `prompt` for the first line and `continuePrompt` for
  ## every line after. Incompleteness is decided by the reader itself
  ## (`ReaderError.incomplete`, `diagnostics.nim`) rather than by counting
  ## delimiters here — that would duplicate string/`|sym|`/`#| |#` lexing.
  var buffer = ""
  var first = true
  var line: string
  while true:
    let ok = readLine((if first: prompt else: continuePrompt), line)
    if not ok:
      if buffer.len == 0:
        return ReadResult(outcome: roEof)
      return ReadResult(outcome: roError,
        message: "lfn repl: unexpected end of input (unterminated form)")
    first = false
    let trimmed = line.strip()
    if buffer.len == 0 and trimmed.len > 0 and trimmed[0] == ':':
      # A `:command` is only recognized as the very first line of a fresh
      # entry — mid-entry, `:name` is a `block`/`break-from` label symbol
      # (`isBlockLabel`, syntax.nim), not a REPL command.
      return ReadResult(outcome: roForm, source: trimmed)
    if buffer.len > 0:
      buffer.add "\n"
    buffer.add line
    try:
      let forms = readAll(buffer, replFileLabel)
      if forms.len == 0:
        # Blank or comments-only so far — not "incomplete" (the reader
        # raised nothing), just nothing to evaluate yet. Reset and wait for
        # a fresh entry rather than treating this as a continuation.
        return ReadResult(outcome: roBlank)
      return ReadResult(outcome: roForm, source: buffer, forms: forms)
    except ReaderError as err:
      if err.incomplete:
        continue
      return ReadResult(outcome: roError, message: $err.diagnostic)

# ---------------------------------------------------------------------------
# Classification: decl vs. printable expression, declared/redefined names
# ---------------------------------------------------------------------------

proc rawEntryKind(rawForms: seq[Syntax]): tuple[kind: EntryKind, macroName: string] =
  ## Detects `defvar`/`defmacro`/`defmacro-proc` on the entry's own *raw*
  ## (pre-expansion) head symbol — after expansion `(defvar x 0)` and
  ## `(var x 0)` are indistinguishable, and a `defmacro` never appears in
  ## the expanded forms at all (expansion consumes it), so neither can be
  ## detected any other way.
  if rawForms.len == 1 and rawForms[0].kind == sxList and
     rawForms[0].items.len > 1 and rawForms[0].items[0].kind == sxSymbol:
    let head = rawForms[0].items[0].sym
    let nameSx = rawForms[0].items[1]
    if nameSx.kind == sxSymbol:
      if head == "defvar":
        return (ekDefvar, "")
      if head in ["defmacro", "defmacro-proc"]:
        return (ekMacroDef, nameSx.sym)
  (ekOrdinary, "")

proc disjoint(a, b: seq[string]): bool =
  for x in a:
    if x in b:
      return false
  true

proc hasAnyName(session: ReplSession; names: seq[string]): bool =
  for e in session.entries:
    if not disjoint(e.names, names):
      return true
  false

proc spliceRedefinition(entries: seq[ReplEntry]; newEntry: ReplEntry): seq[ReplEntry] =
  ## Drops every earlier entry whose declared/macro names collide with
  ## `newEntry`'s, then inserts `newEntry` at the position of the *earliest*
  ## surviving collision (rather than appending at the end) — so a
  ## redefinition lands before any later entry that uses it. Appending
  ## unconditionally would, for a macro redefined after an entry that calls
  ## it, put the new `defmacro` textually after its own call site once
  ## dropped-and-appended, which fails to expand at all: LFN requires a
  ## macro to be defined before use within a module, and the whole
  ## transcript is re-expanded as one module on every input (see the module
  ## doc's replay model). An ordinary expression entry never declares a
  ## name, so it's always disjoint from every redefinition and always ends
  ## up appended at the end, in the order it was typed.
  var insertAt = -1
  for e in entries:
    if disjoint(e.names, newEntry.names):
      result.add e
    elif insertAt < 0:
      insertAt = result.len
  if insertAt < 0:
    result.add newEntry
  else:
    result.insert(newEntry, insertAt)

proc classify(session: ReplSession; rawForms: seq[Syntax]; kind: EntryKind;
              macroName: string): tuple[ok: bool; names: seq[string];
              printable: bool; message: string] =
  ## Expands the *committed* transcript, in order, through one `MacroEnv`,
  ## then expands `rawForms` against that same env — exactly the sequential
  ## `expandModule` threading `compiler.nim`'s `expandSource` uses for a
  ## whole file, just split across entries so the new entry's own expanded
  ## forms can be inspected directly (`expandSource` itself can't be reused
  ## here: it returns one flat, already-merged `seq[Syntax]` for its whole
  ## input, and a consumed `defmacro` never reappears in that output, so
  ## there'd be no way to tell where the new entry's own contribution
  ## starts). `session.importDir` (not the session's temp dir) is passed as
  ## `currentDir` so a relative `(import ./helpers.lfn)` resolves against
  ## where `lfn repl` was launched.
  var env = newMacroEnv()
  try:
    if session.autoloadCore:
      discard expandModule(readAll(coreSource, "std/core.lfn"), env)
    for e in session.entries:
      # Skip an earlier entry that the new one is about to replace
      # (`spliceRedefinition` uses this same `disjoint(e.names, …)` test).
      # This matters specifically for a `defmacro`/`defmacro-proc`
      # redefinition: replaying the *old* definition here would make
      # `defineMacro`/`defineMacroProc` (macros.nim) raise its own
      # "duplicate macro definition" error against the *new* one below,
      # even though the old one is destined to be dropped. `var`/`proc`/
      # `type`/… redefinitions don't hit this — nothing at expansion time
      # tracks their names, only `MacroEnv` does, for macros.
      if not disjoint(e.names, (if kind == ekMacroDef: @[macroName] else: @[])):
        continue
      discard expandModule(e.rawForms, env, session.importDir, replFileLabel)
    let newForms = expandModule(rawForms, env, session.importDir, replFileLabel)
    var names: seq[string] = @[]
    if kind == ekMacroDef:
      names.add macroName
    else:
      for f in newForms:
        names.add declaredNames(f)
    let printable = newForms.len == 1 and not isDeclForm(newForms[0])
    (true, names, printable, "")
  except ReaderError as err:
    (false, @[], false, $err.diagnostic)
  except CompilerError as err:
    (false, @[], false, $err.diagnostic)

# ---------------------------------------------------------------------------
# Emitting session.lfn / wrapper.nim and mapping Nim diagnostics back
# ---------------------------------------------------------------------------

proc entryLineCount(source: string): int =
  source.count('\n') + 1

proc buildSessionText(entries: seq[ReplEntry]): tuple[text: string; offsets: seq[EntryOffset]] =
  var text = ""
  var line = 1
  var offsets: seq[EntryOffset] = @[]
  for idx, e in entries:
    let lines = entryLineCount(e.source)
    if e.printable:
      text.add "(lfnReplShow\n"
      inc line
      offsets.add EntryOffset(startLine: line, endLine: line + lines - 1, entryIdx: idx)
      text.add e.source
      text.add "\n"
      line += lines
      text.add ")\n"
      inc line
    else:
      offsets.add EntryOffset(startLine: line, endLine: line + lines - 1, entryIdx: idx)
      text.add e.source
      text.add "\n"
      line += lines
  (text, offsets)

proc entryForLine(offsets: seq[EntryOffset]; line: int): tuple[ok: bool; entryIdx, rel: int] =
  for o in offsets:
    if line >= o.startLine and line <= o.endLine:
      return (true, o.entryIdx, line - o.startLine + 1)
  (false, 0, 0)

proc rewriteDiagnostics(output, sessionPath: string; offsets: seq[EntryOffset]): string =
  ## Rewrites every `sessionPath:line:col` (LFN-style, `diagnostics.nim`'s
  ## `$Diagnostic`) or `sessionPath(line, col)` (Nim-style, `backend.nim`'s
  ## `attachLineInfo`) occurrence in `output` to `<repl:N>:relLine:col` /
  ## `<repl:N>(relLine, col)`, mapping the absolute `session.lfn` line back
  ## to the entry it came from (1-based, `N`) and that entry's own relative
  ## line. Everything else passes through unchanged.
  result = newStringOfCap(output.len)
  var i = 0
  while i < output.len:
    if output.continuesWith(sessionPath, i):
      let after = i + sessionPath.len
      if after < output.len and output[after] == ':':
        var j = after + 1
        var lineStr = ""
        while j < output.len and output[j].isDigit: lineStr.add output[j]; inc j
        if lineStr.len > 0 and j < output.len and output[j] == ':':
          var k = j + 1
          var colStr = ""
          while k < output.len and output[k].isDigit: colStr.add output[k]; inc k
          if colStr.len > 0:
            let (ok, idx, rel) = entryForLine(offsets, parseInt(lineStr))
            if ok:
              result.add "<repl:" & $(idx + 1) & ">:" & $rel & ":" & colStr
              i = k
              continue
      if after < output.len and output[after] == '(':
        var j = after + 1
        var lineStr = ""
        while j < output.len and output[j].isDigit: lineStr.add output[j]; inc j
        if lineStr.len > 0 and j < output.len and output[j] == ',':
          var k = j + 1
          while k < output.len and output[k] == ' ': inc k
          var colStr = ""
          while k < output.len and output[k].isDigit: colStr.add output[k]; inc k
          if colStr.len > 0 and k < output.len and output[k] == ')':
            let (ok, idx, rel) = entryForLine(offsets, parseInt(lineStr))
            if ok:
              result.add "<repl:" & $(idx + 1) & ">(" & $rel & ", " & colStr & ")"
              i = k + 1
              continue
    result.add output[i]
    inc i

proc nimStringLit(s: string): string =
  ## Mirrors `cli.nim`'s private helper of the same name — duplicated
  ## rather than imported since `cli.nim` is the one importing `repl.nim`
  ## (routing the `repl` command into it), not the reverse.
  result = "\""
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else: result.add c
  result.add '"'

proc repoSrcPath(): string =
  ## Mirrors `cli.nim`'s helper of the same name — see `nimStringLit`.
  let candidate = getCurrentDir() / "src"
  if dirExists(candidate / "lfn"):
    absolutePath(candidate)
  else:
    ""

proc runCaptured(exe: string; args: seq[string]): tuple[output: string; exitCode: int; spawned: bool] =
  let full = if exe.contains(DirSep) or exe.contains(AltSep): exe else: findExe(exe)
  if full.len == 0:
    return ("", 1, false)
  let process = startProcess(full, args = args, options = {poStdErrToStdOut})
  result.output = process.outputStream().readAll()
  result.exitCode = process.waitForExit()
  result.spawned = true
  process.close()

# ---------------------------------------------------------------------------
# Adding one input to the session
# ---------------------------------------------------------------------------

proc tryAddInput*(session: var ReplSession; source: string; forms: seq[Syntax]): AddResult =
  ## Attempts to add one already-read entry (`readEntry`'s `source`/`forms`)
  ## to the session. On success (`aoAdded`) the whole candidate transcript
  ## has been compiled and run, and the session is updated to match; on any
  ## failure the session is left exactly as it was (transactional — see the
  ## module doc), and `message` carries a diagnostic already rewritten to
  ## point at `<repl:N>` REPL input, never at generated Nim or the on-disk
  ## `session.lfn`.
  let (kind, macroName) = rawEntryKind(forms)
  let classified = classify(session, forms, kind, macroName)
  if not classified.ok:
    return AddResult(outcome: aoError, message: classified.message)

  if kind == ekDefvar and classified.names.len > 0 and session.hasAnyName(classified.names):
    return AddResult(outcome: aoSkippedDefvar)

  let newEntry = ReplEntry(source: source, rawForms: forms, names: classified.names,
    printable: classified.printable, kind: kind)
  let candidate = spliceRedefinition(session.entries, newEntry)

  let (sessionText, offsets) = buildSessionText(candidate)
  let sessionPath = session.dir / "session.lfn"
  # The wrapper's own name, not just its directory, must be per-session:
  # `--nimcache:` (below) is a *shared* dir across every concurrent
  # `lfn repl` process (that's the point — it's what makes `lfn/compiler`
  # and the preamble not recompile on every launch), and Nim's nimcache
  # object-file naming keys off a module's basename. Two sessions both
  # naming their wrapper `wrapper.nim` would race to write (and could pick
  # up) each other's `wrapper.nim.o` in that shared cache.
  let wrapperPath = session.dir / ("wrapper" & $getCurrentProcessId() & ".nim")
  let exePath = session.dir / ("session" & ExeExt)
  writeFile(sessionPath, sessionText)
  writeFile(wrapperPath,
    "import lfn/compiler\n" &
    "lfnModule(" & nimStringLit(sessionText) & ", " & nimStringLit(sessionPath) &
    ", autoloadCore = " & $session.autoloadCore &
    ", importDir = " & nimStringLit(session.importDir) & ")\n")

  # Full recompile of the whole transcript on every input, O(session size) —
  # correct (it's what "full replay" means) but a long session gets slower
  # per input; a shared nimcache (below) only avoids recompiling
  # `lfn/compiler` and the preamble each launch, not the session's own
  # growing source. Incremental compilation strategies are tracked as a
  # follow-up (#92).
  var compileArgs = @["c", "--hints:off", "--nimcache:" & sharedNimcacheDir(), "--out:" & exePath]
  let srcPath = repoSrcPath()
  if srcPath.len > 0:
    compileArgs.add "--path:" & srcPath
  compileArgs.add wrapperPath
  let compiled = runCaptured("nim", compileArgs)
  if not compiled.spawned:
    return AddResult(outcome: aoError, message: "lfn repl: nim executable not found in PATH")
  if compiled.exitCode != 0:
    return AddResult(outcome: aoError,
      message: rewriteDiagnostics(compiled.output, sessionPath, offsets))

  let ran = runCaptured(exePath, @[])
  if not ran.spawned:
    return AddResult(outcome: aoError, message: "lfn repl: failed to run compiled session")
  let rewrittenRun = rewriteDiagnostics(ran.output, sessionPath, offsets)
  if ran.exitCode != 0:
    return AddResult(outcome: aoError, message: rewrittenRun)

  session.entries = candidate
  # A plain string-prefix check: if a redefinition (or anything else)
  # changes what an *earlier* entry now produces, the new output no longer
  # starts with the previous run's, and the whole thing is reprinted rather
  # than just the genuinely new part (see man/repl.md's "Known
  # limitations"). Tracked as a follow-up (#93); a real diff, or capturing
  # each entry's own output separately instead of the whole process's
  # stdout, would fix this properly.
  let newSuffix =
    if rewrittenRun.startsWith(session.lastOutput): rewrittenRun[session.lastOutput.len .. ^1]
    else: rewrittenRun
  session.lastOutput = rewrittenRun
  AddResult(outcome: aoAdded, message: newSuffix)
