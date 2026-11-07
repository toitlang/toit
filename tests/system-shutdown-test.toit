// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system.services

import ..system.shutdown

SELECTOR ::= services.ServiceSelector
    --uuid="84a47646-238c-45ba-8a47-dac517b0185a"
    --major=1
    --minor=0

main:
  test-canceled-request
  test-failed-cleanup
  ["resource", "client", "release"].do: test-pending-close it
  test-canceled-handler

test-canceled-handler:
  reset := monitor.Latch
  coordinator := ShutdownCoordinator:: null
  provider := TestProvider "shutdown/canceled" [] coordinator reset
  coordinator.install provider
  client := TestClient provider.name
  client.open
  started := monitor.Latch
  cleaning := monitor.Latch
  continue-cleanup := monitor.Latch
  cleaned := monitor.Latch
  provider.work-action = (::
    try:
      started.set true
      sleep --ms=10_000
    finally:
      critical-do:
        cleaning.set true
        continue-cleanup.get
        cleaned.set true)
  request := task:: client.work
  with-timeout --ms=1000: started.get
  request.cancel
  with-timeout --ms=1000: cleaning.get
  task:: coordinator.reboot:: reset.set true
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=20: reset.get
  expect-throw "Service is shutting down": (TestClient provider.name).open
  continue-cleanup.set true
  with-timeout --ms=1000: reset.get
  expect cleaned.has-value
  client.close

test-pending-close kind/string:
  events := []
  reset := monitor.Latch
  coordinator := ShutdownCoordinator:: null
  provider := TestProvider "shutdown/closing" events coordinator reset
  coordinator.install provider
  client := TestClient provider.name
  client.open
  client.acquire
  closing := monitor.Latch
  continue-close := monitor.Latch
  action := (::
    closing.set true
    continue-close.get)
  if kind == "client":
    provider.client-close-action = action
  else:
    provider.close-action = action
  closed := monitor.Latch
  task::
    if kind == "release": client.release
    else: client.close
    closed.set true
  with-timeout --ms=1000: closing.get
  task:: coordinator.reboot:: reset.set true
  // The resource already unregistered itself, but its cleanup is pending.
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=20: reset.get
  continue-close.set true
  with-timeout --ms=1000: reset.get
  with-timeout --ms=1000: closed.get
  expect-equals 1 provider.closed
  client.close

test-canceled-request:
  events := []
  stopping := monitor.Latch
  continue-stop := monitor.Latch
  reset := monitor.Latch
  coordinator := ShutdownCoordinator::
    events.add "stop"
    stopping.set true
    continue-stop.get
    events.add "stopped"
  a := TestProvider "shutdown/a" events coordinator reset
  b := TestProvider "shutdown/b" events coordinator reset
  coordinator.install a
  coordinator.install b
  client-a := TestClient a.name
  client-b := TestClient b.name
  client-a.open
  client-b.open
  client-a.acquire
  client-b.acquire
  request := task:: client-a.reboot
  with-timeout --ms=1000: stopping.get
  // This cancels the actual service RPC handler while shutdown is waiting.
  request.cancel
  with-timeout --ms=1000: a.request-ended.get
  expect-equals ["stop"] events
  expect-throw "System is shutting down": coordinator.reboot:: unreachable
  continue-stop.set true
  with-timeout --ms=1000: reset.get
  expect-equals ["stop", "stopped", "shutdown/b", "shutdown/a", "reset"] events
  expect-equals 1 a.closed
  expect-equals 1 b.closed
  client-b.close
  client-a.close

test-failed-cleanup:
  events := []
  reset := monitor.Latch
  coordinator := ShutdownCoordinator --phase-timeout=(Duration --ms=20)::
    // A cooperative hang must not prevent service cleanup and reset.
    sleep --ms=10_000
    unreachable
  a := TestProvider "shutdown/a" events coordinator reset
  broken := BrokenProvider "shutdown/broken" events coordinator reset
  coordinator.install a
  coordinator.install broken
  client := TestClient a.name
  client.open
  client.acquire
  coordinator.reboot::
    expect-equals ["shutdown/a"] events
    expect-equals 1 a.closed
    reset.set true
  expect reset.has-value
  broken.really-uninstall
  client.close

class TestClient extends services.ServiceClient:
  constructor name/string:
    super (SELECTOR.restrict.allow --name=name)

  acquire -> none: invoke_ 0 null
  reboot -> none: invoke_ 1 null
  release -> none: invoke_ 2 null
  work -> none: invoke_ 3 null

class TestProvider extends services.ServiceProvider implements services.ServiceHandler:
  events/List
  coordinator/ShutdownCoordinator
  reset/monitor.Latch
  request-ended := monitor.Latch
  closed/int := 0
  close-action/Lambda? := null
  client-close-action/Lambda? := null
  work-action/Lambda? := null

  constructor name/string .events .coordinator .reset:
    super name --major=1 --minor=0
    provides SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == 0:
      TestResource this client
      return null
    if index == 1:
      try:
        coordinator.reboot::
          events.add "reset"
          reset.set true
      finally:
        critical-do: request-ended.set true
      return null
    if index == 2:
      resources-do: it.close
      return null
    if index == 3:
      work-action.call
      return null
    unreachable

  on-closed client/int -> none:
    if client-close-action: client-close-action.call

class TestResource extends services.ServiceResource:
  provider/TestProvider

  constructor .provider client/int:
    super provider client

  on-closed -> none:
    if provider.close-action: provider.close-action.call
    provider.closed++
    provider.events.add provider.name

class BrokenProvider extends TestProvider:
  fail-close/bool := true
  constructor name/string events/List coordinator/ShutdownCoordinator reset/monitor.Latch:
    super name events coordinator reset

  uninstall --wait/bool=false --drain/bool=false -> none:
    if fail-close: throw "TEST_CLOSE_FAILURE"
    super --wait=wait --drain=drain

  really-uninstall -> none:
    fail-close = false
    uninstall
