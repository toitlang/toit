// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.advertising
import ble.experimental.att
import ble.experimental.central
import ble.experimental.gatt
import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.scanning
import ble.experimental.transport
import encoding.hex
import io
import system
import uuid

main args/List:
  if not 1 <= args.size <= 3: throw "Usage: hci-echo.toit <adapter index> [exchange count] [log every]"
  count := args.size >= 2 ? (int.parse args[1]) : 1000
  log-every := args.size == 3 ? (int.parse args[2]) : 1
  run (linux.LinuxTransport (int.parse args[0])) --count=count --log-every=log-every

run radio/transport.Transport --count/int=1000 --log-every/int=1
    --service-id/string="9f6c1000-8e2a-4b13-9e97-94f353eeb001"
    --peer-address/ByteArray?=null:
  if not 1 <= count <= 1_000_000 or not 1 <= log-every <= 10_000: throw "INVALID_ARGUMENT"
  if peer-address and peer-address.size != 6: throw "INVALID_ARGUMENT"
  selected-address := peer-address and peer-address.copy
  service-uuid := wire-uuid service-id
  controller := hci.Controller radio
  host/central.Central? := null
  client/att.Client? := null
  try:
    info := hci.initialize controller
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --early-acl-timeout=(Duration --ms=20)
    peer/advertising.Report? := null
    with-timeout --ms=10_000:
      scanning.scan controller --active: | report/advertising.Report |
        if selected-address and report.address != selected-address: continue.scan true
        if not (report.has-service service-uuid): continue.scan true
        peer = report
        false
    link := host.connect peer.address --address-type=peer.address-type
    client = att.Client host link
    service/gatt.Service := find-uuid (gatt.services client) service-uuid
    characteristics := gatt.characteristics client service
    input/gatt.Characteristic := find-uuid characteristics (wire-uuid "9f6c1001-8e2a-4b13-9e97-94f353eeb001")
    echo/gatt.Characteristic := find-uuid characteristics (wire-uuid "9f6c1002-8e2a-4b13-9e97-94f353eeb001")
    print "initial=$(hex.encode (client.read echo.handle)) input=$(input.handle) echo=$(echo.handle)"
    before := system.process-stats
    retained := []
    run-start := Time.monotonic-us
    run-start-awake := Time.monotonic-us --since-wakeup
    max-gc-us := 0
    max-gc-awake-us := 0
    last/ByteArray := #[]
    gatt.with-notifications client echo: | subscription/att.Subscription |
      count.repeat: | sequence/int |
        started := Time.monotonic-us
        expected := payload sequence
        client.write input.handle expected
        value := with-timeout --ms=3_000: subscription.receive
        if value != expected: throw "ECHO_MISMATCH sequence=$sequence data=$(hex.encode value)"
        last = value
        if sequence % 50 == 0 and retained.size < 20: retained.add [sequence, value]
        if (sequence + 1) % 10 == 0:
          gc-start := Time.monotonic-us
          gc-start-awake := Time.monotonic-us --since-wakeup
          system.process-stats --gc
          max-gc-us = max max-gc-us (Time.monotonic-us - gc-start)
          max-gc-awake-us = max max-gc-awake-us ((Time.monotonic-us --since-wakeup) - gc-start-awake)
          retained.do: | sample/List |
            if sample[1] != (payload sample[0]): throw "RETAINED_VALUE_CHANGED"
        if sequence % log-every == 0 or sequence == count - 1:
          print "ECHO sequence=$sequence data=$(hex.encode value) elapsed-us=$(Time.monotonic-us - run-start) elapsed-awake-us=$((Time.monotonic-us --since-wakeup) - run-start-awake) max-gc-call-us=$max-gc-us max-gc-awake-call-us=$max-gc-awake-us"
        remaining := 100_000 - (Time.monotonic-us - started)
        if remaining > 0: sleep (Duration --us=remaining)
      if subscription.dropped != 0: throw "ECHO_NOTIFICATION_OVERFLOW"
    if (client.read echo.handle) != last: throw "RETAINED_PEER_VALUE_MISMATCH"
    after := system.process-stats
    full-gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if full-gcs < count / 10: throw "GC_COUNT_DID_NOT_ADVANCE"
    print "ECHO_COMPLETE count=$count full-gcs=$full-gcs receive-high-water=$(link.receive-high-water) elapsed-us=$(Time.monotonic-us - run-start) elapsed-awake-us=$((Time.monotonic-us --since-wakeup) - run-start-awake) max-gc-call-us=$max-gc-us max-gc-awake-call-us=$max-gc-awake-us retained=$(retained.size)"
    print "process-stats=$after"
    host.disconnect link
  finally:
    if client: client.close
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed

wire-uuid value/string -> ByteArray:
  return (uuid.Uuid.parse value).to-byte-array.reverse

find-uuid entries/List target/ByteArray:
  entries.do:
    if it.uuid == target: return it
  throw "GATT_UUID_NOT_FOUND $(hex.encode target.reverse)"

payload sequence/int -> ByteArray:
  result := ByteArray 11
  io.LITTLE-ENDIAN.put-uint32 result 0 sequence
  result.replace 4 #[0x54, 0x6f, 0x69, 0x74, 0x48, 0x43, 0x49]
  return result
