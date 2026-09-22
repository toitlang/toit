// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import .vhci-pairing as fixture

main:
  3.repeat: | cycle/int |
    fixture.run --numeric=(cycle == 2)
    print "SECURITY_REQUIREMENTS_PEER CYCLE index=$cycle"
  print "SECURITY_REQUIREMENTS_PEER COMPLETE connections=3"
