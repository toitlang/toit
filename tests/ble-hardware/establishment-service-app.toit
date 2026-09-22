// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as service
import .mixed-update-app as reads

main arguments/List:
  if arguments.size != 1 or not [0, 1_000].contains arguments[0]: throw "INVALID_ARGUMENT"
  delay/int := arguments[0]
  client := service.Client
  error := null
  cleanup-error := null
  with-timeout --ms=20_000:
    try:
      error = catch:
        client.open --timeout=(Duration --s=5)
        client.with-connection #[0xae, 0xe0, 0x60, 0xac, 0xcd, 0x98]
            --timeout=(Duration --s=8): | connection/service.Connection |
          if delay != 0: sleep --ms=delay
          reads.read-batch connection 0
    finally:
      critical-do --no-respect-deadline: cleanup-error = catch: client.close
  print "ESTABLISHMENT_SERVICE CLIENT delay-ms=$delay error=$error cleanup-error=$cleanup-error"
  exit (error or cleanup-error ? 1 : 0)
