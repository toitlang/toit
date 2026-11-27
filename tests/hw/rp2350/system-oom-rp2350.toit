// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import ....system.services show SystemServiceManager

// Use as the envelope's SYSTEM snapshot, not as an application container.
// This exercises the VM's system-process OOM path before trial validation.
main:
  SystemServiceManager
  print "[test] injecting native system-oom"
  sleep --ms=200
  bytes := ByteArray (1 << 20)
  bytes[0] = 1
  print "system-oom-rp2350: unexpected allocation success $(bytes[0])"
