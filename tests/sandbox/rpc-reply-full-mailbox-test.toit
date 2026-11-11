// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
A sandbox can't make the reply of a sandboxed provider fail and with it
  take the provider down (see "Threats tested" in docs/sandbox-policy.md).

The mailbox quota of sandboxed senders is shared, at each receiver, by
  all sandboxed senders. Sandboxes X and Y both provide a service (their
  launch policy grants it) to the trusted client T, so both may send to T.
  While T doesn't process its messages (it spins), X fills T's mailbox up
  to the quota, and then Y answers a request of T. Y's reply hits the full
  mailbox and fails with QUOTA_EXCEEDED. Before the fix, the exception
  escaped the RPC processing task of Y's broker and terminated Y, so X
  took Y's service away from T.

Now Y's broker retries the reply (it is a sandbox, so it is slowed down,
  not T): Y keeps serving the driver, and when T processes its messages
  again it gets the real reply.

The steps are ordered by the driver, not by timing: T writes a file when
  it starts spinning, the driver lets X fill T only then, Y confirms that
  its reply will hit a full mailbox before the driver lets T continue.
*/

import expect show *
import host.directory
import host.file
import monitor
import system.containers
import system.services show ServiceSelector ServiceProvider ServiceHandler ServiceClient TAG-UNTRUSTED-PROVIDER

ROLE-KEY ::= "role"
USER-MESSAGE-TYPE ::= 100
QUOTA ::= 16
QUOTAS ::= {"mailbox-messages": QUOTA}

ANSWER ::= 42

interface TestService:
  static SELECTOR ::= ServiceSelector
      --uuid="d3a1f7c2-6b4e-4f0a-8c9d-1e2f3a4b5c61"
      --major=1
      --minor=0

  // Remembers the caller as the target of $fill and $answer.
  register -> none
  static REGISTER-INDEX ::= 0

  // Sends user messages to the registered caller until the quota is
  // exceeded and returns how many it sent.
  fill -> int
  static FILL-INDEX ::= 1

  // Returns $ANSWER once $release was called.
  answer -> int
  static ANSWER-INDEX ::= 2

  // Lets a pending $answer continue. Returns the exception of a message
  // that the answering task sent to the registered caller right before it
  // returned (null if it was delivered).
  release -> any
  static RELEASE-INDEX ::= 3

  ping value/int -> int
  static PING-INDEX ::= 4

restricted-selector name/string -> ServiceSelector:
  selector := TestService.SELECTOR.restrict
  selector.allow --tag=TAG-UNTRUSTED-PROVIDER
  selector.allow --name=name
  return selector

class TestClient extends ServiceClient implements TestService:
  constructor name/string:
    // The providers are in sandboxes, so the client must opt in.
    super (restricted-selector name)

  register -> none: invoke_ TestService.REGISTER-INDEX null
  fill -> int: return invoke_ TestService.FILL-INDEX null
  answer -> int: return invoke_ TestService.ANSWER-INDEX null
  release -> any: return invoke_ TestService.RELEASE-INDEX null
  ping value/int -> int: return invoke_ TestService.PING-INDEX value

class TestProvider extends ServiceProvider implements TestService ServiceHandler:
  target/int? := null
  released := monitor.Latch
  probed := monitor.Latch

  constructor name/string:
    super name --major=1 --minor=0
    provides TestService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == TestService.REGISTER-INDEX:
      target = pid --client=client
      return null
    if index == TestService.FILL-INDEX: return fill
    if index == TestService.ANSWER-INDEX: return answer
    if index == TestService.RELEASE-INDEX: return release
    if index == TestService.PING-INDEX: return ping arguments
    unreachable

  register -> none: unreachable

  fill -> int:
    sent := 0
    exception := catch:
      (QUOTA + 1).repeat:
        process-send_ target USER-MESSAGE-TYPE sent
        sent++
    expect-equals "QUOTA_EXCEEDED" exception
    return sent

  answer -> int:
    released.get
    exception := catch: process-send_ target USER-MESSAGE-TYPE -1
    // Don't yield between here and the reply: the driver must only learn
    // the result once the broker tried to send the reply.
    critical-do: probed.set exception
    return ANSWER

  release -> any:
    released.set true
    return probed.get

  ping value/int -> int:
    return value + 1

main arguments:
  if arguments is Map:
    role := arguments[ROLE-KEY]
    if role == "x" or role == "y":
      provider := TestProvider role
      provider.install
      while true: sleep --ms=1_000
    else if role == "t":
      run-t arguments["dir"]
    else:
      throw "Unknown role: $role"
    return
  run-driver

/** Absorbs the user messages of X and Y. */
class Sink_ implements SystemMessageHandler_:
  received/int := 0
  on-message type/int gid/int pid/int message/any -> none:
    received++

// The trusted client.
run-t dir/string -> none:
  sink := Sink_
  set-system-message-handler_ USER-MESSAGE-TYPE sink
  x := TestClient "x"
  x.open --timeout=(Duration --s=5)
  x.register
  y := TestClient "y"
  y.open --timeout=(Duration --s=5)
  y.register
  result := null
  done := monitor.Latch
  task::
    exception := catch: result = y.answer
    done.set exception
  // Let the task send its request.
  10.repeat: yield
  file.write-contents "" --path="$dir/spinning"
  // Spin without yielding, so we don't process messages.
  while not file.is-file "$dir/continue": null
  expect-null (with-timeout --ms=20_000: done.get)
  expect-equals ANSWER result
  // The messages of X. The message Y tried to send before it replied
  // didn't fit.
  expect-equals QUOTA sink.received
  print "T got the reply"

wait-for path/string -> none:
  deadline := Time.monotonic-us + 20_000_000
  while not file.is-file path:
    if Time.monotonic-us > deadline: throw "Timed out waiting for $path"
    sleep --ms=10

run-driver:
  dir := directory.mkdtemp "/tmp/rpc-reply-full-mailbox-"
  try:
    x-container := containers.start containers.current {ROLE-KEY: "x"}
        --untrusted
        --quotas=QUOTAS
        --may-provide-services
    y-stopped := false
    y-container := containers.start containers.current {ROLE-KEY: "y"}
        --untrusted
        --quotas=QUOTAS
        --may-provide-services
        --on-stopped=:: y-stopped = true
    x := TestClient "x"
    x.open --timeout=(Duration --s=5)
    y := TestClient "y"
    y.open --timeout=(Duration --s=5)

    t := containers.start containers.current {ROLE-KEY: "t", "dir": dir}
    wait-for "$dir/spinning"
    // T doesn't process its messages: X fills its mailbox.
    expect-equals QUOTA x.fill
    // Y answers T's pending request. Its reply doesn't fit.
    expect-equals "QUOTA_EXCEEDED" y.release
    // Y is still alive and serves other clients.
    expect-equals 8 (y.ping 7)
    expect-not y-stopped
    // T processes its messages again and gets the reply.
    file.write-contents "" --path="$dir/continue"
    expect-equals 0 t.wait
    expect-equals 9 (y.ping 8)

    x.close
    y.close
    x-container.stop
    y-container.stop
  finally:
    directory.rmdir --recursive --force dir
  print "OK"
