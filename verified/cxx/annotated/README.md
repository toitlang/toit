# VeriFast for the C++ that stays C++

The C++ inside the sandbox's security boundary that is not ported to
Rust/Verus (the interpreter glue to the allocator and GC, the message
encoder and decoder, blob argument decoding, a few helpers) is verified
with VeriFast 26.10, unbounded, on 64-bit and 32-bit. The pilot
(verified/CXX-ANNOTATED-PILOT.md) proved this works on hand-written C
renderings of the C++; this directory makes the rendering mechanical, so
that it cannot drift from the sources.

Run: `run.sh` (the whole matrix, also part of
`verified/check.sh --tests`, which skips it with a message when VeriFast is
not installed). Tools: `install-tools.sh` (VeriFast 26.10 and its Rust
front end, under /home/flo/work/opentoit-sandbox-artifacts/annotated-cxx).
The tagged-integer equivalence checks use ESBMC. The UTF-8 validator uses
Frama-C/WP and Alt-Ergo. Install them with `verified/cxx/install-tools.sh esbmc framac`.
What a run writes (Clang's AST dumps, the 32-bit renderings, logs, the
mutants' copies) goes to a directory per checkout under `work/` there
(`ACXX_WORK`, env.sh), and a lock serializes the runs of one checkout:
the scratch directory was shared, and two checkouts rendering at once
wrote the same AST dump twice ("2 definitions of toit::Instance::at_put").
The checks run as parallel jobs: the LP64 proofs together with
`render.sh --check`, the ILP32 proofs and the mutants after it. A job
waiting for model-checker memory does not hold one of the `RUN_JOBS`
slots (at most `RUN_JOBS` jobs wait at once).

Disk: a fast-tier run needs about 8 GB of its work directory at peak
(measured 7.3 GB, 2026-11-24; RUN_JOBS=32) and leaves about 40 MB (logs,
`gen/`, the model-checker jobs' small directories). The bulk is Clang's
JSON ASTs: `render.sh` dumps every translation unit for both targets into
`scratch/` (1.6 GB, removed once the drift check passed), and each mutant
dumps the translation units of its sidecar from its changed tree
(90-550 MB, removed as soon as it is rendered; the rest of the mutant's
tree, about 5 MB of links and copies, when its verdict is out; its logs
stay in `logs/mutants/NAME/`). Without that clean-up a run left 73 GB.
`RUN_KEEP_MUTANTS=1` and `RUN_KEEP_SCRATCH=1` keep the trees for
debugging.

### Two tiers

The model-checker jobs (ESBMC and CBMC harnesses under `../harness/`,
started by `cpp_equivalence`, `ec618_cbmc` and `array_allocation` in
`run.sh`) range from a second to more than an hour and from 0.1 to more
than 36 GB, so the matrix has two tiers:

* the fast tier, `run.sh` (and `verified/check.sh --tests`): the
  renderings, the constant and layout checks, every VeriFast proof, the
  mutants, the Frama-C/WP loops, the EC618 SMT models
  (`heap/smt-models.sh`) and every model-checker job that is not
  listed in `model-check-jobs.sh`;
* the slow tier, `run.sh --slow` (and `verified/check.sh --slow`, which
  runs both): only the jobs listed by `slow` in `model-check-jobs.sh`. It
  has its own lock, so the fast tier can run in the same checkout
  meanwhile.

Every model-checker job, in either tier, runs under a memory cap
(`ulimit -v`) and a timeout, and holds its cap from a memory budget shared
by all checkouts on the machine (`$ACXX_HOME/work/model-check-memory`)
while it runs: memory, not the core count, limits how many run at once.
Jobs waiting for memory queue first come, first served within their tier,
but a slow-tier run of one checkout cannot stall the gate of another:
fast jobs never wait for slow ones, slow jobs wait while any fast job
waits, and the slow jobs together hold at most `RUN_SLOW_BUDGET` (the
budget less 16 GB), so the fast tier always has 16 GB (a slow job larger
than that runs when no other slow job holds memory). A job that has
waited 30 s says on `run.sh`'s stderr what it waits for, and again every
10 minutes. Stopping `run.sh` (TERM, INT) stops its model checkers.
A job prints one of `ok` (its expected verdict), `FAIL` (`property
violated`, or `error`), or `NOVERDICT` (out of time or memory, or killed
by a signal: nothing was proved or refuted). A no-verdict is never an
`ok`; `run.sh` exits with 1 when something failed, otherwise with 4 when
a job gave no verdict. Settings (environment, memory in GB): 
`RUN_MEM_BUDGET` (40), `RUN_SLOW_BUDGET` (24), `RUN_FAST_MEM` (4; `fast_cap` raises it per job),
`RUN_FAST_TIMEOUT` (600 s), `RUN_SLOW_MEM` and `RUN_SLOW_TIMEOUT` (16,
7200 s: for a `slow` entry without its own), `RUN_MEM_SCALE` and
`RUN_TIME_SCALE` (scale every cap or timeout), `RUN_KNOWN_NOVERDICT=1`
(also run the jobs known not to finish), `RUN_MC=0` (skip the model
checkers, for VeriFast iterations). Each job's verdict, time and peak
memory (resident and virtual, of its process tree, sampled every second)
are appended to `$ACXX_WORK/logs/model-check-fast.tsv` or `-slow.tsv`.

A job is in the slow tier when it took more than 90 s when measured. The
measurements below (2026-11-23, 32 cores shared with unrelated work,
up to six model-checker jobs at once, ESBMC 8.6.0) are the last record of
each job in the `.tsv` files; "Cap then" is the cap it ran under
(`model-check-jobs.sh` now gives each job about 1.5 times its peak
virtual size, and 4 times its time, at least 30 minutes, as its timeout).
Peaks are sampled once a second. A NOVERDICT row proved nothing: the
property was neither proved nor refuted at that cap or timeout.

| Job | Verdict | Time (s) | Peak resident (GB) | Peak virtual (GB) | Cap then (GB) | Note |
|---|---|---:|---:|---:|---:|---|
| allocate-task/ILP32 | PASS | 175 | 0.8 | 1.5 | 6 |  |
| allocate-task/LP64 | PASS | 306 | 1.4 | 2.0 | 6 |  |
| encoder-collections/LP64 | PASS | 128 | 1.6 | 2.4 | 6 |  |
| event-notifiers/LP64 | PASS | 156 | 1.3 | 2.0 | 6 |  |
| external-accounting-threads/ILP32 | PASS | 105 | 1.1 | 1.7 | 6 |  |
| external-accounting-threads/LP64 | PASS | 108 | 1.1 | 1.7 | 6 |  |
| external-blob-allocation/ILP32 | PASS | 97 | 0.7 | 1.4 | 6 |  |
| external-blob-allocation/LP64 | PASS | 481 | 1.2 | 1.9 | 6 |  |
| finalizer-queue/LP64 | PASS | 104 | 1.4 | 2.1 | 6 |  |
| free-list-selection/ILP32 | PASS | 1765 | 8.3 | 9.7 | 16 |  |
| gc-compaction-fix-roots/ILP32 | PASS | 234 | 0.9 | 1.5 | 6 |  |
| gc-compaction-fix-roots/LP64 | PASS | 1331 | 1.4 | 2.1 | 6 |  |
| gc-compaction-last-fit/LP64 | PASS | 274 | 1.1 | 1.7 | 6 |  |
| gc-compaction-overhang/ILP32 | PASS | 1429 | 2.5 | 3.2 | 6 |  |
| gc-ec618-reclaim/ILP32 | PASS | 126 | 1.2 | 1.5 | 3 |  |
| gc-ec618-stats/ILP32 | PASS | 84 | 0.6 | 0.7 | 3 |  |
| gc-external-finalizer-raw/LP64 | PASS | 236 | 2.4 | 3.1 | 6 |  |
| gc-external-finalizer-string_buffer/LP64 | PASS | 256 | 2.6 | 3.2 | 6 |  |
| gc-metadata-commit/LP64 | PASS | 797 | 0.4 | 1.0 | 6 |  |
| gc-metadata-layout-ec618/ILP32 | PASS | 503 | 0.4 | 1.1 | 6 |  |
| gc-metadata-layout-esp32/ILP32 | PASS | 1049 | 0.5 | 1.1 | 6 |  |
| gc-metadata-layout/ILP32 | PASS | 162 | 0.2 | 0.8 | 6 |  |
| gc-remembered-card/LP64 | PASS | 518 | 0.3 | 0.9 | 6 |  |
| gc-scavenge-alias/ILP32 | PASS | 165 | 0.9 | 1.5 | 6 |  |
| gc-scavenge-alias/LP64 | PASS | 557 | 1.2 | 1.8 | 6 |  |
| gc-scavenge-graph/ILP32 | PASS | 146 | 0.8 | 1.4 | 6 |  |
| gc-scavenge-graph/LP64 | PASS | 331 | 1.5 | 2.1 | 6 |  |
| gc-stack-shrink/ILP32 | PASS | 147 | 0.8 | 1.4 | 6 |  |
| gc-stack-shrink/LP64 | PASS | 452 | 1.4 | 2.1 | 6 |  |
| ipc-fixed-scalar/LP64 | PASS | 232 | 2.0 | 2.7 | 6 |  |
| ipc-byte-array-visit/LP64 | PASS | 301 | 13.1 | 14.6 | 16 |  |
| ipc-transferred-array/LP64 | PASS | 696 | 2.3 | 3.1 | 6 |  |
| monitor-scavenge-promoted/LP64 | PASS | 219 | 0.9 | 1.5 | 6 |  |
| monitor-scavenge-promotion_failed/LP64 | PASS | 123 | 0.7 | 1.3 | 6 |  |
| monitor-scavenge-young/LP64 | PASS | 117 | 0.7 | 1.3 | 6 |  |
| process-array-allocation/LP64 | PASS | 155 | 0.5 | 1.1 | 3 | 4 modes summed |
| scheduler-notify/ILP32 | PASS | 215 | 17.1 | 18.2 | 24 |  |
| scheduler-spawn/ILP32 | PASS | 432 | 1.6 | 2.3 | 4 | 2026-11-24, wave 8 (refused announcement) |
| scheduler-spawn/LP64 | PASS | 1383 | 3.4 | 4.3 | 7 | 2026-11-24, wave 8 (refused announcement) |
| snapshot-image-layout/LP64 | PASS | 386 | 0.4 | 1.0 | 6 |  |
| task-all-fields/ILP32 | PASS | 172 | 0.9 | 1.5 | 6 |  |
| task-all-fields/LP64 | PASS | 256 | 1.2 | 2.0 | 6 |  |
| task-retry-fields/ILP32 | PASS | 319 | 1.0 | 1.7 | 6 |  |
| task-retry-fields/LP64 | PASS | 698 | 1.8 | 2.5 | 6 |  |
| task-transfer/LP64 | PASS | 490 | 1.0 | 1.7 | 6 |  |
| timer-delete/LP64 | PASS | 153 | 2.2 | 2.9 | 6 |  |
| timer-dispatch/LP64 | PASS | 203 | 4.8 | 5.6 | 6 |  |
| install-image-layout/ILP32 | PASS | 389 | not recorded | not recorded | 12 | 2026-11-25, wave 12, measured outside run.sh |
| install-image-layout/LP64 | NOVERDICT | 1800 | 0.9 | not recorded | 12 | 2026-11-25, wave 12, measured outside run.sh; timeout after 1800 s (Boolector) |
| free-list-selection/LP64 | NOVERDICT | 3601 | 18.9 | 21.0 | 24 | timeout after 3600 s; at a 16 GB cap out of memory after 175 s |
| gc-compaction-overhang/LP64 | NOVERDICT | 7200 | 5.1 | 6.2 | 12 | timeout after 7200 s |
| gc-metadata-layout/LP64 | NOVERDICT | 10800 | 0.5 | 1.1 | 4 | timeout after 10800 s |
| gc-sweep-chunk/ILP32 | PASS | 478 | 1.4 | 2.0 | 6 | 2026-11-24, restructured (below); before: out of memory at 16 GB after 5192 s |
| gc-sweep-chunk/LP64 | PASS | about 4500 (CPU) | 3.3 | 3.9 | 6 | 2026-11-24, restructured (below), measured outside run.sh (a suspend distorted the wall clock); before: out of memory at 16 GB after 3457 s |
| gc-sweep-chunk-uncounted/ILP32 | ok (violation) | 240 | 1.4 | 2.0 | 4 | mutant |
| gc-sweep-chunk-no-sentinel/ILP32 | ok (violation) | 429 | 1.4 | 2.0 | 4 | mutant |
| gc-sweep-chunk-no-sentinel/LP64 | ok (violation) | 258 | 2.7 | 3.3 | 4 | mutant |
| gc-sweep-chunk-uncounted/LP64 | NOVERDICT | 601 | 2.7 | 3.4 | 4 | mutant; timeout after 600 s, not measured longer |

**No verdict.** These jobs still prove nothing; the results that cite
them hold on ILP32 only, and this README and `verified/core/TRUSTED.md`
say so where they cite them. `model-check-jobs.sh` lists them as known
not to finish (`RUN_KNOWN_NOVERDICT=1` runs them). What was tried on
2026-11-24 (each LP64, with the job's own unwinding bounds unless said):

* `gc-compaction-overhang/LP64` (TRUSTED.md's "overhang fixture"); ILP32
  passes (24 min). The planner writes the destination table and reads the
  mark bits through integer addresses, and the source address is the
  only symbolic input once the object size is fixed. Bitwuzla: out of time
  after 2 h (before); Boolector: out of time after 2 h; Bitwuzla in
  multi-property mode: 697 of 1079 claim instances in 80 min (up to 226 s
  each), stopped. A case split on the first object's size (one of the 15
  values; that harness variant is kept with the measurements, not here) did not help: one
  value alone gave no verdict in 1 h with Boolector (56 CPU-minutes) or
  45 CPU-minutes with Bitwuzla. Z3 was stopped after 17 CPU-minutes when the attempts ended.
* `gc-metadata-layout/LP64` (below, "`gc-metadata-layout` checks
  non-embedded GC setup"); ILP32 and the EC618 and ESP32 variants pass.
  Bitwuzla: out of time after 3 h at 0.5 GB (before). Multi-property
  Bitwuzla: 165 of 206 claims in 25 min, then the bounds check of the
  harness's own witness store into the metadata reservation
  (`check_card_write`) ran for more than an hour. That check needs the
  commit bounds as integers through a pointer-to-integer round trip of a
  64-bit symbolic address into a reservation of symbolic size. Restating
  the commit bound as a proved lemma (assert, then assume) did not finish
  in 2 h with Boolector, nor in multi-property mode with Bitwuzla (the
  accessor claim alone took 40 min). A second lemma, the commit address as the reservation's plus
  its offset, was not run to the end (Z3 and multi-property Bitwuzla were
  stopped when the attempts ended).
* `free-list-selection/LP64`; ILP32 passes (29 min, 8 GB). Three regions
  of symbolic 64-bit size, each its own allocation, inserted and one
  selected. Bitwuzla: out of time after 1 h at 24 GB (before);
  multi-property Bitwuzla: 1193 of 1498 claim instances in 1 h (60 to
  500 s each for the field accesses), out of time; Boolector: out of
  memory at 8 GB; allocating only the part of each region the code may
  touch (at most three words): out of memory at 8 GB with Boolector;
  unwinding bounds tightened to what the fixture needs (the undersized
  filler loops to 3, the first-fit walk to 4; 4732 instead of 8281
  assignments): out of time after 2 h with Bitwuzla and with Boolector.
  Multi-property Bitwuzla with the tightened bounds was not run. The VeriFast proof `free-list-search` (`heap/free_list.render`)
  proves `add_region` and `get_region` for any number of regions on both
  widths; this job is the bounded integration check on top of it.

What would work, as far as these attempts show: all three are bounded
fixtures whose cost comes from ESBMC resolving 64-bit addresses computed as
integers against every object (the same cause as core-entry and
gc-sweep-chunk, where removing those conversions or modelling the callee by
its proved contract was enough). The next step on the fixtures themselves
would be the same treatment: replace the integer-addressed metadata
accessors (`starts_for`, `mark_bits_for`, `cumulative_mark_bits_for`) by
models over the harness's own arrays, justified by `gc-metadata-access`
and the VeriFast table proofs, so that the planner, the setup check and the
region walk store through typed pointers. A scoping pilot found that a
Rust+Verus rewrite of the collector proves the young-generation copy for
heaps of any size without admits; the plan is to prove the collector that
way and retire these bounded fixtures, so no more solver time went into
them.

**Restructured (2026-11-24).** Jobs that had no verdict and now have one,
with what made them expensive and what changed. Times and peaks are run.sh's
own records (`model-check-*.tsv`), measured with other agents' matrices on
the machine:

* `core-entry` and `core-entry-checked` (`../harness/core_entry.cc`, both
  widths). Cause: `Interpreter::run_v2` and `v2_program_tables` clear the
  `toit_v2_context` and its `toit_v2_program` with `memset` before filling
  them. ESBMC's byte-wise memset turns every pointer field into a value
  rebuilt from bytes: an integer-to-pointer conversion, resolved against
  every object of the address space. That made 253 conversions on LP64
  (133 on ILP32) and a 106 MB SMT formula for a single claim; at 2.5 GB
  Bitwuzla, Boolector and CVC5 ran out of memory and Z3 failed (Bitwuzla
  had not finished with 36 GB before). Fixing all of the harness's
  nondeterministic choices (policy arities, table verification, task
  switch) still ran out of memory at 3 GB.
  Change: the harness replaces `memset` in `interpreter_v2.cc` (its only two
  calls) by a model of its footprint: it asserts that the call clears one
  whole record with 0, and overwrites exactly that record with arbitrary
  contents. That is an over-approximation of memset (zeros are among the
  arbitrary contents, and the footprint is the same), so the union covers
  the old claim: the same harness assertions over the same input space,
  now for every initial content of the records; ESBMC still checks the
  typed store (valid, aligned, in bounds). The formula is 1.3 MB.
  Verdicts: core-entry/LP64 457 properties in 10.6 s, peak 0.43 GB;
  core-entry-checked/LP64 458 in 11.6 s, 0.43 GB; core-entry/ILP32 459 in
  6.3 s, 0.36 GB; core-entry-checked/ILP32 460 in 6.3 s, 0.36 GB. All four
  are now in the fast tier. Mutants (`cpp_violation`, both widths, 3-4 s
  each, each must report its property violated): `core-entry-stale-epoch`
  passes a copy of the epoch instead of the live word ("the core observes
  this process's epoch and allocation window in place");
  `core-entry-trusted-table` and `core-entry-checked-trusted-table` admit an
  untrusted process to the verified loop with a table accepted only under
  the trusted rules ("untrusted execution uses only the admitted verified or
  checked loop"); `core-entry-no-exit-barrier` drops the remembered-set
  barrier after the core returns ("remember the stack of the task running
  when the core returns").
* `gc-sweep-chunk` (`../harness/gc_sweep_chunk.cc`, TRUSTED.md's
  three-card sweep fixture, both widths). Cause: the sweep addresses the
  heap through integers (`chunk->start()` plus card offsets), so ESBMC
  cannot see the word offset of a store and splits each word store into
  WORD_SIZE byte updates at a symbolic offset. On ILP32, 1560 of the 2578
  versions of the payload array came from `fill_unmarked_words`' loop
  (`sweep_empty_cards.h`). Bitwuzla ran out of memory at 16 GB on both
  widths; in multi-property mode it proved 370 of the 407 properties and
  then ran out of memory at 8 GB; a case split on the shape of the gaps
  (leading, trailing) left the formula as large (the mark bits stay
  symbolic). Change: (1) the harness replaces `fill_unmarked_words` by its
  contract, which Frama-C/WP proves on both widths for the same header
  (`gc-page-scan-wp`: `fill_unmarked_words_ensures`, `_ensures_2`,
  `_assigns`, with its run-time-error goals): the model asserts the
  contract's precondition for this fixture (`first <= 32`, 32 aligned
  words inside the payload) and stores whole words; (2) Boolector instead
  of Bitwuzla. With the model alone Bitwuzla still ran out of memory at
  3.5 GB; Boolector without the model gave no verdict in 1 h on ILP32,
  with it ILP32 took 8 min. The union covers the old claim: the same
  assertions over the same nondeterministic inputs; the filler loop's
  body is proved by WP instead of being executed here. Verdicts:
  ILP32 407 properties, 478 s, peak 1.41 GB; LP64 402 properties, about 75 CPU-minutes, peak 3.3 GB (virtual 3.9 GB), measured outside run.sh because the machine was suspended for about 6 h during the run (its wall clock read 25346 s). Mutants (each
  must report its property violated): `gc-sweep-chunk-uncounted` leaves a
  marked line after a gap out of the count ("count exactly the marked
  payload bytes"; ILP32 240 s, LP64 no verdict within the fast tier's 600 s, not measured longer: it is listed as known not to finish), `gc-sweep-chunk-no-sentinel`
  does not repair the chunk-end sentinel ("restore the sentinel and clear
  the consumed mark table"; ILP32 429 s, LP64 258 s).

The fast tier's model-checker jobs took up to about 90 s each when
measured with a few jobs at once; with the whole fast tier and other
work on the machine some took up to 314 s (gc-compaction-card-rank/LP64),
within the fast tier's 600 s timeout. Their peaks were below 2.3 GB,
except the five with a `fast_cap` (2.4 to 7.0 GB resident).

## The rendering: generated, not hand-written

Decision: **a mechanical translator**, `verified/tools/cxx_render.toit`. For
every function a sidecar (`*.render`) names, it reads Clang's JSON AST of
the real source (`clang-ast.sh`, the build's standard and defines), prints
it as C by the fixed rules below, and weaves in the annotations of the
sidecar. A sidecar holds, per function, a copy of its C++ text with the
VeriFast annotations (`//@ ...`, `/*@ ... @*/`) inserted between
statements, exactly as they would be written in place:

```cpp
@render src/messaging.cc toit::MessageEncoder::encode_array
bool MessageEncoder::encode_array(Array* object, word from, word to)
//@ requires encoder(self, ?ids) &*& self->nesting_ |-> ?n &*& ... &*& [?f]heap(?objs, ?H) &*& ...;
//@ ensures encoder(self, ids) &*& self->nesting_ |-> n &*& [f]heap(objs, H);
{
  if (from < 0 || from > to || to > object->length()) return false;
  write_uint8(TAG_ARRAY);
  write_cardinal(to - from);
  for (word i = from; i < to; i++)
  //@ invariant encoder(self, ids) &*& self->nesting_ |-> n &*& [f]heap(objs, H) &*& from <= i &*& to <= o_len(H(object));
  {
    if (!encode_any(object->at(i))) return false;
  }
  return true;
}
```

The copy is compared **token by token** (comments and whitespace aside) with
the function in the current sources; any difference is a drift error that
names the file, line and token. An annotation is anchored at the token that
follows it. The generated C (`*.gen.c`, committed for review, and the
32-bit one under the artifacts directory) is what VeriFast verifies;
`render.sh --check` fails when it is not what the sources and sidecars give.

What else is checked mechanically, so that the C means what the C++ means:

* **Constants.** Every constant a rendering uses is in one table,
  `model/constants.h`. For every place of use the translator writes a
  `static_assert` that the C++ constant, looked up where the code uses it
  (a struct derived from the class, for an unqualified name), has the
  table's value and type (`*.gen.constants.cc`); `constants-check.sh`
  compiles them for x86_64 and i686 (80 checks today). The same headers
  are the reference of verified/layout_check.cc for the Rust side, so the
  two models' layouts are tied to one source. A wrong value fails (the
  error indices of `FAIL` were found that way).
* **Overloads.** One C name is one C++ function: the translator records the
  canonical parameter types of every call and definition of a C name
  across all units and fails on two (`@overloaded` puts the types into the
  name).
* **Both widths.** The rendering is made again from the i686 AST (the
  implicit conversions differ: `int` is a word there) and verified with
  `-target ILP32`.
* **Drift self-tests.** `run.sh` changes a rendered function in a copy of
  the source only (a bound off by one, a strict comparison made non-strict)
  and requires the drift error.

The rules (all in the translator's header; anything else is an error, the
tool never guesses):

| C++ | C rendering |
|---|---|
| `T C::m(args)`, `this` | `T C_m(C *self, args)`, `self`; field `f` of `this` is `self->f` |
| static member, constructor, destructor | `C_m(args)`, `C_ctor(C *self, ...)`, `C_dtor(C *self)` |
| `obj->m(a)` on static class C | `C_m(obj, a)`; `obj.m(a)` is `C_m(&obj, a)` |
| `C::N`; unqualified `N` in class C | `C_N`; `C_N` if in the table, else `N` (checked at the place of use) |
| implicit conversion | a cast, except lvalue-to-rvalue, no-op, decay, derived-to-base (all classes are one opaque struct) and an integer literal's conversion; to bool is `!= 0`; nullptr is `0` |
| `T&` parameter / `const T&` | `T *` (argument by address, use `(*p)`) / `T` |
| local of a `@raii` class | destructor call at every exit from its scope |
| `return e;` followed by annotations | `{ T r = e; annotations; destructors; return r; }` |
| local whose address is taken | declared at the start of its block, initialized in place |
| discarded `std::atomic<uword>::operator+=` or `operator-=` | A single atomic addition or subtraction on the selected counter. The proof contracts create or consume the charge for the exact byte count. |
| release `ASSERT(c)` (`while (false && (c)) {}`) | a comment (never evaluated) |
| `while (auto p = expression)` with a pointer condition variable | A fresh local is initialized and tested at the start of each iteration. A null pointer exits the loop before the body runs. |
| a reference spelled in a macro | named by its declaring class (Clang's declaration ids) |
| `@render ... trusted` | the prototype and contract only; the body is still compared with the source |
| nested class `A::B` | struct `A_B`, members `A_B_m`, constructor `A_B_ctor`; an unqualified constant of an enclosing class is `A_N` (checked as `A::N`) |
| `a = C(x)` with the implicit assignment operator (Clang's `isImplicit`) | `{ C tmp; C_ctor(&tmp, x); (a).f = tmp.f; ... }`: member-wise, what the implicit copy and move assignments do |
| `@expand-typedef T` | the typedef written as the type it stands for on the rendering's target (`uhalf_word`: unsigned int on LP64, unsigned short on ILP32) |
| Copy or move construction of a `Method` value | A C struct copy. Both ABI checks require a trivially copyable, standard-layout native type with its bytecode pointer at offset zero and the size of one pointer. |
| Subtraction of two unsigned-byte pointers | Subtraction of `char *` values with the same addresses. The spawn-method proof requires both pointers to belong to the same bytecode image and the difference to fit the result type. |
| a default argument (`CXXDefaultArgExpr`) | its value written out; literals only (the expression is spelled in the callee's file) |
| a call of an `@overloaded` member | named by the declared parameter types of the member it refers to (in its class or out of line), not by the argument types (which differ per target: a literal is `int` = `word` on ILP32) |
| `@render ... truncating` | an implicit word-to-int conversion is VeriFast's truncating cast (the modular conversion GCC and Clang define and C++20 standardizes); only for code that checks the round trip (the int arguments of ARGS). Also uword-to-word and uint64-to-int64 (the decoder's cardinals: `word length = read_cardinal()`, checked for the sign and against what is left), and uword-to-int (wave 4: decode_rpc_request_external's `*id = read_cardinal()`). For CRC, explicit casts between `int64` and `uint64` are modular, as is a `uint64` left shift by a literal in [0, 63]. For the process random generator, unsigned 64-bit addition also wraps modulo 2^64. Unsigned word subtraction wraps at the target word width in the scavenger’s address tests, as does unsigned word addition for the biased metadata addresses. Other shift counts retain the usual proof obligations. VeriFast knows nothing of the value of such a cast by itself; `truncate_signed_id` (model/truncate.gh, wave 4, proved with Z3) gives it for a value in the target's range |
| `switch (c) { case V: ... default: ... }` | written as is: the labels (values from the constant table), a label's statement and the statements up to the next label, fall-through, `break` |
| `a op= b` whose computation type is not a's (`cursor_ += sizeof(uint32)`: an unsigned long sum for a word) | `a = (A)((C)a op b)`: the conversions C++ makes, written; `a` must be a variable or a field chain (evaluated twice) |
| `@modular-arguments C::C` | the implicit integral conversion of a constructor argument to an unsigned parameter is VeriFast's truncating cast (the modular conversion C++ defines; HeapTagScope's custom tags are negative numbers in a uword) |
| Clang's `__size_t` (the type of sizeof) | `size_t` |
| `do S while (false)` (a macro's statement wrapper: INT64_VALUE_OR_WRONG_TYPE of ARGS) | `{ S }`; an error when a break or continue of S would leave the do |
| `@render ... truncating`, an explicit `static_cast` narrowing a signed integer (`static_cast<time_t>(int64)` on a 32-bit time_t; Clang's NoOp over an IntegralCast for a typedef) | VeriFast's truncating cast (for code that checks the round trip) |
| an object of a struct spelled with its tag (`struct tm tm;`, a C header's struct) | `struct tm tm; tm_ctor(&tm);` (the constructor named by the tag) |
| an embedded class object initialized by a constructor | calls that constructor on the field address in C++ initialization order |
| `type=A\|B` on a method template | selects the unique instantiated signature matching one alternative for the current target, including ABI-specific integer spellings |
| `@static-member C::field` | a reference to the enclosing class’s static storage uses the sidecar’s C global after checking the Clang declaration identity and storage class |
| a default member initializer (Clang's `CXXDefaultInitExpr`, wave 5: the decoder's `size_ = INT_MAX`, `status_ = DECODE_SUCCESS`) | `self->f = value;` written from the AST's values, never from source text (the expression is spelled in the class, another file): integer and boolean literals, null, enumerators of the constant table (checked in the class's scope); anything else is an error |
| a delegating constructor (`C(a) : C(a, K) {}`, wave 5) | the target constructor called on `self`: `C_ctor__T1_T2(self, a, K);` |
| an out-of-line constructor `C::C` (wave 5) | found although it is named like its class (the lookup took it for the class) |
| a loop whose body has no braces, with an invariant (wave 5: `for (...) deallocate();`) | the annotation anchored at the body's first token is the invariant, written before the added `{` |
| a lambda `[&]() -> R { body }` (wave 6: the closures of `v2_allocate`) | `struct F_lambdaK { T v; ... };` (F the enclosing function's C name, K its lambda's position) and `R F_lambdaK_call(struct F_lambdaK *closure)` with the body, a capture `v` being `closure->v`; where it is created, a local `struct F_lambdaK closureK;` (start of the block) gets the values (`closureK.v = v;`, just before the statement) and the lambda is `&closureK`. A capture by reference becomes a copy of the value, which is the same because the translator checks: the lambda only reads its captures (every use an lvalue-to-rvalue conversion), has no parameters, is not `mutable`, captures no `this` and no objects by copy; it is an argument of a call (it does not outlive the statement); the enclosing function never takes a captured variable's address or binds a reference to it, and the creating statement does not assign it. Annotations inside the lambda are its function's (the contract at its body's `{`) |
| `T* v = new (std::nothrow) T(args);` (the `_new` of src/top.h; wave 6) | `T *v = T_new_nothrow(); if (v != 0) { T_ctor...(v, args); }` (the allocation a function the sidecar declares); the arguments evaluated after a successful allocation (C++17's order; C++11 leaves it open), so they must not assign anything (checked); only as a local's initializer |
| `delete p` (not an array) | `T_delete(p)` for p's static class (destructor and deallocation: a contract the sidecar declares) |
| a non-virtual base-class constructor | Calls the selected base constructor on the sidecar's receiver representation, forwarding the constructor arguments with their conversions. The base body can be rendered, as in the callback node hierarchy. |
| a local that hides another (a nested block's `encoder`; VeriFast rejects hiding) | renamed with a suffix (`encoder_1`), references by the declaration's id; annotations use the rendered name |
| a call through a function-pointer local or parameter (`entry(process, args)`) | the C call through the pointer (its contract is the function type's) |
| a default member initializer `-N` | written out |
| `@render ... truncating`, a uint64 `-` or `*` whose right operand is an explicit cast (wave 10: Utils::wrapping_sub, wrapping_mul, wrapping_negate) | VeriFast's truncating operator (modulo 2^64, as C++ defines unsigned arithmetic); other uint64 differences and products stay checked |
| `@render ... truncating`, an explicit `static_cast<uint64>` of a word (wave 10: smi_unsigned_shift_right) | the modular conversion, as for an int64 |
| `@nested-type NAME OUTER::NAME` (wave 10: `Bytes ot(other);` in String::MutableBytes, where Clang's AST spells the type `Bytes`) | the type spelled NAME is the struct `OUTER_NAME` (its constructor `OUTER_NAME_ctor`, its members `OUTER_NAME_m`); the second word must end in `::NAME`; only in the sidecar that names it |
| a function template instance taking a closure (`@render FILE f lambda=ENCLOSING[#K]`) | the instance whose closure parameter has that lambda's type, as one C function `f__F_lambdaK`; the closure parameter is a pointer to the caller's struct (checked: the instance only calls it, `f()` being `F_lambdaK_call(f)`, so no copy escapes); the sidecar holds one copy of the template's text per instance |
| a member of `List<uint16>` (wave 12: the class bits table) | `List_uint16_m(&list, ...)`, the type `List_uint16` (like `List<uint8>`'s BytecodeList); the projections are the sidecar's |
| `@render ... truncating`, an int64 `>>` by a run-time count (wave 12: large_integer_shift_right) | `asr_int64(x, n)`, which the sidecar defines as the floor division without a shift of a negative value (as the `>>=` by a literal above; GCC's and Clang's arithmetic shift) and whose contract makes VeriFast check the count in [0, 63]; x evaluated once |
| `goto L;` and `L: S` (wave 12: smi_add) | written as is (`L: ;` then S: C before C23 allows no label on a declaration); a goto out of a scope with a destructor or in a macro is an error; in a function with a goto no local reuses a name (VeriFast takes a later one for one that hides it) |
| `auto v = bit_cast<T>(x);` (wave 12: float_to_raw) | the local is a T: Clang's spelling of its type is bit_cast's return type `typename std::enable_if<..., T>::type`, its desugared type T |
| `T a[] = { e0, ..., en };` of a scalar T with every element given (wave 12: string_from_rune) | `T a[n+1] = { e0, ..., en };` (C's initializer); the elements must have no side effects (no assignment, no call: C leaves their order unspecified, C++ evaluates them left to right) |
| `@render ... truncating`, an explicit `static_cast<char>` of an int (wave 12) | the modular conversion (char joined the signed targets of the narrowing rule above) |
| `@render ... truncating`, an implicit conversion of an int or a word to uint16, an explicit `static_cast<uint8>` of a char (wave 12: String::compute_hash_code_for) | the modular conversions C++ defines for unsigned targets |

Each rule added after the pilot has a self-test in `tests/rules.cc` and
`tests/rules.render` (rendered, compared with the committed
`rules.gen.c`, constants checked, verified on both widths).

### The other route: VeriFast's C++ front end in place

Tried (probes `probes/cxx_shim.cpp`, `cxx_shim2.cpp`). Routing the
integer-pointer conversions of `objects.h` through two functions is not
enough:

* the front end rejects **every pointer cast**, not only
  `reinterpret_cast`: `static_cast<uword*>(void*)` and C casts too ("Expression
  of kind 'CXXStaticCastExpr' / 'CStyleCastExpr' is not supported"); only
  integral `static_cast` passes. So one shim function per target pointer
  type (`uword*`, `Object**`, `uint8*`, `HeapObject*`, ...), and objects.h
  has 50 `reinterpret_cast`s and 12 pointer `static_cast`s to replace;
* a **template** shim (`template <T> T* vm_word_to_ptr(uword)`) does not
  parse: a contract cannot mention `T`;
* `static const` members (132 in objects.h) are **globals**, not constants
  ("No matching points-to chunk: ulong_integer(Object::HEAP_TAG, _)"); so are
  `static constexpr` ones;
* every member function needs `[_]C_bases_constructed(this)`: VeriFast
  models construction, and VM objects are never constructed;
* ghost casts to typedef'd pointer types do not parse (`(uword *)p`; only
  `(unsigned long *)p`).

In place, `objects.h` would need: `vm_ptr_to_word(const void*)` and one
`vm_word_to_X(uword)` per pointer type, used by every accessor instead of
the casts (bodies hidden from VeriFast under `#ifdef __VERIFAST__`); every
`static const` turned into an enumerator or a macro, or given a ghost
points-to fact; contracts carrying `[_]X_bases_constructed(this)` (from the
heap predicate); and the standard headers replaced (the pilot's `shim/`).
That is a rewrite of the header's idiom, with the risk in the C++ that
behaviour changes, for no more assurance than the generated rendering
gives. Not proposed; reporting the front end's missing casts upstream is.

## Status

`run.sh`: 66 sidecars (one the translator's self-test), 591 `@render`
functions (`metrics.sh`; the contract-only functions and the closures
among them were not recounted), proved for LP64 and ILP32;
reverted-bug and contract mutants, including an ILP32-only check, and
2 drift tests. Measured 2026-11-23 and -24 on fresh work directories
(32 cores shared with other work and with a slow-tier job): the fast
tier 1211 checks ok, 0 FAIL, 0 NOVERDICT, in 1954 s and 1986 s wall.
140 VeriFast proofs, median 0.8 s, 90th percentile 15 s. The long ones
(LP64 / ILP32) are utf16-to-8 (705 / 219 s; 420 s LP64 alone),
time_info (98 / 58 s), local_epoch (85 / 45 s), ffi (31 / 91 s), the
decoder (18 / 80 s) and the encoder (6 / 17 s). Earlier claims of 40 s
wall for the matrix and 0.1-4 s per proof were not reproduced.
utf16-to-8 and its mutants are the fast tier's critical path. Since wave 7
the model covers blobs up to 2^62 - 1 and class ids up to 2^31 on LP64
(every smi header on ILP32), and 25 primitives prove the retry
obligation (`oom_clean`, "The retry obligation"). After the merge of wave
7 (2026-11-24, fresh work directory, the main checkout's matrix running
at the same time): the fast tier 1215 checks ok, 0 FAIL, 0 NOVERDICT, in
1484 s wall (mutant ffi-allocate-string-unbounded added after that run,
checked on its own). Wave 8 (2026-11-24): 68 sidecars, 596 `@render`
functions (`metrics.sh`: the loader's error-root check, the integer
readers, two translator self-tests), 30 primitives prove the retry
obligation (`oom_clean` or `oom_unchanged`). Fresh work directory
(2026-11-24, the machine shared with other checkouts' matrices and
slow-tier jobs): the fast tier 1265 checks ok, 0 FAIL, 0 NOVERDICT, in
4303 s wall. Wave 9 (2026-11-24): 71 sidecars, 619 `@render` functions
(`metrics.sh`: the signed readers, the byte-array and float writers,
byte_array_at_put and byte_array_is_raw_bytes,
five translator self-tests), 37 primitives prove the retry obligation.
Fresh work directory (2026-11-24, the machine shared with other
checkouts' gate runs): the fast tier 1313 checks ok, 0 FAIL, 0 NOVERDICT,
in 2832 s wall, 61 MB left in the work directory. Wave 10 (2026-11-24):
77 sidecars, 669 `@render` functions (`metrics.sh`: string_at, the
allocating, string, float and integer primitives behind the Rust ports,
three translator self-tests), 63 primitives prove the retry obligation,
the C++ behind 44 of the 106 ports is VeriFast-proved. Fresh work
directory (2026-11-24, the machine shared with other checkouts' runs):
the fast tier 1363 checks ok, 0 FAIL, 0 NOVERDICT, in 1384 s wall, 62 MB
left in the work directory. Wave 12 (2026-11-25): 83 sidecars, 701
`@render` functions (`metrics.sh`: the install-time check of the builtin
classes, the bitwise and additive integer primitives, the raw float
conversions, string_from_rune, the blob primitives string_length,
json_skip_whitespace, blob_hash_code and hash_simple_json_string, six
translator
self-tests), 77 primitives prove the retry obligation, the C++ behind 62
of the 106 ports is VeriFast-proved, and the ESBMC harness
install_image_checks.cc checks the native install-time checks.
Fresh work directory (2026-11-25, RUN_JOBS=8, after the merge of
wip/collector-proofs at 5497a73c): the fast tier 1413 checks ok, 0 FAIL, 0
NOVERDICT, in 3474 s wall, 62 MB left in the work directory. Lines:
`metrics.sh` (C++ = the
rendered functions' lines; annotations among them; then the hand-written C
and annotations of the verbatim sections: trusted prototypes, predicates,
lemmas).

| Unit (sidecar) | Functions | Status | Assumptions | C++ / annot. / trusted C / annot. | Self-test |
|---|---|---|---|---|---|
| Object model (`model/objects.render`) | Process::program/on_program_heap, program_image_size, FlashAllocation::size_no_assets and Header::size, Program::root/class_id, Object::unmark, is_smi, is_heap_object, Smi::from/value/cast, HeapObject::cast/_raw/_raw_at (2)/_at/_word_at/_half_word_at/header/class_id/class_tag/has_class_tag, Instance::_offset_from/at/cast, Array::_offset_from/length/at/cast, String::_internal_length/content_on_heap/_external_length/_external_address/as_external/_as_utf8bytes/cast, String::Bytes (ctor, address, length), ByteArray::raw_length/has_external_address/external_tag/_offset_from/content (2)/_external_address/as_external (2)/cast (2), ByteArray::Bytes and ConstBytes (ctor, address, length), Double/LargeInteger::cast, LargeInteger::value/_initialize/_set_value, HeapObject::_int64_at/_int64_at_put, is_instance/array/byte_array/double/string/large_integer | verified | `Double::value` (contract only); `unsigned_cast` (a template: identity on `uint8*`); the heap predicate is the allocator/GC invariant (bridge `heap`): strings and byte arrays with internal or external content, an external byte array owning its bytes only when tagged RawByteTag | 422 / 486 / 73 / 936 | drift tests; the encoder's and byte_content's mutants exercise it |
| Spawn method (`prims/spawn_method.render`) | spawn_method, Process::spawn_method/group, ProcessGroup::v2_methods, Method::is_valid/header_bcp, Program::is_format2/absolute_bci_from_bcp, V2MethodTable::index_of_entry/entry_of | exact result for either image format, terminating binary search with in-bounds packed-record reads | loader supplies the image bytes, a valid method position and the sorted table for a format-2 lookup. The two const bytecode-list accessors and the trivial Method copy are checked against native types. | 54 / 50 / 9 / 61 | nonshrinking search interval, missing entry reported as zero, wrong format tag, wrong legacy sentinel |
| Finalizers (`prims/finalizers.render`) | add_finalizer, remove_finalizer, ObjectHeap::add_callable_finalizer/prepend_callable_finalizer/remove_callable_finalizer, all four callback-node constructors, the three finalizer nodes’ roots_do methods and RootCallback::do_root, HeapObject::has_active_finalizer/set_has_active_finalizer/clear_has_active_finalizer, _set_header, has_forwarding_address, forwarding_address | VeriFast checks argument decoding, the exact outcome on each path, the original argument slots, and the effect on the object header and callback registrations. Reading a forwarded header observes its destination. | VeriFast assumes successful allocation supplies fresh storage of the requested dynamic type, and assumes native deletion releases a detached node. VeriFast proves the ownership transfer on insertion and checks a hand-specialized removal loop for every finite queue. ESBMC compares the modeled link updates with native prepend on symbolic endpoints. The native unlink method and the removal proof body adapted to native types emit identical code in the two Clang -O1 checks. The header writes and preservation of the VM heap are verified separately. The shared process, program and heap contracts apply. | 120 / 96 / 33 / 160 | removes the read-only or instance guard, reverses the duplicate check, requests an ordinary callback for a weak map, changes the allocation error, skips the forwarding pointer, drops either header write, sets the wrong bit, allocates the wrong node kind, stores the key as the callback, overwrites the tail of a nonempty queue, skips tail repair on removal, reverses the removal key test |
| Blob decoding (`blob/byte_content.render`) | Object::byte_content (the recursive 5-argument one, the 4-argument one, the Blob one), Blob ctor, HeapObject::can_be_toit_finalized | verified: a successful result lies in the content of ONE live string or byte array (internal, or raw external: never a proxy's struct), a string for STRINGS_ONLY; recursion depth bounded by MAX_BYTE_CONTENT_DEPTH; heap read-only | the loaded image supplies a table of tagged class IDs that agree with its heap objects | 79 / 43 / 1 / 28 | 357d1127 (#3373): without the depth limit the recursive call fails at `depth + 1 <= 8`; without the slice's `to <= length`: the pointer leaves the blob |
| MutableBlob decoding (`blob/mutable_byte_content.render`) | Object::mutable_byte_content (5-argument, 4-argument, MutableBlob), MutableBlob ctor; model: Instance::at_put (with the heap update), HeapObject::_at_put, on_program_heap, heap growth and blob hole lemmas | verified: a successful result lies in the content of ONE live byte array (internal or raw external) outside the program heap; the heap only grows (the copy-on-write branch allocates, copies the immutable content with a legal memcpy and stores the new backing and `true`); recursion bounded | the allocator (`Process::allocate_byte_array`: a fresh byte array of the asked length outside the program heap, nothing else changed), `Process::on_program_heap` (an address range: `in_program_heap`), the true object is a heap object, the write barrier (card table outside the model), the error roots | 76 / 54 / 4 / 2 | 357d1127 reverted here too: the recursive call; without the program-heap check: `in_program_heap == false`; without the external tag check (both decoders): `blob_ok` |
| Message encoder (`encoder/`) | encode_any (all branches), encode_array, encode_list, encode_map, encode_copy (inline, out-of-line copy with its malloc and terminator), encode_byte_array (transfer, deduplication), reserve_external, is_too_large, size, total_size, encoding_for_size, encoding_tison, the writers write_uint8/cardinal/pointer/uint32/uint64, TisonEncoder::encode and payload_size, NestingTracker ctor/dtor; the cardinal's byte bound (`cardinal.c`, Z3) | verified: memory safety (reads inside objects, blob copies inside the blob found by the proven byte_content, writes inside the buffer, the tables copied_/transferred_ written below MESSAGING_ENCODING_MAX_EXTERNALS), no overflow or lossy conversion on either width (cursor_ + external_bytes_ stays below the limit plus ENC_SLACK = 32), heap read-only | **ONE assumption: `two_pass_room`** (below); contract only: `Process::policy`, `PrimitivePolicy::restricts_messaging`, HeapTagScope, `bit_cast`; the malloced copies are leaked into the table (ownership not modelled) | 334 / 230 / 51 / 116 | f708ad5d: count (underflow at `to - from`), read past the backing (loop bound), map past the backing; the 32-bit size fix weakened in encode_copy and in the transfer (the size bound fails; on ILP32 the sum overflows); one reservation too many (the table bound fails); the terminator read from the content (memcpy past the blob) |
| Message decoder (`decoder/`) | TisonDecoder::decode (tison_decode's untrusted input), MessageDecoder::decode (IPC), decode_any (the switch, every tag), decode_string, decode_byte_array (both inline: copies; out of line: IPC blocks), decode_array, decode_map, decode_double, decode_large_integer, decode_integer (wave 4: canonical integers), decode_external_data and decode_rpc_request_external (wave 4: the external message handlers; the data handed out is an out-of-line block of the message or a malloced copy, `ext_data`), read_uint8/cardinal/cardinal_64/uint32/uint64/pointer, register_external, success, decoding_tison, overflown, remaining, externals_count, mark_malformed, mark_allocation_failed, NestingTracker; the digits' bound (`radix.c`, Z3); model: Array::at_put, Instance::at_put(Smi*), Smi::zero, the allocator's contracts | verified: for any input bytes (TISON) every read is inside the input (past the end the readers return 0), the cursor stays below the length + 16 on both widths, every length is checked against what is left before the copy or the allocation of that size (`length <= cap - c`, asserted), the recursion is bounded (64), a cardinal fits 64 bits and a length the word, integers are canonical (a large integer only outside the smi range: the allocator contract requires it), the externals table is written below its bound (the FATAL), the heap only grows (new objects; the new array's elements and the map's fields written), a success is a good reference and TISON consumed its input exactly; a failure leaves a well-formed heap | TISON: none beyond the model and the allocator; IPC: **two named assumptions, `ipc_room` and `ipc_external`** (below); contract only: the allocator (CONTRACTS.toml, C++-only contracts), `bit_cast`, `fail`, `Array::max_length_in_process` | 587 / 619 / 70 / 694 | seventeen checks taken out, each rejected on both widths unless noted: the length checks before the inline string and byte-array copies, before the array and map allocations, the nesting limit (#3362), the fixed-size readers' bound (read_uint64; read_uint8 in the header), read_cardinal_64's size check (#3362) and digit check (wave 3), read_cardinal's word check (ILP32 only: dead on LP64), the two smi magnitude checks and decode_integer's smi range check, decode_external_data's two inline length checks (wave 4), the externals table bound |
| Receive path (`decoder/`, wave 5: the ownership of the out-of-line blocks) | the primitives task_receive_message, main_arguments, spawn_arguments (every path: finalizer to run, no message, monitor notification, system message decoded / allocation failure / malformed / allocation of the result array failed); MessageDecoder's three constructors (delegating, default member initializers), allocation_failed, malformed_input, register_external_allocations, remove_disposing_finalizers, deallocate (static, and the recursive walk); SystemMessage's destructor, free_data_and_externals, free_data_but_keep_externals, data/type/gid/pid; the decoder's out-of-line branches, read_pointer, register_external and mark_allocation_failed with ownership | verified: no leak and no double free of a message's buffer and blocks on every path. The message (`msg_whole`) owns its buffer and its blocks; read_pointer hands out block j of the message (in order), a decoder for a process lends it to the object it allocates (`finalized`: the VM finalizer frees it), keeps it when the allocation fails; on a failure remove_disposing_finalizers takes every lent block back (the message is whole again: retried or deleted), on a success every block was lent and only the buffer is freed; deallocate frees each block once and all of them. The primitive heap contract up to finalizer bits (`grows_class`: classes and lengths kept). Since wave 8: a result the retry protocol retries (`oom_error`) leaves the mailbox (its first message queued and whole) or the arguments slot unchanged | **the IPC assumptions, now seven narrow ones** (`ipc_begin`, `ipc_room`, `ipc_pointer`, `ipc_external`, `ipc_length`, `ipc_end`; none creates ownership) and the GC's `gc_owns` (CONTRACTS.toml); contract only: the mailbox and the arguments slots of a process (`mailbox`, `queued`, `dying`, `main_args`, `spawn_args`: a queued system message owns encoded data, its type, gid and pid are smis), `HeapObject::clear_has_active_finalizer` (gives the block back: the GC side, which 05159afd fixed), the allocator's external string and byte array, register_external_allocation, callback root validity, virtual callback dispatch, native node deletion, ObjectNotifier | (in the decoder's row) | receive-malformed-delivered and arguments-malformed-delivered (the 05159afd fix taken out: `st != MALFORMED` fails), receive-no-give-back, receive-give-back-bound (one finalizer bit left), arguments-drop-leak, receive-success-free-all (blocks freed under the objects), decoder-unregistered-block, deallocate-double-free, deallocate-leak, receive-oom-drops-message, arguments-oom-drops-slot |
| The Rust/C++ boundary (`ffi/interpreter_v2.render`, wave 6; stack growth since wave 1, formerly `grow/`) | toit_v2_grow_stack, Stack::v2_copy_to, Stack::v2_set_records; toit_v2_allocate_instance and toit_v2_allocate_double with their lambdas and the two instances of `v2_allocate` (closure rules); toit_v2_try_allocate_large_integer, _double, _array, _string, _byte_array; toit_v2_current_stack, ObjectHeap::task, Task::stack and Task::set_stack; toit_v2_primitive and v2_primitive_failed (the retry protocol), Primitive::unmark_from_error; v2_process | verified against both sides of CONTRACTS.toml's gc_grow_stack, gc_allocate_instance, gc_allocate_double, gc_call_primitive and allocator_* (contract_check.toit compares every conjunct): the VM state at a GC point is `vm(p, v, n)` (stack object, header fields, bytes, heap, epoch count), the GC's guarantee `gc_equiv`; at most three collections per call (the loop bounds), so an unchanged epoch word means nothing moved (the core keeps its views on that); a primitive runs only with its table arity on its frame's slots, the retry re-reads the current stack after each GC; the results are the allocator's objects (`alloc_post`) or the primitive's completion (`prim_done`) with the status and word the core gets | **three named assumptions** (`gc_equiv_trans`, `stack_copy_equiv`: the `stack` bridge as a lemma, `prim_retry`: a call that failed for want of memory has no visible effect, classified per primitive since wave 7, "The retry obligation"); contract only: Scheduler::gc (at most one collection, `gc_equiv` or nothing), the allocator (the model's, plus Process::allocate_string(word)), allocate_stack, the policy table (`PrimitivePolicy::at`: an entry's arity is what its function reads), the primitives (function type `Primitive_Entry`: prim_out, at most PRIM_EPOCHS task switches, an out-of-memory failure leaves the stack alone), v2_validate (debug aid), the write barrier | 332 / 322 / 35 / 374 | grow-stack-unbounded, grow-stack-word-range; ffi-primitive-arity (the arity check: the primitive's precondition fails), ffi-primitive-stale-stack (the stack read before the GC: the arguments' address is not the current stack's), ffi-primitive-retries and ffi-allocate-retries (a loop bound: more collections than the epoch accounting allows); wave 7: ffi-allocate-string-bound (wave 6's check back: its conversion of a length above INTPTR_MAX fails) and ffi-allocate-string-unbounded (lengths up to INTPTR_MAX let through: the allocator's blob bound fails), and no length precondition on the string and byte-array entry points any more |
| Array initialization (`ffi/array_init.render`) | `Array::_initialize_no_write_barrier`, both slot writers and the length setter | from uninitialized storage, sets the length and initializes every slot to the supplied filler | allocation of the fresh object and its header | see metrics.sh | skip the last slot |
| The external handlers' sender side (`sender/external_send.render`, wave 6) | ExternalSystemMessageHandler::send_ (data and encoder), reply_rpc; the encoder they use: the one-argument constructor, the destructor, take_buffer, encode_bytes_external, encode_rpc_reply_external, reserve_external, write_uint8/cardinal/pointer, size, encoding_for_size/tison; SystemMessage's constructor from an encoder (with its base class) and free_data_but_keep_externals | verified: the encoded buffer is freed once or handed over inside the message, the caller's data (a malloced block) goes to the receiver with a sent message, is freed on a failure with free_on_failure and stays the caller's otherwise, on every path (no message allocated, no receiver, quota); the write pass fits the buffer the size pass measured (exact byte counts: `card_len`, `reply_size`; no assumption), memory safety, no overflow, both widths | contract only: the scheduler's send_message (queues the message, or deletes it with free_on_failure, or gives it back), the message's allocation and deletion (only without a buffer: its references are the caller's), the process and VM accessors, strnlen; an external handler's encoder transfers nothing (neuter: `requires false`) | 166 / 145 / 64 / 256 | sender-encoder-owns-buffer (the fix reverted), sender-free-callers-data, sender-delete-with-buffer |
| Primitive `string_write_to_byte_array` (`prims/`) | the primitive with the ARGS/FAIL expansion (Blob and MutableBlob decoding by the proven byte_content / mutable_byte_content, word arguments), Blob/MutableBlob constructors and accessors | verified: the primitive heap contract in VeriFast terms (the heap only grows, objects keep class, length and external address), the copy inside the two contents (source: a string or byte array; destination: a writable byte array outside the program heap; the source range survives the destination's copy-on-write), legal memmove, and the retry rule (`oom_unchanged`, wave 8: an out-of-memory error leaves every old object unchanged) | the loader's error_roots_ok (the `process` predicate) | 15 / 60 / 4 / 21 | af4ba7ab: memcpy fails at its precondition; verifies with the two byte arrays assumed distinct; string-write-oom-after-copy |
| Primitive `time_info` (`prims/time_info.render`, wave 4) | the primitive with the ARGS expansion (int64 and bool), floor_div, floor_mod, is_leap_year, days_from_civil, weekday_from_days, utc_fields, os_localtime, equivalent_year, local_fields, Smi::is_valid32; model: Array::at_put(Smi*) | verified: for every int64 timestamp no signed overflow and no lossy conversion (coarse bounds of every step, lemmas per step so that the proof sees bounds, not division equations), every stored field a smi, the primitive heap contract; not the correctness of the dates | the C library's `localtime_r` (fields in their C11 ranges), memset of the struct, the implicit constructors (do nothing), `Process::false_object`, `fail` (UNREACHABLE) | 135 / 72 / 32 / 109 | the red-team round 4 overflow reverted (`days * SECONDS_PER_DAY` underflows); local_fields without its year check (the shift overflows); the primitive without its year check (not a smi; on ILP32 the conversion to word) |
| Primitive bitmap `byte_zap` (`prims/byte_zap.render`) | the primitive with the ARGS expansion (MutableBlob by the proven decoder; the int argument with its round-trip check, `truncating`), MutableBlob ctor and accessors | verified: the primitive heap contract, the memset covers exactly the destination's range in a writable byte array, a smi result, the retry rule (`oom_unchanged`, wave 8) | the shared argument-error proof, the loader's error_roots_ok | 12 / 30 / 4 / 2 | one byte past the end: the memset fails; byte-zap-oom-after-copy |
| Integer argument failure (`prims/argument_error.render`) | `Primitive::return_not_a_smi` | exact tagged error for a large integer or another VM value; preserves the heap | object model | 8 / 7 / 1 / 14 | return the type error for a large integer |
| Primitive `byte_array_is_valid_string_content` | Blob and integer arguments, range check and validator call | the validator receives a readable slice; the heap and argument slots are preserved; the result is a live heap reference or a tagged error | boolean roots | 13 / 34 / 7 / 6 | omit the upper bound |
| Process IDs (`prims/process_ids.render`) | two primitives, ID assignment and three accessors | exact current and boot IDs, permanent exhaustion at the representable limit | live process ID, VM singleton and scheduler lock | 26 / 16 / 10 / 17 | restart after exhaustion, weaken upper bound, change current ID, change absent boot ID |
| Heap limits (`heap/limits.render`) | Chunk::size, Space::size, combined byte count, growth and cap, limit installation, promotion flag, external allocation check and status | Space::size terminates and sums every chunk’s end minus start, preserving the list and its bounds. The calling code computes the post-GC limit and remaining capacity for all word-sized readings, including a combined size above the signed or unsigned word range. A request must have a nonnegative size that fits the remaining capacity. | The allocator supplies stable finite lists ending at their own anchors, ordered chunk bounds, and a combined size that fits a word. The external reading uses the atomic accounting checked below | 77 / 68 / 15 / 58 | count half of each chunk, count the old space twice, overflow in addition or doubling, omitted cap, exact fit, promotion at equality, negative request, inverted status |
| Heap chunk iterator (`verified/cxx/harness/chunk_iterator.cc`) | the native `ChunkList` const iterator used by `Space::size` and mutable iterator used by the young-space scan | the empty list stops at its own anchor, dereferencing a nonempty cursor recovers its chunk, and advancing a copy follows the forward link while preserving the original cursor. Construction creates an empty circular list. Appending a detached chunk joins it to the old tail and preserves its bounds. An existing mutable tail cursor advances to the newly appended chunk and then to the original end cursor. Unlinking it restores both endpoints | valid chunk and anchor links at the step being checked. The heap-limit proof uses these iterator operations for arbitrarily long finite lists. | — | empty, singleton and distinct endpoints on both word widths |
| External memory accounting (`verified/cxx/harness/external_accounting.cc`) | `ObjectHeap::external_memory`, `register_external_allocation`, `unregister_external_allocation` | ESBMC checks the deployed C++ with arbitrary starting counters. A registration adds exactly the requested bytes to the current count and the lifetime count (modulo 2^64). A release subtracts only from the current count. The unsigned reading preserves the entire word. | nonnegative sizes, sufficient registered bytes for a release, room in the unsigned current count for a registration, and ESBMC's atomic operations. The single-operation proof starts from arbitrary counters and also checks the empty-heap constructor. A separate two-thread harness checks every modeled interleaving of one registration with one release, with enough initial bytes and remaining capacity for either order. | — | native signed-limit crossing and release (`tests/ctest/heap-limits-test.cc`); replacing the atomic addition with a load and store loses an update in the two-thread harness |
| GC counts (`prims/gc_count.render`) | primitive, two accessors, counter increment and collection accounting | exact counter selection, updates for each collection type, rollover | live process heap with valid counters and the collection type returned by the collector | 25 / 13 / 4 / 7 | skip rollover, omit compacting collections from the full count, return the wrong counter |
| Primitive `word_size` | complete body | the returned smi encodes the target word size in bytes | Smi::from | 4 / 2 / 1 / 0 | return bits |
| The loader's error roots (`loader/error_roots.render`, wave 8) | Program::has_valid_error_roots | the result is exactly `error_roots_ok` of the root table's error slots (heap references at or above MAX_TAGGED_ERROR, pairwise different addresses); ProcessGroup::create refuses a program for which it is false, which gives the `process` predicate its conjunct (a process's program passed the check) | VeriFast's pointer_limits for the stored roots | 13 / 13 / 1 / 16 | the comparison with the next root left out; the heap check taken out |
| The install-time check of the builtin classes (`loader/builtin_classes.render`, wave 12) | V2Verifier::builtin_classes_error and its helper builtin_class_error, Program::class_tag_from_class_bits, Program::instance_size_from_class_bits, Instance::fields_from_size | reads only the builtin class id table and the class bits at ids it checked against the table's length; a null result is `builtin_classes_ok` of the 23 ids (each a smi naming a class of the table that a 32-bit header can hold, with its tag and at least its fields); `prog_ok_from_check` (a proved lemma) gives `prog_ok` of the program's ids from it and `classes_agree` | the 23 builtin-id getters (macro-generated: contracts over the raw table, checked by ESBMC `program-class-ids-native` against the native getters and model/program_class_ids.h's indices, both widths); `classes_agree`: the model's class_tag and class_fields are the program's class bits (the heap bridge's meaning); the List<uint16> projections | 77 / 24 / 51 / 171 | the field check vacuous, the header bound left out, the list class with another tag, the range check one too weak |
| The install-time checks, native (`../harness/install_image_checks.cc`, wave 12) | image_layout_error (part 1), builtin_classes_error (part 2), ESBMC on LP64 and ILP32 | part 1: for tables at any offset from the image and arbitrary words in it, a null result puts every table and the method table literal inside the image with the readers' alignment, and no read leaves the image; part 2: the class bits are read only at checked ids | table pointers made by pointer arithmetic on the image and literal words not read from the Program's own fields (ESBMC's integer/pointer model: harness comment); builtin_roots_error not covered (no verdict in 30 minutes) | — | none: install-image-classes-range (the range check taken out, or one too weak) gave no verdict in 600 s on either width; the VeriFast mutants builtin-classes-* cover the check |
| The integer readers (`prims/read_bytes.render`, wave 8; the signed ones wave 9) | read_uint_big_endian, read_uint_little_endian, read_int_big_endian, read_int_little_endian (the C++ behind the Rust ports), Utils::wrapping_shift_left | every read inside the blob for any width and offset (negative ones become large unsigned ones and are rejected), no overflow or lossy conversion but the modular ones the C++ means (`truncating`, `unsigned-word-conversion`; the sign byte's uint8-to-int8, the shift by a run-time count whose range VeriFast checks), the heap unchanged up to the boxed result, `oom_clean`; not which integer the bytes give | the Blob decoder and Primitive::integer's contracts | 78 / 114 / 5 / 43 | the end check left out (a read past the blob); the little-endian loop one byte too high; wave 9: the old `width - 1` in int before the check (LP64: overflow for INT_MIN), the big-endian loop one byte too long, the little-endian sign byte one too high |
| The byte-array writers (`prims/put_bytes.render`, wave 9) | byte_array_replace, put_uint_big_endian, put_uint_little_endian (the C++ behind the Rust ports) | the MutableBlob decoded first (copy-on-write), the other arguments in the grown heap (`valid_arg`: is_large_integer, is_double and the Blob decoder take it); every write inside the destination's content (a writable byte array outside the program heap); byte_array_replace's legal memmove (the source may be the same byte array); no overflow or lossy conversion but the modular ones the C++ means (a value's low byte, the arithmetic shift `value >>= 8`); `grows`, `oom_unchanged` | the MutableBlob and Blob decoders' contracts, the error roots (`process`) | 52 / 141 / 5 / 45 | put_uint_little_endian's old `width - 1` (LP64), put_uint_big_endian's end check, byte_array_replace's length in the destination check, byte_array_replace reporting MALLOC_FAILED after the copy |
| The float writers (`prims/put_float.render`, wave 9) | put_float_32_little_endian, put_float_64_little_endian | 4 (8) bytes written inside the destination's content from the float (double) local; `grows`, `oom_unchanged`; not the bytes written | memcpy's contract for a float or double local (VeriFast has no float-to-bytes lemma); VeriFast's double-to-float conversion (math.h: total, as IEC 60559 defines it) | 31 / 72 / 4 / 25 | the 32-bit writer's end check two bytes weaker (one byte weaker still fits: the C++ is one byte stricter than needed), the 64-bit writer's offset check left out |
| Byte-array element writes (`prims/byte_array_access.render`, wave 9) | byte_array_at_put, byte_array_is_raw_bytes (the C++ behind the Rust ports: they decline for opaque byte arrays), ByteArray::Bytes::is_valid_index and at_put | the write only into the content of an internal or raw external byte array outside the program heap (asserted), at an index checked against it; an external byte array of another tag (a resource proxy) fails before its bytes are touched; the value's low byte (`truncating`, an explicit int64-to-uint8 conversion); `oom_clean`. Not byte_array_at and byte_array_length: they also read a mapped file's bytes (MappedFileTag), which the heap model has no bytes for | the object model's byte arrays | 27 / 34 / 2 / 1 | the program-heap check left out; the index checked only against zero |
| Allocation by size (`prims/allocating.render`, wave 10) | byte_array_new (the C++ behind the Rust port) | the int arguments' round trip (`truncating`), a non-negative length, the allocator's new byte array of that length, the memset inside its content; `grows`, `oom_clean`; the result an error with the heap unchanged or the new byte array | the allocator's contract (`Process::allocate_byte_array`) | see metrics.sh | the memset one byte late |
| Array expansion (`prims/array_expand.render`, wave 10) | array_expand, Array::copy_from, Array::content, Array::fill, Array::at_put_no_write_barrier, Utils::min (the C++ behind the Rust port) | the copy of min(length, old_length) words reads inside `old` (old_length checked against its length) and writes inside the new array (memcpy of the words as bytes: the prelude's exact pointer/char round trips), the fill writes inside it; the result's elements are the copied prefix and the filler (all good references: the heap invariant), every old object unchanged; `grows`, `oom_clean` | the allocator's contract (`ObjectHeap::allocate_array`), the write barrier's | see metrics.sh | old_length unchecked against the old array, one word more copied |
| String concatenation and slicing (`prims/strings.render`, wave 10) | string_add, concat_strings (the static helper and the primitive), string_slice, is_validated_string, utf_8_continuation_byte, String::MutableBytes::_initialize (both copy overloads), String::Bytes::at (the C++ behind the Rust ports) | every read inside the parts (the proven Blob decoder) and the receiver, every write inside the new string, the sum of the parts' lengths checked against MAX_CONCATENATION_LENGTH before it is added (no overflow, at most MAX_BLOB), the result's length (the sum; to - from), concat_strings' two decodings of each part equal, the primitive heap contract, `oom_clean` | the allocator's contract (`Process::allocate_string`), the Blob decoder's | see metrics.sh | the bound one byte higher (both), a failed part used, the slice's copy one byte longer |
| Boxed doubles (`prims/float_ops.render`, wave 10) | the eleven float primitives that box one double (the C++ behind the Rust ports) | the argument decoding (double, or smi / large integer / double for number_to_float), the result a new double or the allocation-failure error with the heap unchanged, `grows`, `oom_clean`; not the value | binary64 arithmetic, libm's fmod, sqrt, ceil, floor, trunc (contracts `requires true; ensures true`: no memory), the allocator's double | see metrics.sh | float_add returning its receiver |
| Integer arithmetic (`prims/int_ops.render`, wave 10) | ten integer primitives and Utils::wrapping_add, _sub, _mul, _negate, _shift_left (the C++ behind the Rust ports) | the argument decoding, the modular uint64 arithmetic of the wrapping helpers (`truncating`), every shift count in [0, 63], the result a good reference (Primitive::integer: a smi or a new large integer) or an error with the heap unchanged, `grows`, `oom_clean`; not which integer | Primitive::integer's proof and the allocator's contract | see metrics.sh | a shift count unchecked (two) |
| Bitwise and additive integers (`prims/int_bits.render`, wave 12) | smi_and, smi_or, smi_xor, large_integer_and, large_integer_or, large_integer_xor, smi_add, smi_subtract, large_integer_shift_right, Utils::wrapping_add, wrapping_sub (the C++ behind the Rust ports) | the argument decoding, a bitwise operation of two smis a smi and of two int64s an int64 (the range lemma of `^` proved from the Z definitions: bitops.gh's `bitxor_signed_limits` states `|`), smi_add's `goto overflow` (both paths), every shift count in [0, 63] (asr_int64), the result a good reference or an error with the heap unchanged, `grows`, `oom_clean`; not which integer | Primitive::integer's proof, the allocator's contract | 93 / 106 / 9 / 170 | the shift count check left out, smi_xor's large path stored in a smi |
| Raw float conversions (`prims/float_raw.render`, wave 12) | float_to_raw, float_to_raw32, raw_to_float, raw32_to_float (the C++ behind the Rust ports) | the argument decoding, raw32_to_float's 32-bit check (the modular conversion and shift, so that the uint32 conversion is exact), the result a new double, a good reference or an error with the heap unchanged, `grows`, `oom_clean`; not the values | bit_cast (contract only, as in the encoder and decoder), VeriFast's double/float conversions, Primitive::integer and the allocator's double | 25 / 30 / 9 / 47 | raw32's range check left out, raw_to_float returning its argument |
| Primitive `string_from_rune` (`prims/string_from_rune.render`, wave 12) | string_from_rune (the C++ behind the Rust port) | the int argument's round trip, INVALID_ARGUMENT outside [0, MAX_UNICODE] and for a surrogate, the bytes in a local array of the sequence's length (the array-initializer rule; each byte the modular int-to-char conversion), the proven Process::allocate_string copying exactly that array, the result a new string of 1 to 4 bytes or the allocation-failure error with the heap unchanged, `grows`, `oom_clean`; not that the bytes are the encoding | the allocator's contract (`Process::allocate_string(word)`) | see metrics.sh | the four-byte branch allocating 5 bytes |
| Blob primitives (`prims/blob_helpers.render`, wave 12) | string_length, json_skip_whitespace (the C++ behind the Rust ports) | the proven StringOrSlice and Blob decoders, every read inside the decoded content, the result a smi (a length, an index in [offset, length]) or an error; the heap unchanged | the decoders' contracts | see metrics.sh | json_skip_whitespace's loop one byte past the end |
| Hashing blob primitives (`prims/blob_hash.render`, wave 12) | blob_hash_code, hash_simple_json_string, String::compute_hash_code_for (the C++ behind the Rust ports) | the proven Blob decoder, every read inside the decoded content (the hash reads the slice it is given: the blob, or the bytes from the offset to the closing quote), the hash's modular uint16 arithmetic (`truncating`), the result a smi or an error; the heap unchanged; not which hash | the decoder's contract | see metrics.sh | hash_simple_json_string hashing one byte past the quote |
| Primitive `string_at` (`prims/string_at.render`, wave 10) | string_at, Utils::is_utf_8_prefix; bytes_in_utf_8_sequence and payload_from_prefix from `utf8/` | every read inside the decoded string or slice (StringOrSlice: the proven Blob decoder) for any bytes, the sequence length at most 4 before payload_from_prefix, no overflow in the decoded value, the heap unchanged; the result a smi, the null object or an error | the Blob decoder's contract | see metrics.sh | the fix reverted, either half of it taken out |
| UTF-8 (`utf8/`) | Utils::utf_8_to_16, bytes_in_utf_8_sequence, payload_from_prefix | verified (Z3) | none | 57 / 45 / 1 / 169 | 07c24665: UB shift at payload_from_prefix; without the length check: the read past the input. Also checks sizing failure, surrogate width and initialization of the second output unit. |
| UTF-16 (`utf8/utf_16_to_8.render`) | Utils::utf_16_to_8, Utils::utf_16le_to_8, read_utf16le_unit | verified (Z3) | readable little-endian byte pairs and an optional writable byte buffer | 60 / 73 / 1 / 70 | byte order, four-byte lead, surrogate replacement, output capacity and write count |
| Rust raw memory (`rust/`) | view.rs: string_len, string_byte; trial: field, array_length, element | verified (VeriFast Rust, host) | predicates over the words (bridge `heap`) | — | `i <= len` fails at the read |

Not attempted, in order of exposure, with what blocks each:

| C++ | Blocker | Estimate |
|---|---|---|
| the two-pass assumption of the encoder, proved | a ghost encoding function (fixpoint over the heap and the encoder state: cursor, externals, transfers, the early stops) shown to be what both passes compute, the write pass ahead by TISON's payload cardinal | 5-7 days |
| take_buffer, the destructor, encode_bytes_external, encode_rpc_reply_external, encode_arguments, encode_bundles | trusted callers (C or the boot), not reachable with untrusted data; the copied_ table would need its ownership modelled (the malloced copies) | 1-2 days |
| the decoder's remaining callers and the rest of the sender side: tison_decode (the Blob argument is the content of a heap object, which the allocations must not touch: the allocator's contracts over `heap_holes`), ExternalSystemMessageHandler::run (the handed-out block: decode_external_data gets it from the message, wave 5), process_send and spawn (the encoder's copies of any object graph and its transfers: take_buffer neuters byte arrays, a heap change; the scheduler's send_message_from with its policy checks; the mailbox quota accounting of Process::_append_message and remove_first_message). Wave 6 did the external handlers' sender side (`sender/`): its encoder model (`ext_encoder`, copies owned in the table) is the start for the general encoder | the encoder unit's tables with ownership of the copies (enc_tables) and of the transferred bytes; the holes form of the allocator's contracts. Wave 7: reviewed (the mailbox quota accounting, ExternalSystemMessageHandler::run, process_send's failure paths with the allocation-failure test): no bug; not proved | 3-4 days |
| the IPC assumptions (`ipc_room`, `ipc_external`), proved | the encoder's ghost encoding (the two-pass assumption's) as the decoder's input: decoding it reads what the encoding wrote | with the two-pass proof, 3-4 days more |
| ProgramOrientedEncoder / EncodeVisitor (encode_error, encoder.cc) | Object traversal and the program and stack data used to produce a trace. The native output buffer has a separate LP64 and ILP32 proof. | 4-5 days |
| toit_v2_allocate_exception (Verus contract gc_allocate_exception), toit_v2_allocate_array (the checked loop only) | a word from Rust stored as an object reference (the exception's value or the checked loop's filler): in VeriFast's C model an integer-to-pointer cast has no provenance, the model's references are pointers with provenance; either an address-based `good` in the model or `-assume_no_provenance` for these functions alone (the exposed-provenance semantics the Rust side has, `IsExposed`); the exception also needs encode_error. Wave 7: VeriFast 26.10 documents `-assume_no_provenance` as unsound even at -O0, so the route is a translator rule rendering `reinterpret_cast<Object*>(w)` as a contract-only conversion (`requires` the word encodes a member of objs or a smi, `ensures good(objs, result) && (uword)result == w`: the exposed-provenance step, one named assumption) | 1-2 days (the provenance), 4-5 days with encode_error |
| the fields of a new instance (null), a double's bits, a byte array's zeros (Verus `new_instance`, `Body::Double(bits)`, `Body::Bytes(0...)`) | outside the VeriFast heap model (only the header of a double is modelled; blob contents unconstrained): the allocator's contract cannot say them. Why it is harmless (wave 7): the Verus side's payload clauses are claims about the allocator (src/heap.cc writes the null object into every field before the header, `_initialize(value)` the double, `_initialize_no_write_barrier(length, filler)` the elements, the byte arrays are cleared: the `byte-array-initialization` check), which is GC-class trusted code like the `heap` bridge itself; no rendered C++ reads a payload it did not write, so no VeriFast proof depends on them | 1 day (payload words in the model) |
| the remaining C++ primitives of the untrusted set (see the coverage inventory below) | Task, message and timer primitives depend on scheduler contracts | 0.5-1 day each |

The C++ write guard checks membership in the half-open interval starting at the
loaded program's address. The process constructor caches the byte length from
the flash header's 16-bit page count. VeriFast proves that conversion, including
the zero length for an absent program, and the address comparison used by
mutable blob decoding. ESBMC checks the native packed-header read and compares
the guard with a wider-integer interval for arbitrary machine-word inputs on
both ABIs. The native harness also checks the address and length written by
`v2_program_tables` for Rust. The cross-language layout test checks both offsets.
The loader still supplies a live image of the declared length, and
the process invariant ties the cached length to that image.

CRC, time and decimal parsing share the proof of `Primitive::integer` in `prims/integer.render`.
A small result encodes its exact input and preserves the heap. Outside that
range the allocator either supplies a fresh large integer while preserving
all existing objects, or the primitive marks the allocation-failure root
and preserves the entire heap. The allocator contract supplies the new
object's class and payload. ESBMC checks the C++ allocation body given fresh
raw storage or exhaustion. It checks the requested size, class ID, tag and
full signed value. The initializer and getter copy eight bytes so a payload
can start at a four-byte boundary. VeriFast tracks those bytes through the
write and read and carries the payload equality to the Rust boundary and
primitive boxing helper. Raw space allocation and its relation to the
abstract heap remain trusted.
The CRC loop borrows each input slice for one read, so the data and byte
table may overlap. The list-table case checks the backing array and decodes
each selected entry. The primitive postcondition covers sandbox safety.
The CRC algorithm suites check the checksum values.

The encoder, decoder and blob validation primitive import the same generated
`Utils::is_valid_utf_8` declaration. VeriFast checks its C++ wrapper.
Frama-C/WP checks the implementation in `src/utf_8_validator.h` for each
word width. Given a readable slice of any nonnegative length, both ASCII
loops and the state-machine loop terminate, read within bounds and leave
caller memory unchanged. The word read uses the C library contract for
`memcpy`. The postcondition leaves the returned boolean unspecified.
Run `run.sh --quick utf8` for the validator and conversion proofs.

The object-model rendering imports contracts for `Smi::from`, both
`Smi::value` overloads and the signed 64-bit `Smi::is_valid` instantiation. VeriFast checks portable arithmetic definitions
in `model/smi.c` against the rendered declarations for each word width.
ESBMC compares the same definitions to the release C++ inline functions
in `src/objects.h`, for every in-range integer and every even tagged word.
The range test covers every signed 64-bit input on each target.
These operations have no loops or heap loads. The comparison
uses ESBMC's target semantics for pointer casts and signed shifts.
Run both checks with `run.sh --quick smi`.

The FFI rendering uses the release configuration with optional hardware profiling disabled.

### EC618 mailbox atomics

Run `run.sh --quick ec618-mailbox` for the source-level checks.

The Cortex-M3 code emitted for the event worker was checked once, in the
EC618 release build's event-source object and in both final format-2 slot
links (after `make ec618-relocations EC618_BYTECODE_FORMAT=2`), by a script
that has since been removed. That result is unchecked now (see [EC618
linked-image results](#ec618-linked-image-results-unchecked)). What it
covered: in a linked image, the resolved branch destinations and singleton
addresses; the relocation build separately compared the relocated canonical
body with the independently linked slot B. It checked the two publish loops,
UART exchange and completion-bit clear, including retry branches, barriers
and the position of the generation store and load, and followed startup,
both producer paths, worker dispatch and queue retirement. For a relocatable
object it checked the call relocation types, targets and branch addends, and
bound each singleton load or store to the same symbol at offset zero. Under
the Cortex-M exclusive-monitor and barrier semantics, each failed attempt
preserves memory and retries, and each successful attempt implements the
specified word update. Eventual success under contention is an additional
hardware and scheduling assumption.

The scheduler and completion-semaphore checks of the linked images were
likewise run once, independently of the historical allocator layout,
against the base ELF used for the slot links: both final format-2 slots
passed against base fingerprint `f0ae7c907be49d8af02ea2dbcfa6aecf`
(unchecked now).

### EC618 linked-image results (unchecked)

The checks of linked EC618 images (the base firmware ELF, built from the
vendor SDK, and the VM slot ELFs of an EC618 build) were Python scripts that
disassembled the images with ARM GNU objdump, read symbols and DWARF with
pyelftools, matched the Thumb instructions against expected encodings, and
ran Z3 or CBMC on models of the matched code. The images are not in the
repository; they come from an EC618 build (the base from the vendor SDK,
the slots from `make ec618` with the ARM toolchain), which the matrix does
not do. The scripts were removed on 2026-11-24 (no Python in the
repository), and no port replaces them. Nothing
checks the results below any more: each is a recorded observation about the
firmware builds named here, and is trusted. A new base or slot build has
none of them.

What is still checked:

- The SMT models the scripts ran on (`heap/ec618_*.smt2`: the memmove and
  memset loops, page classification, chunk admission and append, the
  scavenger's copy and capacity, object and external extents, object and
  process roots, the remembered-set scan, the survivor watermark, the
  small-block grant and release, the free-list buckets, arena return and the
  scheduler's resume countdown). `heap/smt-models.sh` runs Z3 (of Frama-C's
  opam switch) on each and requires its listed verdicts, in order: `run.sh
  ec618-smt`. Two self-tests (`ec618-smt-mutant/...`, not with `--quick`)
  make the page-classification bound and the survivor-space capacity test
  off by one and require a changed verdict. These check the models only:
  that a model is the linked Thumb code was the scripts' part and is
  unchecked.
- The source-level EC618 entries of the matrix (`gc-heap-range-ec618`,
  `gc-metadata-layout-ec618`, `gc-ec618-*`, `ec618-thread-spawn`,
  `ec618-thread-map`, `ec618-mailbox`, `ec618-mailbox-race`,
  `ec618-event-worker-start`), which run on the C++ sources.

Not checked: `heap/ec618_allocator_abi.c`, the CBMC model of the allocator
veneers, includes the instructions and addresses extracted from a base ELF
and has no run in the matrix.

The recorded results (current format-2 slots against base-v5 fingerprint
`f0ae7c907be49d8af02ea2dbcfa6aecf`, or the historical allocator ELF with
manifest fingerprint `b11a03ffa2790e3009abc87587810b4b` where stated):

- GC range, metadata reservation request and descriptor publication against
  the base used for linking; all six table placements, the initial page-type
  fill and the lookup arithmetic. The same metadata request through base
  heap registration and first-fit page allocation under the page ownership
  and exclusion contracts. Normal object-memory teardown and both setup
  rollback paths to metadata release, and the base allocator's release of a
  live page run.
- The linked chunk check: admission, construction of the initial spare,
  owned-chunk metadata fills, space insertion, object construction and
  collector size reads, scavenger spare selection, copy capacity, copying
  and forwarding, survivor and spare handoff, and page-type clearing before
  chunk release. Small-block bucket selection, splitting and zeroing, all
  four coalescing cases, boundary-tag repair, free-list updates, and the
  return of a fully coalesced arena to the page allocator. The scheduler
  proof on the same base, including SysTick and PendSV setup, and which
  task-tag table entries the linked allocator wrappers read and write.
- memmove (historical allocator ELF): the allocator call and the forward
  copy instructions matched, then loop initialization, termination, bounds
  and byte preservation for every lower destination and nonwrapping source
  range. A change in the matched code requires reviewing the instruction
  model against the new ELF.
- GC metadata fills, with the dynamic completion semaphore: its constructor,
  initial queue fields, worker give, join receive and deletion path; the
  linked count arithmetic for both possible token counts, including a second
  give to a full semaphore; the empty receive through its event-list calls
  and retry branches. The linked timeout helper preserves an indefinite
  wait; for finite waits, expiry and remaining ticks against a 33-bit
  elapsed-time model across at most one wrap between samples. The linked
  wake and queue-unlock paths: ready and pending-ready insertion, the
  priority comparison and the number of deferred wakes. For indefinite
  waits, event-list insertion and the transfer from the ready list to the
  suspended list; given a valid sorted list, equal-key ordering and every
  word changed by the insertion. For a single worker and exclusive joiner,
  completion-token publication, consumption and retirement, including
  preemption immediately on critical-section exit; the linked worker's
  remaining instructions and the joiner's queue release, descriptor release
  and handle reset.
- The direct branches used by chunk initialization and destruction to the
  base memset, and the loop's byte effect for every 32-bit length. For page
  classification, the compiled range test and fill arguments against the
  slot's debug field layout. The chunk initializer, executed symbolically:
  all four calls' byte values and extents against their tables. For
  firmware setup, the page-rounded reservation size, placement of all six
  tables, four commit calls, page-type fill and five stored biases on the
  successful path (the heap range nonempty with a representable page-rounded
  end). The release statistics wrapper, for the linker fallback and the
  registered range in the historical allocator ELF: the registration
  arithmetic, descriptor writes, both initial free-list fragment insertions,
  bounds loads and statistics output stores, assuming serialized
  initialization and preservation of the live allocator header by subsequent
  heap operations. For either reported range, the seven-page request into
  the base allocator, its compiled search against first-fit for every
  occupancy pattern, and the descriptor writes and zero-fill extent under
  exclusive ownership. Metadata teardown through base `free`: the status
  changes and counter deltas for every legal ordinary page extent and
  neighbor condition.
- The heap lock through task suspension, the application PendSV vector and
  suspended switch path, and the decrement on unlock. For the outermost
  resume, the linked list operations, ready queue selection, deferred tick
  replay count and PendSV request. Both list splice helpers decoded, with
  their exact memory effects, including cursor repair and the embedded
  sentinel. On first task registration, initialization of all 61 list
  headers and publication of the delayed-list pointers; the task
  constructor's item owners, container fields and priority clamp. The task
  frame: the dynamic creation path, initial register slots, saved stack
  pointer and SVC restore layout for valid word-aligned stacks of 18 to
  65,535 words. The linked tick path: suspended tick accumulation,
  wraparound, removing the due prefix, moving tasks to their ready queues and
  the resulting yield decision, assuming valid scheduler objects, priorities
  and sorted delay lists. Interrupt-side heap access remains a dependency.
- The allocator ABI (historical allocator ELF): the linked implementations
  of `aligned_alloc`, `malloc`, `realloc` and `free` followed to their port
  entry points, with the arguments, the original return address, balanced
  stack use and the early return for `free(NULL)` (11 CBMC properties).

The separate `ec618-thread-spawn` ILP32 gate of the matrix extracts the
current VM wrapper and checks admission, publication and failure cleanup
under modeled RTOS calls. It also exercises synchronous entry, joining
before or after completion, and immediate resource reclamation when the
worker signals. It runs the production thread map through parent/worker
switches, including worker completion inside the modeled RTOS task creation
call. The `ec618-thread-map` gate checks lookup, insertion, replacement and
removal in the configured map, including cache publication at interrupt
mask restoration.

### The primitives of the untrusted set

The untrusted policy allows 141 core primitives, `bitmap.byte_zap`,
`bitmap.blit` and the 7 timer and events primitives
(docs/sandbox-primitive-audit.md). 106 core primitives run as proven Rust
ports for untrusted programs (verified/core/src/prims: **Rust-verified**).
The other 44 are C++. Their status here: **VeriFast-verified** (the
primitive's body, with its ARGS expansion, proved), **ESBMC-verified**
(the native primitive and argument macros model-checked on LP64 and ILP32), **partly** (the C++
it calls on untrusted data proved, the primitive's own glue contract
only), **contract-only** (only the primitive contract of TRUSTED.md
section 8, which the Rust proof assumes; reviewed and fuzzed by the
audit).

| Primitive (C++) | Status | What is proved |
|---|---|---|
| `task_receive_message` | VeriFast-verified (wave 5) | Message ownership on every path and the heap contract up to finalizer bits. A pending callback takes priority over the mailbox. The proof identifies its closure and the resulting runnable and registered lists. Since wave 8 an out-of-memory result leaves the mailbox unchanged (its first message queued and whole). |
| `main_arguments`, `spawn_arguments` | VeriFast-verified (wave 5) | as task_receive_message |
| `task_has_messages` | VeriFast-verified | negative allocation allowance returns the exact marked allocation error. Otherwise the result is the process boolean for a runnable finalizer or a nonempty mailbox. The heap and mailbox are preserved. The rendered readiness accessor checks the runnable queue’s head. The allowance, mailbox peek and cached boolean accessors supply the other observations. |
| `random` | VeriFast-verified | returns the low 28 bits of the xorshift128+ output as a nonnegative Smi. The proof covers both state words, the exact seeded transition, and the modular sum. The seed-copy proof covers every buffer length, including partial words, and preserves the input. On the entropy-mixer path the first draw either fills the seed or triggers a full fallback fill. The entropy provider and the EC618 hardware path remain trusted. |
| `get_real_time_clock` | VeriFast-verified | a successful call returns a fresh two-element array containing the sampled seconds and nanoseconds in order, including boxed values. Covers array allocation failure, clock failure, and failure to box either integer. Assumes the OS clock and shared allocation contracts. The checked Linux ABIs use signed long for both fields. |
| `time_info` | VeriFast-verified (wave 4) | no overflow or lossy conversion for any int64, fields smis |
| `bitmap.byte_zap` | VeriFast-verified | the memset inside one writable byte array; the retry rule (`oom_unchanged`, wave 8) |
| `process_send` | ESBMC-verified | Checks argument errors, policy and boot-target checks, both encoding passes, quota and allocation failures, publication, mailbox charges and delivery results. The traversal contract assumes the same byte counts on both passes. General correspondence between the input graph, encoded bytes and transferred owners remains open. |
| `byte_array_is_valid_string_content` | VeriFast-verified | argument decoding, slice bounds, read-only validation and preserved heap |
| `platform`, `architecture` | VeriFast-verified | the Linux x86 and x86-64 providers return terminated literals. Each primitive allocates a fresh string of the provider's length or returns the marked allocation error. The shared copy checks the destination contains exactly the source bytes before restoring the heap invariant, for both internal and external strings. Allocation by length and the C library remain contracts. |
| `word_size` | VeriFast-verified | exact tagged result on both word widths |
| `byte_array_convert_to_string` | VeriFast-verified | checks arguments and bounds, runs the read-only UTF-8 validator on the slice, and copies only after it accepts. Success produces a fresh string of exactly `end - start` bytes. A marked error preserves the modeled heap. Allocation by length remains a contract. The model tracks the backing object and slice bounds across allocation. Byte-for-byte preservation by the allocator between validation and copying is still open. |
| `string_to_utf_16` | VeriFast-verified | Checks the string or slice, bounds the doubled allocation size, and returns a fresh byte array only if the destination is aligned and the writing pass reports exactly the measured number of units. The proof covers allocation failure and a write pass that needs fewer or more output units than the sizing pass predicted. Both passes read within a live source slice. The allocator contract preserves object identity and bounds. Preservation of the exact source payload across allocation remains open. |
| `crc` | VeriFast-verified | all six arguments, empty and invalid ranges, bounds for the data and either 256-entry table, checked shift counts, integer result or marked error |
| `time` | VeriFast-verified | boolean argument, either signed 64-bit clock reading and integer result or marked error. The platform clock implementations supply the readings |
| `add_finalizer` | VeriFast-verified | Rejects an ineligible key, accepts an eligible program-heap key without registering it, and reports an existing active finalizer. For a mutable eligible key the queue helper prepends the callback with the correct weak-map status or reports allocation failure. The body sets the header flag only after success. |
| `remove_finalizer` | VeriFast-verified | A non-heap argument gets the marked type error. Program-heap keys, non-instances and inactive instances return false and preserve the state. An active mutable instance returns true. The specialized loop removes every registration for the key and preserves survivor order. The native deletion contract and mapping of modeled fields to native subobjects remain trusted. The body then clears the flag, preserving every other header bit. |
| `spawn_method` | VeriFast-verified | An invalid method returns the tagged integer -1. A valid legacy method returns its bytecode offset. A valid format-2 method returns its index in the loaded table, or -1 when its entry is absent. The legacy offset must fit a tagged integer. |
| `task_new` | ESBMC-verified | Checks the argument and allocation errors, the sole initial code slot and empty frame state on format 2, and the legacy interpreter call order, dispatch entry and restoration of the calling task. Successful allocation supplies a fresh task with a valid stack. The legacy interpreter operations are modeled. Separate checks cover task ID representability and rejection before allocation on exhaustion, plus stack initialization for every supported stack length given a valid card mapping. |
| `task_transfer` | ESBMC-verified | Checks argument errors, self-transfer, the dead-target error, detachment, the active task and epoch, legacy save/load ordering and format-2 stack card writes. The first-transfer proof checks each destination word for every supported stack length, the two frame records, saved bci, preserved code and early rejections. The transfer assumes a saved running stack, valid task layouts and GC card mapping. Legacy interpreter operations are modeled. |
| `encode_error` | ESBMC-verified | The [primitive body](../harness/encode_error.cc) passes the original arguments and stored stack to the encoder, reloads the stack on both encoder outcomes, and returns the exact marked error or a fresh byte array containing the encoded bytes. Checks both internal and external result layouts and native-buffer release on every return. Traversal, interpreter stack operations, result allocation and libc supply contracts. |
| `process_current_id`, `process_system_id` | VeriFast-verified | A live process returns its tagged ID. The system ID is the boot ID observed under the scheduler mutex, or -1 when absent. ID assignment stops at the representable limit and exhaustion persists. The VM singleton, process lifetime and lock contracts remain assumptions. |
| `gc_count` | VeriFast-verified | Reads the process heap’s total collection count as an exact tagged integer. The update proof covers all three collection types and rollover at the representable limit. It assumes a live heap with valid counters and the collection type supplied by the collector. |
| `seconds_since_epoch_local` | VeriFast-verified on Linux | Checks six signed 32-bit calendar arguments in order, the wrapped year offset and the null/true/false DST flag passed to libc. A successful `mktime` result, including -1, goes through integer boxing. Failure returns the process null object. Linux libc supplies the calendar conversion and its weekday success indicator. The cached roots and allocator supply their shared contracts. |
| `array_new` | VeriFast-verified | Checks the length and its type, returns the shared empty array for zero, and delegates positive lengths to the verified primitive allocation wrapper. The [object-heap constructor check](../harness/process_array_allocation.cc) establishes the requested extent, builtin class, length, and every filler word on ILP32 and LP64. It uses the [verified initializer](ffi/array_init.render) at an arbitrary observed slot and checks that the reserved storage meets its preconditions. It follows the native two-space retry, charging the exact extent of an old-space array and marking its card before initialization. The individual space providers supply aligned reservations or exhaustion. The check assumes a valid program class table and card mapping. |
| `smi_divide`, `smi_mod`, `large_integer_divide`, `large_integer_mod` | VeriFast-verified | Exact signed quotient or remainder, including the minimum integer divided by −1, immediate or boxed zero divisors, wrong types and boxing. The native division-error accessor is checked by the division-error-root ESBMC harness. |
| `int_parse` | VeriFast-verified | Decodes all four arguments, checks the slice and the 18-byte limit, and boxes the signed value of its decimal digits. The parser terminates, preserves the bytes, and rejects invalid signs, bytes, and leading or trailing separators. Integer boxing uses the shared allocator contract. |
| `int64_to_string`, `uint64_to_string`, `printf_style_int64_to_string`, `smi_to_string_base_10` | VeriFast-verified | All four decode their arguments and select signed or unsigned formatting. For bases 2–36 the writer stays within 65 bytes, terminates and supplies the allocator with canonical lowercase digits and the required sign. The proof checks the exact argument and radix errors. String allocation uses the shared allocator contract. |
| `float_round` | VeriFast-verified | Checks both arguments and their exact type and precision errors. The decimal scale is exactly 10 raised to the requested precision for 0–15. Success preserves the receiver or allocates one fresh double. Marked errors preserve the heap. The double payload, binary64 arithmetic, libm and the underlying allocator remain trusted. |
| `float_parse` | VeriFast-verified | The entire selected slice must be consumed. Direct string suffixes use the string’s trailing NUL. Other inputs use a terminated copy which is freed on both parser outcomes. The proof covers argument and slice checks, the unsigned input to `isspace`, buffer bounds, embedded NUL rejection, and boxing or a marked error. Numeric conversion and character classification use libc contracts. The image loader checks the trailing NUL for internal and external strings. The allocator and GC supply this invariant for runtime strings. |
| `float_to_string` | VeriFast-verified | Checks the receiver, special values and precision branches. Fixed-precision formatting retries once and frees the temporary buffer on success and failure. The shortest writer checks Dragonbox’s returned components, extracts up to 17 digits and emits a terminated string within 26 bytes in every notation. Numerical conversion relies on Dragonbox and libc. The proof covers memory safety and result or error representation. |
| `utf_16_to_string` | VeriFast-verified | Checks the input byte slice and its even length, computes the UTF-8 size, and checks it fits a Smi before allocation. On LP64 the full possible expansion fits. On ILP32 an unrepresentable result length yields OUT_OF_BOUNDS. Success returns a fresh string containing exactly the encoding of the bytes read by the writing pass. Allocation failure and a changed output length produce marked errors. Preservation of the original input bytes across allocation remains open. |
| `bitmap.blit` | VeriFast-verified | Decodes all eleven arguments. Copy-on-write destination allocation preserves the remaining references. Each pixel borrows and returns its source, optional lookup and writable destination slices in order, allowing overlap. The loops terminate, stay within both buffers and reject excess work before the first pixel for either an uninterrupted-run quota or a total CPU quota. ESBMC also checks all six pixel results and preservation of unrelated bytes. The shared heap, allocator and live process-policy reference supply their contracts. The retry rule (`oom_unchanged`, wave 8). |
| `events.register_monitor_notifier`, `events.unregister_monitor_notifier` | ESBMC-verified | The native bodies check proxy representation and tag, group membership and the event source. Registration rejects closed proxies and propagates monitor allocation failure. Unregistration accepts closed, correctly typed proxies without a callback. A live, matching pair calls the owning source exactly once with the original arguments. |
| Event monitor lifetime | ESBMC-verified | The native registration and cancellation bodies create a monitor and reusable message, replace the object, or roll back after either allocation fails. From an empty root list and mailbox, the gate checks exact root membership, immediate sends on nonzero resource state and cleanup before or after dequeue, with leak checking. Allocation uses symbolic failure and placement construction at a stable address. Cancellation runs under the source mutex, and the modeled scheduler publishes to a live receiver through the native mailbox. The separate monitor-scavenge gate verifies the callback used in the lifetime check for a two-word young object and space for one copy. The native visitor forwards its monitor and optional global alias. The native receive primitive, with no runnable finalizers, reads the surviving object or returns program null after cancellation. The monitor-scavenge checks use the native size calculation on a valid class table and cover successful promotion, young copying and failed promotion. They check preservation of an outstanding old-space GC request, creation of one on fallback, and each alias’s remembered-set flag. Source extent, allocation outcomes and root visitation order are assumed. |
| `events.read_state` | ESBMC-verified | Rejects invalid or closed proxies and mismatched groups before acquiring the mutex. The native read returns the sampled mask and clears the state inside the critical section. The primitive preserves both argument slots and returns the tagged bits of the sampled mask. Exact numeric representation requires the mask to fit a Smi on ILP32. |
| `timer.arm` | ESBMC-verified | Checks the timer proxy and decodes either a Smi or a boxed signed 64-bit deadline. Success passes the original timer and exact deadline to the singleton event source once and returns program null. Rejection leaves the queue operation uncalled. With zero to two sorted peers and an optionally linked target, the same gate runs the native queue update and unregistration callback. It checks exact forward and backward links, stable placement at equal deadlines, event-state preservation on a no-op, and the signal decision under the source mutex. The separate timer-dispatch gate checks the native timer thread, event state update and monitor notification decision. |
| Timer thread dispatch | ESBMC-verified | Starts with zero to two sorted timers, arbitrary signed deadlines, event masks and optional monitors. The check cuts at the next outer loop header. A live round dispatches exactly the due prefix, leaves the pending queue linked in both directions, and waits only when it dispatched nothing. A stopped thread skips the round. A modeled condition wake preserves the queue and may set the stop flag. Time comes from a nonnegative monotonic clock. EC618’s freertos-wait gate checks conversion to finite 1 kHz tick counts for every signed 64-bit delay. The scheduler-notify gate checks the scheduler's send under nested scheduler and mailbox locks, a second send with or without an intervening dequeue, unchanged quota charges, and the ready queue for every receiver state. It starts with a live notifier, at most one preceding message and one ready peer. The RTOS wait and worker wakeup use contracts. |
| `timer.init` | ESBMC-verified | Heap proxy allocation precedes the caller's group quota check. Only admission and successful native allocation construct and register a group with the caller and timer source, then publish its typed proxy. Each failure returns its own error. Heap allocation, admission, group-list insertion and nonthrowing allocation are modeled. |
| `timer.delete` | ESBMC-verified | Only an open timer in the supplied group reaches unregistration. Success closes its proxy and decrements a positive quota count once. Rejection preserves the proxy and quota, including on retry. Native list removal and destruction are assumed. |
| `timer.create` | ESBMC-verified | Checks the group proxy, exact errors, quota reservation and rollback on native allocation failure. Success registers the initialized timer before publishing its typed proxy. The harness models allocation and group-list insertion and assumes the live timers fit in the address space. |

Of the 150 allowed primitives, 106 have Rust ports with proofs, 33 have
VeriFast body proofs and 11 have ESBMC body proofs.
Behind the 106 ports, the C++ of 62 has a VeriFast body proof (wave 9:
9 more; wave 10: 27 more; wave 12: 18 more, below), the other 44 are
contract-only. Counted by `metrics.sh`
(its last line: the primitives of CONTRACTS.toml's [prim_retry] whose
`primitive_NAME` has a rendered, not contract-only, definition, split by
`family` in verified/core/src/prims/mod.rs). Wave 8's "2 of the 106" was
an undercount: array_new, the four integer divisions and
string_write_to_byte_array, listed above with their C++ proofs, have Rust
ports too (8 before wave 9).
Of the 44, 42 are unreachable from untrusted code (proved in Verus:
`prims::never_falls_back`, the ensures of `prims::call` and
`rarrays::rust_primitive_r`; the list has 45 ports: smi_mod,
byte_array_is_raw_bytes and byte_array_at_put are VeriFast-proved too),
so 2 are contract-only and reachable, number_to_integer and smi_multiply
(10 before branch prims/trust-round, 28 before wave 12, 55 before wave 10; the list and
what blocks each: "The reachable contract-only fallbacks (wave 12)"
below). Counted by
`contract_check.toit` (verified/check.sh section contracts), which checks
CONTRACTS.toml `[unreachable]` against the Verus list.
These counts classify primitive names. A port can still delegate a case
to C++, as `concat_strings` does for a malformed slice
(`verified/core/src/prims/blob.rs`); which cases, per primitive, is
"When the C++ behind a port runs" below. Body proofs also rely on the
contracts of their callees, including the allocator.

`process-send-body` runs the production primitive and message constructors on
ILP32 and LP64. It checks the exact return value and which stages run for
each argument, policy, quota, allocation, encoder and scheduler outcome.
The scheduler observer checks the destination, sender identity, message type,
combined inline and external byte charge, and both mailbox limits. Allocation,
payload traversal, creation of encoder errors, ownership handoff and delivery
supply contracts. The modeled traversal permits any representable sum of
nonnegative byte counts and assumes an unchanged size between passes. The
separate ownership checks below cover encoder destruction and transfer.

`ipc-array-traversal` checks the native `encode_array` loop by induction
over every permitted slice length. It verifies the array tag, the declared
child count and the exact source slot passed at each recursive call. This
holds for arbitrary slot contents, including repeated references. Both passes
therefore select the same children in order on an unchanged array. Either
pass can fail at any child and stops there. Invalid slices emit no header.
The process-array length limit used for rejection is derived from the native
heap limit on each word size. The calls that encode each child still supply
their own contracts for bytes and ownership.

The same proof checks native `encode_list`. It validates the requested
interval against the logical list size and checks the backing before
delegating to the array loop with the original offsets. Rejected bounds
or an unsupported backing emit no header.
For a list slice, the native encoder reads the tagged endpoints and routes
the exact interval to a direct array or a list. The traversal proof covers
both routes, including an arbitrary child failure. It also checks that a
wrong instance backing reports its class ID and that other rejected inputs
preserve the diagnostic.

`ipc-map-traversal` checks the map tag, declared entry count and the
sequence of calls to encode each key and value. On success that sequence
is exactly the first declared number of live pairs in the original backing
array, in slot order. A deleted entry contributes neither slot. A list
backing restricts the scan to its declared length. An unmatched last slot
cannot supply a pair. If a child rejects, the trace ends at that key or
value. If the backing is readable and all visited children succeed, a
shortage of live pairs is detected after the last complete pair. Child
encoding still supplies its byte and ownership contracts.

`ipc-smi` follows a tagged integer through the native IPC sizing pass,
writing pass, and either decoding or disposal. For every Smi on each word
size and every permitted starting encoder depth, the writer fits an envelope
of exactly the measured length. The decoder recovers the original value,
including its sign, without allocating a boxed integer. Decoding and disposal
each consume the whole leaf. The harness checks that no external owner is
registered and no owned storage is released. Recursive container alternatives
have explicit unreachability assertions in this leaf proof.

`ipc-fixed-scalar` follows null, both booleans, doubles and boxed integers
through the same native passes. The roots occupy one wire byte and decode to
the corresponding root of the receiver's image. A double or boxed integer
occupies nine bytes. Integers in the receiver's Smi range become Smis.
For other integers and for doubles the proof checks the value passed to the
box allocator, the returned object and the allocation-failure status. Every
non-NaN double must preserve its bits, including the sign of zero. A NaN must
remain a NaN. The cleanup walk consumes each complete leaf without freeing
an external owner. The separate `boxed-allocation` check follows the native
constructors from a fresh raw reservation (or exhaustion) through the class
header and numeric payload.

`internal-string-allocation` checks the native string constructor for every
permitted internal length. It requests one word-aligned reservation containing
the header, payload and trailing NUL, propagates exhaustion, and initializes
the class, length, hash sentinel and terminator.

`external-blob-allocation` checks the native constructors used for external
IPC strings and raw byte arrays. It supplies the caller's block, including
the extra terminator byte for a string, and follows finalizer registration
through the native queue append and header flag update. It covers borrowed
and owned blocks, an empty queue or a queue with a prior node, and failure
of either the raw reservation or the nothrow finalizer allocation. The byte
array uses the decoder's `clear_content=false` path. A symbolic payload
index checks preservation of every input byte. These checks assume that raw
reservation returns fresh storage of the requested size or reports failure.

`ipc-tree-disposal` checks the native recursive disposal walk against a
description of one complete IPC value. Each child starts at the previous
child's end offset, and every external string or byte array carries exclusive
ownership of its allocation. VeriFast checks that the walk reaches the end
offset and consumes all those owners, for any finite tree satisfying the
description. It checks the concrete tag, fixed-width, pointer and cardinal
reads. For a cardinal, the proof reads the actual bytes, sums the seven-bit
digits at their base-128 positions and stops just after the terminal byte.

The native tag, cardinal, fixed-width and pointer writers now supply the
byte chunks for this description at any starting offset. The cardinal proof
uses exactly the required space, constructs the reader's digit predicate
with the original value, and gives the same final offset in sizing mode.
Scalar and external-leaf lemmas assemble cleanup nodes from those fields.
The external case also consumes the caller's ownership of the allocation.
The tagged-integer branch of `encode_any` calls the native `encode_smi`
writer. From any valid offset with room for its sign tag and magnitude,
its sizing and writing passes end at the same byte. The field readers
recover the original sign and magnitude, and the cleanup walk consumes
exactly that leaf. The proof leaves the rest of the envelope and existing
external ownership with the caller.

The native array loop writes its tag and length and joins the completed
children in slot order. Given the byte boundaries of successful child calls,
both modes reach the predicted final offset. The writing pass produces the
node the disposal walk consumes. Invalid slices leave the cursor and buffer
unchanged. If a child fails, the array proof returns the header, the complete
prefix with its external owners, and the failing child's state. This requires
a contract for each recursive call and enough space for the array header.
For an empty slice, the proof runs both native array passes and the disposal
walk from the same arbitrary offset, with no recursive-call assumption.
All three cursors advance exactly two bytes.
Deriving those contracts for arbitrary nested inputs and reclaiming partial
outputs on failure remain open. The enclosing buffer release is checked
separately.

`ipc-cardinal-wire` checks both passes of the native cardinal writer for
every unsigned machine word. It verifies the payload and continuation bit
of each byte, the absence of redundant leading zeros, and the exact extent
of the write. The native reader then recovers the word from that buffer.

`mailbox-delivery` checks the native system-message enqueue with symbolic
word-sized counters, sizes and limits on ILP32 and LP64. Its FIFO starts
empty or with one prior tail. Its reply grant set has capacity zero, one
or two and may require allocation. Rejection preserves the links, counters
and grant membership. Success publishes all three before releasing the
mailbox mutex.

`mailbox-removal` checks native peek, readiness and removal on ILP32 and
LP64. After the first successor, the outgoing link and cached tail are
symbolic. The proof checks that removing the head preserves both, so the
suffix can have any length. System messages refund the
exact encoded size and count, including the restricted sender's charges
when applicable. An owned notification returns to its notifier with its
queue flag cleared. An abandoned notification or a system message reaches
destruction after unlinking. The check observes the links and counters at
mutex release. It assumes valid starting charges and models the mutex and
system payload cleanup.

`scheduler-delivery` checks the direct and system routing bodies from
`scheduler.cc` with the native enqueue and grant code. It observes lookup,
wakeup, locking, termination decoding, shutdown and calls to delete through
contracts. Direct routes cover
present and absent destinations, old grants, same-group and boot-process
exceptions, and mailbox or grant refusal. System routes cover delivery to
the boot process, a full boot mailbox and consumption without a boot
process, including the decoded termination value. Since wave 8 a
process's TERMINATED or SPAWNED notice is refused on either route before any
lookup, delivery or decoding, and the scheduler's own notices take the
system route directly (send_system_message, as terminate_process and
spawn call it). Every unqueued message
reaches one delete. Destruction of the encoded payload remains a separate
obligation at the scheduler boundary. The receive-path VeriFast proof
checks the destructor and deallocation walk given the IPC encoding and
block-ownership assumptions described below.

`byte-array-neuter` checks the concrete sender-side detach operation and
the heap's external-memory counters. Given an owned raw external array
whose length is charged to the process, the operation returns its data
pointer, clears the sender's address and length, and subtracts exactly
that length from current external memory. Lifetime allocation accounting
and the object header are preserved.

`byte-array-ownership` proves `ByteArray::has_owned_external_memory` from the
byte-array layout and finalizer flag. An external array is eligible for
transfer exactly when the active-finalizer bit is set. The shared flag
accessor also handles a forwarded header when given a valid destination.

`ipc-byte-array-visit` checks one visit to an owned external byte array
with any valid number of prior transfers and copies. The reference can be
absent from the transfer table or appear in any occupied slot. The sizing
and writing passes agree on the representation, reservation count, byte
charge and emitted length. A first visit records the original pointer.
A repeat copies up to 128 bytes inline, or records a fresh allocation for
a larger payload. The checks cover size and table limits, allocation failure,
preservation of prior entries and the sender's ownership before publication.
The blob-accessor proof supplies the original backing object, base address
and length for a direct byte array. Allocation and the two payload memcpy
sites supply contracts. The copy observer checks both addresses, the byte
count and an arbitrary byte. The visit proof checks the arguments and order
of the field writes. `ipc-array-fields` checks the native writers against
those operations and reads back the tag, length and pointer from a buffer
of exactly the specified extent. Publication and teardown are covered below.

`encoder-handoff` starts with the encoder's copy and transfer tables
populated with distinct owners, up to the native limit of eight entries in
total. It checks the message constructor, transfer order, finalizer-clear
calls and destruction of the writing encoder. Aborting releases the main
buffer and each copy. Publishing gives the message the buffer and leaves
the external blocks for the receiver. The table check observes detachment
and finalizer clearing at their call sites. `byte-array-neuter` checks both
operations on a concrete tagged byte array.

`ipc-transferred-array` follows one owned external byte array from its
size pass into a buffer of exactly the measured length. It checks the
native reader's tag, length, pointer and final cursor, then checks the
writer-abort and message-disposal paths. An assertion excludes recursive
array/map cleanup for this leaf. Native storage release and external-byte
refunds are observed through contracts. The heap accounting operation has
its own proof above. For general nested messages, connecting the traversal and
cleanup contracts to the bytes and owners produced by both passes remains open.

The `encode-error-body` target checks the host-configured primitive on LP64
and ILP32. Its traversal contract summarizes construction and encoding by
an arbitrary attempted output size and arbitrary contents. Success requires
the size to fit strictly below the native buffer capacity. For a successful
result allocation the harness checks the source, destination and length of
the libc copy and observes an arbitrary byte under the memcpy contract.
The symbolic allocator supplies disjoint storage. Recursive encoding and
legacy stack enumeration still need proofs.

The [native visitor dispatch proof](../harness/visitor_dispatch.cc) checks
every immediate integer and all 16 heap tag patterns. A supported tag
forwards the original reference to exactly one matching callback. GC and
reserved tags reach the VM fatal handler before any callback. Heap references
are assumed to point to a readable header. The [scalar encoder proof](../harness/encoder_scalar.cc)
follows the same dispatch through the actual scalar callbacks. It checks the
integer value, the full binary64 payload, and the byte markers for the three
distinct null and boolean roots at the writer boundary.

Frama-C/WP checks the [string prefix selector](../../../src/encoder_string_prefix.h)
on both word widths. Strings of up to 255 bytes keep their full length. For
longer inputs, the backwards scan stops at zero or the last non-continuation
byte at or before index 255. The proof covers malformed byte runs, read bounds
and termination. The visitor's payload emission is exercised by the host
object-encoder test.

The collection proof checks the native list-field validator and the shared
array/list traversal. The validator accepts exactly an array backing and a
tagged size from zero through the backing length. Given a validated size,
the traversal announces that size and passes at most ten original children
to the next level in order. The depth guard writes null at level 16 and
suppresses output when the buffer is already full. The harness checks the
arguments to the separately proved wire writers and models recursive child
dispatch as a read-only callback. The class dispatch and fallback in
`visit_instance` remain outside these checks.

The stack-frame callback proof uses induction on the number of frames delivered.
Its input is a stable count and a sequence numbered from zero. The
[format-2 walker proof](../harness/v2_frame_walk.cc) establishes that sequence
for a valid packed frame layout and a stable skip setting. A count-only call
reads the frame top. During enumeration each step advances the index by one,
reports the suspended instruction’s successor for a recognized opcode or reads
the corresponding saved return offset, and stops at the announced count.
The proof assumes a live stack, readable bytecode below the format-2 size
limit, and offsets representable in the callback's integer type. The legacy
walker still supplies its sequence by contract. The callback checks the emitted
count after each frame and the encoded index and bytecode offset. Long traces
retain the first 33 and last 67 frames on the host, or the first 13 and last
27 under the FreeRTOS policy. The latter check selects the production limit
in the ILP32 harness and uses host headers.

The notifier checks (`run.sh --quick event-notifiers`) assume that an open,
correctly tagged proxy points to a live native object of its declared type.
The harness models the outcomes of the event-source update and deletion
methods. Their locking, notifier lifetime and scheduler effects still need
proofs.

The read-state check includes the native `EventSource::read_state` and
the `Locker` constructor and destructor. It models mutex entry and exit,
allowing independent updates at both boundaries. On LP64 every uint32
mask fits in a Smi. On ILP32 an exact nonnegative result requires a mask
at most 0x3fffffff. The native timer constructor starts at zero and the
timer event callback sets only bit zero. The read proof covers arbitrary
32-bit masks in the release configuration and checks the numeric result
when representable.

The format-2 loader obtains the method table from the program's last
literal. ESBMC checks that `v2_last_table_literal` handles missing and
empty lists and selects the final slot only when it contains a heap object
with the byte-array tag. This assumes a readable literal list and valid
object headers. The object model verifies how `ByteArray::Bytes` obtains
the pointer and length of an inline or external payload.
`v2_read_table_literal` rejects lengths below 16 before reading memory.
Given the advertised bytes, it accepts exactly the TMT2 marker, matching
bytecode length, nonzero 24-bit count, and a size of 16 + 4 × count bytes.
It returns a view starting immediately after the 16-byte header.
Every accepted count fits a tagged integer and every current and lookahead
record used by the loop fits inside that literal. For each current record,
ESBMC checks `v2_check_header` against the five canonical kind bytes and
their sizes from format note 21. A successful check places the header at
the expected offset, leaves room for a body, and accepts exactly the receiver
intervals allowed by that kind; every entry but a block's must be odd (the
header's u16 fields are then 2-byte aligned for the core's aligned loads).
The proof covers rejection of invalid positions, kind bytes, even entries
and receiver intervals on LP64 and ILP32.
ESBMC also checks `v2_next_header` for an arbitrary four-byte record, header
kind and legal current entry and image length. Every successful call locates
the exact header strictly between the current and next entries. A rejected
pair has the corresponding bad-entry or empty-body result. The backing
memory must be readable for the advertised lengths.

Frama-C/WP verifies the same validation loop compiled by the VM
(`src/v2_validate_records.h`) against those helper contracts. For every
permitted count the loop terminates and accepts exactly the record
sequences specified in `loader/records.c`. The first header starts after
the four-byte tag. Each header is canonical (including the odd entry) and
every method has at least one body byte before the next header or the end
of the image. This gives
strictly increasing entry offsets. Run `run.sh --quick v2-table` to
check the loop and its native helpers on both word sizes.

After validation, `V2MethodTable::install` borrows aligned records and
copies unaligned records into owned storage. ESBMC checks an arbitrary
byte of any permitted record count, the bytecode view, optional
allocation-failure reporting, and release of owned memory on failure or
destruction. The new table starts unverified. After `mark_verified`,
`runs_verified` admits a process only for a verdict of its own policy:
an untrusted process only for a table accepted under the untrusted rules
and table, a trusted process only for one accepted under the trusted
ones (exact match since 2026-11-26; before, an untrusted verdict also
admitted a trusted process, which the verified loop must not do now that
it gets the process' own policy table; mutants
v2-table-install-untrusted-verdict-trusted and v2-table-install-any-verdict). The harness models libc's
`memcpy` at the observed byte and checks the copy extent and separation.
It models the null outcome of nonthrowing scalar allocation explicitly
and invokes the native destructor before releasing the table storage.
ESBMC also checks the body of `V2MethodTable::compute` against the
separately verified helper outcomes. The source image must pass the TBC2
tag and size checks and be 2-byte aligned before literal selection. The
reader receives the selected inline or external payload. Installation receives exactly the
image, record pointer and count passed to successful validation. The
caller gets the installation result, and only allocation failure sets
the optional out-of-memory flag. Diagnostic output is outside this proof.
The validity and lifetime of the program heap and its backing storage and
the allocator and libc contracts remain assumptions.

The object model reads built-in class IDs through the rendered body of
`Program::class_id`. ESBMC checks all 23 native named getters against their
indexed slots and checks the ten aliases used by the proof model against the
native getters on both word widths. The loader still supplies the invariant
that the table holds tagged class IDs consistent with the program's objects.

VeriFast also checks the C++ eligibility decision used by `add_finalizer`.
An object qualifies for an ordinary Toit finalizer exactly when it is an
instance, has a class ID different from the program's map class ID, and
cannot be decoded as a string or byte-array view. The decoder proof gives
the exact length on success and models failure for malformed views and
excessive nesting. Consequently, a malformed wrapper can pass this
eligibility check. The primitive handles maps separately for weak-map
registration.

For each writable, non-forwarded header in the heap model, VeriFast checks
the C++ store that sets or clears the flag. Both operations are idempotent.
The stored word changes by exactly 32 when the flag changes. The class ID,
tag, object fields and all other objects survive the update. Registration
changes the header only after the native queue helper reports success.
Removal first unlinks the registrations and then clears the header. The
queue helpers' contracts carry no permission to modify any VM object.

The native `finalizer-header` check exercises the C++ accessors on every
Smi-tagged header word. Reading the flag through a forwarding pointer gives
the flag of its destination. Setting or clearing the flag on the destination
preserves every other header bit and the forwarding pointer. The decoder
still assumes that clearing the flag returns ownership of an external block.
That obligation also depends on the finalizer queue and the collector.

Callback registration selects the weak-map or ordinary allocation and checks
for allocation failure before inserting a node. VeriFast follows the
derived and base constructors that store the key, closure and owning heap.
The native `finalizer-prepend` check covers the empty queue and a queue
with arbitrary existing endpoints. Insertion makes the new link the head,
points it to the previous head and changes the tail only when the queue was empty.
VeriFast proves that these updates transfer ownership of the detached node
to the process heap’s queue. The inductive list records the callback kind,
key and closure of each node. Insertion preserves the order and ownership
of every previous registration for any finite queue length. The process
accessor contract identifies the queue owner with its embedded object heap.

The native `finalizer-queue` check runs the C++ delivery and removal code
with the intrusive FIFO and both concrete callback kinds. Delivery consumes
the first runnable callback, returns its lambda, deletes an ordinary
callback, and puts a weak-map callback back at the head of the registered
list. The harness covers an optional runnable successor and an optional
existing registration. Removal checks every pattern of matching keys and
callback kinds in a three-node list, including duplicates. It checks which
destructors run, both keys' header words, the surviving order and an append
through the repaired tail or empty anchor.
The unwinding assertion checks that the native traversal finishes within
this bound. VeriFast separately proves termination of the specialized C
loop for any finite registration list. At each iteration the unvisited
suffix shrinks by one. A match hands the detached node to the delete
contract. Otherwise the link is restored. The resulting list contains
exactly the registrations whose key address differs, in their original
order, with the correct tail or empty anchor.

The `finalizer-unlink-code` check compiles the original `src/heap.cc` and
the VeriFast loop from each target’s generated C with Clang at `-O1`.
The adapter uses the native link type for traversal and converts the link
to its owning node for the key read and virtual deletion. The check
requires identical bytes for the entire unlink method and rejects
relocations in either function section. This comparison covers all loop
iterations on the i686 and x86-64 check builds. It relies on the adapter’s
type mapping and the compiler. Release binaries and other architectures
need their own evidence.

Both `task_has_messages` and `task_receive_message` use the rendered body
of `ObjectHeap::has_finalizer_to_run`. Its read permission is for the head
of the process heap’s runnable queue, and the result is true exactly when
that link is non-null. ESBMC compares the emptiness decision with the
native queue for a symbolic head.

The main and spawn argument primitives use the rendered getters and clear
operations from `src/process.h`. Each getter reads its own encoded-buffer
slot. Clearing a slot requires write permission for that slot alone. The
two pointer-taking setters in `src/process.cc` require an empty slot and
preserve ownership of the supplied encoded message and its external blocks.

The receive proof now calls the rendered `ObjectHeap::next_finalizer_to_run`
with ownership of both callback queues. From a nonempty queue it returns
the first closure and preserves the remaining runnable callbacks in order.
It prepends a weak-map node to the registered list or passes an ordinary
node to native deletion. A direct call on an empty queue reads the program
null root. The FIFO proof covers any finite suffix and restores the anchor
when the last node leaves. ESBMC compares the link updates and the
conversion back to the containing C++ node on both word sizes.
The receive precondition requires that queued closures are valid references
in the current VM heap. Establishing this across GC, dynamic dispatch of
`keep_after_callback`, native deletion and the program null root accessor
remain trust boundaries.

VeriFast checks the native `roots_do` bodies for ordinary, weak-map and VM
finalizers. Given a visitor that forwards a reference in place, each
callable node hands it the key slot and then the closure slot. A VM node
hands it only the key slot. The proof records slot addresses, so it also
checks the order and visit count when both fields hold the same reference.
The rendered `RootCallback::do_root` passes a length of one.

The native `finalizer-roots-test` CTest runs the heap’s traversal with up to
two callable nodes and one VM node. Either callback can be absent,
registered or runnable, and either kind can come first. The visitor checks
slot identity, writes distinct replacement values and checks that the
updates survive the traversal. A separate ESBMC attempt reported a null
dereference in the runnable iterator on ILP32. The compiled test passed
all 36 queue configurations on i686 and x86-64. The model-checker result
remains unresolved. The concrete collector’s forwarding map and traversal
of queues of arbitrary length also remain open.

The C++ primitive failure path also verifies its shared error decoding on
both word widths. An immediate selects a slot in the program root table.
An unused immediate selects `INVALID_ARGUMENT`. A marked heap pointer
recovers the original heap-tagged address. VeriFast checks the table read
against the loaded program's root array and carries this result through
the retry loop. ESBMC checks the native decoder for every marked word and
arbitrary root values, including the named error accessors. This still
assumes that the loader supplied a live program with initialized roots.

The encoding module (`tison_decode`: the decoder
verified, its glue not rendered) is denied to untrusted programs.

Since wave 7 every one of the 150 also has its retry classification
(CONTRACTS.toml `[prim_retry]`, "The retry obligation"), the 106
Rust-verified ones for their C++ primitive, which runs when the port
declines: that C++ is reachable by untrusted programs too (the
concat_strings overflow of "Findings" was in it). Their C++ bodies are
otherwise contract-only, except (wave 8) read_uint_big_endian and
read_uint_little_endian: VeriFast-verified (`prims/read_bytes.render`:
every read inside the blob for any width and offset, no overflow or
lossy conversion but the modular ones the C++ means, `oom_clean`), and
(wave 9) read_int_big_endian, read_int_little_endian, byte_array_replace,
put_uint_big_endian, put_uint_little_endian, put_float_32_little_endian,
put_float_64_little_endian, byte_array_at_put and byte_array_is_raw_bytes
(`prims/read_bytes.render`, `prims/byte_array_access.render`,
`prims/put_bytes.render`, `prims/put_float.render`). Memory safety of the
C++ behind the 106 ports: 62 VeriFast-verified, 44 contract-only
(`metrics.sh`; 44 and 62 before wave 12, 17 and 89 before wave 10, 8 and
98 before wave 9), of which 42 are unreachable from untrusted code
(proved in Verus; below), leaving 2 (10 before branch prims/trust-round,
28 before wave 12, 55 before wave 10). Wave 10 added byte_array_new,
array_expand, string_at, string_add, concat_strings, string_slice, the
eleven boxed-double float primitives and ten integer primitives
(`prims/allocating.render`, `array_expand.render`, `string_at.render`,
`strings.render`, `float_ops.render`, `int_ops.render`). Wave 12 added
nine integer primitives (`prims/int_bits.render`), the four raw float
conversions (`prims/float_raw.render`), string_from_rune
(`prims/string_from_rune.render`), blob_hash_code and
hash_simple_json_string (`prims/blob_hash.render`), string_length and
json_skip_whitespace (`prims/blob_helpers.render`).

### The reachable contract-only fallbacks (wave 12)

The 2 primitives behind Rust ports whose C++ an untrusted program can
reach and that have no body proof (both only after an allocation that
did not fit, `NeedsGc`), grouped by what blocks each (the
fallback conditions are "When the C++ behind a port runs" below). Since
branch prims/trust-round byte_array_at, byte_array_length and list_add
are no longer among them: their ports never fall back (the opaque byte
arrays read through their tag and length words; list_add's large-array
backing in Rust, with a bound on the nesting that the C++
`Interpreter::fast_at` lacked until branch fix/fast-at-depth (it now gives
up after 8 nested vectors): a deep chain of large arrays made by a
program's own library overflowed the native stack, a VM crash; regression
tests tests/sandbox/cli/large-array-chain-main.toit and
tests/large-array-depth-test.toit). Nor are blob_equals,
blob_index_of, compare_simple_json_string, size_of_json_number and
string_rune_count: their ports take a byte array a transferring send
neutered (raw bytes of length 0 at a null address, and empty slices of
one) as the empty blob, as the C++ decoders do (`BlobArg::Empty`), fail
for a resource proxy as the C++ decoders do, and fail with OUT_OF_RANGE
for a count above MAX_SMI, which no blob reaches (the C++ made it a smi
unchecked). In the table the first four rows are theirs (their C++ stays
unproved, but no untrusted program reaches it); the last two remain:

| Blocker | Primitives |
|---|---|
| a loop over the blob's bytes with a C library call or a helper not yet rendered: `memcmp`/`memchr` contracts, `String::compute_hash_code_for` (a uint16 modular hash: the narrowing of `31 * hash + byte` to uint16 needs a `truncating` rule for int to uint16), `String::equals`; with an opaque argument (the ports' only fallback) the proved decoders give the bodies an empty blob or fail | blob_equals, compare_simple_json_string |
| `static const` locals (no rendering rule; its loop is over pointers into the blob) | size_of_json_number |
| intrinsics: blob_index_of's SSE loop (x86-64 hosts) | blob_index_of |
| reads outside the blob by design: string_rune_count's word-sized aligned loads read the bytes before and after the blob in the same word (they cannot fault, AddressSanitizer builds count byte by byte); the model has no chunk for them | string_rune_count |
| VeriFast's floating point (no double-to-integer conversion, uninterpreted comparisons) | number_to_integer |
| `__builtin_mul_overflow`, and the parity of a product through the modular conversions to a word and to an address | smi_multiply |

### When the C++ behind a port runs (wave 9)

For an untrusted process the core calls a port first, and its C++
primitive only when the port returns `NotPorted` or `NeedsGc`
(`rarrays.rs`: `op_primitive`, `rust_primitive_r` maps both to `None`,
then `cxx_primitive_v`, which collects garbage and retries in C++). The
port is called only where the policy's core arity table says the policy
resolves the primitive to the VM's own entry with the method's arity
(`PrimitivePolicy::initialize_core_arities`), so the arity mismatches and
the family guards of `prims::call` and the family dispatches are not
reached from `op_primitive` (every ported arity matches src/primitive.h).
Other routes to the C++ for an untrusted process: none on the default
paths (ProcessGroup::create and the registry's spawn verify an untrusted
format-2 table under the untrusted rules, so it runs on the verified loop;
the checked loop, `machine.rs` `op_primitive_cold`, calls C++ for every
primitive but runs only unverified tables, never an untrusted process's).
Format-1 untrusted programs, which would reach every C++ primitive on the
C++ interpreter, are refused by every build (the host opt-in
`-Xuntrusted_format1` / `TOIT_UNTRUSTED_FORMAT1=1` was removed).

Per primitive (read from verified/core/src/prims/{ints,array,blob,float}.rs
and the allocator, `ffi.rs`; no port allocates twice, and every `NeedsGc`
follows the one failed allocation, so the heap is unchanged):

| Falls back | Primitives | When |
|---|---|---|
| never (45; 35 before branch prims/trust-round) | smi_mod, smi_shift_right, smi_not, count_leading_zeros, popcount, object_class_id, the 5 smi and 5 large-integer comparisons; array_length, array_at, array_at_put, array_replace, rebuild_hash_index, list_add; string_hash_code, string_raw_at, string_compare, int_vector_equals, byte_array_is_raw_bytes, byte_array_length, byte_array_at, byte_array_at_put; string_rune_count, blob_equals, blob_index_of, compare_simple_json_string, size_of_json_number; float_sign, float_is_nan, float_is_finite, the 5 float comparisons, compare_to, min_special_compare_to | no path returns NotPorted or NeedsGc (no allocation; results in the smi range; an opaque byte array read through its tag and length words, as the C++ reads it; list_add's large-array backing in Rust with at most 8 nested vectors, else INVALID_ARGUMENT for the Toit code) |
| only when an allocation does not fit (NeedsGc) | the other integer operations (a result outside the smi range: a large integer), every float operation that returns a double (number_to_float, raw_to_float, raw32_to_float, arithmetic, sqrt, rounding), float_to_raw, number_to_integer (a large result), float_to_raw32 (ILP32 only), array_new, array_expand, string_slice, string_from_rune, string_add, byte_array_new (also every ByteArray above 2^30 - 1 bytes on ILP32, and an external one the process limit or malloc refuses) | the new-space allocation, or the external blob's, fails |
| copy-on-write or opaque byte arrays (NotPorted) | byte_array_replace, string_write_to_byte_array, put_uint_big_endian, put_uint_little_endian, put_float_32_little_endian, put_float_64_little_endian | a destination that is a CowByteArray_ not yet copied (a byte-array literal, or a slice of one: `LITTLE-ENDIAN.put-uint16 #[0, 0] 0 1`), or opaque (below); the source of byte_array_replace and string_write if opaque |
| opaque byte arrays (NotPorted) | blob_hash_code, json_skip_whitespace, hash_simple_json_string, read_int_big_endian, read_int_little_endian, read_uint_big_endian, read_uint_little_endian (these four also NeedsGc for a large result) | a byte array the model has no bytes for (`view.rs`: external with another tag than RawByteTag, or RawByteTag with a null address); since branch prims/trust-round only the latter, a byte array neutered by a transferring process_send (address null, an empty blob for the C++): the ports fail for another tag (resource proxies; mapped files only from a program image, which is refused since wave 11) as the C++ decoders do |
| other | concat_strings | a malformed StringSlice_ among the parts; a sum above MAX_BLOB_LENGTH (ILP32: 2^30); the result's allocation (NeedsGc) |
| | string_at | a byte of 0xf8 or more, or a lead byte whose sequence runs past the end (invalid UTF-8: a concatenation of a StringSlice_ that cuts a character, which a program's own library can make, is such a string; the C++ is proved since wave 10, `prims/string_at.render`) |
| | string_length, json_skip_whitespace, string_add | a string longer than MAX_SMI (unreachable: the heap model bounds byte arrays, not strings, abs.rs) |

The program-level checks (a builtin class of the program without the tag
the port expects: ints.rs, float.rs, array.rs, blob.rs) decline for every
input of a malformed program, never for a compiled one. Since wave 11 the
verifier refuses such a program (`V2Verifier::builtin_classes_error`), so
these declines are unreachable for untrusted programs too.

What the C++ then does with an opaque byte array (the paragraph before
branch prims/trust-round; since then the ports reject a proxy or a
mapped file themselves, as below, and the four byte_array_* ports read
the tag and length words, so the C++ runs only for a neutered array in
the blob primitives): the primitives that
decode it as a Blob or MutableBlob (all of the opaque rows but the four
byte_array_* ones) reject a proxy or a mapped file in the proved decoders
(`blob/byte_content.render`, `blob/mutable_byte_content.render`: an
external byte array other than RawByteTag is not a blob) before their
body runs, and a neutered array decodes to an empty blob (null address,
length 0); so for an opaque argument their bodies run only on an empty
blob. byte_array_at and byte_array_length read a mapped file's bytes
(MappedFileTag; not proved: the model has none), byte_array_at_put and
byte_array_is_raw_bytes are proved (`prims/byte_array_access.render`).
Wave 10 looked for the mapped files: no C++ of this tree makes a byte
array tagged MappedFileTag (`set_external_address<T>` writes `T::tag`, and
no class declares `TAG(MappedFile)`; the flash registry's proxies are
RawByteTag over memory the process does not own; a snapshot's external
byte arrays are read as RawByteTag, objects.cc). The tag is only read
(byte_array_at, byte_array_length, the GC, interpreter_core.cc). So the
unproved branch runs only for a byte array a program image brings with
that tag word, and the program-heap walk (src/verifier.cc `walk_heap`)
checks an external byte array's address range, not its tag. Whether a
raw (not snapshot) image can be an untrusted container and carry another
tag word, a mapped file's or a resource proxy's, was not established in
wave 10 (for the lead: a proxy tag would make the C++ take image bytes for
a native struct). Wave 11 established it: a flash image can (it is
installed word for word; the format-2 conversion accepted any other tag,
or a null address, as an opaque object), and since wave 11 such an image
is refused at install ("Findings", wave 11). So the MappedFileTag branch
of byte_array_at and byte_array_length is unreachable for untrusted
programs, and the opaque byte arrays of the table above are resource
proxies and neutered arrays only.

Consequences. The C++ behind the 35 "never" ports does not run for an
untrusted process on the default paths, so it needs no proof for the
sandbox; it still runs for trusted format-1 programs (the C++
interpreter), so it can leave the f2 firmware only together with them
(`-Xuntrusted_format1`, the other route, was removed;
verified/core/OBLIGATIONS.md, "Ports
that never fall back", says what else that needs). Now a proved fact
(branch core/ports-never-fall-back): `prims::never_falls_back` is the
list (the 35 of the table, none added or removed by the check against
the code), `prims::call` ensures that they complete in Rust and
`rarrays::rust_primitive_r` that they do where the policy gate passes,
with the method's arity the verifier's arity of the primitive; that
this is the port's arity rests on src/primitive.h (the gate's table and
the C++ entry's arity check) and the layout check, both trusted already.
The plan was:
(1) each family dispatch (`ints::dispatch`, `array::dispatch`,
`blob::dispatch`, `float::dispatch`) and then `prims::dispatch` and
`prims::call` ensure `index == I && a.n == k ==> !(r.0 is NotPorted) &&
!(r.0 is NeedsGc)` for the 35 indices; most bodies give it directly
(cmpop and array_length/at/at_put already ensure `!(r.0 is NotPorted)`,
object_class_id `r.0 is Success`; NeedsGc is excluded wherever the
per-primitive `core_contract` has no OutOfMemory branch), the integer
ones need `int_res` to ensure `smi_in(x) ==> r.0 is Success` and range
lemmas (trem, `>>`, `!`, clz and popcount at most 64), string_compare and
string_raw_at need `blob_or_fail` to forward blob_arg's
`mode == STRINGS_ONLY ==> !(r is NotPorted)`; (2) an invariant of the
core's environment that `core_arities[i]` is 0 or the port's arity plus
one (supplied by C++ today, trusted), so that `rust_primitive_r` returns
`Some` for them. The other 71 ports fall back as the table says; for
those the C++ is reachable by untrusted programs and its proof matters:
wave 9 proved the readers' and writers' C++ (the byte-array rows above:
the cheapest to trigger, a byte-array literal suffices, and the ones that
write memory at offsets the program chooses).

### Young-space allocation

The proof in `heap/semispace.render` covers the original C++ bodies of
`SemiSpace::try_allocate`, `SemiSpace::allocate`, `SemiSpace::flush` and
the end-sentinel helpers. Given ownership of the unused range of a
word-aligned chunk, a successful call hands out the requested prefix,
advances the allocation pointer by its exact byte length and stores a null
sentinel in the next word. The remaining words retain their contents.
An exact fit fails because the sentinel needs its own word. The fast path
leaves the range intact on failure. The ordinary allocator refreshes the
sentinel when its active chunk is nonempty.

The [raw allocation proof](heap/young_allocation.render) follows this ownership
through `TwoSpaceHeap::allocate` and `ObjectHeap::_allocate_raw`. For a
positive word-aligned request that fits with room for the sentinel, the
returned tagged pointer addresses exactly the prefix transferred to the
caller. The heap retains the sentinel and the remaining words. A miss
preserves the young allocation window. An ordinary miss returns null. On
a primitive retry the proof follows the production fallback into the
old-space allocator. A successful return transfers the old allocator’s
word permissions to the caller at the exact tagged address. Both paths
expose the same `raw_reservation` postcondition. A constructor can consume
the granted words while the allocator retains ownership of its cursor,
sentinel and metadata. The proof
retains the updated old-space window and the object-start byte or the
slow provider’s returned state. The proof now follows
`record_direct_old_allocation` through a relaxed atomic charge of the
requested size and a store of `NEW_SPACE_POINTERS` to the reserved object's
card. The address proof derives the byte offset from the published heap
base, extent, remembered-table base and installed bias. It assumes the
atomic operation’s semantics and ownership of that live byte. The [barrier proof](heap/remembered_card.render) checks the
native word-address writer and reader, including modular bias addition.
The reader preserves the byte and reports every nonzero value as dirty.

Given the unused words of a chunk, `update_base_and_limit` installs its
top and end, writes the sentinel and preserves the words above it.
For a fresh chunk inside the metadata range it also clears the object-start
table. `initialize_starts_for_chunk` verifies the exact byte count for
full and partial clears, including an empty suffix. The mapping from a
heap address to its metadata table and ownership of that table remain
assumptions. The proof also assumes that chunk-list emptiness agrees with the active range.
Establishing ownership of that range across chunk acquisition, collection
and reuse remains open.

For old space, the same sidecar proves that `OldSpace::use_whole_chunk`
reserves the last word for a null sentinel, charges exactly the usable bytes
to `used_`, and leaves the allocation range intact. With promotion tracking
enabled, it reserves the three-word header before handing out the remaining
range. The proof assumes ownership of the new chunk, enough room for the
accounting increment, and the contract of `PromotedTrack::initialize` for
the header and its card metadata. The `allocate_and_use_chunk` proof carries
that ownership through attachment and installation, assuming fresh pages,
a valid descriptor and the list attachment contract. The new list contains
the full chunk extent, including the sentinel, so the total reserved bytes
increase by the full page allocation. A page-provider failure
leaves the list, active window, charge and promotion track intact.
The [native installation check](../harness/old_chunk_install.cc) supplies one
page and runs the production list insertion, owner change, table initialization
and promotion-header writes on both word widths. A tracked installation must
return with the header’s start recorded and its card dirty. Clearing the
tables after installing the header erased both marks.

`OldSpace::allocate` transfers the requested aligned words from the active
range, including an exact fit, and leaves the remaining words intact. The
native `record_start` writes the low address byte to the object-start
table. When the range is too small, the proof checks the GC decision and
the order of the free-list and new-chunk calls. On the free-list path the
proof follows `allocate_from_free_list` through selection and installation.
Its input owns the free regions and supplies the relevant card metadata.
On success, the returned words come from the selected region. On a miss,
the active window is empty and the charged byte count reflects the flush.
The new-chunk provider still supplies a storage contract.

`old-space-retry` checks the release-build `TwoSpaceHeap::allocate` path
across a semispace miss. Only a primitive retry calls the old-space provider.
A successful retry charges the allocation once and writes the remembered-set
byte for the returned address. It preserves both neighboring card bytes.
The check includes failure of both providers and persistence of the
large-allocation-failed flag. It assumes the providers return aligned
reservations or zero and the remembered-set bias maps the candidate address
to valid card storage. The `process-array-allocation` check follows that
retry into array initialization. Removing the card mark fails at the initializer
entry. Passing an incorrect filler on either allocation path fails at the
returned array element.

`free-list-search` verifies the production old-space free-list insertion,
selection and flush for arbitrary chain lengths on both word widths. Insertion
prepends a chainable region to its size bucket and leaves the table intact for
short fillers. Selection detaches the first fit in the chosen bucket and
preserves the order of all surviving links. Flush relinquishes the unused
suffix, subtracts its exact extent from the charged bytes, clears the active
window and trims the active promotion record when present. The installer uses the same region predicate as the search. It owns every
word, including the header, size and successor. The native link accessor and
mutator read and write the third word. The provider passes the detached region to the installer,
which accounts for its full extent and calls the verified bump allocator. The returned reservation
and the remaining window are disjoint, including with a promotion header
and on an exact fit. The installer assumes room in the accounting counter
and valid card metadata. The native selection helper derives the accounting
bound from the incoming charged bytes plus the sum of every free region.
It proves the exact conservation equation across flush and search, including
the loss of a too-small suffix to walkable fillers and a search that finds
nothing. The selection contract identifies the exact region returned from the
post-flush buckets and the contents and order of every surviving chain. The
search starts at the highest nonempty bucket above the request’s bucket,
or takes the first fit in the request’s own bucket. Selection also establishes room for the payload and any promotion
header. The proof assumes
the active range is owned and accounted for and uses contracts for region
headers and promotion metadata. Mutations that drop a link or omit the
accounting decrement are rejected.

`free-list-region` exercises the native header constructor and link accessors
for symbolic word-aligned extents, including zero. It checks the tagged address,
the recorded size, the links and the boundary of writes to short filler regions.
`free-list-bucket` checks the native leading-zero calculation against all bucket
thresholds for every positive machine word.

`promotion-header` checks the production initializer with symbolic end and
predecessor, with valid table biases and every word position within a card.
It checks the class ID, tag, next pointer, end, dirty byte and object-start
byte. Recording the payload start updates that same byte or the adjacent
card, preserving neighboring metadata and the first payload word.

(No verdict on LP64: `gc-metadata-layout/LP64` gave no verdict in 3 h,
nor after the attempts of 2026-11-24, see "Two tiers", "No verdict"; ILP32
and the EC618 and ESP32 variants pass.) `gc-metadata-layout` checks non-embedded GC setup for arbitrary reported heap
bounds. Empty intervals and unrepresentable exclusive ends fail before
reservation. The OS model supplies a machine-word-aligned metadata reservation
or null, and can fail each commit. The bulk-fill
observer checks the destination, value and length. The layout proof establishes
the six table extents and their installed addressing biases. Using the mapping
published by setup, a write for any interior heap address sets the corresponding
remembered byte. An independently selected byte in any of the four committed
tables retains its value unless it is that byte.
`gc-metadata-access` checks the native word, card and overflow accessors for
every heap byte using those bounds and biases. The
[remembered-card check](../harness/gc_remembered_card.cc) follows a write
through a whole-chunk reset or a reset above a word-aligned live extent.
The raw-address and tagged array, instance and stack writers select the
same card. The last partially live card and cards outside the selected
interval retain their values. The C library fill is modeled at an arbitrary
observed byte after checking its entire destination interval. Setup must commit the four
eagerly mapped tables before initializing the page types and publishing the
singleton. Failed commits return the entire reservation. A duplicate setup
preserves the active mapping. Teardown withdraws all six table pointers,
preserves the heap heuristics setting, and releases the mapping once even
when called twice.

The EC618 and ESP32 variants follow native setup through chunk ownership
and destruction. They check each metadata slice for an arbitrary aligned
chunk of the published heap. ESP32 exercises all combinations of the heap
and metadata RAM flags, including the internal RAM prefix adjustment.

`gc-internal-ram-range` checks the production ESP32 internal RAM sizing
helper on ILP32 for every nonempty, representable interval of 4 KiB pages.
It checks the retained size in each metadata tier and the 108 KiB trim cap.

`gc-metadata-commit` checks the two lazy commits for a page-aligned chunk
within a covered heap. Given the reserved table layout, it checks both exact
2 MiB rounding intervals clipped to the reservation, including the mark
scanner's one-byte lookahead, and the fatal path on either commit failure.
`gc-page-type` checks classification for every machine word. A tagged address
inside the interval uses its page's recorded kind. Smis and outside addresses
return the unknown page type without reading the table. The OS reservation
and commit implementation and preservation
of table ownership across collections are separate obligations.

`gc-mark-roots` verifies the C++ marking visitor for arbitrary valid root
ranges. A previously unmarked heap reference enters the 128-slot stack or
is recorded for overflow recovery. The root slots retain their values.
The stack scanner filters the half-open bytecode address range, and the
weak-map rule uses the finalizer bit, instance tag and program map class.
The drain loop pops before enumeration and marks the object's post-visit
extent. Given a finite collection heap and returning enumeration and
mark-table operations, the drain terminates. Popping removes one queued
object, and pushing a newly discovered object consumes a previously
unmarked heap candidate. Every initially queued object has been scanned
when the drain returns. For an arbitrary finite path of enumerated strong
references from a marked root, if the marked objects on the path were
initially accounted for and previously scanned edges were marked, then
every object on the path has been scanned or the path contains an object
recorded for overflow recovery. Clearing the overflow flag preserves
those records. These statements concern the supplied roots and edges. `gc-object-roots` checks native enumeration for all ordinary
non-stack tags, including the exact array/instance slot range and the
active-finalizer callback.

`gc-stack-shrink` checks format-2 stack shrinking for arbitrary valid
nonempty stack storage on ILP32 and LP64, including an empty live slice.
It compares the native reserve calculation with wide arithmetic for every
signed method height, checks the source, destination and count of the move,
and checks the new length, top and unchanged execution metadata. Observing
an arbitrary word covers retained records, the unused gap, live slots and
every released word, including overlapping moves. This uses the libc
`memmove` contract and the pointer-word store contract proved by
`gc-stack-fill`, which proves termination for every valid fill count.
Using the native size dispatcher and sentinel test on the result, the shrink
harness checks the post-visit heap partition. The stack ends at the first
released word or its original successor. Each released word has a nonsentinel
header, advances the walker by one word and has no root callbacks. The
successor retains its original header, including a chunk-end sentinel.
The shrink harness also checks that the native scanner's base accessor points
to the first storage slot. Given that base and the retained bounds,
`gc-mark-roots` proves the scanner visits exactly the non-bytecode slots
in the half-open live range. `gc-stack-relocate` also checks visitors that
rewrite roots. For any supplied forwarding function, each visited slot
receives its forwarded value, bytecode pointers retain their original
values and the visitor sees the original references in order. The actual
copying collector must establish the forwarding callback contract.
The native `stack-gc-roots-test` checks the public scanner with a relocating
visitor. The `gc-stack-scan-entry` check follows the production
`Stack::roots_do` entry with a format-2 image. A damaged guard reaches
the fatal path before either shrinking or scanning. With an intact guard,
the entry passes the original top and image height to the shrinker and
dispatches the scanner on the resulting live slice. Its bytecode interval
equals the program table's half-open range and contains the frame marker.
This check assumes valid incoming stack storage and an aligned, readable
bytecode table.

For the host snapshot loader, `snapshot-image-layout` checks the image size
calculation for all signed header counts. Accepted sizes include all table
padding and program blocks. Each typed allocation from a valid aligned
cursor either fits in the external prefix or leaves the cursor unchanged.
`snapshot-bytecode-slice` runs the native byte-list reader and image
allocator with a symbolic input cursor, length and available capacity.
A successful result contains the exact payload and advances the input
past it. A truncated length, invalid payload length or exhausted image
produces an empty view and records failure. The copy uses the pointwise
libc contract.

`image-backing` checks the native aligned allocation for arbitrary sizes
and alignments, including rounding overflow and malloc failure. The aligned
payload and the last partially occupied page fit in the grant. The host
image retains the original owner and logical extent. Given an aligned
movable object outside the malloc grant, its tagged reference is outside
the published image. With a power-of-two POSIX page size and successful
protection calls, nonempty images request read-only access and restore write
access before releasing the original allocation. A second release of the
invalidated handle leaves it invalid. The debug targets also check both
fill ranges and the order of fill, protection and release. Process lifetime
and synchronization must keep the releasing handle alive while the image
is in use. Independent copies of a handle require a shared ownership
discipline at their callers.

`process-group-lifetime` checks the release decision with two exiting
members, an arbitrary representable prior teardown count and an optional
new member. `scheduler-teardown` exercises the native exit path with a
peer exiting while the lock is released. It checks that boot routing is
detached before destruction and the group survives through notification.
It runs the native GC wait before unlinking. The lock, condition variable
and destructor are modeled at their call boundaries.
`scheduler-spawn` exercises process quota and PID exhaustion, both
notification allocations, child allocation and notification rejection.
It runs the native encoder handoff and process setter with any permitted
copy count and up to one transferred external byte array. Its assertions
cover the sender's charge and finalizer flag, the child's argument slots,
and ownership of the encoder buffer on admission and refusal. The group
starts with zero or one peer. Child construction, notification delivery
and scheduling use contracts. Since wave 8 a rejected notification tears the
constructed child down (out of its group, destroyed outside the lock, the
notice released once) and leaves the arguments in the encoder; only an
accepted one schedules the child with its arguments.

The format-2 boundary represents the current task and its stack as
mutable process state. After a collection the caller must read both
pointers again. The `grow-stack-stale-task` regression retains the task
pointer across that collection and fails when it tries to use it.

The format-2 boundary owns four concrete header words for each stack.
VeriFast checks the native reads of length, top, packed record bounds and
bytecode index, the write of top, and the slot address computed from a
primitive argument's position. It compares the header offsets and sizes
against the compiled C++ constants for both host word sizes. Record
packing on write uses the native `stack-records` check described below.

The stack-growth proof takes a fresh format-2 stack with an allocated
header and initialized slot storage. The two copies preserve the record
prefix and live suffix. The unused gap stays initialized, as required by
Rust's `StackMem` view, when the task publishes the destination.
The `grow-stack-missing-slots` regression removes the live-slot copy.
The `fresh-stack` check calls the C++ allocator for every length through
`Stack::max_length()` with a valid loaded class ID and a raw reservation
that can fail. It checks the slot range, header, guards and the address of
each primitive argument counted from the end of the array. It applies
the VeriFast fill contract at an arbitrary slot. The slot contains tagged
zero for format 2 and retains its incoming value for format 1. The `stack-records` check
packs and reads back every frame top, finally count and bytecode index
that fits such a stack, and checks all unaffected header words.

`initial-task-capacity` compares the process-group admission check with
the actual initial stack and task reservations for every class descriptor.
It covers both host word sizes and the smaller FreeRTOS page. The separate
`allocate-task` harness exercises native task and stack initialization
with two to six task fields, a symbolic task ID and a bounded young-space
window. It checks failure at either reservation, guard words, task fields,
the write barrier, the sentinel and when the ID advances.

`instance-allocation` checks every encoded instance size, a symbolic
class ID, and the exact-fit and insufficient-space paths. It checks the
arguments to `Utils::fill_words` and applies that function's VeriFast
postcondition at an arbitrary field. The native allocator writes the
class header and sentinel. An empty descriptor fails before reservation.
`task-all-fields` uses the same fill contract inside native task creation
for every representable task field count starting at two.

`scheduler-gc-barrier` checks native target selection for every process
state. It exercises two collectors with at most one cross-process barrier
owner and checks that their claims cannot overlap. It runs native FIFO
removal with an optional predecessor and successor, checks the repaired
tail and ready count, and runs the native wait with zero or one
spurious wakeup and an arbitrary nonnegative preemption count.
`scheduler-gc-scan` runs the native collection loop for a single registered
target and up to one running interpreter. It checks idle scans, an arriving
waiter, a barrier owned by a peer, and preemption with either acknowledgment
or timeout. A worker still running after a timeout must be skipped. The
production code claims and resumes idle and scheduled targets. Two wakeups
during the heap callback produce one ready entry on ordinary resumption.
The heap callback, OS calls and worker notification use observers.

`scheduler-gc-ownership` starts with the target owned by a collector,
an arbitrary requested and active priority, and an optional pending wake.
It checks each locked wakeup, priority change and competing claim preserves
the collector link. Release removes the link before queuing a runnable
process at its requested priority. A barrier waiter stays suspended.
These native checks supply the selected physical FIFO at the bucket lookup
and run the production FIFO operations. `scheduler-target-queue` separately
checks the actual scheduler array for symbolic priorities, including when
two priorities address the same bucket.

`scheduler-ready-dispatch` proves the dispatch loop for arbitrary finite
contents of all five priority queues. Given FIFO empty/pop contracts and an
initial count equal to the total length, dispatch returns the first process
in priority order, preserves the remaining FIFO order in each bucket and
updates the count. Empty dispatch returns null with a zero count.

`scheduler-gc-targets` proves queue construction for any finite registry.
It follows the group anchor and each group's null-ended membership list,
passes the barrier ownership flag to every claim and appends each admitted
process once in visitation order. It preserves the original membership
links. The input assumes a well-formed registry and a detached scheduler
link for each successful claim. Scanning calls the heap scan helper with the original
collection mode once per entry, returns the queue length and preserves the
links. Cleanup consumes the queue and calls resume in FIFO order for every
ordinary suspension. The proof assumes a well-formed claimed queue with a
representable length, a terminating scan that preserves its links, and
state observations under the scheduler lock. `scheduler-target-queue`
checks the native worker, group, member and queue iterators and FIFO
append and pop, including separation from the group membership link.

`scheduler-gc-workers` proves that the preemption loop visits every
worker in list order and sends one signal per interpreter bound to a
process other than the requester. Each pass replaces every worker's mark
with its membership in that request. Its returned count equals the number
of signals. Acknowledgment consumes the mark, decrements a positive count
once and wakes the collector when the count reaches zero. A late return
after timeout clears the mark with the count still at zero. The proof assumes
a stable finite worker list of at most `INT_MAX` entries, valid live process
pointers and a terminating signal operation that preserves the list and
interpreter bindings.

`scheduler-worker-handoff` follows one native worker-loop dispatch from
dequeue through return to the scheduler. Its interpreted process has the
untrusted policy. It also checks a trusted external runner. The fixture
includes a queued peer, an initial GC waiting for another interpreter, and
a collector requesting preemption during the unlocked execution callback.
One schedule runs the native cross-process collection to completion before
the dispatch returns. Its wait times out for a bound interpreter, and the
collector skips the running heap. At a dispatch barrier wait, the fixture
runs native target selection, scan and release over the subject's group.
The heap callback checks both worker bindings and the suspended state.
Assertions reject any call to ordinary GC suspension or resumption for this
worker-owned subject.
It checks publication and retirement of both worker bindings, elapsed CPU
time, skipped execution for pending signals, and routing of yields, kills,
termination and device halt requests. A previous dispatch leaves a method
pointer in the interpreter. Only a new run that returns preempted may read
the header for a sample. The fixture checks profiler activation bookkeeping
with no sampleable task. Interpreter and runner bodies, locks, condition
variables, profiler notification, ready notification and termination use
observers. The fixture stops the worker after that dispatch.

`gc-mark-queue` checks the native grey-mark, repeated-visit and overflow
operations with arbitrary existing mark bits and valid metadata storage.
It checks the one-bit change, the second mark bit on either side of a card
boundary, and the overflow recovery address. An overflow sets exactly one
card bit and records the earliest of the previous and newly queued object
starts, preserving adjacent bytes.

`gc-overflow-byte` checks the production bitmap scan with arbitrary starting
bits and arbitrary further overflows during each callback. It checks the
order and address of every selected card, immediate clearing before the
callback, same-pass handling of flags raised ahead of the scan, and
retention of flags raised on the current or an earlier card.
`gc-overflow-registration` connects the native overflow recorder to the
group scanner. Starting with any existing flags and valid recorded starts,
it registers two word-aligned objects in any order, including on the same
card. Both fall within the delivered scan intervals, every marked card is
delivered once, and its interval begins at the earliest recorded start.
The Frama-C target `gc-page-scan-wp` also proves by induction over a
sequence of arbitrary representable length that the production registration
update preserves every earlier discovery. For any of the eight cards,
its flag after the sequence is set exactly if it was set initially or an
event selected that card. Its start is the earliest of its initial valid
start and all offsets registered for it, including duplicates. The sequence
covers registrations between scans that clear flags.
This check observes intervals before object traversal. The per-card proof
supplies the traversal under its heap-partition assumptions.

`gc-overflow-card` checks the native per-card object walk. For any object
start in the scanned interval before the chunk sentinel, the walk inspects
that object and traces it and marks its post-visit extent exactly when it
is grey at inspection. Positive extents give the loop a decreasing
distance to the sentinel. The partition contract supplies a readable header
at each boundary, a zero header only at the sentinel, and sizes that
advance to a valid boundary without skipping an original object. Stack
visitation may shrink the current object. The chunk loop pairs each group
of eight cards with its metadata byte and drains the mark stack after
each group. `gc-mark-process` checks repeated passes over the actual
old- and young-space chunk lists. The proof nominates arbitrary chunks
in both spaces and permits deferred cards to exist while the overflow
flag is clear during a pass. The process returns with the queue empty,
the flag clear and no pending cards in the nominated chunks. Raising
the flag after a reset requires a first discovery, so another pass
decreases the number of unmarked candidates. This result assumes stable
chunk ownership, valid heap partitions, complete marking callbacks and
the correspondence between recorded work and physical bitmap bits.

`v2_gc` verifies the handoff from the format-2 interpreter to the scheduler.
Before collection it remembers the current task's stack and forwards the
malloc-failure and cross-process collection flags. Attempt three reports
allocation failure and preserves the VM state and epoch if reporting returns.
A primitive call consumes evidence that its argument stack was remembered.
The retry reloads the stack and runs the barrier again after collection.
The FFI proof reads the current task from the object heap and reads or
writes the task's stack pointer at the checked `Task::STACK_INDEX`.
The store that publishes a grown stack requires evidence that the task's
card was marked. The field accessors use the native `Instance::at` and
`at_put` bodies with permission for this one slot.
`gc-stack-barrier` checks the native barrier on both word widths for an
arbitrary aligned stack header and installed card mapping. Collector
semantics, scheduler synchronization, and OS reporting still use contracts.

`gc-process-roots` checks the addresses, lengths and ordering of the
ranges supplied by `ObjectHeap::iterate_roots`. Its callback visits
the task slot, the globals range (including length zero), and
each reachable external-root and notifier slot. The harness supplies
forward chains with up to two nodes of each type and a symbolic valid
global count. In `gc-current-task`, the callback writes a chosen task
address into the process root. The harness reloads that task and scans
its two fields through `HeapObject::roots_do`. Updating the stack reference preserves the ID,
and the native accessors return the selected task and stack whether
either, both, or neither moved. The harness supplies the forwarding addresses.
`gc-root-iterator` checks the mutable C++ cursors and the
local link updates that prepend a head or remove a registered node at any
position for both node types.
`gc-process-root-lists` proves that the production enumeration terminates
and delivers those same ranges, in order, for arbitrary finite forward
chains on ILP32 and LP64. The callback may update slot values while the
proof retains ownership of the list links. The global-count getter uses
the contract checked by the native harness. Establishing that all live
references have been registered at collection time remains open.

`gc-process-epoch` checks the production `Process::gc`, `ObjectHeap::gc`
and `set_task` on LP64 and ILP32. For an arbitrary starting epoch, each
completed collection increments the exported word once under the heap lock,
including wraparound. The check covers collection kind, counters, retry
state, full-collection limits and task publication. Lock primitives, the
two-space collection and space-size measurements use contracts.
The FFI predicate owns the exported epoch word and tracks its unbounded
count. VeriFast checks the native increment at every starting count,
including wraparound, and checks that publishing a task advances the
count exactly once. Both GC and task publication use this increment.

`gc-scavenge-clone` verifies both native specializations of
`ScavengeVisitor::clone_into_space`. Given a valid object size that fits
an int, aligned to a word, initialized source bytes, a valid allocation
window and the libc copy contract, the destination retains the original header and payload.
The original header then points to the destination, its payload remains
intact, and allocation failure preserves the entire original object. The
clone calls import the generated allocator contracts from `heap/semispace.gen.h`.
The young allocator leaves a sentinel after the copy. The old-space fast path
records the start, and the slow path retains the free-list or new-chunk
provider's outcome.
`gc-scavenge-roots` proves the native range loop terminates and visits every
reference slot in order, including empty ranges and repeated references.
The proof includes the single-slot helper. A reference outside from-space stays
unchanged. A forwarded object reuses its installed destination. A first visit
copies or promotes the object, falling back to young space when promotion fails.
The card byte and old-space collection request retain their initial values
unless a young reference or a failed promotion respectively requires an update.
For a distinct inventory of source objects and valid root values, the proof
owns each object's header word. It follows the native tag test and header
load. Both clone bodies establish the same tagged forwarding pointer that the
visitor consumes. Installing one entry preserves the other headers, so a
later alias reads the installed destination. For a chunk whose extent fits in the
address space, both native membership checks implement a half-open interval,
including when unsigned subtraction wraps below the start. The source test
also rejects every tagged integer. The relocation map records the address
returned by each first successful copy. The final array equals the result
of applying that map to every original slot. Exclusive ownership of each
copied header prevents distinct copied sources from acquiring the same
destination. Collection entry still supplies the source inventory and valid
chunk descriptors. The native visitor constructor derives both cached intervals
from those descriptors. For a borrowed destination chunk, the embedded semispace
constructor establishes the empty allocation window, writes its first sentinel
and preserves the remaining words. The empty source-list case is excluded by
the single-chunk lookup contract. The native owner setter publishes the supplied owner,
uses its page type, and invokes all four initializers. Given the table mappings,
the native fills reset overflow bits, remembered cards and object starts over
their exact slices. Clearing the owner preserves that metadata. For mapped chunks the page table receives one classification byte per page.
The two host targets both use the 32 KiB page size checked against the VM headers.
The native clear zeros one mark byte per eight heap words. The remembered-card
and overflow accessors derive their addresses from the published biases.
These proofs require aligned chunks and mapped storage with the expected
extent. The semispace proof uses the native object-start accessor for both bulk
initialization and single-byte allocation records. Its address-range test includes
the upper endpoint. The setup harness checks interior addresses against the
committed tables and checks lookup at their logical end. The native space constructor initializes the program, page
type and zero allocation bounds. The native semispace append sets ownership and
links the destination chunk. The same sidecar proves removal for an empty or
single-chunk space, including reclassification of the full page range. It also
proves that survivor transfer rebinds the descriptor, transfers the allocation
window, and clears the temporary space's bounds. The underlying list operations, the LivenessOracle
base constructor, and ownership of mapped memory still supply contracts. The allocator supplies storage, the placement of successful
copies in the requested space, and enough young-space capacity.
`gc-scavenge-alias` exercises the native root visitor on a three-word
object with repeated references. It checks promotion, fallback when old
space refuses allocation, and direct copying to the destination semispace.
A later alias in a different root range must reuse the forwarded object
and record a young destination on that range's card. The harness assumes
to-space can accept the survivor.

`gc-promotion-capacity` checks the production page calculation used by
`OldSpace::allocate_in_new_chunk`. For every request, preferred size, signed
expansion limit and tracking mode, it verifies exact admission and the chosen
page count. A successful request fits its object, the sentinel and, when
tracking, the three-word promotion header.

`old-chunk-expansion` checks the native expansion decision together with
the process quota calculation. It includes both space reservations and
external memory, even when their mathematical sum exceeds a machine word.
A stopped promotion or insufficient budget requests no pages. A provider
failure sets the malloc-failure flag. Success installs the admitted page
count and retries the original payload size exactly once. For a bounded
process the remaining allowance drops by the size of the entire linked
chunk. The check uses the space-size, installation and bump-allocation
contracts and assumes stable quota inputs during the call.

`gc-scavenge-drain` proves termination of the loop that alternates scans
of the destination semispace and promoted objects in old space. Either
scan can enqueue work in either space. The proof includes
`OldSpace::complete_scavenge` and its per-track walk. After flushing, it
detaches the original chain, selects the object's card before each visit,
advances by the post-visit size, and retires every detached header. New
promotions remain on the live chain for a later pass. Empty tracks report
no work. The old pass imports the generated `free_list.gen.h` contract for
`OldSpace::flush`, opens the concrete end word of the current header, and
recovers the trimmed range and the free-list update. The budget includes
occupied old payloads, unused bump space, free-list regions and retained
short fillers. Starting a scavenge flushes the untracked allocation window
before enabling tracking and preserves its capacity. The drain exits with
the physical track head null, satisfying the tracking exit condition. The old pass deducts each detached nonempty extent. A root
visit can transfer capacity to another region subject to the combined bound. The same proof includes the young-space pass over
a finite chain of chunks. Each empty chunk shortens the remaining walk. A
nonempty chunk advances its scan pointer and can append chunks. Remaining
young capacity is the sum of chunk ends minus scan pointers. The loop combines
this capacity with the old-space and external reserves. The iterator
reads its successor after the visit. A visited chunk stays drained and
the pass reports work if any visited chunk contained objects. The per-chunk
interface assumes the pending suffix survives allocation, visited chunks
stay drained, and the number of remaining chunks fits in an address word.
Providers must charge appended capacity against the available reserve. The native `gc-promoted-track` check covers track initialization,
card metadata, trimming the end, and replacing exactly the three header
words with single-word fillers. `gc-scavenge-chunk`
verifies the inner walk of a destination chunk. The queue can grow at
each call to the object's root enumerator. For an arbitrary object
address initially pending or newly enqueued, the walk visits it exactly once before
publishing the final sentinel as the next scan position. Progress follows
from positive object sizes within the chunk limit. The allocator derives a finite,
duplicate-free list of aligned addresses from its window and splits that list
at each successful reservation. Given coverage of the current chunk, the scan
removes visited addresses without relying on the callback for membership.
For every address in a duplicate-free input pool, membership in the returned
pool is equivalent to having remained unvisited. Object layouts and the
enumerator's preservation of the pending suffix supply contracts.

`gc-collection-phases` checks the production full-collection entry on both
word sizes. Strong roots, callback finalizers and VM finalizers feed three
marking waves before the collector computes destinations. Sweeping publishes
the survivor size and clears young marks. Compaction uses old-space marks
to select live young objects, updates ordinary and finalizer roots before
clearing marks, and restores chunk ends. The harness checks the selected
mode, callback identities, ordering and byte accounting. Enumeration,
object movement, finalizer behavior and bitmap operations supply contracts
at these call sites.

`tests/gc-mark-overflow-test.toit` exercises the untrusted
runtime with a cyclic graph of 320 live children, checking their payloads
and links after allocation pressure. A host run instrumented at the card
walker confirmed that overflow recovery ran for this test's snapshot UUID.

`gc-object-size` checks the production size dispatcher for all twelve tags
with valid class metadata and representable layout fields on both word
sizes. It also checks the overflow walker's one-word exception. For a
discovered object whose native size is one word, the mark covers the
whole extent and the native root enumerator delivers no reference slots,
even with weak-map skipping disabled. For a larger object, the grey test
reads the second mark inside the object, including across a card boundary.
The size coverage includes single-word fillers, free regions, promoted tracks,
internal and external byte arrays and strings, boxed numbers, and stacks.
The harness materializes the header and class entry and checks that the
reported extent matches the represented layout. Actual allocation of that
extent, construction of a complete partition, discovery of all roots and
preservation of the reachable graph across marking, movement and sweeping
remain separate obligations.

The Frama-C target `gc-page-scan-wp` checks the card traversal and filler helpers used directly by
`OldSpace::sweep` on both word sizes. The empty-card scan clears the
object-start entries of the empty run, stops at the first nonempty card or
the chunk end, and permits whole-chunk release only for an entirely empty
mark map scanned from its start. For every 32-bit card pattern and every
starting word from zero through 32, the filler loop writes its marker to
each unmarked word in the selected suffix and preserves the prefix and
every marked word. The caller supplies aligned card storage and the mark
map.

`gc-sweep-free-region` checks the production calculation of the interval
passed to free-list insertion. For an aligned run of one or more empty
cards it admits arbitrary nonzero neighboring mark words or a chunk
boundary. The preceding suffix and following prefix end exactly at the
nearest marks. At the chunk end the extent excludes the sentinel. Each
interval has room for the native header, and skipping filler writes in a
following card implies that every word after the prefix is marked. This
check takes the empty run and neighboring marks from the production card step.
Frama-C checks that the step reads the exact adjacent mark words, substitutes
the boundary values only at the chunk edges for an empty run, and advances
past the following marked card. An induction from card zero proves that
repeated steps terminate and select each nonempty card exactly once for any
valid number of cards. Intervening heap and free-list writes must preserve
the mark map.
The header constructor and insertion have separate proofs (`free-list-region`
and `free-list-search`).

For whole-object marking, `gc-mark-all` checks the native fast path and
selection of the slow path with both aligned and unaligned access on both
word widths. `gc-mark-range` checks the production slow marker, including
machine-width object sizes, against an arbitrary bit inside or outside the
requested interval. Its bulk-fill observer uses the contract of the native
32-bit word loop. `gc-bitmap-fill` proves that loop by induction over its
element count. These checks require a valid object extent and writable,
mark-table storage aligned for a 32-bit word. The harness varies the offset
of the table relative to the heap page's mark bytes. The C++ build of the fast path
with unaligned access uses little-endian words.

### The externals' ownership (wave 5, done)

A message (`msg_whole(b)`) owns its malloced buffer and its out-of-line
blocks `ps` (the order of their pointers; `encoded(b, cap, ps)` is the
abstract fact that the encoder wrote it). The decoder's predicate `dec`
holds, for IPC, the blocks after the j pointers read (`ipc_pos`), and for
a decoder with a process the `lent` tokens of the first k (one per entry
of the externals table: `finalized(o, p)`, from allocate_external_*), and
block k when its allocation failed (status ALLOCATION_FAILED).
read_pointer hands block j to its caller (`ipc_pointer`: the j-th pointer
is the j-th block; ownership is never created, only moved), so the walk
of MessageDecoder::deallocate frees each block once, and a decoder for a
process holds it out (`dec_out`) until register_external records the
token or mark_allocation_failed takes it back (`dec_af`).
remove_disposing_finalizers turns every token back into its block
(`clear_has_active_finalizer`) and gives the whole message back
(`dec_back`); on a success `ipc_end` says every block was read, hence
lent, and the tokens go to the GC (`gc_owns`). The "reads stop at the
first failure" fact is the condition `not_failed` on the decoder's reads
and marks (a decoder for a process reads no pointer after an allocation
failure). The finalizer bit is in the header word, so the receive
primitives keep `grows_class` (classes, lengths and aux words), not
`grows`. The malformed path of the three primitives fails the proof
without the drop (mutants *-malformed-delivered); the drop is applied
(05159afd). Modelling clear_has_active_finalizer's contract ("gives the
block back") exposed the double free of "Findings".

### The retry obligation (wave 7)

The core's contract for a call of a C++ primitive (gc_call_primitive)
takes the whole C++ call as ONE step, including the calls after a GC when
the primitive failed for want of memory (MALLOC_FAILED, ALLOCATION_FAILED,
CROSS_PROCESS_GC; v2_primitive_failed, at most four calls). That is a
completion of the original step only if a failed call has no visible
effect: no existing object written, no message sent or consumed, no
resource, timer, notifier or finalizer registered, no malloced memory kept
or freed. New objects that nothing references are garbage (the GC before
the retry removes them), and so is a VM finalizer node whose object gave
its memory back (a failed decode). The ffi proof states this as the
assumption `prim_retry`; this wave discharges it per primitive.

Reach: every C++ primitive of the untrusted policy, 150. The 35 core, 2
bitmap and 7 timer and events primitives that stay C++ are called
directly; the 106 core primitives ported to Rust call their C++ primitive
when the port declines (NeedsGc: an allocation did not fit; NotPorted:
proxies, copy-on-write byte arrays not yet copied, sums above
MAX_BLOB_LENGTH, ...). The Rust side cannot decline after an effect: Verus
proves `NeedsGc`/`NotPorted` leave the heap equal (`prims::prim_post`) and
the machine unchanged (`rarrays::rust_primitive_r`, `res is None ==>
*final(m) == *old(m)`).

Classification (CONTRACTS.toml `[prim_retry]`, checked by
contract_check.toit: the untrusted set is read from src/primitive_policy.cc
and src/primitive.h; a primitive missing, classified twice or not in the
set fails the gate, so a new primitive in the untrusted set must be
classified):

| Class | Count | Evidence |
|---|---|---|
| (a) cannot fail for want of memory | 62 | the primitive's body (or its macro) has no allocation, allocating argument kind (MutableBlob, cstring) or out-of-memory error: checked by contract_check.toit (a tripwire for helpers that allocate; reviewed) |
| (b) fails for want of memory only before any visible effect | 88 | 86 by tests/ctest/prim-retry-test.cc (below), 77 of them also proved with VeriFast (`oom_clean` or `oom_unchanged`, below; 63 before wave 12, 37 before wave 10, 30 before wave 9, 25 before wave 8), 9 tested only (23 before wave 12, 49 before wave 10, 56 before wave 9); 2 reviewed (task_new: a format-1 path needs an interpreter; encode_error: needs a scheduler thread), the arguments in the table |
| (c) violates it | 0 | |

tests/ctest/prim-retry-test.cc makes every allocation of a call fail in
turn, the k-th and all after it, for every k up to the number a successful
call makes (the linker wraps malloc, calloc, realloc, free and
TwoSpaceHeap::allocate, through which every heap object but instances is
allocated; libstdc++ is static, so `new` is wrapped too). For each failure
reported as out-of-memory it compares the arguments (deeply: fields,
elements, bytes, finalizer bits, string hash codes), the process
(mailbox, main and spawn arguments, timers, resource groups, object
notifiers, external memory, finalizers to run) and the malloc balance with
the state before the call, then the retry with a call that never failed.
task_has_messages fails for want of memory by the process's limit, not an
allocation: the test sets the limit. 86 primitives, host and host32; a
mutant that drops timer.create's `remove_timer()` on a failed malloc fails
it (the timer quota counter leaks). Limits: instance allocation
(ObjectHeap::allocate_instance, inline allocate_new_space) is not wrapped
(the receive path's maps; their allocation failure is in the wave-5
VeriFast proof); the process is format 1, so task_new's format-2 path and
encode_error are reviewed.

Proved with VeriFast (evidence "verifast", LP64 and ILP32) for 25 of the
rendered primitives: array_new, byte_array_convert_to_string,
string_to_utf_16, utf_16_to_string, crc, float_to_string, float_parse,
float_round, the four integer formatters, smi_divide, smi_mod,
large_integer_divide, large_integer_mod, int_parse,
seconds_since_epoch_local, platform, architecture, time_info, time,
get_real_time_clock, add_finalizer and task_has_messages. Their contracts
state `oom_clean(objs, H, objs2, H2, result)` (model/objects.render): an
error result (a marked word; every out-of-memory error is one) leaves
every object of the heap before the call unchanged. It is stated for every
error, not only the out-of-memory ones, so it needs no identity of the
error roots, and it holds for these primitives because each of their
errors comes before any write to an existing object (most contracts
already said so per error; get_real_time_clock needed the chain of
`same_obj` through its second integer, `same_obj_trans`). The argument
slots and the rest of what each contract owns (add_finalizer: the
registered callbacks, unchanged on every error by `addition_out`) are in
the contract. contract_check.toit checks that the definition's contract
states `oom_clean` and that run.sh proves the rendering. Mutant
finalizer-primitives-oom-after-effect: add_finalizer returning
MALLOC_FAILED after the registration fails at `oom_clean`.

Wave 8 adds five: string_write_to_byte_array, byte_zap and blit
(`oom_unchanged`, below) and read_uint_big_endian, read_uint_little_endian
(`oom_clean`; their C++ runs when the Rust port declines,
`prims/read_bytes.render`).

Wave 9 adds seven, all C++ behind Rust ports: read_int_big_endian and
read_int_little_endian (`oom_clean`, `prims/read_bytes.render`), and the
writers byte_array_replace, put_uint_big_endian, put_uint_little_endian
(`prims/put_bytes.render`), put_float_32_little_endian and
put_float_64_little_endian (`prims/put_float.render`), which decode a
MutableBlob first and so state `oom_unchanged`. Their success result is
the null object, a heap object: `oom_unchanged` now has the disjunct
`mem(result, objs2)` that `oom_clean` already had (model/retry.h; the
lemma `heap_object_not_oom` proves from the heap that such a result is
not an `oom_error`). Mutant byte-array-replace-oom-after-copy (an
out-of-memory error after the copy-on-write copy).

Wave 10 adds the allocating primitives behind the Rust ports, whose C++
runs when the port's allocation does not fit (NeedsGc): byte_array_new
(`prims/allocating.render`) and array_expand (`prims/array_expand.render`),
both `oom_clean` (the allocation is their only failure for want of memory,
before anything is written). Mutants byte-array-new-memset,
array-expand-old-length, array-expand-copy-long (memory safety). Also
string_add, concat_strings and string_slice (`prims/strings.render`,
`oom_clean`; mutants concat-strings-bound, string-add-bound,
concat-strings-failed-part, string-slice-copy-long). concat_strings
decodes each part twice, before the allocation (to sum the lengths) and
after it (to copy): the proof shows the second decoding gets the same
lengths (`decoded_stable`: what byte_content decodes depends only on the
objects it reaches, which the allocation keeps; the Blob decoder's
contract now states its result's length as `decoded_length`), and copies
with the new string taken out of the heap (`foreach_restrict`: the old
objects reference only each other), so a part is never the new string.
Also the eleven float primitives that box a double (`prims/float_ops.render`:
float_unary_minus, float_add, float_subtract, float_multiply,
float_divide, float_mod, float_sqrt, float_ceil, float_floor, float_trunc,
number_to_float) and ten integer primitives whose result may be a large
integer (`prims/int_ops.render`: large_integer_add, _subtract, _multiply,
_unary_minus, _not, _shift_left, _unsigned_shift_right, smi_unary_minus,
smi_shift_left, smi_unsigned_shift_right), all `oom_clean`; mutants
float-add-returns-receiver, smi-shift-left-count,
large-integer-unsigned-shift-count. Still tested only (23): the bitwise
and/or/xor primitives (VeriFast needs a range lemma between a call's
result and the operator, and bitops.gh's `bitxor_signed_limits` states
`|`, not `^`), large_integer_shift_right (an arithmetic shift by a
run-time count: no rendering rule yet), smi_add, smi_subtract,
smi_multiply (`goto`, `__builtin_mul_overflow`: no rendering rules),
the four raw float conversions and number_to_integer (bit_cast and the
double-to-int64 conversion), string_from_rune (array initializers), and
the message, timer and notifier primitives (below).

Wave 12 adds fourteen, all C++ behind Rust ports and all `oom_clean`:
smi_and, smi_or, smi_xor, large_integer_and, large_integer_or,
large_integer_xor, smi_add, smi_subtract and large_integer_shift_right
(`prims/int_bits.render`: the signed range of `^` proved from VeriFast's
Z definitions; smi_add's `goto overflow` by the translator's goto and
label rules; the arithmetic shift by a run-time count by its asr_int64
rule), float_to_raw, float_to_raw32, raw_to_float and raw32_to_float
(`prims/float_raw.render`) and string_from_rune
(`prims/string_from_rune.render`: the translator's array-initializer
rule). Mutants int-bits-shift-count,
int-bits-xor-smi, float-raw32-range, float-raw-returns-argument,
string-from-rune-length. Still
tested only (9), with what blocks each: smi_multiply
(`__builtin_mul_overflow` has no rule, and its success path returns the
product as a tagged word: the parity of a product through the modular
conversions to a word and back to an address, `truncate_signed` and
`truncate_unsigned`, for which VeriFast's library has no lemma),
number_to_integer (VeriFast 26.10 has no double-to-integer conversion,
no `vf__int128_t_of_double`, and its double comparisons are
uninterpreted, so the C++'s range check cannot be connected to the
conversion), the
receive primitives (below; the decoder's contracts), and the message,
timer and notifier primitives (scheduler contracts: process_send,
timer.init, timer.create, events.register_monitor_notifier; the ESBMC
body checks of the README's primitive table cover their failure
paths, not as `oom_clean`).

string_write_to_byte_array, byte_zap and blit install a copy-on-write byte
array's copy (a write to an existing instance) before a later argument or
range check can fail with another error, so `oom_clean` does not hold.
They state `oom_unchanged(prog, objs, H, objs2, H2, result)`
(model/objects.render): a result the retry protocol retries,
`oom_error` (moved from ffi/interpreter_v2.render to the model, the same
definition: a marked error that decodes to MALLOC_FAILED's,
ALLOCATION_FAILED's or CROSS_PROCESS_GC's root by address), leaves every
object of the heap before the call unchanged. Proving that the other
errors are not out-of-memory ones needs the error roots to be distinct:
FAIL(OUT_OF_BOUNDS) decodes to the OUT_OF_BOUNDS root, Error::from of a
root decodes to that root only if the root is a heap reference above the
immediate errors. Decision (wave 8): a model fact checked where the
program is loaded, not an assumption. The `process` predicate's body
(objects.gen.c; `process_program` hands it out) states
`error_roots_ok(drop(Program_FIRST_ERROR_INDEX, program_roots(prog)))`
(the error roots are heap references at or above `Error::MAX_TAGGED_ERROR`
at pairwise different addresses), ProcessGroup::create refuses a program
for which `Program::has_valid_error_roots` (src/program.cc) is false, and
VeriFast proves that this function returns exactly `error_roots_ok` of the
root table (`loader/error_roots.render`, LP64 and ILP32; mutants
error-roots-skip-neighbour, error-roots-heap-check). The definitions and lemmas
are in model/retry.h, included only by the renderings that use them: in
objects.gen.h, which every rendering includes, they made the unrelated
utf16-to-8 proof fail (Z3's search depends on the declarations in
scope; it failed on ILP32 with the lemmas there, and on LP64 with the
fixpoints in the `program` predicate). Regression test
tests/ctest/program-error-roots-test.cc: a compiled program passes, each of
the 378 pairs of equal error roots, a smi, a low address and a word tagged as a marked error is
refused by the check, and ProcessGroup::create refuses the samples. The
lemmas `immediate_error_not_oom` and `marked_root_not_oom` give the facts a
proof needs; the named accessors (`Program_wrong_object_type`,
`Program_permission_denied`) now state their slots (checked against the
native accessors by the ESBMC error-roots harness), Error::from the marked
word's quotient. Object::mutable_byte_content states the same retry fact:
an out-of-memory error comes only from a call that changed nothing on a
non-byte-array (its copy-on-write allocation), so the slice case that
fails after an inner copy reports WRONG_OBJECT_TYPE. Mutants (an
out-of-memory error after the copy): mutable-byte-content-oom-after-copy,
string-write-oom-after-copy, byte-zap-oom-after-copy, blit-oom-after-copy.

The receive primitives (decision, wave 8): their contracts now state that a
result `oom_error` retries leaves the mailbox (the same first message,
queued and whole again) or the arguments slot (`a2 == a`) unchanged, and
every other result is an object or another error (proved; mutants
receive-oom-drops-message, arguments-oom-drops-slot). Their retry evidence
stays "test": the heap part would need the decoder's contracts to say that
it writes only the objects it allocates and that remove_disposing_finalizers
clears only their finalizer bits (they say the heap grows and keeps
classes). The test covers their failure points (the result array, the
decoder's allocations).

### The two-pass assumption

Every caller of the encoder (process_send, spawn, the program registry's
spawn, tison_encode) runs it twice on the same heap: a size pass without a
buffer, then a write pass into a buffer of the size the size pass
returned. The encoder never checks a write against the buffer: a write is
in bounds only because the size pass counted it. This is the encoder's one
assumption, the bodiless lemma `two_pass_room` (encoder/message_encoder,
CONTRACTS.toml `[[assumption]]`, checked by contract_check.toit: listed,
bodiless, its contract as written; an unlisted bodiless lemma of a
rendering fails the check): at a write of n bytes at cursor c in the write
pass, `c + n <= cap`. Why it holds: both passes decide the same way (the
heap, the policy and the encoder's inputs are the same; between the
passes the callers only allocate the buffer); the write pass can stop
earlier, never later (its only extra failure is a failed malloc; TISON
writes the payload's cardinal before the payload instead of after, so the
write pass's sizes are ahead by at most that cardinal and its size checks
fire first); so it writes a prefix of what the size pass counted. To prove
it: a ghost encoding function over the heap and the encoder state (the
early stops depend on the cursor, the externals and the transfers),
shown equal for both passes (5-7 days). Everything else about the buffer
is proved: the writers keep `cursor_ + external_bytes_` below the limit
plus ENC_SLACK on both widths (the predicate `enc_out`), and every write
goes to `uchars_(buffer, cap)` at the cursor.

### The decoder's assumptions

The untrusted path, TISON (`tison_decode`: the bytes of a blob, `size_` its
length), needs none: every reader checks the cursor against `size_`. The
inter-process path decodes a message the encoder wrote, with `size_` set
to INT_MAX: the readers' checks do not bound the reads by the message.
Bodiless lemmas (CONTRACTS.toml `[[assumption]]`, checked by
contract_check.toit like `two_pass_room`) state what that path relies on
(wave 5 split the old `ipc_external`, which created a block's ownership
out of nothing, into narrower facts; ownership now comes from the message,
"The externals' ownership"):

* `ipc_begin(d, b)`: a decoder constructed over an encoded message reads it
  from the start (names the message, `[_]ipc_msg(d, b, cap, ps)`, and
  starts the pointer count `ipc_pos(d, 0)`).
* `ipc_room(d, n)`: a read of n bytes at the cursor lies in the message.
  Used at each read of the IPC path, with the read's size.
* `ipc_pointer(d, p)`: the j-th pointer read is the j-th block.
* `ipc_external(d, length)`: the length before a pointer is a content
  length, below MESSAGING_ENCODING_MAX_SIZE.
* `ipc_length(d, n)`: a length the deallocation walk reads is that of what
  follows (a byte per element at least).
* `ipc_end(d)`: after the message's value (a process's decoder: with
  success; the walk: always) every pointer was read.

and the GC's `gc_owns` (an object with an active finalizer owns its block).

Why they hold: the encoder writes the message, the decoder reads it in the
same VM with the same tags and limits (nesting 8 against 64, the smi
range, array and map lengths: since this branch the encoder refuses arrays
and maps longer than a process heap holds, "Findings"), so it reads
exactly what was written; each out-of-line block is written once, after
reserve_external (at most 8). Proving them takes the encoder's ghost
encoding (the two-pass assumption's) as the decoder's input. Like
`two_pass_room`, each is used only at the reads it describes (an
assumption with a large `n` would give false: review the calls, they are
in the reader functions and the two out-of-line branches).

The proof's model of the input is a chunk separate from the heap. For
tison_decode the bytes are the content of a heap object (Blob): the
allocations must leave it alone, which the allocator does (it only adds
objects) but which the contracts state over `heap(objs, H)` as a whole;
the primitive's glue is not rendered yet ("Not attempted").

Past bugs of the upstream series #3361-#3382 in the covered code are
mutants (byte_content depth 357d1127, the encoder bounds f708ad5d, the
UTF-8 bounds 07c24665, the string_write memmove af4ba7ab, the decoder's
nesting and cardinal shift of #3362); those in the units not attempted
(encoder recursion and buffer overflow of #3373/#3374 are in the encoder
proof's checks but have no mutant of their own, encoding size truncation
of #3378, malformed system messages of #3381) become mutants with them.


## Findings

Wave 12 (the install-time checks proved, the tested-only retry
classifications, the reachable contract-only fallbacks):

* **The install-time check of the builtin classes accepted a builtin class
  id that no object header can hold** (FIXED here, src/verifier_v2.cc
  `builtin_class_error`; found by the VeriFast proof of
  `V2Verifier::builtin_classes_error`, `loader/builtin_classes.render`).
  An object's header is a smi holding the class id above the class tag
  and the finalizer bit (`HeapObject::_set_header`), so on a 32-bit VM a
  class id is below 2^25; the check (and the verifier's conversion before
  it) bounded a builtin id only by the class count. A program with more
  than 2^25 classes (a class-bits table of 64 MB and a dispatch table of
  at least 128 MB inside the image) could name a builtin class, say its
  array class, that every array allocation then gives a header whose
  class id field overflows the smi. The model's `prog_ok` states ids below
  `MAX_CLASS_IDS` (2^25 on ILP32, 2^31 on LP64: the C++ keeps class ids in
  ints), and the proof failed there. Now every builtin id is at most
  `Smi::MAX_SMI32_VALUE >> CLASS_ID_OFFSET` (the 32-bit header's bound, on
  both word sizes). Not reachable on the ESP32 (flash of at most 16 MB);
  on a 32-bit host in principle. Regression test:
  tests/ctest/program-image-validation-test.cc (each of the 23 builtin ids
  set to 2^25 is refused with "too large for a header", called directly:
  the conversion refuses an id at or above the class count first).
  Mutant builtin-classes-header. Upstream master: no install-time
  verification and no format 2 (n/a).
* **The format-1 verifier read a builtin class id as an `int`: on a 64-bit
  VM an id of 2^32 + k passed as k** (FIXED here, src/verifier.cc
  `check_builtin_classes`; found while comparing it with the format-2
  check above). `int id = Smi::value(b.id)` truncated the smi's value, so
  the range and tag checks looked at class k while the VM then used the
  real id (`class_bits[2^32 + k]`: a read far past the class table, e.g.
  in `Program::instance_size_for`). Reachable by an untrusted format-1
  image on a 64-bit host with `-Xuntrusted_format1` (an opt-in, since
  removed: untrusted format 1 is refused by every build; the
  format-2 conversion compares the whole id with the class count, and the
  devices are 32-bit). Now a word. Regression test:
  tests/ctest/program-image-validation-test.cc ("builtin class id above
  2^32": accepted by the format-1 check before the fix). Upstream master:
  no src/verifier.cc (n/a).
* `builtin_classes_error` was restructured for the proof (the same checks
  in the same order and the same messages): one call of a static helper
  per builtin class instead of a table of anonymous structs walked by a
  range-for (no rendering rule for either), and the roots' half moved to
  `V2Verifier::builtin_roots_error` (v2_verify calls it after the classes
  passed: its reads presuppose the classes' facts, and its lambda with
  parameters has no rendering rule).

Wave 11 (what the install-time checks pin in a program image; the
argument objects of the primitives without a body proof):

* **A program image could carry external byte arrays that the C++ takes
  for native objects or reads at address 0, reachable by any untrusted
  flash image** (FIXED here, verified/vmverify/src/from_vm.rs and
  src/verifier.cc `walk_heap`). An image is installed word for word
  (src/resources/image.cc, the flash registry's allocate) and verified in
  place (`V2Verifier::install_verdict`). The format-2 conversion modeled an
  external byte array with another tag than RawByteTag, or raw bytes at a
  null address, as an opaque object and accepted it; the format-1 heap walk
  checked only the address range. What the C++ then did with such a
  literal: a resource-proxy tag makes the proxy-decoding ARGS of
  src/primitive.h (`MAKE_UNPACKING_MACRO`: tag in range, then
  `as_external<T>()`) take the address word for a pointer to a native
  object of that type, for the timer and events primitives of the
  untrusted set (`timer.arm`, `timer.delete`, `events.read_state`, ...:
  their ESBMC checks assume "an open, correctly tagged proxy points to a
  live native object of its declared type", which nothing established for
  a proxy an image brings); a MappedFileTag makes byte_array_at and
  byte_array_length read the content in place; raw bytes at address 0
  with a nonzero length make the blob decoders return (null, length), so
  byte_array_at and the blob primitives read from [0, length) (a neutered
  array, the only runtime byte array without an address, has length 0).
  A snapshot cannot express either (the snapshot reader writes RawByteTag
  and an address in the image, objects.cc `ByteArray::read_content`). The
  allow-list now: an external byte array of a program image has the raw
  tag and a non-null address with its content in the image (what the
  snapshot reader makes for the byte arrays above
  SNAPSHOT_INTERNAL_SIZE_CUTOFF); everything else is refused at install
  and at launch. Upstream master: no install-time verification and no
  untrusted programs (n/a).
* **The finalizer flag of a program-heap object came from the image or the
  snapshot, and the message encoder hands an external byte array with it to
  the receiver** (FIXED here, same files). The snapshot reader copies an
  object's header word as the snapshot gives it (src/snapshot.cc
  `read_object`), the flash image as it is, and neither verifier looked at
  bit 4. `MessageEncoder::encode_byte_array` transfers an external byte
  array whose `has_owned_external_memory()` holds (external and flagged):
  for a program-heap literal above 1024 bytes the receiver would own a
  pointer into the program image and free it, and the sender's
  `ByteArray::neuter` would write into the program heap. Round 3's crafted
  heap `str-finalizer-bit` (the flag on a string literal) ran; on a large
  byte-array literal sent by `process_send` it is this. Now no object of a
  program image may have the flag (layout.rs `FINALIZER_BIT_OFFSET`, a new
  LAYOUT.toml fact). Upstream master: the same snapshot reader and encoder
  (yes; upstream runs only trusted programs).
* **The install read the program's tables wherever the image pointed**
  (FIXED here, src/verifier_v2.cc `V2Verifier::image_layout_error`). The
  Program's List and Table fields (bytecodes, literals, globals, dispatch
  table, class tables) and the method table literal are words of the
  image: with the relocation bit an offset into it, without it any
  address. `is_format2`, `V2MethodTable::compute` (the last literal's
  header and content), `v2_program_tables` and the conversion (which
  borrows the tables in place; its safety comment: "Every pointer of `p`
  must be valid for its length") read them before anything checked them,
  so a crafted image made the install read outside the image, and a table
  at an absolute address in RAM is neither verified memory nor immutable
  after the verdict (the globals are copied from it at every launch). Now
  every table, the last literal and the method table literal it holds lie
  inside the image (raw bytes, non-null), checked first by
  `verify_installed`, and again by `v2_verify` and
  `V2Verifier::verify(program, trusted)` for programs read from a snapshot
  (which has them inside by construction). Upstream master: n/a.
* **Format-2 programs' builtin classes and roots were not checked**
  (FIXED here, `V2Verifier::builtin_classes_error`, called when the
  verifier accepts a program). The VeriFast model's `prog_ok`
  (model/objects.render: "What VerifierImpl::check_builtin_classes
  (src/verifier.cc) establishes for an accepted program"; a precondition of
  every proof that decodes a blob, a list or a map) was established only
  for format 1: the format-2 verifier checks the classes the verified core
  allocates or dispatches on (`tables_ok`, verified/spec/src/v2/verifier.rs:
  object, stack, double, smi, exception, task), not the tags and field
  counts of List_, Map, the slices, CowByteArray_, LargeArray_, the array,
  string and byte-array classes, nor the roots. A program brings its own
  core library: one whose List_ has no fields and whose code never reads
  them makes list_add write field 1 past the instance (and the decoders,
  the encoder and the interpreter's fast paths read past slices and maps);
  one whose array class is an instance class makes `Array::cast` read a
  field as a length. Now the format-1 checks run for format 2 too: every
  builtin class id is a class with its tag, the classes whose fields the
  C++ reads have at least those fields, null, true and false are the
  oddballs of their classes, empty_array is an empty array,
  out_of_memory_error an exception, the string roots strings. Of the 34
  class edits the test makes, the method or heap check refuses 31 first
  (the fixture's code uses those classes); the stack, large-integer and smi
  classes with another tag and six root edits were accepted before
  (checked by running the test without the new check). Round 3's heap
  battery: `null-as-true` and four Exception_ roots of another class
  (`exc-as-list`, `-largearray`, `-cowbytearray`, `-rpcexception`) ran and
  are refused now (review/red-team/round3/repro/heap-results.txt updated).
  Upstream master: n/a (format 1 only, which has the checks).
* Observation, fixed: blob_index_of's SSE loop (x86-64 hosts) indexed with
  an `int`: a blob above 2 GB would wrap the index and read before the
  blob (a word now). Unreachable for untrusted programs (the port runs the
  C++ only for opaque, hence empty, byte arrays) and on the ESP32. No
  regression test (it needs a 2 GB byte array). Upstream master: the same
  code (yes).
* Observations, not changed: float_to_raw32 converts a double outside the
  float range to float (undefined in C++, infinity on every target; not a
  memory access). The pilot entries `int-parse` and `int64-to-string` of
  verified/cxx/run.sh do not parse with ESBMC 8.6 (`fpclassify` in
  float_to_string, a line this wave did not touch).

What the install-time checks require of each program-heap object that
carries a tag or wraps native state (format 2: the conversion
verified/vmverify/src/from_vm.rs and the verified heap check
`x_loaded_ok_stream`, verified/spec/src/v2/heap_check.rs, run by
`toit_vmverify_verify` for an install and a launch; format 1:
src/verifier.cc `walk_heap`):

| Object kind | Requirement | Where enforced | Wave 11 |
|---|---|---|---|
| every object | smi header, class id in the class table, tag equal to the class's tag | from_vm.rs `object`; walk_heap | - |
| every object | no finalizer flag | from_vm.rs `object`; walk_heap | added |
| external byte array | raw-bytes tag, non-null address, content inside the image | from_vm.rs (BYTE_ARRAY_TAG); walk_heap | tag and address added (range was checked) |
| internal byte array | content inside the image | from_vm.rs `Image::bytes`; walk_heap | - |
| string (internal, external) | content and terminator inside the image; well-formed UTF-8 | from_vm.rs `string_bytes`; heap_check `x_utf8_ok`; walk_heap | terminator added to walk_heap (format 1 had none); UTF-8 is format 2 only |
| string hash field | nothing (any value; string_hash_code returns it, no memory depends on it) | - | - |
| instance of a builtin wrapper class (slices, CowByteArray_, List_, ListSlice_, Map, LargeArray_, Tombstone_) | its class's field count; every field a smi or an object of the image; the fields' values are not pinned (the C++ checks them: the decoders, list_add, the encoder) | from_vm.rs, heap_check `x_loaded_obj_ok`; walk_heap | the classes' tags and field counts added for format 2 (builtin_classes_error) |
| lambda, lazy initializer | the method id field | format 2: the verifier's method checks; walk_heap `check_heap_method_ids` | - |
| stack | none in a program image | from_vm.rs (no STACK_TAG); walk_heap (tag not allowed) | - |
| task | none in a program image (only the builtin task class has TASK_TAG) | heap_check (builtin task class refused), `x_task_class_ok`; walk_heap (tag not allowed) | - |
| double, large integer | any payload (a large integer in the smi range is not refused; no memory depends on it) | from_vm.rs reads the payload inside the image | - |
| oddball | the null, true and false roots are the oddballs of their classes | format 2: builtin_classes_error; format 1: check_builtin_classes | added for format 2 |
| the Program's tables | inside the image | `image_layout_error` (both formats at install) | added |

Tests: tests/ctest/program-image-validation-test.cc compiles a fixture
with a 1100-byte byte-array literal and an 1100-byte string literal
(both external), reads it as the snapshot reader does, edits one field of
the program heap or the Program at a time, and checks that
`V2Verifier::install_verdict` (an untrusted image's install),
`V2Verifier::verify` (an untrusted launch) and, for a format-1 build of
the fixture, `Verifier::verify` with the untrusted rules refuse it and name
the reason: 12 external tags, address 0, the finalizer flag on four kinds
of object, a string without its terminator, every table moved outside the
image or misaligned, the method table literal with another tag, at
address 0 or outside, 34 builtin-class edits and 6 root edits; the original
is accepted before and after. Without the fixes the heap edits give 69
failures (format 2 accepted every one but the missing terminator, format
1 every one), the edits of the method table literal crash
V2MethodTable::compute (a read at address 0), and the 3 class and 6 root
edits above are accepted. vmverify's unit tests cover the conversion
(`models_external_byte_arrays_as_the_core`, `rejects_the_finalizer_flag`).
The gate runs the ctest in its ctest-host part and the unit tests in
check.sh's vmverify section.

The arguments of the 28 reachable contract-only primitives (behind the
Rust ports, no body proof: blob_equals, blob_hash_code, blob_index_of,
byte_array_at, byte_array_length, compare_simple_json_string,
float_to_raw, float_to_raw32, hash_simple_json_string,
json_skip_whitespace, large_integer_and, _or, _xor, _shift_right,
list_add, number_to_integer, raw32_to_float, raw_to_float,
size_of_json_number, smi_add, _and, _multiply, _or, _subtract, _xor,
string_from_rune, string_length, string_rune_count), the message
encoder's object walk (process_send's ESBMC proof takes the traversal as
a contract) and the proxy decoders of the timer and events primitives,
reviewed for every property of an argument object their memory accesses
depend on:

| Dependency | Primitives | Classification |
|---|---|---|
| slice bounds, the wrapped object's kind, a CowByteArray_'s backing, an external byte array's tag | the 9 Blob and StringOrSlice arguments (blob_*, compare/hash_simple_json_string, json_skip_whitespace, size_of_json_number, string_length, string_rune_count), the encoder's `encode_copy` | validated by the primitive: the proved decoders (`blob/byte_content.render`, `blob/mutable_byte_content.render`), then explicit offset checks against the decoded length |
| the slice and CowByteArray_ classes have the fields the decoders read | the same | was missing for format 2 (`prog_ok`), now builtin_classes_error |
| an external byte array without an address has length 0 | the same, byte_array_at, byte_array_length | runtime: the allocator and `ByteArray::neuter`; program image: was missing, now from_vm.rs / walk_heap |
| UTF-8 structure of string contents | none of these decode sequences (string_rune_count counts lead bytes; the json primitives compare bytes); the encoder validates a restricted sender's strings itself | validated where needed (string_at, wave 10; `encode_copy`) |
| a mapped file's or a proxy's tag and address | byte_array_at, byte_array_length (MappedFileTag), the timer and events proxy ARGS | runtime proxies are made by the C++ only (`set_external_address<T>`); program image: was missing, now refused |
| List_ has fields 0 and 1; size against the backing's length; the backing's class; a large backing's structure | list_add | size, class and program heap validated by the primitive (`Interpreter::fast_at` checks the LargeArray_ classes, sizes and that each vector is smaller, and gives up after 8 nested vectors); the field count was missing for format 2, now builtin_classes_error |
| list size against backing length, slice bounds, map backing, class ids before casts, nesting and size | the message encoder | validated by the encoder (`encode_array`, `encode_list`, `encode_map`, the nesting and size limits); the builtin classes' tags and field counts were missing for format 2, now builtin_classes_error |
| boxed number kinds | the 15 number primitives | validated by the ARGS macros (`is_large_integer`, `is_double` by tag); no other object structure |
| lengths fit a smi | string_length, string_rune_count, the json primitives | program image: content inside the image (from_vm.rs); runtime: the allocators' bounds |

Missing and now added: the four items above (program-image byte arrays,
the finalizer flag, the table layout, the builtin classes and roots). The
Rust ports' `requires` clauses (verified/core/src/prims) state
representation facts only (`heap_inv`, `heap_model_ok`, `args_rel`: one
address per object, bodies agree with their class tags), no fact about
library-maintained structure; the VeriFast contracts' `prog_ok` was the
one such fact without a check (above). No body proof was added: the
changed code is the install-time checks (C++ over Program memory, no
model yet) and blob_index_of's SSE loop (intrinsics).

Wave 10 (the fallbacks of the allocating ports, the receive primitives'
heap part, the tested-only retry classifications):

* **string_at read past the end of a string that is not valid UTF-8,
  reachable by untrusted programs** (FIXED here, src/primitive_core.cc;
  reported by the agent that proved which ports never fall back). For a
  lead byte at index i the C++ read as many continuation bytes as the lead
  byte announced (`bytes_in_utf_8_sequence`: up to 4 for the lead bytes a
  string can hold, 8 for 0xff, with a negative shift count in
  `payload_from_prefix` for 0xff) without looking at the string's length;
  the comment said "String contain only verified UTF-8". The Rust port of
  string_at declines exactly these strings (a lead byte of 0xf8 or more, or
  one whose sequence runs past the end) and leaves them to the C++. Such
  strings exist in an untrusted process: the loader checks the program's
  string literals (`heap_check.rs`, "a string literal isn't valid UTF-8"),
  but nothing checks the strings a program makes. A program brings its own
  library, the loader checks the builtin classes' shapes, not their code,
  so its StringSlice_ can cut a character (the SDK's constructor checks the
  boundaries, `StringSlice_ "a€" 0 2` in a library without the check does
  not), and string_add or concat_strings (the Rust ports and the C++ alike)
  copies the cut bytes into a new string. For a string "aaaaaa\xe2" (7
  bytes: content and terminator fill the internal string's words) `t[6]`
  read the terminator and the first byte of the next heap object and
  returned 6 bits of it (`at=8194` on x86-64 before the fix); for an
  external string the bytes after the malloced block. Fix: a lead byte
  whose sequence is longer than 4 or longer than what is left of the
  string (`n_byte_sequence > receiver.length() - index`, in word: the
  first version of the fix, `index + n_byte_sequence` in int, can overflow
  on a 64-bit VM for a string above 2 GB; VeriFast rejected it) gives null,
  as a continuation byte does; the continuation index is a word. A debug
  build's `ASSERT(c > MAX_ASCII)` (an overlong sequence, which such a string
  can hold, ends the VM there) is gone. Proved with VeriFast
  (`prims/string_at.render`, LP64 and ILP32: every read inside the decoded
  string or slice for any bytes, the shift count, no overflow); mutants
  string-at-past-end (the fix reverted), string-at-end-check,
  string-at-sequence-length. Regression tests:
  tests/ctest/prim-string-at-test.cc (every lead byte 0xc0..0xff at the end
  of strings of 1 to 9 bytes, a cut slice and its concatenation, an
  external string; 580 failures without the fix) and
  tests/sandbox/cli/cut-slice-main.toit (`toit.run --untrusted`, compiled
  against a copy of the library without StringSlice_'s checks,
  run-cut-slice.cmake). An AddressSanitizer run was not made: the ASan
  host32 configuration does not link here (mbedtls objects need ubsan
  symbols). Upstream master: the same string_at; reachable by any program
  that brings its own StringSlice_ (or a snapshot with an invalid literal:
  upstream checks no literals). Observation, not changed (trusted only):
  `iterate_font_characters` (src/primitive_font.cc) decodes the same way;
  the font primitives are not in the untrusted set. string_rune_count and
  string_raw_at do not decode sequences.
* **concat_strings and string_add allowed a string one byte longer than
  the heap model's largest blob** (FIXED here, src/primitive_core.cc; an
  off-by-one in wave 7's fix of the wrapping sum, not on upstream master,
  which has no bound at all). MAX_CONCATENATION_LENGTH was 2^30 (2^62 on
  64-bit) and the checks let the sum reach it; the core's MAX_BLOB_LENGTH
  is exclusive (every byte length of its heap model is below it, so that
  it is a smi), and so is the C++ allocator contract's MAX_BLOB. The Rust
  ports decline a sum of exactly 2^30 by NeedsGc (the core's allocation
  entry refuses it), and the C++ then made the string, on a 32-bit VM with
  1 GB to spare: a string whose length is not a smi (`size` negative) and
  outside the heap model the Rust proofs rely on. Found by the VeriFast
  proof (`prims/strings.render`: allocate_string's `length <= MAX_BLOB`
  failed in string_add's helper). Now 2^30 - 1 (2^62 - 1). Reachable by
  untrusted programs in principle (a large literal and 64 references to
  it; the ESP32 has no 1 GB). Regression test
  tests/concat-strings-overflow-test.toit (host32: 64 references to a
  16 MB string throw OUT_OF_RANGE; before, the C++ allocated 1 GB). Mutants
  concat-strings-bound and string-add-bound.
* **concat_strings ignored byte_content's result** (FIXED here). A string
  slice that is not a slice of a string (its `from` above its `to`, or no
  heap object in its string field: a program's own StringSlice_ can be
  one, and the Rust port leaves such a slice to the C++) was concatenated
  as what the failed decoding left: the whole string it wraps, or nothing,
  copied by a memcpy from a null pointer (undefined even for 0 bytes).
  The decoding is checked now (WRONG_OBJECT_TYPE, as in string_add; the
  copy loop decodes again and the proof shows it gets the same lengths).
  Not a memory-safety bug: the partial result was a range of a live string.
  Regression test tests/ctest/prim-string-at-test.cc
  (test_concat_malformed). Mutant concat-strings-failed-part. Upstream
  master: the same code.
* **put_uint_big_endian accepted width 9, an off-by-one of the initial
  commit** (FIXED here, src/primitive_core.cc, and its Rust port,
  verified/core/src/prims/blob.rs `put_endian`, which mirrored it). Not a
  memory-safety bug: the bounds check used the same width, so the nine
  bytes were inside the destination. But the ninth byte was the sign byte
  of the arithmetic shift (`value >>= 8` on an int64: 255 for a negative
  value), where everything else accepts 1..8 (put_uint_little_endian
  rejects 9 and the readers too) and both Toit fallbacks of
  lib/io/byte-order.toit write `value >>> 64`, that is 0. So
  `BIG-ENDIAN.put-uint b 9 0 -1` wrote nine 255s while `LITTLE-ENDIAN`
  wrote eight 255s and a 0, and a 9-byte width is not a uint the library
  can mean (no int64 has a ninth byte; `ByteOrder.put-uint` documents no
  width above 8). The check is now `unsigned_width > 8`: width 9 fails with
  OUT_OF_BOUNDS and the fallback writes the 0, as in little endian. Width 0
  stays accepted (nothing written, as the fallback does). Reachable by
  untrusted programs (the port and the C++ for a literal destination); no
  effect on safety. Regression tests: tests/ctest/prim-byte-order-test.cc
  (width 9 now OUT_OF_BOUNDS for both writers) and
  tests/sandbox/cli/byte-order-width-main.toit (`toit.run --untrusted`:
  both byte orders, a fresh byte array through the port and a literal
  through the C++, give the same bytes; fails without the fix). The VeriFast
  proof (`prims/put_bytes.render`) is about the bounds and holds either way.
  Upstream master: the same `unsigned_width > 9`.

Wave 9 (the readers and writers behind the Rust ports, when the C++
behind a port runs, two audits):

* **read_int_big_endian, read_int_little_endian and
  put_uint_little_endian computed `width - 1` in int before checking the
  width: undefined behaviour for INT32_MIN, reachable by untrusted
  programs on 64-bit VMs** (FIXED here, src/primitive_core.cc). Wave 8
  observed it for the readers and called it unreachable for untrusted
  programs because "the Rust port rejects a negative width first"; it does
  not: every byte-array port decodes the byte array first and returns
  `NotPorted` for a copy-on-write destination not yet copied or an opaque
  byte array, leaving the width to the C++ (`blob.rs` `read_endian`,
  `put_endian`; "When the C++ behind a port runs"). So
  `LITTLE-ENDIAN.put-uint #[0, 0] -2147483648 0 0` (a byte-array literal is
  a CowByteArray_) runs the C++ with width INT32_MIN in an untrusted
  process; on ILP32 (the ESP32) an int argument is a smi and INT32_MIN is
  not one. In practice the compilers wrap and the width is rejected
  anyway; the fix makes it defined: the three check `unsigned_width == 0 ||
  unsigned_width > 8` on the unsigned width, as the unsigned readers do,
  and compute `width - 1` after the check. VeriFast proves all three
  (`prims/read_bytes.render`, `prims/put_bytes.render`); mutants
  read-int-width-overflow and put-uint-width-overflow put the old
  subtraction back and fail on LP64 (and verify on ILP32, where it cannot
  overflow). Regression test tests/ctest/prim-byte-order-test.cc: the six
  integer readers and writers called directly with every width from
  INT32_MIN to INT32_MAX that matters and every offset around a 10-byte
  array (results and bytes written; the undefined subtraction itself shows
  only under the proofs or a sanitizer). Upstream master: the same three
  primitives.
* Observation, not changed: put_float_32_little_endian and
  put_float_64_little_endian reject the exact fit (`offset + 4 >= length`:
  an offset of length - 4 fails with OUT_OF_BOUNDS though the 4 bytes fit;
  the Rust port mirrors it). Not a safety issue: lib/io/byte-order.toit's
  fallback then writes the bytes with put-int32 / put-int64.
  put_uint_big_endian accepts a width of 9 (the ninth byte is the sign
  byte of the arithmetic shift); the port mirrors it, and both are inside
  the bounds check (wave 10: an off-by-one, fixed, see above).
* The wave-8 count "behind the 106 ports, the C++ of 2 has a VeriFast body
  proof" was an undercount (8: array_new, the four integer divisions and
  string_write_to_byte_array were already proved); `metrics.sh` counts it
  now (17 after wave 9).
* Audit (ESBMC's `T()` value-initialization of aggregates, which ESBMC
  8.6 leaves nondeterministic): no harness under ../harness/ and no
  header under ../include/ value-initializes an aggregate with `T()`. The
  fourteen `T()` there are placement news of the intrusive list types
  and their elements (MessageFIFO, FinalizerNodeFifo, ObjectNotifierList,
  ProcessListFromProcessGroup, ProcessListFromScheduler and its
  ReadyLink, ProcessGroupList, SchedulerThreadList, TimerList) and of the
  harness's own Ec618EventSource: classes with user-provided constructors
  (LinkedListElement sets `next_` to null, LinkedFifo `tail_` to the
  anchor, DoubleLinkedListElement both links to itself), so value
  initialization calls the constructor, which sets every field. The
  harnesses' zeroing uses `T x = {}` and `T{}`. src/ was scanned too
  (`_new T()`, `= T()`, `return T()`): none. Harmless, nothing changed.
* Audit (system message types): neither an untrusted nor a trusted
  process can crash the VM or the system process with a system message on
  this branch. process_send on the system route (a negative pid) refuses
  TERMINATED and SPAWNED from every sender (wave 8); a trusted sender may
  send any other int type, a sandboxed one 2 (TRACE), 3, 4, 5, 7 and 64 or
  more (`PrimitivePolicy::may_send_type`). Without a boot process
  (Scheduler::terminate_process clears `boot_process_` before the boot
  process's destructor runs, with the scheduler unlocked, and the VM keeps
  running other processes until terminate_execution stops them) the
  default handling of send_system_message drops every type but TERMINATED
  (the `FATAL("unhandled system message")` of upstream was replaced by a
  drop on this branch, 6e064fc7); ESBMC `scheduler-delivery` checks every
  int type on both routes with no boot process, live or exiting. In the
  system process the container manager's `unreachable` (system/
  containers.toit) is behind the per-type handler map (it is registered
  for 0, 1 and 2 only), and MessageProcessor_.invoke-handler catches every
  exception of a handler and drops unregistered types with a warning.
  Upstream master still has the FATAL: any process that sends a system
  message other than TERMINATED or SPAWNED while there is no boot process
  ends the VM, e.g. a process printing an uncaught exception's trace
  (lib/system/trace.toit: `process-send_ -1 SYSTEM-TRACE_ ...`) while the
  boot process is being torn down. Not reproduced on upstream (no build of
  it here); for the lead's upstream list.

Wave 8 (the scheduler review's two findings, the error roots, the receive
path, weak maps):

* **A trusted process could forge the scheduler's TERMINATED (and
  SPAWNED) notices and end the VM with an exit code of its choice**
  (FIXED here, src/scheduler.cc, src/primitive_policy.cc). process_send
  with a negative pid routes a message to the system process
  (Scheduler::send_message_from, then send_system_message); sandboxed
  senders were stopped by `may_send_type`, trusted ones were not. The
  system process takes a TERMINATED notice as the termination of the
  sender (its gid and pid) with the payload as exit value; without a boot
  process the default handling makes the payload the VM's exit state. A
  trusted application container ending the VM with 42:
  `process-send_ -1 SYSTEM-TERMINATED_ 42` (toit.run exits with 42).
  Rule: the life-cycle notices originate only from the scheduler
  (Scheduler::new_process_message). send_message_from refuses both types
  from every sender on both routes (MESSAGE_PERMISSION_DENIED, the
  primitive throws PERMISSION_DENIED; the check comes after the encoding,
  so the existing tests that use type 0 to provoke an encoding error keep
  their error). Regression test
  tests/sandbox/trusted-forge-life-cycle-test.toit (exits 42 without the
  fix). ESBMC `scheduler-delivery` checks
  the refusal before any lookup or delivery, and the scheduler's own
  route (send_system_message with the termination decoding) separately.
  Upstream master: the same route, open to every process (there is no
  policy there).
* **Scheduler::spawn started a child whose SPAWNED notice the system
  process refused** (latent: unreachable today; now handled). The notice
  is refused only by the boot process's mailbox admission; the boot
  process has the system policy, whose quotas are all zero (no limit), the
  notice is charged one message and no bytes and is not restricted, so
  `mailbox_has_room` fails only at a counter of INTPTR_MAX messages, more
  than the address space can hold. Instead of relying on that, spawn now
  tears the child down before it ever ran (out of its group, destroyed
  outside the scheduler lock: its destructor frees the termination notice
  and the initial memory) and returns QUOTA_EXCEEDED_PROCESS_ID; the
  arguments are taken from the encoder only after the notice is queued,
  so a refused spawn transfers nothing. ESBMC `scheduler-spawn` (slow
  tier) checks both outcomes of the announcement: an accepted notice
  schedules the child with its arguments, a refused one destroys it with
  the arguments still in the encoder and the notice released once.
* **Map.weak lets an untrusted program observe the collector write into
  a reachable object** (a model gap, not a memory-safety bug; not
  changed). add_finalizer on a Map (allowed untrusted, CoreIndex::
  add_finalizer) registers a WeakMapFinalizerNode; at every old-space
  mark-sweep the marker skips the map's backing
  (MarkingVisitor::skip_marking) and WeakMapFinalizerNode::weak_processing
  writes the program's null into each value slot of the backing (or of a
  large array's arraylets) whose value is not otherwise reachable, and
  resets an unreachable weak map's size, spaces-left, index and backing.
  tests/sandbox/cli/weak-map-main.toit (`toit.run --untrusted`) observes a
  value become null. The writes are of valid references (null, smi 0)
  into in-bounds slots of objects the collector owns while the mutator is
  stopped; the core re-reads the heap after every collection (the epoch)
  and the verifier types stack slots, not the contents of arrays or
  instance fields, so neither memory safety nor the verifier's typing
  depends on it. But `gc_equiv` and the spec's GC step said a collection
  leaves every reachable object equivalent, which is false for weak maps.
  Refusing weak maps to untrusted programs is not a clean restriction:
  the SDK's ServiceResourceProxyManager_ (lib/system/services.toit) keeps
  every notifying resource proxy (network sockets, storage, discovery) in
  a Map.weak in the client process, so service resources would break.
  MODELED since stage 0 of the collector plan (branch gc/stage0-spec,
  verified/core/OBLIGATIONS.md "The collector"): a collection of the spec
  (verified/spec/src/v2/gc.rs) is weak processing (a map may be reset; a
  value slot of a map's backing array or arraylet that holds an object
  other than a tombstone may become null) followed by a compaction
  (garbage gone, live objects renumbered), and `gc_equiv(a, b)` means
  that b represents a state that collections reach from a's (the `stack`
  bridge, CONTRACTS.toml). `gc_equiv_trans`, `stack_copy_equiv` and
  `prim_retry` hold of that relation as stated, with no weak-map
  exception; which VeriFast proofs pass does not change (gc_equiv stays
  uninterpreted).
* **The error roots of a program image were not checked to be distinct**
  (a gap in the loader, now checked). The retry protocol decides by the
  root's address whether to collect and call a primitive again; an image
  with, say, WRONG_OBJECT_TYPE's root equal to ALLOCATION_FAILED's made a
  failure after a copy-on-write copy (string_write_to_byte_array, byte_zap,
  blit) a retried one. Compiled images have distinct roots; the format-2
  verifier did not check it. ProcessGroup::create now refuses such an
  image ("The retry obligation").
* (Wave 9: fixed, and reachable by untrusted programs after all, see
  wave 9 above.) Observation, not fixed (trusted programs only): read_int_big_endian and
  read_int_little_endian compute `width - 1` in `int`, which overflows
  (undefined) for width INT_MIN; the Rust port rejects a negative width
  before the C++ runs, so untrusted programs cannot reach it, and the
  unsigned result would be rejected anyway. Their proof needs a rule for
  Utils::wrapping_shift_left's variable shift count (not attempted).

Wave 7 (the retry obligation, the C++ behind the Rust primitives' declines,
the model gaps):

* **concat_strings summed the lengths of its parts without a bound: on
  32-bit an untrusted program overflows the VM's heap** (FIXED here,
  src/primitive_core.cc; ccde26f7). The primitive adds the lengths of the
  strings of an array in a `word`; 257 references to one 16 MB string sum
  to 2^32 + 16 MB, which wraps to 16 MB: a 16 MB string is allocated and
  the copy of all parts writes 4 GB past it (segfault on host32, heap
  corruption otherwise). Reachable by untrusted programs although the
  primitive is ported to Rust: the port declines sums above its
  MAX_BLOB_LENGTH (2^30 on 32-bit) and leaves them to the C++ primitive.
  On an ESP32 (128 KB untrusted heap) the parts can be a large string
  literal of the program (flash, not heap) and an array of a few thousand
  references to it. string_add (two parts) had the same unchecked sum
  (reachable only by trusted programs with a 1 GB string). Found by the
  retry audit, which followed every Rust decline to its C++ primitive.
  Fix: both check each part against what is left of the core's bound
  (MAX_CONCATENATION_LENGTH, 2^30 or 2^62) and fail with OUT_OF_RANGE.
  Reproducer and regression test: tests/concat-strings-overflow-test.toit
  (host32: segfaults without the fix, also `toit.run --untrusted`).
  Upstream master: the same concat_strings (sum unchecked), reachable by
  any program on a 32-bit VM.
* **The retry obligation holds for every C++ primitive of the untrusted
  set** (no violation): 62 cannot fail for want of memory, 88 fail only
  before any visible effect, 25 of them proved with VeriFast for every
  input, the others tested ("The retry obligation"). Close calls, all
  correct: timer.create takes the timer quota before its malloc and gives
  it back when the malloc fails; process_send neuters transferred byte
  arrays only after the message is allocated; register_monitor_notifier
  deletes the notifier when its message cannot be allocated; a failed
  decode leaves VM finalizer nodes for the GC that precedes the retry.
* **The core's allocation entry points let INTPTR_MAX through to
  Process::allocate_string's `length + 1`** (latent, wave 6). Fixed twice
  in parallel: the collector-proof work made Process::allocate_string
  reject INTPTR_MAX (ESBMC `process-blob-allocation`), and wave 7 made
  toit_v2_try_allocate_string and _byte_array return 0 above
  V2_MAX_BLOB_LENGTH (2^62 - 1 / 2^30 - 1, the heap models' bound;
  src/interpreter_v2.cc): the core's port then declines and the C++
  primitive allocates. Both checks are kept; the second gives the VeriFast
  contracts of allocator_string/_byte_array no length precondition, as the
  Verus ones (the "MISSING" clauses are gone). Mutants
  ffi-allocate-string-bound and ffi-allocate-string-unbounded. Branch-only code (not upstream).
* **Two model gaps closed by widening the model, not the C++**: blob
  lengths (MAX_BLOB) are now per width as the Verus heap model's (2^62 - 1
  on LP64, was 2^30 - 1 and then INT_MAX), and class ids below 2^31 on
  LP64 and every smi header on ILP32 (was 1024; CLASS_ID_BIT_SIZE = 10 is
  declared but unused, the C++ takes any class id). The encoder caps the
  class ids at 2^31 on LP64: `problematic_class_id_` is an `int` (a class
  id of 2^31 would truncate; it needs a 4 GB class table). Checked after
  the merge with the collector-proof base, whose newer proofs relied on the
  narrow model in three places, now generalized: HeapObject::class_tag and
  the finalizer flag lemmas read a header as 16 bits (now 64 bits, and the
  flag lemmas split a header's value into its five low bits over the rest,
  for any width), and byte_array_is_valid_string_content /
  byte_array_convert_to_string bounded `end - start` by the blob bound
  (now by the int range of `end`). No C++ change.
* No bug in the mailbox quota accounting (Process::_append_message and
  remove_first_message under the process mutex, the scheduler's lock
  around both; sizes and the restricted flag are set before the message is
  queued and never change; every queued system message is counted and
  uncounted once), nor in ExternalSystemMessageHandler::run (a failed
  decode deletes the whole message; an allocation failure keeps it for
  on_failed_allocation's retry).
* Latent, not changed (not a unit proved here): blob_index_of's SSE2 loop
  (x86_64 hosts only) counts with an `int` (`for (int i = from -
  last_bits; i < to; i += 16)`, `int answer`): a search past 2^31 bytes
  overflows the index (undefined behaviour; in practice a read before the
  blob). Byte arrays made by Toit code are below 2^31 bytes
  (byte_array_new takes an `int`) and a 2 GB string failed to allocate on
  the host (the process's memory limit), so not reproduced
  (repro/blob-index-of-large.toit). For upstream: `word i`, `word answer`
  (the same code there).
* Utils::is_valid_utf_8 agrees with a strict RFC 3629 validator on every
  sequence of 1 to 3 bytes and every 4-byte sequence starting 0xf0-0xf7, on
  both widths (the 64-bit and 32-bit state machines differ; 19.1 M
  sequences each; /home/flo/work/opentoit-sandbox-artifacts/annotated-cxx/
  repro/utf8-validator-exhaustive.toit).

Wave 6 (the external handlers' sender side, `sender/`):

* **MessageEncoder's one-argument constructor did not take its buffer: the
  external message handlers leaked it whenever the message could not be
  allocated** (FIXED here, src/messaging.h). The class says it takes
  ownership of the buffer and frees it in the destructor unless
  take_buffer() gave it to a message; ExternalSystemMessageHandler::send_
  (behind toit_msg_notify and ExternalSystemMessageHandler::send) and
  reply_rpc (toit_msg_request_reply) rely on it: when `_new SystemMessage`
  fails they return MESSAGE_OOM "since the destructor of the encoder
  already takes care of" the buffer. But `MessageEncoder(uint8* buffer)`
  left take_ownership_of_buffer_ at false, so each such failure leaked the
  encoded buffer (the data itself was handled right). Reachable from
  native services under memory pressure (the C API), not from Toit code.
  Found when the destructor's contract had to give the buffer back in
  send_'s out-of-memory path. Fix: the constructor sets the flag (its
  other users, Process::set_main_arguments and set_spawn_arguments, always
  call take_buffer). Reproducer and regression test:
  tests/ctest/message-encoder-ownership-test.cc (a 1 MB buffer, mallinfo2:
  fails without the fix). Mutant sender-encoder-owns-buffer. Upstream
  master: the same constructor and the same two callers.
* No other ownership bug on the external handlers' sender side: the data
  is freed exactly when free_on_failure says so, the buffer exactly once.
  RPC reply ids must be non-negative (write_cardinal of an int as a uword):
  the Toit side wraps its ids below 2^30 (lib/rpc/rpc.toit).

Wave 6 (the Rust/C++ boundary, `ffi/`):

* **The trusted GC contract of waves 1-5 was false: it said the stack's
  used slots were byte for byte the same after a collection** (FIXED in
  the model; no C++ change). v2_gc's contract (grow_stack's, wave 1)
  ensured `same_abstraction`, i.e. `drop(top * W, bs2) == drop(top * W,
  bs)`: a moving GC rewrites every reference slot to the moved object, so
  the claim was false whenever a slot held a moved object, and the proof of
  stack growth rested on it. It now says what the GC does: the VM state
  after it (stack, heap, epoch) is `gc_equiv` to the one before (an
  uninterpreted relation the `stack` and `heap` bridges interpret: since
  stage 0 of the collector plan, the state after is one that collections
  of the spec reach from the state before, `toit_spec::v2::gc::gc_steps`;
  before, the same abstract state), and stack growth, the allocations and the primitive
  call are proved over that, with `stack_copy_equiv` (the old `stack`
  bridge, now a named assumption) for the copied stack.
* **An assumption of the Verus side the C++ wrapper does not establish:
  the retry of a primitive after an out-of-memory failure completes the
  original step** (`prim_retry`, CONTRACTS.toml). gc_call_primitive says
  the whole C++ call is a completion of the PRIMITIVE step; the C++ calls
  the primitive up to four times, each time on the state the failed call
  left (after a GC). That is a completion of the original step only if a
  call that fails for want of memory changes nothing the spec sees: a
  property of every primitive (allocate before changing anything), not of
  the wrapper, and stated nowhere before (TRUSTED.md section 8 lists
  prim_default only). Reviewed for the untrusted set's C++ primitives
  (process_send neuters transferred byte arrays only after the message is
  allocated; the receive primitives give the blocks back on an allocation
  failure, wave 5); not checked for the others. (Wave 7: checked for all 150, "The retry obligation".)
* **The epoch the core relies on is sound only because the retry loops are
  bounded** (verified; no bug). The core keeps its stack view when the
  epoch word is unchanged (TRUSTED.md, Epoch). The word wraps; the proof
  shows at most three collections and four primitive calls per C++ call,
  so an unchanged word is an unchanged count. The mutants ffi-*-retries
  take a bound out: the proof fails.
* The string allocator now rejects `INTPTR_MAX` before adding its terminator.
  The native `process-blob-allocation` check covers both FFI entries and the
  process allocators across the full input word. The `byte-array-initialization`
  check follows each byte-array constructor to the libc fill and checks its
  destination, extent, and value for internal and external storage.
* The VeriFast model is narrower than the C++ in three places, listed as
  gaps in CONTRACTS.toml: class ids below 1024 (`header_ok`), blob lengths through 2^30 − 1 on ILP32 and INT_MAX on LP64
  (the allocation precondition; TRUSTED.md allows lengths below 2^62 on LP64), and incomplete allocator payload contracts (a new instance's null
  fields, a double's bits, a byte array's zeros are the allocator's, not
  stated). The exception wrapper still converts its value from a word to a
  pointer. The no-GC array wrapper takes the tagged filler as a pointer;
  Rust reconstructs it with exposed provenance at the trusted heap boundary.
  Its caller proves the filler is encodable and denotes a smi or live object.
  The wrapper checks the length and passes the filler through. Given writable
  storage for a fresh array, the initializer sets the length and fills every
  slot. The allocator contract still supplies the storage, sets the class,
  and connects the initialized object to the heap model.
  (Wave 7: the class-id and blob bounds closed, "Findings, Wave 7"; the
  payload words and the provenance stay, "Not attempted".)
* The model's large-integer allocator no longer requires a value outside
  the smi range (the C++ takes any value, and the Rust allocator's
  contract has no such precondition); decode_integer's postcondition
  keeps the decoder canonical (mutant decoder-integer-canonical).
* Build: test snapshots did not depend on the compiler (f3f44dde: they do
  now, through the toit.compile target).

Wave 5:

* **Double free of a message's out-of-line data when a receiver dies
  after a failed decode** (FIXED here, src/heap_roots.h; 05159afd).
  Reachable by any process, sandboxed included, against the VM's malloc
  heap. A failed decode gives the blocks back to the message by clearing
  the finalizer bits of the external strings and byte arrays it made
  (remove_disposing_finalizers); their VM finalizer nodes stay until the
  next GC, which unlinks them. VmFinalizerNode::heap_dying freed the
  memory of every node without looking at the bit. So a process that
  fails to decode a message twice (an allocation failure, and again on
  the retry after the GC: task_receive_message throws) and then ends
  (uncaught exception: no GC in between) frees each such block twice: the
  message frees it when the process deletes its mailbox, the dying heap
  again. A receiver controls both its heap limit (set-max-heap-size) and
  its end, and any sender can make the message (a byte array over 128
  bytes, then lists). glibc aborts the VM ("free(): double free detected
  in tcache 2"); without its check, heap corruption. The same with
  main_arguments and spawn_arguments. Found while writing the contract of
  clear_has_active_finalizer ("gives the block back") for the receive
  proof: the GC side did not honour it at heap death. Fix: heap_dying, like
  weak_processing, frees only when the bit is set. Reproducers and
  regression tests: tests/message-receive-oom-test-compiler.toit (end to
  end from Toit code: aborts without the fix) and
  tests/ctest/message-receive-ownership-test.cc (through main_arguments,
  also host32). Upstream master: the same heap_dying and the same callers.
* **The malformed-message leak of wave 3: fixed and proved** (05159afd;
  the wave-4 draft applied). task_receive_message, main_arguments and
  spawn_arguments drop a message the decoder rejects (after giving the
  blocks back) and free all of it; before, it was delivered as decoded
  and the blocks after the error leaked. Unreachable from this branch's
  encoder (b609da9f), reproduced with a hand-made message
  (message-receive-ownership-test.cc: 1 MB leaked without the fix). The
  drop alone would have introduced the double free above (the dropped
  message frees the blocks the decoded objects' nodes still name): both
  are needed. Upstream master: delivers malformed messages as decoded.
* **encode_error read a proxy byte array as bytes** (FIXED here,
  src/encoder_visitor.h EncodeVisitor::visit_byte_array; reported by the
  coordinator from the core fuzzer on the assertion-enabled sanitizer
  build: `objects.h:591 external_tag() == RawByteTag || ...` 3 times).
  The exception and trace encoder (encode_error: any object as the error's
  message, and the stack) built ByteArray::Bytes over any byte array; for a
  proxy (an external byte array whose address is a C++ struct: a timer, a
  resource group, tagged with the struct's type) that calls as_external,
  whose assertion forbids it. The code is wrong, not the assertion: it
  treats a struct pointer as bytes. Release builds read the proxy's
  external length, 0 for every proxy the VM makes, so nothing was read
  (no memory-safety impact in release; assertion builds stopped). Fix: a
  non-raw external byte array is encoded as empty. Regression test:
  tests/encode-error-proxy-test.toit (stops the asan build without the
  fix). The byte-array writer now has a native
  ESBMC proof for both word widths. The message encoder uses the separately
  proved byte_content, which refuses proxies.
* No other bug in the receive path: on every path (no message, a monitor
  notification, a finalizer to run, the result array not allocated, an
  allocation failure, a malformed message, success) the message's buffer
  and blocks are freed exactly once (or kept whole for the retry), and
  the walk of MessageDecoder::deallocate frees every block once (under
  the IPC assumptions).

Wave 4:

* **TISON integers were not portable between 64 and 32 bits** (wave 3's
  finding 3, FIXED here, src/messaging.cc; 1d19379a). A 64-bit VM writes
  smi tags up to 2^62, which a 32-bit VM rejected above 2^30
  (WRONG_OBJECT_TYPE: a millisecond timestamp in an asset), and a 32-bit
  VM writes large integers that a 64-bit VM decoded as non-canonical large
  integers in its smi range (equal, not identical, encoded again as large
  integers). Fix: the smi tags' magnitude is read with 64 bits on both
  widths (read_cardinal_64; read_cardinal checks that a length fits the
  word) and decode_integer makes every integer canonical: a smi whenever
  the value is in this VM's smi range, else a large integer (int.MIN only
  with the large-integer tag). Proof: decode_integer's postcondition (a
  smi for a value in the smi range; until wave 6 also the allocator's
  `canonical` clause), mutant decoder-integer-canonical. Tests:
  tests/tison-integer-width-test.toit (host and host32: fails without the
  fix on both), tests/tison-test.toit updated (2^62 with a smi tag is now
  an integer). Upstream master: the same decoder (smi tags read as words,
  large integers allocated as they are).
* **decode_process_message decoded any message without a process** (wave
  3's finding 4, made SAFE here; 1d19379a). Not provably unreachable (any
  unrestricted process can send a TERMINATED system message with any
  content; the window, no boot process, is empty in practice), so it now
  reads only an integer in the range of `int` and refuses everything else
  before decoding it. Reproducer and regression test:
  tests/ctest/message-process-message-test.cc (crashes without the fix:
  null, strings, arrays and large integers dereferenced the missing process
  or program). Upstream master: the same code (`decoder.decode()` with a
  null process, "TODO(kasper): Make this more robust").
* **time_info: signed overflow near INT64_MIN** (red-team round 4, FIXED
  and PROVED here, src/primitive_core.cc utc_fields). The seconds of the
  day were `timestamp - days * SECONDS_PER_DAY` with `days` rounded down:
  for the timestamps of the last partial day above INT64_MIN the product is
  below INT64_MIN (undefined behaviour, UBSan flags it; release builds
  wrapped and then threw OUT_OF_RANGE for the year). Reachable by an
  untrusted program calling the primitive directly. Fix: floor_mod. The
  primitive and its whole calendar are now proved free of overflow and
  lossy conversion for every int64 on both widths (`prims/time_info`); the
  proof found no other overflow (local_fields' year check is what keeps its
  shift in range: mutant time-info-local-year). Regression test:
  tests/time-info-range-test.toit (the window's timestamps; meaningful
  under UBSan, the proof is the guard in release builds). Upstream master:
  not affected (utc_fields is this branch's, 431ceaf8; upstream's time_info
  calls gmtime_r/localtime_r and returns uninitialized fields when they fail,
  fixed here by 637498d3). If 431ceaf8 goes upstream, the fix goes with it.
* **decode_external_data: the inline length was unchecked** (hardened here,
  src/messaging.cc; latent). The external message handlers' decoder read
  the length of inline byte arrays and strings into an `int` without a
  check: a cardinal above INT_MAX became a negative int, `malloc(max(1,
  n))` one byte and `memcpy(copy, ..., n)` a copy of almost SIZE_MAX bytes
  (heap overflow), and a length of INT_MAX overflowed `encoded_length + 1`
  (undefined behaviour). Unreachable from the encoder (it writes inline
  only small contents; the proof's `ipc_room` assumption covers it), so not
  a reachable bug; the check (`length < 0 || length > remaining()`, as in
  decode_byte_array) makes the proof independent of the assumption for
  these two values. Mutants decoder-external-inline-length and
  -string-length. Also: an RPC request's id and name are cardinals
  converted to `int` (modular: an id above INT_MAX is truncated; the reply
  goes to the truncated id; functional only). Upstream master: the same
  code.

Wave 3 (the decoder):

* **The encoders sent arrays the receiver cannot decode, and the receiver
  then leaked the message's out-of-line data** (FIXED here, src/messaging.cc
  encode_array, encode_map; b609da9f). An array of a program heap can be
  longer than a process heap holds (format-2 images bound an array only by
  the image; the format-1 snapshot reader by the program heap's blocks,
  4092 against 4082 elements on 64-bit, 1020 against 998 on 32-bit). The
  IPC decoder rejects such an array (`length > max_length_in_process()`)
  as malformed, and task_receive_message (likewise main_arguments,
  spawn_arguments) only distinguishes allocation failures: a malformed
  message is delivered as decoded, its value 0 (the decoder's null is the
  smi 0), and free_data_but_keep_externals frees the buffer but not the
  out-of-line blocks after the array (malloced copies, transferred
  external byte arrays: up to 8 per message, within the sender's message
  quota). So a crafted sandboxed program could make the system process
  leak memory with every message. Fix: the encoders refuse an array (list,
  slice) longer than `Array::max_length_in_process()` and a map of more
  than half that, so everything they produce decodes (which the decoder's
  IPC assumption needs). Reproducer: tests/ctest/message-oversized-array-
  test.cc (an over-long array built outside the heap; fails without the
  fix). Not reproduced end to end: making such a literal needs an image
  editor that grows program-heap blocks (tools/heapcraft.toit keeps block
  counts). Upstream master: the same encoder, the same decoder check and
  the same primitive (reachable there only with a crafted snapshot, as
  upstream runs no untrusted programs). The primitive's treatment of a
  malformed message stays (now unreachable from the encoder): a draft below.
* **read_cardinal dropped the bits of a digit beyond the word** (FIXED
  here, src/messaging.cc; 965bff66). #3362 bounded the number of digits
  (shift < WORD_BIT_SIZE) but not their bits: the last digit at shift 63
  (28 on 32-bit) was shifted out, so the TISON cardinal 2^64 + 5 decoded
  as 5 and 2^64 as an array length of 0 (silently, as a valid message).
  VeriFast refuses the unsigned overflow of `digit << shift`; the fix
  checks `digit > (UINTPTR_MAX >> shift)` (malformed), and the proof shows
  the sum then stays in the word (`radix.c`). Not memory-unsafe (every
  length is checked afterwards) but a second encoding of every value.
  Regression test: tests/tison-cardinal-overflow-test.toit (both widths).
  Upstream master: worse, no bound at all (`result += ... << shift` with a
  shift up to the input's length: undefined behaviour), as before #3362.
* **TISON smis are not portable from 64 to 32 bits** (FIXED in wave 4, above; a
  functional bug, not a memory-safety one). The encoder writes every smi
  as TAG_POSITIVE_SMI/TAG_NEGATIVE_SMI; on a 64-bit VM that is any value
  below 2^62. A 32-bit VM rejects one above its smi range (2^30) as
  malformed, and read_cardinal cannot even read one above 2^32. So TISON
  made on a 64-bit host (assets of host tools) with an integer such as a
  millisecond timestamp (1.7 * 10^12) fails to decode on an ESP32 with
  WRONG_OBJECT_TYPE. Fix proposal: decode an out-of-range smi tag as a
  large integer (a 64-bit cardinal reader for the two smi tags), or encode
  values outside the 32-bit smi range as TAG_LARGE_INTEGER. Upstream
  master has it too (with the undefined shift).
* **TISON large integers in the smi range are not canonical** (FIXED in wave 4, above;
  minor). TAG_LARGE_INTEGER with the value 5 decodes to a LargeInteger 5:
  `==`, hashing and maps treat it as 5, `identical x 5` is false (reproducer
  /home/flo/work/opentoit-sandbox-artifacts/annotated-cxx/repro/tison-large-
  integer-small.toit). The encoder never writes one; a fix would return a
  smi when the value fits.
* **MessageDecoder::decode_process_message decodes without a process**
  (latent; made safe in wave 4, above). The scheduler decodes a TERMINATED system message
  itself when there is no boot process, with `MessageDecoder(null,
  buffer)`: for anything but a smi the decoder dereferences the missing
  process or program (the proof's contracts require both). Any
  unrestricted process can send TERMINATED to -1 with any content, but the
  window is empty in practice: when the boot process terminates, its own
  TERMINATED message makes the scheduler terminate the VM (tried: a child
  outliving the boot program never runs again). Fix proposal (draft): check
  the first byte for a smi tag before decoding.
* No other bug in the decoder: every TISON read is bounded, every length
  is checked before the copy or allocation of that size, the half-built
  map's fields are null so a failure leaves the heap well-formed, the
  externals table is bounded (FATAL beyond 8, as the encoder reserves at
  most 8).

Waves 1-2:

* **The Verus contract of `gc_grow_stack` lacked a bound on `needed`**
  (found by both pilots; FIXED by `core/trusted-integration`, merged).
  Without a bound the C++ overflowed at `static_cast<word>(needed)` and at
  `(length - free) + needed`. Now the C++ returns STACK_OVERFLOW for
  `needed > Stack::max_length()` and verifies without any precondition on
  `needed`; the Verus contract requires `needed < GROW_STACK_MAX_NEEDED`
  (CONTRACTS.toml: a Verus-only clause, sound because the C++ precondition
  is weaker). The mutants `grow-stack-unbounded`, `grow-stack-word-range`
  take the new check out again and fail at the cast and at the sum.
* **The encoders' size limit was dead on 32-bit: heap overflow in
  `tison.encode` on the ESP32** (FIXED here, src/messaging.h and
  messaging.cc). a4d19ec2 stopped the encoders at
  `cursor_ > MESSAGING_ENCODING_MAX_SIZE` (0x7fffffff), which a 32-bit
  `word` can never exceed: the size pass of a shared object graph
  overflowed the cursor (signed overflow; it wraps), returned a small
  size, and the write pass wrote gigabytes past the byte array allocated
  for it. Reproduced on the host32 build with 100 x 100 x 43 references to
  one 10 KB string (segfault; the 64-bit VM throws OUT_OF_RANGE), and
  reachable by untrusted code with a few KB of memory (`tison.encode`;
  `process_send` and `spawn` of unrestricted senders too). The external
  byte counter could overflow the same way (8 out-of-line copies of one
  blob). Fix: the limit is 0x3fffffff and covers the out-of-line data
  (`is_too_large` checks `total_size()`), and `encode_copy` and
  `encode_byte_array` check a blob's length against what is left before
  adding it, so `cursor_ + external_bytes_` stays below the limit plus the
  few bytes written between two checks (`ENC_SLACK`). The VeriFast proof of
  the encoder needs exactly this (mutant `encoder-size-limit`). Full ctest
  green; tests/message-encoding-size-test.toit passes on both widths.
* **The out-of-line copy of a string read one byte past its content**
  (FIXED here, src/messaging.cc encode_copy). It copied `length + 1`
  bytes from the content byte_content returned, for the terminator. A
  string slice's content is not followed by a '\0' (the receiver's
  allocate_external_string repaired that), and byte_content with
  STRINGS_OR_BYTE_ARRAYS lets a crafted string slice wrap a byte array:
  for an external byte array (its own malloc block of exactly `length`
  bytes) ending at the slice's end, the copy read one byte past the block.
  Fix: copy `length` bytes and write the '\0'. The mutant
  `encoder-copy-terminator` reverts it (memcpy's precondition fails).
  Also made `TISON_VERSION` a `static const` (it was a mutable static
  global, never written).
* No bug or missing check in the newly covered code: the real
  `encode_any` (including the byte-array/string class branches, the double
  and large-integer reads and the printf of an unencodable class tag), the
  write barrier added to `toit_v2_grow_stack`, the ARGS expansion of the
  primitive, and the NestingTracker verify as they are.
* The pilot's hand copy of the encoder had the message tags off by one
  (`TAG_POSITIVE_SMI` is 1); the constant table, checked against the C++,
  has the real ones. Hand renderings do drift; generated ones cannot.
* **byte_content / mutable_byte_content: no bug** in the decoding of
  attacker-controlled slices and copy-on-write byte arrays (bounds, depth,
  the external tag, the program heap; a source range stays valid when the
  destination's copy-on-write replaces a backing in the same primitive).
  One dead check: `if (content == null) return inner_success;` in the
  slice branch of `mutable_byte_content` compares the out-parameter
  (the address of a local of the wrapper, never null) instead of
  `*content`; VeriFast proves it dead (run with `-allow_dead_code`). It
  has no effect; were it live, it would return the whole backing instead
  of the slice, still inside one writable byte array. Not changed (no
  behaviour difference); a cleanup for upstream.
* VeriFast 26.10's Rust front end does not support `>>` ("Todo:
  BinOp::Shr"): six external_body bodies of view.rs use it.

## Upstream candidates

Drafts, not filed (no issue or PR has been opened).

* Wave 11: upstream's snapshot reader copies an object's header word
  (src/snapshot.cc `read_object`), finalizer flag included, and
  `MessageEncoder::encode_byte_array` transfers an external byte array
  with the flag: a crafted snapshot's large byte-array literal sent in a
  message would be freed by the receiver. Upstream runs trusted
  snapshots only; a check in the reader (refuse the flag) would close it.
  blob_index_of's SSE loop indexes with an `int` (blobs above 2 GB on
  x86-64 hosts). "Findings", wave 11.

* Wave 7: `concat_strings` (src/primitive_core.cc, upstream
  primitive_core.cc:1767) must bound the sum of its parts' lengths (on a
  32-bit VM the sum wraps and the copy overflows the result: "Findings");
  the same for string_add's helper (`len_a + len_b`). The fix of ccde26f7
  (OUT_OF_RANGE above 2^30 / 2^62) and tests/concat-strings-overflow-test.toit
  go with it.

* Wave 6: `explicit MessageEncoder(uint8* buffer)` (src/messaging.h,
  upstream messaging.h:168) must take ownership of the buffer
  (`take_ownership_of_buffer_(true)`): ExternalSystemMessageHandler::send_
  and reply_rpc leak the encoded buffer when allocating the SystemMessage
  fails ("Findings"). One line; tests/ctest/message-encoder-ownership-test.cc
  goes with it.

* Wave 5: VmFinalizerNode::heap_dying must not free the memory of an
  object whose finalizer bit is clear (src/heap_roots.h, upstream
  heap_roots.h:94): the double free of "Findings", reachable upstream by
  any process that fails to decode a message twice and then ends. One
  line; the regression tests of 05159afd go with it. With it, the drop of
  malformed messages (task_receive_message, main_arguments,
  spawn_arguments: 05159afd) can go too.

* `mutable_byte_content` (src/objects_runtime.cc, the byte-array slice
  branch; upstream master has the same line, objects_runtime.cc:80):
  `if (content == null) return inner_success;` tests the out-parameter,
  which is never null, so the check is dead (VeriFast proves it, see
  "Findings"). The comment means `*content`: an inner success with a null
  content (a failed allocation does not give one: it returns false with
  the error set; a neutered external byte array does, address null and
  length 0). But `if (*content == null) return inner_success;` would
  return the whole (empty) backing for ANY slice bounds of a neutered
  array, where today bounds other than [0, 0] fail. Proposed one-line fix:
  delete the line (behaviour unchanged, as it is dead); the `*content`
  variant is safe (length 0) but accepts bogus bounds.
* The encoders' sizes on 32-bit: upstream master still returns the size
  as `unsigned` (messaging.h:175) and has no size limit, so the
  truncation of a4d19ec2 applies there on every width; the fix of this
  branch (a limit of 0x3fffffff including out-of-line data, blobs checked
  against what is left) is the one to propose, together with a4d19ec2.
* encode_copy's `memcpy(data, source, length + extra)` (upstream
  messaging.cc:461): the one-byte over-read for a string slice over a
  byte array ("Findings"); the fix is two lines.
* VeriFast (drafts for its issue tracker): the C++ front end rejects every
  pointer cast ("The other route" above); ghost code cannot take the
  address of a parameter before the real code does ("Taking the address
  of this expression is not supported"), so a conversion of a parameter's
  chunk before its first `&` in the code is impossible; the prelude has no
  `u_llong_integer`-to-`chars` auto lemma (model/llong.gh adds it);
  `lemma_auto` with a body is a parse error in a .c file (fine in a .gh).
  Wave 3: with the default prover (Redux) `is_smi_w(0)` (a fixpoint
  `w % 2 == 0`) is not provable, with Z3 it is (the decoder runs with
  Z3); a truncating cast has no known value even in range
  (`/*@truncating@*/(word)u` with `u <= INTPTR_MAX` is not known to be
  `u`; `truncate_signed_def` with a Z gives single values, e.g. 0); the
  elements of a `uchars` chunk are not known to be bytes (a lemma per
  read, `uchars_nth_limits`).

Wave 3 (the decoder; upstream master's messaging.cc has all of them):

* The encoders' arrays and maps longer than a process heap holds
  (b609da9f): the two checks in encode_array and encode_map ("Findings");
  upstream reaches it only with a crafted snapshot. With them, the
  task_receive_message/main_arguments/spawn_arguments handling of a
  malformed message (delivered as decoded, the externals after the error
  leaked) is unreachable; a defensive fix would drop such a message with
  `remove_disposing_finalizers()` and the message's own deallocation.
  Wave 4 draft (applied and proved in wave 5, 05159afd, together with
  the heap_dying fix it needs): in task_receive_message, after the
  allocation-failure branch, `if (decoder.malformed_input()) {
  decoder.remove_disposing_finalizers(); process->remove_first_message();
  return process->null_object(); }` (the library skips a null message);
  in main_arguments and spawn_arguments the same with
  `clear_main_arguments()` / `clear_spawn_arguments()`,
  `MessageDecoder::deallocate(arguments)` and `FAIL(INVALID_ARGUMENT)`.
* decode_external_data's inline lengths (wave 4, "Findings"): the two
  checks.
* read_cardinal (965bff66 here): upstream shifts by any amount (undefined
  behaviour for long cardinals) and drops high bits; #3362's digit count
  check plus this branch's digit check.
* TISON smis between 2^30 and 2^62 written on 64-bit fail to decode on
  32-bit (and 32-bit large integers in the 64-bit smi range decode as
  non-canonical large integers on 64-bit): fixed in wave 4 (1d19379a:
  read_cardinal_64, decode_integer, and the tests); the fix to propose.
* decode_process_message without a process: fixed in wave 4 (1d19379a:
  reads only an int-sized integer; tests/ctest/message-process-message-
  test.cc); upstream has the same code and the same TODO.

## One contract, two renderings

verified/CONTRACTS.toml writes each leaf contract (gc_grow_stack,
gc_allocate_instance, gc_allocate_double, gc_allocate_exception,
gc_call_primitive) once, clause by clause: name, Verus text, VeriFast
text, bridge, note. verified/tools/contract_check.toit (in check.sh)
compares the clauses with the Verus external_body function and the
conjuncts with the contract of the generated rendering; a change on either
side fails until the table, and the other side, follow. "MISSING" marks a
clause one side lacks and is reported. The bridges between the views,
`stack` (the machine's reloaded views against the VM state `vm(p, v, n)`
and `vm_equiv`), `heap` (the abstract heap against VeriFast's
`heap(objs, H)` at `(uword)o - 1`) and `primitive` (a primitive's
`prim_out` against the spec's `prim_call_post`), are written there once:
**the remaining reviewed assumption** of the seam, with the three
named lemmas of `ffi/` (gc_equiv_trans, stack_copy_equiv, prim_retry).
Since wave 6 both sides are checked for every leaf contract the verified
loop uses except gc_allocate_exception (gc_grow_stack, gc_allocate_instance,
gc_allocate_double, gc_call_primitive) and for the Rust primitives'
allocator (allocator_large_integer, _double, _array, _string, _byte_array). A clause whose Verus text is
empty is a VeriFast conjunct the Verus side states by a type (the views of
a `&mut Heap`). Contracts between two pieces of C++ (the allocator's,
Array::at_put, used by the decoder) are in the table too, with no Verus
function: only the VeriFast prototype (model/objects.gen.h) is compared.
contract_check also requires every bodiless lemma of a rendering and, since
wave 6, of a ghost header (`.gh`) to be a listed assumption.

## One layout table

verified/LAYOUT.toml lists the layout facts both heap models rely on, once,
per object kind (tagging, header bits, class tags, instance, task, array,
double, large integer, byte array internal/external with the RawByteTag,
string internal/external with the sentinel and half words): value on
64-bit and on 32-bit, the C++ expression, the Verus constant of
verified/core/src/layout.rs and the VeriFast macro of `model/constants.h`.
verified/tools/layout_table.toit (in check.sh) compares every Verus name
with layout.rs on both widths and generates
`model/layout.gen.constants.cc`, static assertions of every C++ expression
and every VeriFast macro against the table, compiled for x86_64 and i686 by
`constants-check.sh` (74 checks). The model's predicates use the
`LAYOUT_*` macros (word indices of the length, element, external address
and tag words, byte offsets of the half words and of the content), so a
fact changed on either side fails until the table and the other side
follow. The later Verus raw-pointer work can import the same rows (the
names are layout.rs's).

## The Rust raw-memory layer

Trusted items of crate core (verified/TRUSTED.toml, `rust/census.sh`): 93
external_body, 66 unsafe (159), of which 58 are view.rs accessor bodies (27
with integer-to-pointer casts, 6 with `>>`) and 19 the FFI wrappers of
ffi.rs (15 call C++: contracts, not bodies).

Like for like, on the same five accessors (class_id, class_tag, field,
array_length, element):

| | VeriFast (Rust front end) | Verus with vstd::raw_ptr |
|---|---|---|
| bodies | verbatim (copy-out is textual: the sidecar mechanism without a translation) | rewritten: no integer-to-pointer cast in Verus; `with_exposed_provenance` + `ptr_ref` |
| result | 3 of 5 (class_id, class_tag: `>>` unsupported) | 5 of 5, 11 obligations, < 1 s |
| annotations | 3 predicates + 2-6 ghost lines per accessor | a permission map per object + one assert per accessor; callers must thread `Tracked` permissions |
| what stays trusted | VeriFast, the copy (tool-checked), the bridge from words to the abstract heap (`heap`) | vstd's raw_ptr axioms, and an external_body that hands out fresh permissions after every GC point (the same bridge, but stated in Verus) |

Verdict: VeriFast is cheaper now (no change to verified/core, bodies
verbatim; with the shift supported about 90% of the view.rs bodies would
go through as they are). Verus with permissions leaves less trusted in the
end: the accessors' abstract meaning (`r == objs()[id].class_id`) becomes
provable inside the one proof, and the trusted part shrinks to the
permission hand-out at the FFI returns. But it changes every accessor and
its callers (a `Tracked` heap-permission invariant through the machine),
an estimated 3-4 weeks against 1 week for VeriFast on all view.rs bodies.
Recommended: VeriFast now for the bodies (automating the copy-out with the
sidecar check), Verus permissions as the long-term step when the heap
model is revised.

## What remains trusted in the C++

* VeriFast itself; Clang's AST (the translator prints what Clang parsed);
  the translator's rules (small, documented, each an error when not
  applicable). Among them the implementation-defined behaviour the C++
  relies on, as GCC and Clang define it (and C++20 standardizes): the
  modular conversions of `truncating` and `unsigned-word-conversion`, and
  since wave 9 the arithmetic right shift of a negative int64 (rendered as
  the same floor division without a negative shift).
* The C library's contracts as the sidecars state them (memcpy, memmove,
  memset: the bytes they touch); since wave 9 memcpy from a float or
  double local (`prims/put_float.render`: VeriFast has no lemma turning a
  float's chunk into bytes) and VeriFast's own double-to-float conversion
  (total, as IEC 60559 defines it); since wave 10 libm's fmod, sqrt,
  ceil, floor and trunc (`prims/float_ops.render`: `requires true; ensures
  true;`, they touch no memory; float_round's `round` was the first).
* The bridges `stack` and `heap` (CONTRACTS.toml): that the predicates are
  what the allocator and GC establish (TRUSTED.md V2).
* The contract-only functions: `Double::value`,
  `unsigned_cast`, `Scheduler::gc`, `v2_report_allocation_failure`, the allocator (`allocate_stack`,
  `allocate_byte_array`, and for the decoder `allocate_string`,
  `allocate_array`, `allocate_instance`, `allocate_double`,
  `allocate_large_integer`, the external string and byte array over a
  message's block: CONTRACTS.toml),
  `Array::max_length_in_process`, `Process::true_object`,
  the write barrier and the error roots, the named
  assumptions (CONTRACTS.toml `[[assumption]]`: the encoder's
  `two_pass_room`, the decoder's `ipc_begin`, `ipc_room`, `ipc_pointer`,
  `ipc_external`, `ipc_length`, `ipc_end` for inter-process messages only,
  the GC's `gc_owns`, and at the boundary `gc_equiv_trans`, `stack_copy_equiv`,
  `prim_retry`), the boundary's model (Scheduler::gc, the policy table, each
  primitive's contract `Primitive_Entry`), the receive side's model (a process's mailbox and
  arguments slots, `HeapObject::clear_has_active_finalizer` giving a block
  back, the finalizer queue), the
  policy reads, HeapTagScope, the
  program roots, `fail`. Each is still compared with its source when it is
  a `@render ... trusted`; the others are plain prototypes.
* Wave 12's trusted specifications (each with why there is no proved
  alternative): the 23 builtin-class-id getters of
  `loader/builtin_classes.render` (`result == nth(INDEX, ws)` over the raw
  table: the getters are generated by a macro, so the translator cannot
  compare their text; ESBMC `program-class-ids-native` checks every
  native getter against its slot and every index on both widths);
  `classes_agree` in `prog_ok_from_check` (the model's uninterpreted
  `class_tag` and `class_fields` are the program's class bits for the
  builtin classes: what those functions stand for, the heap bridge's
  part; making them defined would change the heap predicate every proof
  uses); the bit_cast instances of `prims/float_raw.render` (`requires
  true; ensures true;`, as the encoder's and decoder's: VeriFast has no
  lemma between a float's chunk and its bytes); the translator's
  rendering of an int64 `>>` by a run-time count as `asr_int64` (the
  arithmetic shift GCC and Clang define, written as the floor division
  without a shift of a negative value: the same trust as wave 9's `>>=`
  by a literal); the List<uint16> projections (`List_uint16_length`,
  `List_uint16_data`, hand-written like the BytecodeList ones).
* The link between the install-time check of the builtin classes and
  `prog_ok` in the `process` predicate (wave 12): what
  `V2Verifier::builtin_classes_error` returns is proved
  (`loader/builtin_classes.render`), and v2_verify refuses a program for
  which it is not null; that every untrusted process runs a program
  v2_verify accepted is reviewed, as for the error roots below.
* The link between the loader's check and the `process` predicate (wave
  8): the predicate's `error_roots_ok` for its program (the error roots are distinct heap
  references above the immediate errors) is what
  `Program::has_valid_error_roots` returns (proved,
  `loader/error_roots.render`), and ProcessGroup::create refuses a program
  for which it is false; that every process runs a program that went
  through ProcessGroup::create (its group's program) is reviewed, not
  proved, like the other facts the loader supplies (the page count, the
  class-id table).
* Everything not attempted (table above).

## Files

* `model/`: the object model (`objects.render`, generated `objects.gen.h/.c`),
  the constant table, `arith.gh` (shift and mask lemmas), `model.cfg`,
  `retry.h` (wave 8: the retry protocol's `oom_error`, `oom_unchanged`
  and the loader-checked error-root facts, for the renderings that use
  them).
* `loader/error_roots.render` (wave 8): the loader's error-root check.
* `loader/builtin_classes.render` (wave 12): the install-time check of the
  builtin classes (what `prog_ok` rests on); its native counterpart and
  image_layout_error's are `../harness/install_image_checks.cc` (ESBMC).
* `encoder/`, `decoder/`, `ffi/`, `prims/`, `utf8/`: the targets (sidecar
  and generated files); `encoder/cardinal.h`/`.c` (the cardinal's byte
  bound, proved with Z3 so that the encoder verifies with the default
  prover), `model/llong.gh` (a prelude conversion VeriFast lacks),
  `decoder/radix.h`/`.c` (read_cardinal's digit bound, Z3).
* `rust/`: the Rust accessors (VeriFast), the Verus permission trial, the
  census.
* `render.sh` (translator, both widths), `prefetch-ast.sh` (Clang dumps in
  parallel), `clang-ast.sh`, `constants-check.sh`, `mutant.sh`, `run.sh`,
  `metrics.sh`, `vf.sh`; `model-check-jobs.sh` (the slow tier and the
  per-job memory caps, "Two tiers").
* `probes/`, `shim/`, `fcshim/`, `framac.sh`, `cn.sh`, `cxx-ast.sh`: the
  pilot's probes of other tools and of the C++ front end.
