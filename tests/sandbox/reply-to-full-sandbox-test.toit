// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that the messages queued at a sandboxed process are bounded by the
  sandbox heap floor, and that a reply that its mailbox refuses fails the
  sandbox's call instead of leaving it waiting.

A sandboxed client calls a trusted provider and then doesn't process its
  messages for 1.5 s (it spins). Meanwhile the provider sends it user
  messages until a send fails, then replies.
- Without the floor, the client's mailbox (quota of 4 messages per sender:
  16 in total) is full after 16 messages; the reply is refused. Before, it
  was dropped: the call waited until its deadline (DEADLINE_EXCEEDED).
  Now the client gets an error reply and the call fails with
  QUOTA_EXCEEDED; its next call works.
- With the floor (simulated system heap of 600 KB, 400 KB floor), the
  messages (10 KB each) stop at the floor, long before the quotas (here 256
  messages, 4 MB on the host). Before, the floor didn't apply to messages: the
  provider could queue 100 (its limit here, 1 MB) at the client.
*/

import expect show *
import .sandbox-util show *

PROGRAM ::= """
import monitor
import system.containers
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient

interface TestService:
  static SELECTOR ::= ServiceSelector
      --uuid="9b7e2d14-58c3-4f6a-a1d0-7c3e5b2f8e91"
      --major=1
      --minor=0
  call pid/int limit/int size/int -> ByteArray
  static CALL-INDEX ::= 0

class TestClient extends ServiceClient implements TestService:
  static SELECTOR ::= TestService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    super selector
  call pid/int limit/int size/int -> ByteArray:
    return invoke_ TestService.CALL-INDEX [pid, limit, size]

class TestProvider extends ServiceProvider implements ServiceHandler:
  constructor:
    super "test/reply" --major=1 --minor=0
    provides TestService.SELECTOR --handler=this
  accepts-untrusted-clients -> bool:
    return true
  handle index/int arguments/any --gid/int --client/int -> any:
    pid/int := arguments[0]
    limit/int := arguments[1]
    size/int := arguments[2]
    sent := 0
    while sent < limit:
      if not process-send_ pid 100 (ByteArray size): break
      sent++
    if limit > 0: print "fill: \$sent"
    // The reply is a little larger than each message.
    return ByteArray size

main args:
  if args is Map:
    client args["size"]
    return
  provider := TestProvider
  provider.install
  size := int.parse args[0]
  messages := int.parse args[1]
  container := containers.start containers.current {"size": size}
      --untrusted
      --quotas={"mailbox-messages": messages}
  container.wait
  provider.uninstall

client size/int -> none:
  service := TestClient
  service.open
  pid := Process.current.id
  done := monitor.Latch
  task::
    exception := catch:
      with-timeout --ms=4_000:
        done.set (service.call pid 100 size).size
    if exception: done.set exception
  // Let the task send the request, then don't process messages for a while.
  yield
  deadline := Time.monotonic-us + 1_500_000
  while Time.monotonic-us < deadline: null
  print "call: \$done.get"
  print "next call: \$((service.call pid 0 0).size)"
"""

main args:
  toit-run := args[0]
  with-tmp-directory: | dir |
    source := "$dir/reply-to-full-sandbox-main.toit"
    write-file source PROGRAM

    // The quota: 16 small messages fill the client's mailbox.
    output := run toit-run source [] "16" "4"
    expect-equals ["fill: 16", "call: QUOTA_EXCEEDED", "next call: 0"] (outcomes output)

    // The floor: 10 KB messages stop at the floor (the quota would take 256).
    output = run toit-run source ["-Xsandbox_heap_floor=400000", "-Xsandbox_system_heap=600000"] "10000" "64"
    results := outcomes output
    expect-equals 3 results.size
    fill := int.parse results[0][6..]
    expect fill < 20
    expect-equals ["call: QUOTA_EXCEEDED", "next call: 0"] results[1..]
  print "reply-to-full-sandbox-test OK"

run toit-run/string source/string flags/List size/string messages/string -> string:
  result := run-process [toit-run] + flags + [source, size, messages] --timeout-ms=60_000
  print result.output
  expect-equals 0 result.exit-code
  return result.output

outcomes output/string -> List:
  result := []
  output.split "\n": | line/string |
    if line.starts-with "fill: " or line.starts-with "call: " or line.starts-with "next call: ":
      result.add line
  return result
