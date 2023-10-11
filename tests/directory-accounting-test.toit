// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.directory
import expect show *

main:
  stats := process-stats --gc=true
  base := stats[STATS-INDEX-ALLOCATED-MEMORY]
  10.repeat:
    stats2 := process-stats --gc=true
    print "Object heap $stats2[STATS-INDEX-ALLOCATED-MEMORY] bytes on heap."
    expect:
      stats2[STATS-INDEX-ALLOCATED-MEMORY] - base <= 64 * 1024
    catch:
      // If there is no directory with this name, silently let the test pass.
      dir := directory.DirectoryStream "/usr/bin"
      i := 0
      while entry := dir.next:
        i++
