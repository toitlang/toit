// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import ble.experimental.esp32
import .connection-events as events
import .mixed-update-peer as fixture

main:
  radio := events.ConnectionEvents (esp32.Esp32Transport)
  try:
    fixture.run --timeout=(Duration --s=170) --radio=radio
  finally:
    // The fixture joins the controller reader before returning or throwing.
    // Keep diagnostics out of the live receive path.
    radio.dump
