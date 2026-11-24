# Copyright (C) 2026 Toit contributors.
#
# The model-checker jobs of run.sh that need more than the defaults
# (sourced by run.sh; see the README, "Two tiers"):
#   slow NAME/ABI CAP-GB TIMEOUT-S
# a job of the slow tier (run.sh --slow), which the fast tier (the gate)
# does not run: it took more than 90 s in the measurements of the README's
# slow-tier table. CAP-GB is its memory cap (ulimit -v on the virtual
# size, about 1.5 times the measured peak) and what it holds of the memory
# budget while it runs; TIMEOUT-S its timeout (4 times the measured time,
# at least 30 minutes).
#   known_noverdict NAME/ABI REASON
# a slow job known not to finish: the slow tier prints NOVERDICT for it
# without running it (RUN_KNOWN_NOVERDICT=1 runs it with a 40 GB cap).
#   fast_cap NAME/ABI CAP-GB
# a job of the fast tier that needs a larger cap than RUN_FAST_MEM (4 GB).

fast_cap encoder-handoff/LP64 12
fast_cap scheduler-notify/LP64 11
fast_cap ipc-byte-array-visit/ILP32 6
fast_cap scheduler-worker-handoff/LP64 6
fast_cap scheduler-target-queue/LP64 5

slow allocate-task/ILP32                         3  1800
slow allocate-task/LP64                          4  1800
slow encoder-collections/LP64                    4  1800
slow event-notifiers/LP64                        3  1800
slow external-accounting-threads/ILP32           3  1800
slow external-accounting-threads/LP64            3  1800
slow external-blob-allocation/ILP32              3  1800
slow external-blob-allocation/LP64               3  1980
slow finalizer-queue/LP64                        4  1800
slow free-list-selection/ILP32                  15  7080
slow gc-compaction-fix-roots/ILP32               3  1800
slow gc-compaction-fix-roots/LP64                4  5340
slow gc-compaction-last-fit/LP64                 3  1800
slow gc-compaction-overhang/ILP32                5  5760
slow gc-ec618-reclaim/ILP32 3 1800
slow gc-ec618-stats/ILP32 3 1800
slow gc-external-finalizer-raw/LP64              5  1800
slow gc-external-finalizer-string_buffer/LP64    5  1800
slow gc-metadata-commit/LP64                     3  3240
slow gc-metadata-layout-ec618/ILP32              3  2040
slow gc-metadata-layout-esp32/ILP32              3  4200
slow gc-metadata-layout/ILP32                    3  1800
slow gc-remembered-card/LP64                     3  2100
slow gc-scavenge-alias/ILP32                     3  1800
slow gc-scavenge-alias/LP64                      3  2280
slow gc-scavenge-graph/ILP32                     3  1800
slow gc-scavenge-graph/LP64                      4  1800
slow gc-stack-shrink/ILP32                       3  1800
slow gc-stack-shrink/LP64                        4  1860
slow ipc-fixed-scalar/LP64                       5  1800
slow ipc-byte-array-visit/LP64                    22  1800
slow ipc-transferred-array/LP64                  5  2820
slow monitor-scavenge-promoted/LP64              3  1800
slow monitor-scavenge-promotion_failed/LP64      3  1800
slow monitor-scavenge-young/LP64                 3  1800
slow process-array-allocation/LP64 3 3600
slow scheduler-notify/ILP32                       24  1800
slow scheduler-spawn/ILP32                       4  1800
slow scheduler-spawn/LP64                        7  2580
slow snapshot-image-layout/LP64                  3  1800
slow task-all-fields/ILP32                       3  1800
slow task-all-fields/LP64                        3  1800
slow task-retry-fields/ILP32                     3  1800
slow task-retry-fields/LP64                      4  2820
slow task-transfer/LP64                          3  1980
slow timer-delete/LP64                           5  1800
slow timer-dispatch/LP64                         9  1800
# No verdict yet when measured (the README table): out of memory at 16 GB
# (gc-sweep-chunk) or out of time (the others). Their caps and timeouts are
# estimates for the next attempt; a cap above RUN_SLOW_BUDGET runs when no
# other slow job holds memory.
slow free-list-selection/LP64 30 14400
slow gc-compaction-overhang/LP64 10 14400
slow gc-metadata-layout/LP64 4 10800
slow gc-sweep-chunk/LP64 6 14400
# gc-sweep-chunk with fill_unmarked_words by contract and Boolector
# (2026-11-24), and its mutants (README, "Restructured").
slow gc-sweep-chunk/ILP32                        3  1920
slow gc-sweep-chunk-uncounted/ILP32              3  1800
slow gc-sweep-chunk-no-sentinel/ILP32            3  1800
slow gc-sweep-chunk-no-sentinel/LP64             5  1800
slow gc-sweep-chunk-uncounted/LP64               5  7200
