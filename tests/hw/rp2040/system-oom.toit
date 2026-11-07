// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import ....system.services show SystemServiceManager
import io.stdio

// Install as the envelope's SYSTEM snapshot, never as an application.
main:
  SystemServiceManager
  print "[test] system-oom ready"
  // Let the observer attach before triggering a failure that resets USB.
  if (stdio.stdin.read-bytes 4).to-string != "oom\n": throw "Invalid OOM trigger"
  print "[test] injecting native system-oom"
  sleep --ms=200
  bytes := ByteArray (1 << 20)
  bytes[0] = 1
  print "system-oom-rp2040: FAIL unexpected allocation success $(bytes[0])"
