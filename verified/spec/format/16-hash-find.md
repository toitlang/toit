# 16. Should HASH_FIND come back? (recommendation)

## Question

Note 11 removed the four intrinsics. Format 2 executes more instructions
than format 1, and there is no time benchmark (the C++ VM cannot run
format 2, so callgrind on the VM is not an option). Which part of the
increase does each intrinsic account for, and should a `HASH_FIND`-style
instruction return in Phase 4 as a verified built-in?

## Measurement

Instruction (step) counts of the reference interpreter, attributed to the
method executing each instruction (`verified/tools/method_steps.toit`,
which runs `toit-spec-run --trace-bci` on both formats). Each intrinsic's
replacement is charged to the methods where its work now runs: HASH_FIND
to the Toit body of `find-body_`; HASH_DO to `hash-do_` and to the loops of `Map.do`,
`Set.do` and their reverse forms (which iterate themselves when
`hash-do_` returns at once); ARRAY_DO to the arrays' `do_`; SMI_REPEAT to
`SmallInteger_.repeat`. In format 1 these methods count the intrinsic's
dispatches (one per entry and one per re-entry after a block call).

The 14 programs of `tests/toit`:

| program | format 1 | format 2 | |
|---|---:|---:|---:|
| blocks | 9 229 | 9 246 | +0.2 % |
| classes | 9 123 | 8 924 | -2.2 % |
| collections | 57 539 | 88 527 | +53.9 % |
| exceptions | 8 436 | 7 809 | -7.4 % |
| floats | 8 175 | 8 084 | -1.1 % |
| hello | 5 677 | 5 442 | -4.1 % |
| large_ints | 8 816 | 10 350 | +17.4 % |
| maps | 105 640 | 170 334 | +61.2 % |
| non_local | 9 167 | 9 689 | +5.7 % |
| sleep_timers | 10 992 | 10 279 | -6.5 % |
| smi_edges | 6 114 | 5 879 | -3.8 % |
| strings | 18 140 | 18 619 | +2.6 % |
| tasks | 34 458 | 19 807 | -42.5 % |
| try_finally | 6 822 | 6 710 | -1.6 % |
| total | 298 328 | 379 699 | +27.3 % |

By intrinsic (format 1 -> format 2, difference, share of the total
difference):

| | 14 spec programs | | map-heavy suite tests | |
|---|---:|---:|---:|---:|
| HASH_FIND | 2 563 -> 47 662 (+45 099) | 55 % | 226 450 -> 3 649 280 (+3 422 830) | 66 % |
| HASH_DO | 594 -> 10 345 (+9 751) | 12 % | 65 010 -> 944 833 (+879 823) | 17 % |
| ARRAY_DO | 2 509 -> 31 993 (+29 484) | 36 % | 74 053 -> 973 981 (+899 928) | 17 % |
| SMI_REPEAT | 2 806 -> 29 856 (+27 050) | 33 % | 8 462 -> 81 414 (+72 952) | 1 % |
| everything else | 289 856 -> 259 843 (-30 013) | -37 % | 6 900 799 -> 6 826 291 (-74 508) | -1 % |
| total | 298 328 -> 379 699 | +27.3 % | 7 274 774 -> 12 475 799 | +71.5 % |

The map-heavy suite tests are `map-test`, `set-map-middle-gap-test` and
`rebuild-hash-index-test` (+48.9 %, +75.0 %, +64.5 %). Without the
HASH_FIND share the spec programs would be at +12.2 % and the map-heavy
tests at +24.4 %. Everything else gets cheaper in format 2 (no frame
words to push, `TRY` instead of `LINK`/`UNLINK`, cheaper task switches).

The whole suite (the 272 tests that pass in both formats,
`run_suite.toit --format both`): 259.9 M -> 317.4 M instructions, +22.1 %
(the +13.9 % of the Phase 2 report was over 268 tests; `list-test`,
which now finishes within the step limit, adds 143 M -> 182 M):

