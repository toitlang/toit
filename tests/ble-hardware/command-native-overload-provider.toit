// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .fixtures.vhci-command-overload-provider as fixture
import ble.experimental.transport
import io

main:
  provider := Provider
  provider.install
  try:
    provider.uninstall --wait
    print "COMMAND_OVERLOAD_PROVIDER COMPLETE"
  finally:
    provider.uninstall

class Provider extends fixture.Provider:
  first_/bool := true
  constructor --authenticated/bool=false:
    super --no-receive-flow --authenticated=authenticated
  local-random-address -> ByteArray?: return null
  open-transport -> transport.Transport:
    radio := PausedRadio first_
    first_ = false
    return radio

class PausedRadio extends fixture.Radio:
  pause_/bool := ?
  constructor .pause_: super

  receive -> ByteArray:
    packet := super
    // This plaintext fixture uses unfragmented eleven-byte ATT commands.
    // The peer first reads back sequence0, then floods sequences1 onward.
    if pause_ and packet.size == 23 and packet[0] == 2 and
        (packet[2] & 0x30) != 0x10 and packet[7] == 4 and packet[8] == 0 and
        packet[9] == 0x52 and (io.LITTLE-ENDIAN.uint32 packet 12) == 1:
      pause_ = false
      print "NATIVE_OVERLOAD_PAUSE milliseconds=500 sequence=1"
      sleep --ms=500
      sample := diagnostics
      if not sample or sample.fault != "HCI_QUEUE_OVERFLOW":
        throw "NATIVE_OVERFLOW_NOT_REACHED"
      // Consume the native primitive's actual sticky error. The held packet
      // must not reach the application after transport failure is known.
      return super
    return packet
