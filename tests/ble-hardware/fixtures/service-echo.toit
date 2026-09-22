// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.service.client as service
import encoding.hex
import system
import monitor

import .hci-echo as fixture

main: run 1000

run expected-count/int --log-every/int=1 --probe-rejection/bool=false --probe-deadline/bool=false --probe-exception/bool=false --probe-cancel/bool=false --probe-client-death/bool=false:
  if (probe-exception ? 1 : 0) + (probe-cancel ? 1 : 0) + (probe-client-death ? 1 : 0) > 1: throw "INVALID_ARGUMENT"
  if not 1 <= expected-count <= 1_000_000 or not 1 <= log-every <= 10_000: throw "INVALID_ARGUMENT"
  client := service.Client
  client.open --timeout=(Duration --s=5)
  try:
    session := client.configure --name="Toit HCI"
    uuid := fixture.wire-uuid "9f6c1000-8e2a-4b13-9e97-94f353eeb001"
    session.add-service uuid
    input := session.add-characteristic (fixture.wire-uuid "9f6c1001-8e2a-4b13-9e97-94f353eeb001")
        --write
        --validate-write
    echo := session.add-characteristic (fixture.wire-uuid "9f6c1002-8e2a-4b13-9e97-94f353eeb001")
        --read
        --notify
        --dynamic-read
        --value=#[0x70, 0x17]
    advertisement := ByteArray 21
    advertisement.replace 0 #[2, 1, 6, 17, 7]
    advertisement.replace 5 uuid
    session.start advertisement
    peer := session.peer
    print "BLE_SERVICE_APP CONNECTED address=$(hex.encode peer[0]) type=$(peer[1])"
    count := 0
    reads := 0
    validated := 0
    rejected := 0
    expired := 0
    retained := []
    run-start := Time.monotonic-us
    run-start-awake := Time.monotonic-us --since-wakeup
    max-gc-us := 0
    max-gc-awake-us := 0
    before := system.process-stats
    saved/service.Request? := null
    serving-error := null
    cancel-ready := monitor.Latch
    ended := monitor.Latch
    handler-ended := false
    worker := task::
      try:
        serving-error = catch:
          session.serve
              (: | request/service.Request |
                if request.handle != echo:
                  request.reject 0x0e
                else:
                  if probe-client-death and count == expected-count:
                    try:
                      task::
                        print "BLE_SERVICE_APP TERMINATING reason=BLE_FIXTURE_CLIENT_DIED"
                        throw "BLE_FIXTURE_CLIENT_DIED"
                      sleep --ms=10_000
                      throw "CLIENT_DID_NOT_TERMINATE"
                    finally:
                      print "BLE_SERVICE_APP UNEXPECTED_HANDLER_FINALLY"
                  if probe-cancel and count == expected-count:
                    saved = request
                    reads++
                    try:
                      cancel-ready.set true
                      sleep --ms=10_000
                      throw "CANCEL_NOT_DELIVERED"
                    finally:
                      handler-ended = true
                  if probe-exception and count == expected-count:
                    saved = request
                    reads++
                    throw "BLE_FIXTURE_HANDLER_FAILED"
                  if probe-deadline and reads == 0:
                    sleep (Duration --us=(request.deadline - Time.monotonic-us + 100_000))
                    error := catch: request.reply #[0xff]
                    if error != "GATT_REQUEST_EXPIRED": throw "LATE_REPLY_ACCEPTED: $error"
                    expired++
                    reads++
                    print "BLE_SERVICE_APP EXPIRED late-reply-rejected=true"
                  else:
                    if probe-rejection and rejected == 1 and count == 0:
                      if not (session.value input).is-empty: throw "REJECTED_WRITE_COMMITTED"
                    if reads == 0: sleep --ms=250
                    reads++
                    request.reply (session.value echo))
              (: | request/service.Request |
                if request.handle != input or request.value != (fixture.payload count):
                  request.reject 0x13
                  rejected++
                  print "BLE_SERVICE_APP REJECTED error=0x13"
                else:
                  validated++
                  request.accept)
              (: | handle/int value/ByteArray |
                if handle == input:
                  session.set-value echo value
                  if not (session.notify echo): throw "ECHO_PEER_NOT_SUBSCRIBED"
                  count++
                  if count % 50 == 1 and retained.size < 20: retained.add [count - 1, value]
                  if count % 10 == 0:
                    gc-start := Time.monotonic-us
                    gc-start-awake := Time.monotonic-us --since-wakeup
                    system.process-stats --gc
                    max-gc-us = max max-gc-us (Time.monotonic-us - gc-start)
                    max-gc-awake-us = max max-gc-awake-us ((Time.monotonic-us --since-wakeup) - gc-start-awake)
                    retained.do: | sample/List |
                      if sample[1] != (fixture.payload sample[0]): throw "RETAINED_VALUE_CHANGED"
                  if (count - 1) % log-every == 0 or count == expected-count:
                    print "BLE_SERVICE_APP ECHO count=$count data=$(hex.encode value) elapsed-us=$(Time.monotonic-us - run-start) elapsed-awake-us=$((Time.monotonic-us --since-wakeup) - run-start-awake) max-gc-call-us=$max-gc-us max-gc-awake-call-us=$max-gc-awake-us")
      finally:
        critical-do --no-respect-deadline: ended.set true
    try:
      if probe-cancel:
        with-timeout --ms=75_000: cancel-ready.get
        worker.cancel
        with-timeout --ms=1_000: ended.get
      else:
        ended.get
    finally:
      worker.cancel
    if probe-cancel:
      if not handler-ended or not session.is-closed or not saved:
        throw "CANCELLATION_CLEANUP_INCOMPLETE"
      late-error := catch: saved.reply #[0xff]
      if late-error != "GATT_REQUEST_EXPIRED": throw "LATE_REPLY_ACCEPTED: $late-error"
      replacement := client.configure
      replacement.close
      print "BLE_SERVICE_APP CANCELED closed=true late-reply-rejected=true slot-reused=true"
    else if probe-exception:
      if serving-error != "BLE_FIXTURE_HANDLER_FAILED" or not session.is-closed or not saved:
        throw "HANDLER_EXCEPTION_NOT_PROPAGATED: $serving-error"
      late-error := catch: saved.reply #[0xff]
      if late-error != "GATT_REQUEST_EXPIRED": throw "LATE_REPLY_ACCEPTED: $late-error"
      replacement := client.configure
      replacement.close
      print "BLE_SERVICE_APP EXCEPTION closed=true late-reply-rejected=true slot-reused=true"
    else if serving-error:
      throw serving-error
    after := system.process-stats
    full-gcs := after[system.STATS-INDEX-FULL-GC-COUNT] - before[system.STATS-INDEX-FULL-GC-COUNT]
    if count != expected-count or validated != count or reads < 2 or full-gcs < expected-count / 10:
      throw "SERVICE_ECHO_INCOMPLETE"
    if probe-rejection and rejected != 1: throw "REJECTION_PROBE_INCOMPLETE"
    if probe-deadline and expired != 1: throw "DEADLINE_PROBE_INCOMPLETE"
    if reads != 2 + (probe-rejection ? 1 : 0) + (probe-deadline ? 1 : 0):
      throw "READ_PROBE_INCOMPLETE"
    print "BLE_SERVICE_APP COMPLETE count=$count reads=$reads validated=$validated full-gcs=$full-gcs retained=$(retained.size) elapsed-us=$(Time.monotonic-us - run-start) elapsed-awake-us=$((Time.monotonic-us --since-wakeup) - run-start-awake) max-gc-call-us=$max-gc-us max-gc-awake-call-us=$max-gc-awake-us"
    print "BLE_SERVICE_APP process-stats=$after"
  finally:
    client.close
