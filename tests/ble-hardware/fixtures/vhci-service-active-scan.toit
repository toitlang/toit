// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import ble.experimental.transport
import ble.experimental.service.scanning-provider as providers
import system.containers
import .service-scan-active as application

main arguments:
  with-timeout --ms=20_000:
    if arguments is Map:
      application.main
    else:
      provider := Provider
      provider.install
      try:
        child := containers.start containers.current {"application": true}
        try:
          result := child.wait
          if result != 0: throw "ACTIVE_SCAN_APPLICATION_FAILED"
          print "SERVICE_ACTIVE_SCAN COMPLETE client-exit=$result"
        finally:
          child.close
      finally:
        provider.uninstall

class Provider extends providers.Provider:
  constructor: super
  open-transport -> transport.Transport: return esp32.Esp32Transport
