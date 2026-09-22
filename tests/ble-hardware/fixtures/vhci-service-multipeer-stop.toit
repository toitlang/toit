// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import .vhci-service-multipeer as fixture

main arguments:
  with-timeout --ms=60_000:
    if arguments is Map:
      fixture.application arguments
    else:
      fixture.run --abrupt
