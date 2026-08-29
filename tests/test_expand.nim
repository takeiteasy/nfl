import std/os
import std/strutils
import std/unittest

import lfn/compiler
import lfn/diagnostics
import lfn/expand
import lfn/macros
import lfn/reader
import lfn/syntax

proc expandOne(source: string): Syntax =
  let env = newMacroEnv()
  let forms = expandModule(readAll(source, "expand-test.lfn"), env)
  check forms.len == 1
  forms[0]

proc expectExpandError(source, messagePart: string) =
  try:
    discard expandOne(source)
    fail()
  except CompilerError as err:
    check err.diagnostic.span.file == "expand-test.lfn"
    check err.diagnostic.message.contains(messagePart)

proc expectCoreExpandError(source, messagePart: string) =
  ## Like `expectExpandError`, but auto-loads the preamble (`expandSource`'s
  ## default) — needed for anything exercising a preamble macro, like
  ## `defclass`, that `expandOne`'s bare `newMacroEnv()` never registers.
  try:
    discard expandSource(source, "expand-test.lfn")
    fail()
  except CompilerError as err:
    check err.diagnostic.message.contains(messagePart)

proc renderForms(forms: seq[Syntax]): string =
  for form in forms:
    if result.len > 0:
      result.add "\n"
    result.add form.renderSyntax()