| | format 1 | format 2 | difference | share |
|---|---:|---:|---:|---:|
| HASH_FIND | 0.25 M | 4.14 M | +3.89 M | 6.8 % |
| HASH_DO | 0.07 M | 1.02 M | +0.95 M | 1.7 % |
| ARRAY_DO | 0.80 M | 5.19 M | +4.39 M | 7.6 % |
| SMI_REPEAT | 6.04 M | 55.94 M | +49.91 M | 86.7 % |
| everything else | 252.76 M | 251.15 M | -1.61 M | -2.8 % |

Over the suite the `repeat` loop dominates: `list-test` alone runs 3.5 M
`repeat` iterations (38.0 M of its 38.6 M extra instructions); without
`list-test` SMI_REPEAT is 63 % of the increase, ARRAY_DO 21 %, HASH_FIND
20 %. The compiled loop costs about 12 instructions per iteration (counter
load, `INVOKE_LT`, branch, block load, `INVOKE_BLOCK`, pop, `INVOKE_ADD`,
store, `BRANCH_BACK`) around a block call whose body runs anyway.

Caveat: the format-1 programs of `run_tests.sh` and `run_suite.toit` are
compiled by `toit compile`, which keeps asserts, the format-2 programs by
`toit.compile -Xbytecode_format=2`, which drops them (`maps.toit`: 105 640
instructions with asserts, 101 283 without, both format 1). The `assert_`
method accounts for 0.2 M instructions of format 1 over the suite; the
totals above slightly understate the increase, the per-intrinsic rows are
not affected.

## Recommendation

Bring HASH_FIND back in Phase 4, as a verified built-in of a different
shape than the format-1 intrinsic; leave HASH_DO and ARRAY_DO out; handle
`repeat` separately (last point).

* It is the largest single cost of map-heavy code: more than half of the
  increase on the spec programs and two thirds on the map tests. Maps and sets are
  everywhere in Toit code (the system services, JSON, the RPC layer), and
  each lookup costs about 16 instructions per format-1 dispatch in its
  Toit form (`find-body_`, 226 k dispatches -> 3.65 M instructions).
* The cost is in the probe loop itself (index read, empty test, position,
  backing read, tombstone test, hash compare, next slot), not around block
  calls; the other three intrinsics mostly surround a block call that
  costs far more than the loop instructions, so their instruction counts
  overstate their time cost (note 11).
* The format-1 intrinsic is a re-entrant state machine with state in
  stack slots, which is what made it hard to specify (note 11, 428 spec
  lines for the four, a bug found in it). A verified built-in should not
  be re-entrant: a `HASH_PROBE` that, given the collection, the key's hash
  and a probe state (slot, step, deleted slot) in locals, walks the index
  with checked reads of `index_` and `backing_` and returns to the Toit
  loop at the first point that needs Toit code (a hash match to compare, a
  free slot, a full index) or on any malformed field (the Toit loop then
  continues as now). It never calls a block, never keeps state outside its
  operands, and is a function from the heap and its operands to a
  smi and new probe state, so its spec is a bounded loop over checked
  array reads, of the kind the verified core already proves (the fast
  paths of `INVOKE_AT` and the collection-field checks of note 12).
  The comparison stays in Toit: `compare_` can be overridden, so the
  built-in cannot decide equality itself.
* HASH_DO and ARRAY_DO stay out: their replacements are ordinary proven
  instructions, and each iteration calls a block, which dominates the
  time of an iteration.
* By instruction count `repeat` costs more than HASH_FIND over the whole
  suite (+49.9 M vs +3.9 M), concentrated in loop-heavy programs. Its fix
  is cheaper than a hash built-in and needs no Toit-level invariants: a
  `REPEAT` instruction with frame-relative state (note 11, about 40 spec
  lines) or a fused compare-and-branch for the compiled counter loop. It
  should be decided together with HASH_FIND, on the same time benchmark.

The decision should be confirmed by a time measurement on the Phase 4
interpreter (a map-lookup and a `repeat` micro-benchmark, and the system
snapshot's boot) before either is specified; until then format 2 keeps no
intrinsics.
