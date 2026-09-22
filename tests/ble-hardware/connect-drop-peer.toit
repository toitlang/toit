// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble
import .fixtures.reference-central as fixture

main:
  adapter := ble.Adapter
  try:
    adapter.set-preferred-mtu 23
    central := adapter.central
    identifier := fixture.find central
    started := Time.monotonic-us
    error := catch:
      with-timeout --ms=4_000:
        device := central.connect identifier
        device.close
    elapsed := Time.monotonic-us - started
    print "CONNECT_DROP_PEER RESULT error=$error elapsed-us=$elapsed"
    if error != "BLE connection failed": throw "SETUP_DISCONNECT_NOT_REPORTED"
    print "CONNECT_DROP_PEER COMPLETE"
  finally:
    adapter.close
