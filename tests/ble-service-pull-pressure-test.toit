// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.service.client as clients
import expect show *
import system
import .ble-service-requests-test as fixture

REPORT ::= 1000

main:
  failures := 0
  successes := 0
  with-timeout --ms=30_000:
    64.repeat: | trial/int |
      provider := Provider
      provider.install
      try:
        spawn:: run-client trial
        provider.uninstall --wait
        expect provider.reported
        expect provider.closed
        if provider.error: failures++
        else: successes++
      finally:
        provider.uninstall
    if failures == 0 or successes == 0: throw "PRESSURE_BOUNDARY_NOT_COVERED"
    print "SERVICE_PULL_PRESSURE COMPLETE failures=$failures successes=$successes"

run-client trial/int:
  slots := List 16384
  client := Client
  client.open
  try:
    session := client.session
    set-max-heap-size_ (256 * 1024)
    filled := 0
    failure := catch:
      while filled < slots.size:
        slots[filled] = ByteArray 8 --initial=42
        filled++
    if failure != "ALLOCATION_FAILED" and failure != "OUT_OF_MEMORY":
      throw "PRESSURE_NOT_REACHED"
    (trial * 16).repeat: slots[filled - 1 - it] = null
    request/clients.Request? := null
    error := catch: request = session.next
    slots.fill null
    system.process-stats --gc
    if error and error != "ALLOCATION_FAILED" and error != "OUT_OF_MEMORY": throw error
    if not error:
      expect-equals 3 request.handle
      request.reply #[7, 8]
    // A failed pull has uncertain remote delivery. Close instead of retrying it.
    session.close
    client.report error
  finally:
    slots.fill null
    client.close

class Client extends clients.Client:
  constructor: super
  report error -> none: invoke_ REPORT error

class Provider extends fixture.TestProvider:
  reported/bool := false
  error := null

  constructor: super

  handle index/int arguments/any --gid/int --client/int -> any:
    if index != REPORT: return super index arguments --gid=gid --client=client
    // Check before client disconnect/process exit could clean up on its behalf.
    expect closed
    error = arguments
    reported = true
    return null
