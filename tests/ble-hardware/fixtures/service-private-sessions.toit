// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import .service-secure-values as fixture

main:
  with-timeout --ms=150_000:
    2.repeat:
      while true:
        error := catch: fixture.main
        if not error: break
        if error != "GATT_SERVICE_BUSY": throw error
        // Resource close returns before the old controller reader is joined.
        sleep --ms=10
    print "PRIVATE_SERVICE_APP COMPLETE sessions=2"
