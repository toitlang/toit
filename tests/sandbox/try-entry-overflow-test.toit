// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
A try whose entry can't grow the stack must not leave the state of the code
  around it changed.

On the verified core (format 2) the TRY instruction calls the try's block,
  and it checks the room for that call before it installs the finally code:
  when the stack can't grow (a stack overflow, or out of memory at the heap
  quota) the exception is raised at the TRY and the finally code doesn't
  run. Code that changed some state right before its try and restored it in
  the finally code kept the change:
- a monitor's locked method took the lock before its try: the lock stayed
  taken, and the next locked method of the monitor waited for it forever.
  For an RPC client the monitor is the one of the pending calls: its next
  call, or the reply handler of a call, waited for the lock.
- the message processing set its flag before its try: the flag stayed set
  and the process never processed a message again, so a task waiting for
  one yielded forever with the message in its mailbox, and the process spun
  on the scheduler threads (an RPC worker at its heap quota: three
  scheduler threads at 100 % CPU).

The untrusted container calls a locked method and the message processing
  with the stack almost full, at every depth and word offset of a window
  around the overflow, so that one of the attempts overflows at each grows
  stack instruction of their code, the tries' entries included. After every
  attempt the monitor, the message processing and an RPC call must still
  work. A leaked lock fails with DEADLINE_EXCEEDED; a stuck message
  processing never delivers the timer's message of the timeout, so the test
  then times out.
*/

import expect show *

import .sandbox

main args:
  sandbox-test args --quotas={"heap": 4_000_000} --error="SWEEP DONE": | arguments/Map |
    sweep
    throw "SWEEP DONE"

monitor Counter:
  count_/int := 0
  increment -> int:
    count_++
    return count_

/**
Recurses $n levels, the first $wide of them in frames that are one word
  larger, and calls the $block at the bottom.
*/
descend n/int wide/int [block] -> none:
  if n == 0:
    block.call
  else if wide > 0:
    descend-wide n - 1 wide - 1 null block
  else:
    descend n - 1 0 block

descend-wide n/int wide/int extra [block] -> none:
  if n == 0:
    block.call
  else if wide > 0:
    descend-wide n - 1 wide - 1 extra block
  else:
    descend n - 1 0 block

/**
Calls the $target $n levels deep, the first $wide levels in larger frames.
Returns whether that overflowed the stack.
*/
attempt n/int wide/int target/Lambda -> bool:
  exception := catch: descend n wide: target.call
  if exception == null: return false
  expect-equals "STACK_OVERFLOW" exception
  return true

sweep -> none:
  counter := Counter
  client := SiblingClient
  client.open
  self := Process.current.id
  targets := [
    // A monitor's locked method.
    :: counter.increment,
    // The message processing: a message in the mailbox (for which there is
    // no handler: it is dropped), so that yield processes the messages.
    ::
      process-send_ self USER-MESSAGE-TYPE 0
      yield,
  ]
  targets.do: | target/Lambda |
    // The shallowest depth at which the target overflows.
    low := 0
    high := 1
    while not (attempt high 0 target):
      low = high
      high *= 2
    while high - low > 1:
      middle := (low + high) / 2
      if attempt middle 0 target:
        high = middle
      else:
        low = middle
    check counter client
    // Every depth and word offset around it: the frames of descend take
    // fewer than 24 words, so there is an attempt for every amount of room
    // left in a window of three frames.
    overflowed := 0
    for n := high - 3; n <= high; n++:
      for wide := 0; wide <= 24; wide++:
        if attempt n wide target: overflowed++
        check counter client
    expect overflowed > 0
  client.close

/**
Checks that the $counter's lock is free, that the messages are processed
  and that the $client's calls work.
*/
check counter/Counter client/SiblingClient -> none:
  with-timeout --ms=5_000:
    counter.increment
    expect-equals 8 (client.ping 7)
    sleep --ms=1
