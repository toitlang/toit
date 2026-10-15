// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system

/** Prints one BENCH line with the process and system memory figures after a GC. */
report tag/string phase/string --extra/string="" -> none:
  stats := system.process-stats --gc
  print "BENCH $tag phase=$phase free=$stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY] largest=$stats[system.STATS-INDEX-SYSTEM-LARGEST-FREE] allocated=$stats[system.STATS-INDEX-ALLOCATED-MEMORY] reserved=$stats[system.STATS-INDEX-RESERVED-MEMORY] us=$Time.monotonic-us$extra"

/** Reports every $interval in a background task until cancelled. */
periodic tag/string --interval/Duration=(Duration --s=2) -> Task:
  return task --background::
    while true:
      sleep interval
      report tag "periodic"
