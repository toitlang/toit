// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import .native as native
import .transport as transport

/**
The ESP32 transport: the host's HCI packets go to the chip's own controller
  through VHCI.

$Esp32Transport is the transport a provider's `open-transport` hook returns
  on a controller-only ESP32 firmware. It adds the vendor transmit power
  control of $transport.TxPowerControl on top of the shared
  $native.NativeTransport.
*/

/**
An exclusive ESP32 VHCI controller transport.

Requires firmware configured with the controller-only Bluetooth host option.
  Supports the original ESP32 and ESP32-S3 in BLE-only mode. The native ingress
  queue stays in internal RAM for lock-free counters, including when the managed
  heap uses PSRAM. The SDK keeps ESP-IDF's PSRAM atomic workaround enabled for
  other native code.

Explicit close reports HARDWARE_ERROR if controller disable or deinitialization
  fails, after releasing the native resource. Exact controller errors are logged.
  A caller must not treat an idempotent subsequent close as proof of recovery.
*/
/**
Whether this firmware has the controller-only transport: its primitives are
  linked in only when the Bluetooth controller runs without a native host.
*/
available -> bool:
  catch --unwind=(: it != "PRIMITIVE_LOOKUP_FAILED"):
    native.tx-power_ 2 0 0
    return true
  return false

class Esp32Transport extends native.NativeTransport implements transport.TxPowerControl:
  constructor:
    super 0 --packet-limit=1029

  /**
  Returns the advertising transmit power in dBm, or null while the controller is off.

  The original ESP32 supports -12 to +9 dBm in 3 dB steps, the ESP32-S3
    -24 to +18 dBm in 3 dB steps and +20 dBm.
  */
  tx-power -> int?: return native.tx-power_ 0 0 0

  /** Sets advertising, scanning and default connection power; see $transport.TxPowerControl.set-tx-power. */
  set-tx-power dbm/int -> int?: return native.tx-power_ 1 dbm 0

  closest-tx-power dbm/int -> int: return native.tx-power_ 2 dbm 0

  /**
  Sets one connection's power; see $transport.TxPowerControl.set-connection-tx-power.

  Throws BLE_UNSUPPORTED on the original ESP32: its controller accepts a
    per-connection level but keeps transmitting at the default one.
  */
  set-connection-tx-power handle/int dbm/int -> int?:
    catch --unwind=(: it != "UNIMPLEMENTED"):
      return native.tx-power_ 3 dbm handle
    throw "BLE_UNSUPPORTED"

  /** Returns one connection's power, or null where only HCI knows it (the original ESP32). */
  connection-tx-power handle/int -> int?:
    catch --unwind=(: it != "UNIMPLEMENTED"):
      return native.tx-power_ 4 0 handle
    return null
