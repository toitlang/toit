# Copyright (C) 2026 Toit contributors.
#
# The slow tier of run.sh (sourced by it): the model-checker jobs that take
# well over a minute, which the fast tier (the gate) does not run and
# `run.sh --slow` runs alone. One line per job:
#   slow NAME/ABI [CAP-GB [TIMEOUT-S]]
# CAP-GB is the job's memory cap (ulimit -v) and what it holds of the
# memory budget while it runs; TIMEOUT-S its timeout. The README's
# slow-tier table has the measured time and peak memory of each.
#   known_noverdict NAME/ABI REASON
# a job known not to finish: the slow tier prints NOVERDICT for it without
# running it (RUN_KNOWN_NOVERDICT=1 runs it with a 40 GB cap).

known_noverdict core-entry/LP64 "does not finish alone with 36 GB; the harness is to be split"
known_noverdict core-entry-checked/LP64 "does not finish alone with 36 GB; the harness is to be split"

slow allocate-task/ILP32
slow allocate-task/LP64
slow core-entry-checked/ILP32
slow core-entry/ILP32
slow encoder-collections/LP64
slow event-notifiers/LP64
slow external-accounting-threads/ILP32
slow external-accounting-threads/LP64
slow external-blob-allocation/ILP32
slow external-blob-allocation/LP64
slow finalizer-queue/LP64
slow free-list-selection/ILP32
slow free-list-selection/LP64
slow gc-compacted-chunk-tails/LP64
slow gc-compaction-card-rank/LP64
slow gc-compaction-fix-roots/ILP32
slow gc-compaction-fix-roots/LP64
slow gc-compaction-last-fit/LP64
slow gc-compaction-overhang/ILP32
slow gc-compaction-overhang/LP64
slow gc-current-task/LP64
slow gc-external-finalizer-raw/ILP32
slow gc-external-finalizer-raw/LP64
slow gc-external-finalizer-string_buffer/LP64
slow gc-metadata-commit/LP64
slow gc-metadata-layout-ec618/ILP32
slow gc-metadata-layout-esp32/ILP32
slow gc-metadata-layout/ILP32
slow gc-metadata-layout/LP64
slow gc-overflow-registration/LP64
slow gc-remembered-card/LP64
slow gc-scavenge-alias/ILP32
slow gc-scavenge-alias/LP64
slow gc-scavenge-graph/ILP32
slow gc-scavenge-graph/LP64
slow gc-stack-shrink/ILP32
slow gc-stack-shrink/LP64
slow gc-sweep-chunk/ILP32
slow gc-sweep-chunk/LP64
slow ipc-byte-array-visit/LP64
slow ipc-fixed-scalar/ILP32
slow ipc-fixed-scalar/LP64
slow ipc-transferred-array/LP64
slow monitor-scavenge-promoted/LP64
slow monitor-scavenge-promotion_failed/LP64
slow monitor-scavenge-young/LP64
slow scheduler-notify/ILP32
slow scheduler-spawn/ILP32
slow scheduler-spawn/LP64
slow snapshot-image-layout/LP64
slow task-all-fields/ILP32
slow task-all-fields/LP64
slow task-retry-fields/ILP32
slow task-retry-fields/LP64
slow task-transfer/LP64
slow timer-delete/LP64
slow timer-dispatch/LP64
