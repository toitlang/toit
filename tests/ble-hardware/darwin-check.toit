// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The macOS backend on a Mac: scans, connects to a peripheral (the one
// whose identifier is given, else the first connectable one with a name),
// discovers and reads its database, then serves a small database itself
// for a while. Run with `toit run tests/ble-hardware/darwin-check.toit
// [identifier]` on a Mac; every step prints a DARWIN_CHECK line.

import ble.v2 as ble
import ble.v2.darwin as darwin
import encoding.hex

main args/List:
  adapter := darwin.open
  try:
    wanted/ble.Peer? := args.is-empty ? null : (ble.PlatformPeer (hex.decode (args[0].replace --all "-" "")))
    print "DARWIN_CHECK adapter capabilities central=$adapter.capabilities.central peripheral=$adapter.capabilities.peripheral"
    found/ble.ScanReport? := adapter.find --duration=(Duration --s=8): | report/ble.ScanReport |
      print "DARWIN_CHECK report $report services=$report.advertisement.services"
      wanted ? report.peer == wanted : (report.name != null and report.is-connectable == true)
    if not found: throw "DARWIN_CHECK no peripheral found"
    print "DARWIN_CHECK connecting to $found"
    adapter.with-connection found.peer --timeout=(Duration --s=15): | connection/ble.Connection |
      print "DARWIN_CHECK connected mtu=$connection.mtu"
      connection.discover-services.do: | service/ble.RemoteService |
        print "DARWIN_CHECK service $service.uuid"
        service.discover-characteristics.do: | characteristic/ble.RemoteCharacteristic |
          line := "DARWIN_CHECK   characteristic $characteristic.uuid properties=$characteristic.properties"
          if characteristic.can-read:
            error := catch: line += " value=$characteristic.read"
            if error: line += " read failed: $error"
          print line
    print "DARWIN_CHECK disconnected"
    server := ble.GattServer
    service := server.add-service (ble.BleUuid "fff0")
    counter := service.add-characteristic (ble.BleUuid "fff1") --read --notify --value=#[0]
    service.add-characteristic (ble.BleUuid "fff2") --write --on-write=:: | connection/ble.Connection value/ByteArray |
      print "DARWIN_CHECK written $value"
    peripheral := adapter.peripheral server --advertisement=(ble.Advertisement --name="Toit Mac" --services=[ble.BleUuid "fff0"])
    connection := peripheral.accept
    print "DARWIN_CHECK serving as $connection.peer for 30 s; connect with a phone and read or subscribe to fff1"
    30.repeat: | second/int |
      counter.notify #[second]
      sleep --ms=1000
    peripheral.close
    print "DARWIN_CHECK COMPLETE"
  finally:
    adapter.close
