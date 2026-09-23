// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Drives examples/ble/heart_rate.toit (unchanged, on a controller-only
// board) through the `ble` package's public API on the Toit host: a
// Linux provider is installed in this process and Adapter falls back to it.
//
// Usage: toit.run compat-central.snapshot <adapter index> scan
//        toit.run compat-central.snapshot <adapter index> connect <identifier hex>
//
// Two invocations because bluetoothd (AutoEnable) powers the adapter back on
// as soon as a session's user channel closes; the runner powers it off again
// between the phases.

import ble show *
import encoding.hex
import ble.experimental.linux
import ble.experimental.transport
import ble.experimental.service.gatt-provider as gatt

SERVICE ::= BleUuid "1825"
SEND ::= BleUuid "634b3c6e-ac41-4085-a97c-dd687fa1e50d"
RECEIVE ::= BleUuid "634b3c6e-1c41-4085-a97c-dd687fa1e50d"

main args/List:
  provider := Provider (int.parse args[0])
  provider.install
  try:
    adapter := Adapter
    print "COMPAT adapter=$adapter.adapter-metadata.identifier"
    central := adapter.central
    if args[1] == "scan":
      found/RemoteScannedDevice? := null
      central.scan --duration=(Duration --s=10): | device/RemoteScannedDevice |
        if device.data.name == "Toit heart rate demo": found = device
      if not found: throw "COMPAT_PEER_NOT_FOUND"
      print "COMPAT found identifier=$(hex.encode (found.identifier as ByteArray)) rssi=$found.rssi"
      adapter.close
      return
    identifier := hex.decode args[2]
    device := central.connect identifier
    print "COMPAT connected mtu=$device.mtu"
    service := (device.discover-services [SERVICE])[0]
    characteristics := service.discover-characteristics
    send := characteristics.filter: it.uuid == SEND
    receive := characteristics.filter: it.uuid == RECEIVE
    if send.size != 1 or receive.size != 1: throw "COMPAT_CHARACTERISTICS $characteristics"
    send[0].subscribe
    3.repeat:
      value := send[0].wait-for-notification
      print "COMPAT notification $value"
    receive[0].write #[1, 2, 3]
    // A write without response is only handed to the stack; give the
    // controller a few connection events before the disconnect.
    sleep --ms=300
    send[0].unsubscribe
    device.close
    print "COMPAT COMPLETE notifications=3 written=3"
    adapter.close
  finally:
    provider.uninstall

class Provider extends gatt.Provider:
  index_/int
  constructor .index_: super
  early-acl-timeout -> Duration?: return Duration --ms=20

  open-transport -> transport.Transport: return linux.LinuxTransport index_