suite "macro expansion":
  test "expands fixed parameter macro":
    let sx = expandOne """
(defmacro id (x) x)
(id (+ 1 2))
"""
    check sx.renderSyntax() == "(+ 1 2)"

  test "expands rest parameter macro with quasiquote splicing":
    let sx = expandOne """
(defmacro when (test . body)
  `(if ,test (block ,@body) nil))
(when true (echo "yes") 3)
"""
    check sx.renderSyntax() == "(if true (block (echo \"yes\") 3) nil)"

  test "expands a destructuring pattern in a required macro parameter (#47)":
    let sx = expandOne """
(defmacro swap ([a b]) `(list ,b ,a))
(swap (1 2))
"""
    check sx.renderSyntax() == "(list 2 1)"

  test "expands a nested destructuring pattern in a macro parameter (#47)":
    let sx = expandOne """
(defmacro firstOfFirst ([[a b] c]) a)
(firstOfFirst ((1 2) 3))
"""
    check sx.renderSyntax() == "1"

  test "expands a rest capture in a macro parameter pattern (#47)":
    let sx = expandOne """
(defmacro headTail ([head & rest]) `(list ,head ,@rest))
(headTail (1 2 3))
"""
    check sx.renderSyntax() == "(list 1 2 3)"

  test "rejects a macro argument arity mismatch against a pattern parameter (#47)":
    expectExpandError("""
(defmacro swap ([a b]) `(list ,b ,a))
(swap (1 2 3))
""", "macro argument has 3 elements, destructuring pattern expects 2")

  test "rejects a non-list macro argument against a pattern parameter (#47)":
    expectExpandError("""
(defmacro swap ([a b]) `(list ,b ,a))
(swap 1)
""", "macro argument does not match destructuring pattern shape")

  test "rejects an object pattern in a macro parameter (#47)":
    expectExpandError("""
(defmacro bad ([:name n]) n)
(bad (1))
""", "object patterns are not supported in macro parameters")

  test "rejects a duplicate name across a macro parameter pattern (#47)":
    expectExpandError("""
(defmacro bad ([a a]) a)
(bad (1 2))
""", "duplicate macro parameter: a")

  test "named block evaluates like an anonymous block in a macro body (#41)":
    let sx = expandOne """
(defmacro pick ()
  (block :result 1 2 3))
(pick)
"""
    check sx.renderSyntax() == "3"

  test "break-from is rejected inside a macro body (#41)":
    expectExpandError("""
(defmacro pick ()
  (block :result (break-from :result 1) 2))
(pick)
""", "break-from is not supported in macro bodies")

  test "gensym generates distinct symbols":
    let sx = expandOne """
(defmacro twice (x)
  (let ((a (gensym "tmp"))
        (b (gensym "tmp")))
    `(let ((,a ,x) (,b ,x)) (+ ,a ,b))))
(twice 1)
"""
    let rendered = sx.renderSyntax()
    check rendered.contains("tmp__gensym1")
    check rendered.contains("tmp__gensym2")

  test "gensym identity cannot be forged by matching printed name":
    let sx = expandOne """
(defmacro collision ()
  (let ((a (gensym "tmp")))
    `(list ,a tmp__gensym1)))
(collision)
"""
    check sx.renderSyntax() == "(list tmp__gensym1 tmp__gensym1)"
    check sx.items[1].kind == sxSymbol
    check sx.items[2].kind == sxSymbol
    check sx.items[1].sym == sx.items[2].sym
    check sx.items[1].hygieneId != 0
    check sx.items[2].hygieneId == 0
    check not sx.items[1].sameSyntax(sx.items[2])

  test "macro-time truthiness matches runtime truthiness":
    let sx = expandOne """
(defmacro truthy-empty-values ()
  (list
    (if nil 'nil-false 'nil-true)
    (if false 'false-true 'false-false)
    (if '() 'empty-list-true 'empty-list-false)
    (if '[] 'empty-vector-true 'empty-vector-false)))
(truthy-empty-values)
"""
    check sx.renderSyntax() == "(nil-true false-false empty-list-true empty-vector-true)"

  test "macro errors include call site context":
    try:
      discard expandOne """
(defmacro nope () (macro-error "bad macro"))
(nope)
"""
      fail()
    except CompilerError as err:
      check err.diagnostic.span.file == "expand-test.lfn"
      check err.diagnostic.message.contains("error expanding macro nope")
      check err.diagnostic.message.contains("bad macro")

  test "rejects fixed parameter macro with too few arguments":
    expectExpandError("""
(defmacro pair (x y) `(list ,x ,y))
(pair 1)
""", "pair expects 2 arguments, got 1")

  test "rejects fixed parameter macro with too many arguments":
    expectExpandError("""
(defmacro pair (x y) `(list ,x ,y))
(pair 1 2 3)
""", "pair expects 2 arguments, got 3")

  test "rejects rest parameter macro with too few required arguments":
    expectExpandError("""
(defmacro when (test . body) `(if ,test (block ,@body) nil))
(when)
""", "when expects at least 1 arguments, got 0")

  test "rejects macro-time builtin with bad arity":
    expectExpandError("""
(defmacro bad () (first))
(bad)
""", "first expects 1 arguments, got 0")

  test "rejects unquote outside quasiquote":
    expectExpandError(",x", "unquote is only valid inside quasiquote")

  test "rejects unquote-splicing outside quasiquote":
    expectExpandError(",@xs", "unquote-splicing is only valid inside quasiquote")

  test "rejects malformed unquote":
    expectExpandError("""
(defmacro bad () `(unquote a b))
(bad)
""", "unquote expects 1 arguments, got 2")

  test "rejects malformed unquote-splicing":
    expectExpandError("""
(defmacro bad () `(a (unquote-splicing (list 'x) (list 'y))))
(bad)
""", "unquote-splicing expects 1 arguments, got 2")

  test "rejects duplicate macro parameters":
    expectExpandError("""
(defmacro bad (x x) x)
(bad 1 2)
""", "duplicate macro parameter: x")

  test "rejects duplicate macro rest parameter":
    expectExpandError("""
(defmacro bad (x . x) x)
(bad 1 2)
""", "duplicate macro parameter: x")

  test "rejects expansion recursion limit":
    expectExpandError("""
(defmacro loop () `(loop))
(loop)
""", "macro expansion depth exceeded")

  # ---------------------------------------------------------------------------
  # macro-time builtins (#70)
  # ---------------------------------------------------------------------------

  test "arithmetic builtins incl. int/float promotion":
    let sx = expandOne """
(defmacro test1 ()
  (list (+ 1 2 3) (+ 1 2.0) (- 5) (- 5.0) (- 10 3 2) (* 2 3 4) (* 2 2.0)
        (/ 2) (/ 10 4) (/ 10 5) (div 10 3) (mod 10 3)))
(test1)
"""
    check sx.renderSyntax() == "(6 3.0 -5 -5.0 5 24 4.0 0.5 2.5 2.0 3 1)"

  test "division by zero raises a compiler error, not a Nim trap":
    expectExpandError("""
(defmacro bad () (/ 1 0))
(bad)
""", "division by zero")
    expectExpandError("""
(defmacro bad () (div 1 0))
(bad)
""", "division by zero")
    expectExpandError("""
(defmacro bad () (mod 1 0))
(bad)
""", "division by zero")

  test "comparison builtins":
    let sx = expandOne """
(defmacro test1 ()
  (list (< 1 2 3) (< 1 3 2) (<= 1 1 2) (> 3 2 1) (> 1 2 3)
        (>= 3 3 2) (not nil) (not true) (not false)))
(test1)
"""
    check sx.renderSyntax() == "(true false true true false true true false true)"

  test "= is structural, not numeric — (= 1 1.0) is false":
    let sx = expandOne """
(defmacro test1 ()
  (list (= 1 1) (= 1 1.0) (= '(1) '(1.0)) (= 'a 'a) (/= 1 2) (/= 1 1)))
(test1)
"""
    check sx.renderSyntax() == "(true false false true true false)"

  test "list builtins incl. out-of-range nth and failed member":
    let sx = expandOne """
(defmacro test1 ()
  (list (nth '(a b c) 1) (nth '(a b c) 5) (nth '(a b c) -1)
        (length '(1 2 3)) (reverse '(1 2 3))
        (member 2 '(1 2 3)) (member 5 '(1 2 3))))
(test1)
"""
    check sx.renderSyntax() == "(b nil nil 3 (3 2 1) true false)"

  test "symbol/string builtins":
    let sx = expandOne """
(defmacro test1 ()
  (list (symbol->string 'foo) (string->symbol "bar") (string-append "a" "b" "c")))
(test1)
"""
    check sx.renderSyntax() == """("foo" bar "abc")"""

  test "type predicates discriminate each syntax kind (#80)":
    let sx = expandOne """
(defmacro test1 ()
  (list (symbol? 'a) (symbol? 1)
        (list? '(1 2)) (list? [1 2])
        (vector? [1 2]) (vector? '(1 2))
        (string? "s") (string? 1)
        (int? 1) (int? 1.0)
        (float? 1.0) (float? 1)
        (bool? true) (bool? 1)))
(test1)
"""
    check sx.renderSyntax() ==
      "(true false true false true false true false true false true false true false)"

  test "syntax? is no longer a macro-time builtin (#80)":
    expectExpandError("""
(defmacro bad () (syntax? 1))
(bad)
""", "unknown macro-time function: syntax?")

  test "rejects wrong arity for a new builtin":
    expectExpandError("""
(defmacro bad () (not 1 2))
(bad)
""", "not expects 1 arguments, got 2")

  test "rejects wrong argument type for a new builtin":
    expectExpandError("""
(defmacro bad () (+ 1 "x"))
(bad)
""", "expected a number")

  test "unknown macro-time function still reports clearly":
    expectExpandError("""
(defmacro bad () (frobnicate 1))
(bad)
""", "unknown macro-time function: frobnicate")

  # ---------------------------------------------------------------------------
  # defmacro-proc (#70)
  # ---------------------------------------------------------------------------

  test "defmacro-proc recursion drives a defmacro":
    let sx = expandOne """
(defmacro-proc plist-get (plist key)
  (if (nil? plist)
      nil
      (if (= (first plist) key)
          (nth plist 1)
          (plist-get (rest (rest plist)) key))))
(defmacro get-it (key &rest items) `(quote ,(plist-get items key)))
(get-it b a 1 b 2 c 3)
"""
    check sx.renderSyntax() == "(quote 2)"

  test "mutually recursive defmacro-procs":
    let sx = expandOne """
(defmacro-proc my-even? (n) (if (= n 0) true (my-odd? (- n 1))))
(defmacro-proc my-odd? (n) (if (= n 0) false (my-even? (- n 1))))
(defmacro check (n) (my-even? n))
(check 10)
"""
    check sx.renderSyntax() == "true"

  test "defmacro-proc with a rest parameter":
    let sx = expandOne """
(defmacro-proc first-and-rest-len (&rest xs) (list (first xs) (length (rest xs))))
(defmacro test1 () (first-and-rest-len 10 20 30))
(test1)
"""
    check sx.renderSyntax() == "(10 2)"

  test "defmacro-proc with a destructuring parameter":
    let sx = expandOne """
(defmacro-proc swapped ([a b]) (list b a))
(defmacro s2 (pair) `(quote ,(swapped pair)))
(s2 (1 2))
"""
    check sx.renderSyntax() == "(quote (2 1))"

  test "an evaluated keyword-symbol argument does not confuse macro-proc binding":
    let sx = expandOne """
(defmacro-proc echo-arg (x) x)
(defmacro test-kw () (echo-arg ':accessor))
(test-kw)
"""
    check sx.renderSyntax() == ":accessor"

  test "&key is rejected in a defmacro-proc lambda list":
    expectExpandError("""
(defmacro-proc bad (x &key y) x)
""", "&key is not supported in a defmacro-proc parameter list")

  test "rejects defmacro-proc recursion depth exceeded":
    expectExpandError("""
(defmacro-proc loop (n) (if (= n 0) 0 (loop (- n 1))))
(defmacro run (n) (loop n))
(run 1000)
""", "macro-time procedure recursion depth exceeded")

  test "the macro-proc depth counter unwinds after a failed call, allowing a later legal deep recursion":
    let env = newMacroEnv()
    let defForms = expandModule(readAll("""
(defmacro-proc loop (n) (if (= n 0) 0 (loop (- n 1))))
(defmacro run (n) (loop n))
""", "expand-test.lfn"), env)
    check defForms.len == 0
    let overflowCall = readAll("(run 1000)", "expand-test.lfn")[0]
    var raised = false
    try:
      discard expandExpr(env, overflowCall)
    except CompilerError as err:
      raised = true
      check err.diagnostic.message.contains("macro-time procedure recursion depth exceeded")
    check raised
    let legalCall = readAll("(run 150)", "expand-test.lfn")[0]
    check expandExpr(env, legalCall).renderSyntax() == "0"

  test "defmacro-proc is rejected in expression position":
    expectExpandError("(+ 1 (defmacro-proc bad (x) x))", "defmacro-proc is only allowed at statement/module scope")

  test "rejects duplicate defmacro-proc definition":
    expectExpandError("""
(defmacro-proc dup (x) x)
(defmacro-proc dup (x) x)
""", "duplicate macro-proc definition: dup")

  test "rejects a defmacro-proc that shadows a builtin":
    expectExpandError("(defmacro-proc first (x) x)", "cannot redefine macro-time builtin: first")

  test "rejects a defmacro-proc that shadows a new type predicate (#80)":
    expectExpandError("(defmacro-proc vector? (x) x)", "cannot redefine macro-time builtin: vector?")

  test "rejects a defmacro-proc that shadows a special form":
    expectExpandError("(defmacro-proc if (x) x)", "cannot redefine macro-time builtin: if")

  # ---------------------------------------------------------------------------
  # CLOS-lite defclass/make-instance (#66)
  # ---------------------------------------------------------------------------

  test "rejects a defclass slot that isn't a list":
    expectCoreExpandError("(defclass Bad () (name))", "defclass slot must be a list")

  test "rejects a defclass slot shorter than (name Type)":
    expectCoreExpandError("(defclass Bad () ((name)))", "defclass slot must be (name Type [options...])")

  test "rejects an unknown defclass slot option":
    expectCoreExpandError("(defclass Bad () ((name string :foo bar)))", "defclass: unknown slot option :foo")

  test "rejects a defclass slot option missing its value":
    expectCoreExpandError("(defclass Bad () ((name string :accessor)))", "defclass slot option missing its value")

  test "rejects a non-symbol defclass accessor name":
    expectCoreExpandError("(defclass Bad () ((name string :accessor 1)))", "defclass slot accessor/reader/initarg value must be a symbol")

  test "rejects more than one defclass superclass":
    expectCoreExpandError("(defclass Bad (A B) ((name string)))", "defclass supports a single superclass")

  test ":accessor generates a getter and a setter; :reader generates a getter only (#75)":
    let forms = expandSource("(defclass C () ((n string :accessor cN) (m string :reader cM)))", "expand-test.lfn")
    let rendered = renderForms(forms)
    check rendered.contains("proc cN ")
    check rendered.contains("proc cN= ")
    check rendered.contains("proc cM ")
    check not rendered.contains("cM=")

  test ":initform is accepted and lowers into the object field's default slot (#78)":
    let forms = expandSource("""(defclass C () ((n string :initform "anon") (m int)))""", "expand-test.lfn")
    let rendered = renderForms(forms)
    check rendered.contains("""(n string "anon")""")
    check rendered.contains("(m int)")

  test ":initform composes with :accessor (#78)":
    let forms = expandSource("""(defclass C () ((n string :accessor cN :initform "anon")))""", "expand-test.lfn")
    let rendered = renderForms(forms)
    check rendered.contains("""(n string "anon")""")
    check rendered.contains("proc cN ")
    check rendered.contains("proc cN= ")

  test "rejects a duplicate :initform on one defclass slot (#78)":
    expectCoreExpandError(
      "(defclass Bad () ((name string :initform \"a\" :initform \"b\")))",
      "defclass slot has more than one :initform")

  test "an unknown defclass slot option is still rejected alongside :initform (#78)":
    expectCoreExpandError("(defclass Bad () ((name string :foo bar :initform \"a\")))", "defclass: unknown slot option :foo")

  test ":initarg lowers into a pragma'd field carrying the keyword's text (#85)":
    let forms = expandSource("""(defclass C () ((n string :initarg :nom) (m int)))""", "expand-test.lfn")
    let rendered = renderForms(forms)
    check rendered.contains("""(n (pragma (: lfnInitarg ":nom")) string)""")
    check rendered.contains("(m int)")

  test ":initarg composes with :accessor and :initform (#85)":
    let forms = expandSource(
      """(defclass C () ((n string :accessor cN :initarg :nom :initform "anon")))""", "expand-test.lfn")
    let rendered = renderForms(forms)
    check rendered.contains("""(n (pragma (: lfnInitarg ":nom")) string "anon")""")
    check rendered.contains("proc cN ")
    check rendered.contains("proc cN= ")

  test "make-instance expands to the lfnMakeInstance Nim macro (#85)":
    let forms = expandSource("""(make-instance C (n "x"))""", "expand-test.lfn")
    check renderForms(forms) == """(lfnMakeInstance C (n "x"))"""

  test "rejects a duplicate :initarg on one defclass slot (#85)":
    expectCoreExpandError(
      "(defclass Bad () ((name string :initarg :a :initarg :b)))",
      "defclass slot has more than one :initarg")

  test "an unknown defclass slot option is still rejected alongside :initarg (#85)":
    expectCoreExpandError("(defclass Bad () ((name string :foo bar :initarg :nom)))", "defclass: unknown slot option :foo")

  test "rejects a non-symbol defclass :initarg value (#85)":
    expectCoreExpandError("(defclass Bad () ((name string :initarg 1)))", "defclass slot accessor/reader/initarg value must be a symbol")

  # ---------------------------------------------------------------------------
  # automatic template hygiene (#11)
  # ---------------------------------------------------------------------------

  test "quasiquoted let auto-renames its own literal binding":
    let sx = expandOne """
(defmacro m (a) `(let ((tmp ,a)) (+ tmp tmp)))
(let ((tmp 99)) (m tmp))
"""
    # sx == (let ((tmp 99)) (let ((tmp<hygienic> tmp)) (+ tmp<hygienic> tmp<hygienic>)))
    let innerLet = sx.items[2]
    let innerBinding = innerLet.items[1].items[0]
    let boundName = innerBinding.items[0]
    let substitutedArg = innerBinding.items[1]
    let bodyRefA = innerLet.items[2].items[1]
    let bodyRefB = innerLet.items[2].items[2]
    check boundName.sym == "tmp"
    check boundName.hygieneId != 0
    # The substituted `,a` is the caller's own `tmp` — untouched (hygieneId 0).
    check substitutedArg.hygieneId == 0
    # Both body references resolve to the same renamed binding.
    check bodyRefA.hygieneId == boundName.hygieneId
    check bodyRefB.hygieneId == boundName.hygieneId

  test "nested lets in one template each get their own hygieneId":
    let sx = expandOne """
(defmacro dbl (a) `(let ((tmp ,a)) (let ((tmp (+ tmp tmp))) tmp)))
(dbl 3)
"""
    let outerBoundName = sx.items[1].items[0].items[0]
    let innerLet = sx.items[2]
    let innerBoundName = innerLet.items[1].items[0].items[0]
    check outerBoundName.hygieneId != 0
    check innerBoundName.hygieneId != 0
    check outerBoundName.hygieneId != innerBoundName.hygieneId

  test "a destructuring pattern's bound names are hygienically renamed (#47)":
    let sx = expandOne """
(defmacro grab-first-two (xs) `(let (([a b] ,xs)) (+ a b)))
(let ((a 99)) (grab-first-two [1 2 3]))
"""
    let innerLet = sx.items[2]
    let pattern = innerLet.items[1].items[0].items[0]
    let boundA = pattern.items[0]
    let boundB = pattern.items[1]
    let bodyRefA = innerLet.items[2].items[1]
    let bodyRefB = innerLet.items[2].items[2]
    check boundA.hygieneId != 0
    check boundB.hygieneId != 0
    check boundA.hygieneId != boundB.hygieneId
    check bodyRefA.hygieneId == boundA.hygieneId
    check bodyRefB.hygieneId == boundB.hygieneId

  test "an object pattern's shorthand key is hygienically renamed to an explicit form (#47)":
    let sx = expandOne """
(defmacro grab-name (p) `(let (([:name] ,p)) name))
(let ((name 5)) (grab-name x))
"""
    let innerLet = sx.items[2]
    let pattern = innerLet.items[1].items[0].items[0]
    check pattern.items.len == 2
    check pattern.items[0].sym == ":name"
    check pattern.items[0].hygieneId == 0
    let boundName = pattern.items[1]
    check boundName.sym == "name"
    check boundName.hygieneId != 0
    let bodyRef = innerLet.items[2]
    check bodyRef.hygieneId == boundName.hygieneId

  test "unhygienic escape hatch leaves the binding and its references unrenamed":
    let sx = expandOne """
(defmacro with-it (test &body body) `(let (((unhygienic it) ,test)) (block ,@body)))
(with-it 41 (+ it 1))
"""
    let binding = sx.items[1].items[0]
    let boundName = binding.items[0]
    check boundName.sym == "it"
    check boundName.hygieneId == 0

  test "rejects unhygienic outside a quasiquote template":
    expectExpandError("(unhygienic x)", "unhygienic is only valid as a binding target inside a quasiquote template")

  test "rejects malformed unhygienic binding target":
    expectExpandError("""
(defmacro bad () `(let (((unhygienic 1) 2)) 1))
(bad)
""", "unhygienic expects exactly one symbol argument")

  # ---------------------------------------------------------------------------
  # var/const section and single-declaration hygiene (#62)
  # ---------------------------------------------------------------------------

  test "a var section's target is hygienically renamed, visible to a following sibling":
    let sx = expandOne """
(defmacro m () `(block (var ((tmp 1))) (+ tmp tmp)))
(m)
"""
    let blk = sx
    let boundName = blk.items[1].items[1].items[0].items[0]
    let siblingRefA = blk.items[2].items[1]
    let siblingRefB = blk.items[2].items[2]
    check boundName.sym == "tmp"
    check boundName.hygieneId != 0
    check siblingRefA.hygieneId == boundName.hygieneId
    check siblingRefB.hygieneId == boundName.hygieneId

  test "a const section's target is hygienically renamed":
    let sx = expandOne """
(defmacro m () `(block (const ((k 1))) (+ k k)))
(m)
"""
    let blk = sx
    let boundName = blk.items[1].items[1].items[0].items[0]
    check boundName.hygieneId != 0
    check blk.items[2].items[1].hygieneId == boundName.hygieneId

  test "a single var declaration's target is hygienically renamed, visible to a following sibling":
    let sx = expandOne """
(defmacro m () `(block (var tmp 1) (+ tmp tmp)))
(m)
"""
    let blk = sx
    let boundName = blk.items[1].items[1]
    check boundName.sym == "tmp"
    check boundName.hygieneId != 0
    check blk.items[2].items[1].hygieneId == boundName.hygieneId
    check blk.items[2].items[2].hygieneId == boundName.hygieneId

  test "a var section value is renamed with the scope from before this section's own targets":
    # (var ((x tmp) (tmp 2))) — the FIRST binding's value `tmp` must resolve
    # to the caller's outer `tmp`, not this section's own second `tmp`
    # target — mirrors lowerVarSection lowering every value before declaring
    # any target.
    let sx = expandOne """
(defmacro m () `(block (var ((x tmp) (tmp 2))) x))
(let ((tmp 99)) (m))
"""
    let varForm = sx.items[2].items[1]
    let bindingsList = varForm.items[1]
    let xValue = bindingsList.items[0].items[1]
    check xValue.hygieneId == 0

  test "unhygienic escape hatch works for a var section target":
    let sx = expandOne """
(defmacro with-it () `(block (var (((unhygienic it) 9))) (+ it 1)))
(with-it)
"""
    let blk = sx
    let boundName = blk.items[1].items[1].items[0].items[0]
    check boundName.sym == "it"
    check boundName.hygieneId == 0

  # ---------------------------------------------------------------------------
  # routine parameter hygiene (#84)
  # ---------------------------------------------------------------------------

  test "proc params are hygienically renamed; the name and generic params are not (#84)":
    let sx = expandOne """
(defmacro m () `(proc adder [T] ((self int)) (: int) (+ self 1)))
(m)
"""
    let procForm = sx
    check procForm.items[1].sym == "adder"
    check procForm.items[1].hygieneId == 0
    check procForm.items[2].items[0].hygieneId == 0     # generic param T
    let param = procForm.items[3].items[0]
    let paramName = param.items[0]
    check paramName.sym == "self"
    check paramName.hygieneId != 0
    check param.items[1].hygieneId == 0                 # param type `int`
    let bodyRef = procForm.items[5].items[1]
    check bodyRef.hygieneId == paramName.hygieneId

  test "do params are hygienically renamed the same way proc params are (#84)":
    let sx = expandOne """
(defmacro m () `(do ((self int)) (: int) (+ self 1)))
(m)
"""
    let doForm = sx
    let paramName = doForm.items[1].items[0].items[0]
    check paramName.hygieneId != 0
    check doForm.items[3].items[1].hygieneId == paramName.hygieneId

  test "a proc param default is renamed with the accumulating scope, seeing an earlier param (#84)":
    let sx = expandOne """
(defmacro m () `(proc adder ((a int) (b int a)) (: int) (+ a b)))
(m)
"""
    let procForm = sx
    let params = procForm.items[2]
    let aName = params.items[0].items[0]
    let bDefault = params.items[1].items[2]
    check aName.hygieneId != 0
    check bDefault.hygieneId == aName.hygieneId

  test "a proc's own literal param name doesn't capture an identically-named caller symbol (#84)":
    let sx = expandOne """
(defmacro m (bodyExpr) `(let ((self 999) (f (proc adder ((self int)) (: int) (+ self 1)))) ,bodyExpr))
(m self)
"""
    let letForm = sx
    let outerSelf = letForm.items[1].items[0].items[0]
    let procParamName = letForm.items[1].items[1].items[1].items[2].items[0].items[0]
    let procBodyRef = letForm.items[1].items[1].items[1].items[4].items[1]
    let macroArg = letForm.items[2]
    # The template's own `self` let-binding is itself a hygiene-rename
    # target (it's a plain literal let binding) — the point of this test is
    # that it and the proc param `self` get *distinct* hygienic identities,
    # so neither can capture the other, not that either is left unrenamed.
    check outerSelf.hygieneId != 0
    check procParamName.hygieneId != 0
    check procParamName.hygieneId != outerSelf.hygieneId
    check procBodyRef.hygieneId == procParamName.hygieneId
    # `,bodyExpr` substitutes the caller's own `self` — untouched.
    check macroArg.hygieneId == 0

  # ---------------------------------------------------------------------------
  # labelled loop hygiene (#54)
  # ---------------------------------------------------------------------------

  test "a labelled for inside a template keeps its label unrenamed and still renames the loop var":
    let sx = expandOne """
(defmacro m (xs) `(for :outer (x ,xs) (echo x)))
(m (list 1 2))
"""
    # sx == (for :outer (x<hygienic> (list 1 2)) (echo x<hygienic>))
    let label = sx.items[1]
    check label.sym == ":outer"
    check label.hygieneId == 0
    let clause = sx.items[2]
    let loopVar = clause.items[0]
    check loopVar.sym == "x"
    check loopVar.hygieneId != 0
    let bodyRef = sx.items[3].items[1]
    check bodyRef.hygieneId == loopVar.hygieneId

  test "a labelled while inside a template keeps its label unrenamed":
    let sx = expandOne """
(defmacro m () `(while :outer true (echo 1)))
(m)
"""
    # sx == (while :outer true (echo 1))
    let label = sx.items[1]
    check label.sym == ":outer"
    check label.hygieneId == 0

suite "golden macro expansion":
  test "core macro fixtures":
    for sourcePath in ["tests/golden/core_macros.lfn",
                       "tests/golden/escaped_symbols.lfn",
                       "tests/golden/hygiene.lfn",
                       "tests/golden/destructuring.lfn",
                       "tests/golden/macro_procs.lfn",
                       "tests/golden/clos.lfn",
                       "tests/golden/static_when.lfn"]:
      let expectedPath = sourcePath.changeFileExt("out")
      let actual = expandSource(readFile(sourcePath), sourcePath).renderForms()
      check actual.strip() == readFile(expectedPath).strip()
