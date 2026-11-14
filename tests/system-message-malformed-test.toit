// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
import system.services

/**
Malformed RPC and trace messages don't kill the receiver.

Any process can send the RPC message types to any other process, and trace
  messages to the system process. The handlers of these messages run in
  whatever task of the receiver processes its messages, so an exception in
  a handler killed that task and with it the receiver: a single malformed
  SYSTEM-RPC-REQUEST_ or SYSTEM-TRACE_ took down the system process (and
  with it the VM), or a service provider. The receivers now drop malformed
  messages.
*/

SELECTOR ::= services.ServiceSelector
    --uuid="6f0f6d3e-5f0e-4d0c-9a51-3c2f0a8d7b14"
    --major=0
    --minor=1

PAYLOADS ::= [
  null, 42, "string", #[1, 2, 3], [], [1], ["id", 0, null], [1, "name", null],
  [1.5, 0, null], [1, 0], [[1], [2], [3]],
]

TYPES ::= [
  SYSTEM-RPC-REQUEST_,
  SYSTEM-RPC-REPLY_,
  SYSTEM-RPC-CANCEL_,
]

class PingClient extends services.ServiceClient:
  static PING-INDEX ::= 0
  static DONE-INDEX ::= 1

  constructor: super SELECTOR
  ping value/int -> int: return invoke_ PING-INDEX value
  done -> none: invoke_ DONE-INDEX null

class PingProvider extends services.ServiceProvider implements services.ServiceHandler:
  done/monitor.Latch ::= monitor.Latch

  constructor:
    super "test/system-message-malformed" --major=0 --minor=1
    provides SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == PingClient.PING-INDEX: return arguments + 1
    if index == PingClient.DONE-INDEX:
      done.set true
      return null
    unreachable

main:
  provider := PingProvider
  provider.install
  target := Process.current.id
  spawn:: attack target
  // If a malformed message kills this process or the system process, the
  // test fails without reaching the end.
  with-timeout --ms=10_000: provider.done.get
  provider.uninstall --wait

attack provider-pid/int -> none:
  client := PingClient
  client.open
  expect-equals 8 (client.ping 7)
  PAYLOADS.do: | payload |
    process-send_ SYSTEM-PROCESS-ID_ SYSTEM-TRACE_ payload
    TYPES.do: | type |
      process-send_ SYSTEM-PROCESS-ID_ type payload
      process-send_ provider-pid type payload
  // Messages from one process to another are delivered in order, so the
  // requests below are handled after the malformed messages. Opening a
  // client goes through the system process.
  other := PingClient
  other.open
  expect-equals 43 (other.ping 42)
  other.close
  expect-equals 100 (client.ping 99)
  client.done
  client.close
