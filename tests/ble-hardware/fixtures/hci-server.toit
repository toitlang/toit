// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.attribute-server as attributes
import ble.experimental.central
import ble.experimental.gatt-server
import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.transport
import encoding.hex
import system

import .hci-echo as fixture

main args/List:
  if not 1 <= args.size <= 2: throw "Usage: hci-server.toit <adapter index> [static]"
  if args.size == 2 and args[1] != "static": throw "INVALID_ARGUMENT"
  dynamic := args.size == 1
  run (linux.LinuxTransport (int.parse args[0])) --dynamic=dynamic
      --early-acl-timeout=(Duration --ms=20)

run radio/transport.Transport --dynamic/bool=true --early-acl-timeout/Duration?=null --sequence-base/int=0
    --service-id/string="9f6c1000-8e2a-4b13-9e97-94f353eeb001" --isolation-delay-ms/int=0
    --cycles/int=1 --expected-count/int?=null --receive-acl-packets/int=0 --report-address/bool=false
    --numbered-cycles/bool=false --warmup/int=0
    --handler-timeout/Duration=(Duration --s=1):
  if not 1 <= cycles <= 10_000: throw "INVALID_ARGUMENT"
  if not 0 <= warmup <= 100 or (warmup > 0 and not numbered-cycles): throw "INVALID_ARGUMENT"
  if numbered-cycles and not expected-count: throw "INVALID_ARGUMENT"
  if expected-count != null and expected-count < 1: throw "INVALID_ARGUMENT"
  if not 0 <= sequence-base <= 0xffff_ffff: throw "INVALID_ARGUMENT"
  if numbered-cycles and sequence-base + (cycles + warmup) * expected-count > 0x1_0000_0000:
    throw "INVALID_ARGUMENT"
  if not 0 <= isolation-delay-ms <= 5_000 or (isolation-delay-ms > 0 and not dynamic):
    throw "INVALID_ARGUMENT"
  database := attributes.Database.with-defaults --name="Toit HCI"
  uuid := fixture.wire-uuid service-id
  database.add-service uuid
  input := database.add-characteristic (fixture.wire-uuid "9f6c1001-8e2a-4b13-9e97-94f353eeb001")
      --write
      --validate-write=dynamic
  echo := database.add-characteristic (fixture.wire-uuid "9f6c1002-8e2a-4b13-9e97-94f353eeb001")
      --read
      --notify
      --dynamic-read=dynamic
      --value=#[0x70, 0x17]
  advertisement := ByteArray 21
  advertisement.replace 0 #[2, 1, 6, 17, 7]
  advertisement.replace 5 uuid
  controller := hci.Controller radio
  host/central.Central? := null
  try:
    info := hci.initialize controller --receive-acl-packets=receive-acl-packets
    if report-address: print "GATT_SERVER ADDRESS public=$(hex.encode info.address.reverse)"
    host = central.Central controller --acl-length=info.acl-length --acl-count=info.acl-count
        --early-acl-timeout=early-acl-timeout
    total := 0
    baseline/int? := null
    maximum := 0
    (cycles + warmup).repeat: | cycle/int |
      cycle-base := numbered-cycles ? sequence-base + cycle * expected-count : sequence-base
      database.set-value echo #[0x70, 0x17]
      print "GATT_SERVER READY input=$input echo=$echo"
      link := host.accept advertisement --timeout=(Duration --s=60)
      server := gatt-server.Server host link database --handler-timeout=handler-timeout
      print "GATT_SERVER CONNECTED interval=$(link.info.interval)"
      server.request-parameters --interval=12
      count := 0
      before := system.process-stats
      retained := []
      reads := 0
      validated := 0
      waiting := false
      heartbeats := 0
      hci-during-read := 0
      heartbeat := task --background::
        while true:
          sleep --ms=25
          if waiting:
            heartbeats++
            if hci-during-read == 0:
              // Prove command completion can be processed while the read yields.
              address := controller.command hci.READ-ADDRESS
              if address.size != 6: throw "INVALID_CONTROLLER_ADDRESS"
              if waiting: hci-during-read++
      try:
        server.serve-with-requests
            (: | request/attributes.ReadRequest |
              if request.handle != echo:
                request.reject 0x0e
              else:
                if reads == 0:
                  waiting = true
                  try:
                    sleep --ms=250
                  finally:
                    waiting = false
                  if heartbeats == 0 or hci-during-read == 0: throw "HANDLER_BLOCKED_PROGRESS"
                if reads == 1 and isolation-delay-ms > 0:
                  // Tell the subscribed test client the handler has entered its
                  // delay, so another link's progress is measured in that window.
                  if not (server.notify echo): throw "DELAY_PEER_NOT_SUBSCRIBED"
                  print "GATT_SERVER DELAY_BEGIN ms=$isolation-delay-ms"
                  sleep --ms=isolation-delay-ms
                  print "GATT_SERVER DELAY_END"
                reads++
                request.reply (database.value echo))
            (: | request/attributes.WriteRequest |
              if request.handle != input or request.value != (fixture.payload (cycle-base + count)):
                request.reject 0x13
              else:
                validated++
                request.accept)
            (: | handle/int value/ByteArray |
              if handle == input:
                database.set-value echo value
                if not (server.notify echo): throw "ECHO_PEER_NOT_SUBSCRIBED"
                count++
                if count % 50 == 1: retained.add [cycle-base + count - 1, value]
                if count % 10 == 0:
                  system.process-stats --gc
                  retained.do: | sample/List |
                    if sample[1] != (fixture.payload sample[0]): throw "RETAINED_VALUE_CHANGED"
                print "GATT_SERVER ECHO count=$count data=$(hex.encode value)")
      finally:
        heartbeat.cancel
      if dynamic and (reads < 2 or validated != count): throw "DYNAMIC_HANDLER_COUNT_MISMATCH"
      print "GATT_SERVER HANDLERS reads=$reads validated=$validated heartbeats=$heartbeats hci-during-read=$hci-during-read"
      after := system.process-stats
      full-gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
      if full-gcs < count / 10: throw "GC_COUNT_DID_NOT_ADVANCE"
      print "GATT_SERVER COMPLETE count=$count full-gcs=$full-gcs retained=$(retained.size)"
      print "process-stats=$after"
      print "parameter-request=$(server.parameter-status)"
      if expected-count != null and count != expected-count: throw "RECONNECT_COUNT_MISMATCH"
      total += count
      if numbered-cycles:
        stats := system.process-stats --gc
        live := stats[system.STATS-INDEX-ALLOCATED-MEMORY]
        if cycle == (max 0 (warmup - 1)): baseline = live
        if cycle >= warmup:
          maximum = max maximum live
          if live > baseline + 4096: throw "RECONNECT_MEMORY_GREW"
        print "VHCI_RECONNECT cycle=$cycle allocated=$live free=$(stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY]) largest=$(stats[system.STATS-INDEX-SYSTEM-LARGEST-FREE]) compacting-gcs=$(stats[system.STATS-INDEX-FULL-COMPACTING-GC-COUNT])"
      else if cycles > 1:
        stats := system.process-stats --gc
        print "VHCI_RECONNECT cycle=$cycle allocated=$(stats[system.STATS-INDEX-ALLOCATED-MEMORY]) persistent=true"
    if numbered-cycles:
      print "VHCI_RECONNECT COMPLETE cycles=$cycles warmup=$warmup baseline=$baseline maximum=$maximum"
    else if cycles > 1:
      print "VHCI_RECONNECT COMPLETE cycles=$cycles persistent=true"
    return total
  finally:
    if host:
      host.close
      host.wait-closed
    else:
      controller.close
      controller.wait-closed
