// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system
import system.assets

main arguments/List:
  expect-equals "rp2040-persistent-container-assets" assets.decode["marker"].to-string
  retained := List 20: ByteArray 193 --initial=it
  20.repeat:
    system.process-stats --gc
    retained.size.repeat: | i/int | expect-equals i retained[i][192]
  token := arguments.is-empty ? "boot" : arguments[0]
  print "container-child-rp2040: PASS assets, GC and token=$token"
