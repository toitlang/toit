// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.directory
import expect show *
import system
import system show process-stats

main:
  stats := process-stats --gc
  base := stats[system.STATS-INDEX-ALLOCATED-MEMORY]
  10.repeat:
    stats2 := process-stats --gc
    expect
        stats2[system.STATS-INDEX-ALLOCATED-MEMORY] - base <= 64 * 1024
    dir := null
    catch:
      // If there is no directory with this name, silently let the test pass.
      dir = directory.DirectoryStream "/usr/bin"
    if dir:
      i := 0
      // Read all the directory entries.
      // Because we read until we are done (and there's no rewind), the
      // directory also gets closed, so we are not testing the Toit finalizers
      // here, only the VM finalizers (on the external byte arrays that are
      // used to create the dirname strings).
      while entry := dir.next:
        i++
