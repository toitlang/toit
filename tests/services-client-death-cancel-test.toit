// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system.services

SELECTOR ::= services.ServiceSelector
    --uuid="5b1c7a52-9c44-4a07-8f0f-eb6f1f7a1e02"
    --major=0
    --minor=1

class Client extends services.ServiceClient:
  constructor: super SELECTOR
  block -> none: invoke_ 0 null

class Provider extends services.ServiceProvider implements services.ServiceHandler:
  canceled/monitor.Latch ::= monitor.Latch

  constructor:
    super "test/client-death-cancel" --major=0 --minor=1
    provides SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    try:
      // Nothing ever sets this latch, so only a cancelation can wake us up.
      (monitor.Latch).get
    finally:
      // Setting a latch is a monitor operation, which would throw in a canceled
      // task outside a critical region.
      critical-do: canceled.set Task.current.is-canceled
    return null

client-main -> none:
  client := (Client).open as Client
  // Exit while the main task is blocked in the call. The delay gives the
  // handler time to block, and lets the provider's message processing task
  // (idle time of 100ms) terminate, so no other task wakes up after the handler.
  task::
    sleep --ms=200
    exit 0
  client.block

/**
Tests that the service provider cancels a blocked handler when the client
  process terminates.

The main task blocks here before the handler can start, because the handler only
  starts when the provider processes messages, and that doesn't happen until the
  main task blocks. If no other task wakes up, the handler is the last task to
  block, and the process runs its message loop on the handler's stack, in a
  critical region. The termination message is handled on another task while that
  critical region is open, so the cancelation must wake up the handler even though
  its critical count is non-zero.

This relies on no other task waking up after the handler. If one does, the test
  passes without exercising this case.
*/
main:
  provider := Provider
  provider.install
  spawn:: client-main
  // If the cancelation is lost, nothing wakes up the handler and this times out.
  expect (with-timeout --ms=5_000: provider.canceled.get)
  provider.uninstall
