// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the rate limit of the out-of-memory reports of containers.

An allocation that still fails after the collections prints a heap report
  (on a device a walk of the whole heap and about 100 ms of output; on the
  host one "Out of memory process" line). A sandboxed container at its quota
  printed one for every failed allocation: 397 reports in one device run,
  followed by a hang. Now a process group gets one report per 10 seconds
  (src/out_of_memory.h), the first failure is always reported, and the next
  report carries the number of failures in between.

The sandboxed container here fails 50 allocations in a row and the trusted
  one 30: each container is reported once. Before the limit: 80 lines.
*/

import expect show *
import .sandbox-util show *

PROGRAM ::= """
import system.containers

main args:
  if args is Map:
    failures := 0
    args["count"].repeat:
      exception := catch: ByteArray 300_000
      if exception: failures++
    print "failures: \$failures"
    return
  container := containers.start containers.current {"count": 50}
      --untrusted
      --quotas={"heap": 200_000}
  container.wait
  container = containers.start containers.current {"count": 30}
      --quotas={"heap": 200_000}
  container.wait
"""

main args:
  toit-run := args[0]
  with-tmp-directory: | dir |
    source := "$dir/oom-report-rate-main.toit"
    write-file source PROGRAM
    result := run-process [toit-run, source] --timeout-ms=60_000
    print result.output
    expect-equals 0 result.exit-code
    lines := result.output.split "\n"
    failures := lines.filter: it.starts-with "failures: "
    expect-equals ["failures: 50", "failures: 30"] failures
    reports := lines.filter: it.starts-with "Out of memory process "
    // One report per container (two process groups).
    expect-equals 2 reports.size
    expect-not (reports[0].starts-with reports[1][..reports[1].index-of ":"])
