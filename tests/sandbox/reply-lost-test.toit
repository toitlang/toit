// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that a sandbox whose RPC reply is lost is ended instead of waiting
  forever.

A reply that a sandbox's mailbox refuses (its quotas, or the memory floor)
  is replaced by an error reply, within a small allowance (8 error replies
  beyond the quotas, reply-to-full-sandbox-test.toit). Beyond the allowance
  the reply was dropped: the call waited forever (a sandboxed worker waited
  98 minutes in a device run, holding its memory). Now the VM ends the
  sandbox with exit code 244 (containers.EXIT-REPLY-LOST); its trusted owner
  sees the exit code and can restart it.

Here a sandboxed client calls a trusted provider and doesn't process its
  messages for a while. The provider fills the client's mailbox (16
  messages), sends it 9 replies the mailbox refuses (8 get error replies,
  the 9th is lost), then its real reply. Before: the client got the error
  replies, its call failed after its 3 s timeout and it ended with 0. Now:
  it is ended with 244.
*/

import expect show *
import .sandbox-util show *

PROGRAM ::= """
import monitor
import system.containers
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient

interface TestService:
  static SELECTOR ::= ServiceSelector
      --uuid="5c1e2f0a-7d3b-4e9a-8f21-6b4d0c9e3a17"
      --major=1
      --minor=0
  call pid/int -> int
  static CALL-INDEX ::= 0

class TestClient extends ServiceClient implements TestService:
  static SELECTOR ::= TestService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    super selector
  call pid/int -> int:
    return invoke_ TestService.CALL-INDEX pid

class TestProvider extends ServiceProvider implements ServiceHandler:
  constructor:
    super "test/reply-lost" --major=1 --minor=0
    provides TestService.SELECTOR --handler=this
  accepts-untrusted-clients -> bool:
    return true
  handle index/int arguments/any --gid/int --client/int -> any:
    pid/int := arguments
    sent := 0
    while process-send_ pid 100 #[1, 2, 3]: sent++
    print "fill: \$sent"
    // Replies (type 4) to calls the client didn't make: the full mailbox
    // refuses them.
    refused := 0
    9.repeat:
      if not process-send_ pid 4 [1_000 + it, false, null]: refused++
    print "refused replies: \$refused"
    return 42

main args:
  if args is Map:
    client
    return
  provider := TestProvider
  provider.install
  container := containers.start containers.current {"role": "client"}
      --untrusted
      --services=[TestService.SELECTOR.uuid]
      --quotas={"mailbox-messages": 4}
  print "exit: \$container.wait"
  provider.uninstall

client -> none:
  service := TestClient
  service.open
  pid := Process.current.id
  done := monitor.Latch
  task::
    exception := catch:
      with-timeout --ms=3_000:
        done.set (service.call pid)
    if exception: done.set exception
  // Let the task send the request, then don't process messages for a while.
  yield
  deadline := Time.monotonic-us + 1_500_000
  while Time.monotonic-us < deadline: null
  print "call: \$done.get"
"""

main args:
  toit-run := args[0]
  with-tmp-directory: | dir |
    source := "$dir/reply-lost-main.toit"
    write-file source PROGRAM
    result := run-process [toit-run, source] --timeout-ms=60_000
    print result.output
    expect-equals 0 result.exit-code
    lines := []
    result.output.split "\n": | line/string |
      if line.starts-with "fill: " or line.starts-with "refused replies: "
          or line.starts-with "call: " or line.starts-with "exit: ":
        lines.add line
    expect-equals ["fill: 16", "refused replies: 9", "exit: 244"] lines
    expect (result.output.contains "the reply to its call")
  print "reply-lost-test OK"
