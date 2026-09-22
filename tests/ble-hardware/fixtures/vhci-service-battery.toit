// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import ble.experimental.transport
import ble.experimental.service.central-provider as providers
import system.containers
import .service-battery as application

main arguments:
  with-timeout --ms=40_000:
    if arguments is Map:
      application.main
    else:
      provider := Provider
      provider.install
      try:
        2.repeat: | cycle/int |
          child := containers.start containers.current {"application": true}
          try:
            result := child.wait
            if result != 0: throw "BATTERY_APPLICATION_FAILED"
            print "SERVICE_BATTERY CLIENT cycle=$cycle exit=$result"
          finally:
            child.close
        if provider.opens != 4: throw "EXPECTED_SCAN_AND_CONNECT_PER_CLIENT"
        print "SERVICE_BATTERY COMPLETE clients=2 controller-opens=$(provider.opens)"
      finally:
        provider.uninstall

class Provider extends providers.Provider:
  opens/int := 0

  constructor:
    super

  open-transport -> transport.Transport:
    opens++
    return esp32.Esp32Transport
