import sys
root = sys.argv[1]


def edit(path, pairs):
    p = root + '/' + path
    s = open(p).read()
    for old, new in pairs:
        assert s.count(old) == 1, (path, old)
        s = s.replace(old, new)
    open(p, 'w').write(s)


edit('verified/core/PROGRESS.md', [
("""   ASSUMED, allowlisted). Gate: core 174 verified, 0 errors.
""", """   ASSUMED, allowlisted). Gate: core 174 verified, 0 errors.
2. Finally records (spec change R1, format note 17, branch
   core/refinement-r1): entering finally code with an unwinding writes a
   4-word record after the frame records instead of allocating a heap
   token (DESIGN.md section 3); C++ copies, shrinks and reports the
   records with the frame records. The abstraction relates `State2.fins`
   to the records (`fins_rel`). Proven: RETURN/RETURN_NULL and calls with
   the records (`do_return` drops the popped frame's records,
   `fins_popped`; `push_call` moves them), and (src/unwind.rs) THROW, TRY,
   UNWIND, NON_LOCAL_RETURN and NON_LOCAL_BRANCH against `spec::step`,
   including the unwinding loop over frames, `enter_finally` with a
   record, `pop_frame`; raising stays unverified. Gate: core 298 verified,
   0 errors. Cost: the verified unwinding in the run loop adds about 6
   percent instructions to richards and 4.5 percent to deltablue on the
   verified loop (callgrind, `TOIT_VERIFY=1`, against routing these
   opcodes to the checked handlers; richards throws nothing, the cost is
   in the loop head's `Ctl` handling, independent of inlining): open for
   the performance pass.
"""),
("""5. Spec change request R1 (unwinding without a heap token).
""", """5. Spec change request R1 (unwinding without a heap token): done
   (milestone 2 above).
"""),
("""- channel-retention-test, services-resource-close-pressure-test: the
  unwinding token of note 4 (PHASE4-REQUESTS.md R1).
""", """- services-resource-close-pressure-test: listed for the unwinding token
  of note 4 (R1), which is gone (finally records); not re-run since.
  channel-retention-test passes in format 2.
"""),
])

edit('verified/core/OBLIGATIONS.md', [
("""| B1 blocks | NON_LOCAL_RETURN, NON_LOCAL_BRANCH; INVOKE_BLOCK's CODE_INVOCATION_FAILED path | unwinding over frames (`spec::unwind`); raising allocates. LOAD_BLOCK, LOAD_OUTER, STORE_OUTER, LOAD_OUTER_BLOCK and INVOKE_BLOCK are verified (src/blocks.rs) |""",
"""| B1 blocks | INVOKE_BLOCK's CODE_INVOCATION_FAILED path | raising allocates. LOAD_BLOCK, LOAD_OUTER, STORE_OUTER, LOAD_OUTER_BLOCK and INVOKE_BLOCK are verified (src/blocks.rs), NON_LOCAL_RETURN and NON_LOCAL_BRANCH too (src/unwind.rs) |"""),
("""| T1 try/unwind | TRY, UNWIND, THROW | needs R2 and the heap (the token is a 5-element array); `unwind` is a loop over frames, `enter_finally` allocates |""",
"""| T1 try/unwind | (raising only) | TRY, UNWIND and THROW are verified (src/unwind.rs: the unwinding loop `spec::unwind`, `enter_finally` with a finally record, `pop_frame`; TRY never raises for an accepted program). Unwindings started by raising (the failures the machine raises, a primitive's THROW, stack overflow) go through the unverified `raise`/`unwind` of machine.rs |"""),
("""  The audited places are `enter_finally` (value and payload are pushed on
  the object stack before the token allocation and re-read after),
  `raise_value_msg`""", """  The audited places are `raise_value_msg`"""),
])

edit('verified/core/TRUSTED.md', [
("""`header`/`set_header` access the Stack header words (top, frame top, bci) |""",
 """`header`/`set_header` access the Stack header words (top, record top, bci with the finally-record count) |"""),
("""(top, frame top, bci) into the Stack object first (`Machine::save`) and""",
 """(top, record top, bci and finally-record count) into the Stack object
first (`Machine::save`) and"""),
("""  the preallocated `OUT_OF_MEMORY` error. A failed unwinding-token
  allocation turns the unwinding into an `OUT_OF_MEMORY` throw past the
  handler (DESIGN.md, open problems).""", """  the preallocated `OUT_OF_MEMORY` error. Unwinding itself allocates
  nothing (finally records live in the task's stack, format note 17)."""),
])
