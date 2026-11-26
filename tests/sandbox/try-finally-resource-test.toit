// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
The finally code of a try runs whenever the try was reached, also when the
  try's entry fails for lack of stack (STACK_OVERFLOW) or of memory (the
  stack can't grow at the heap quota): format note 23, "Resource failures
  at TRY" (verified/spec/format/23-format3-try.md).

The test uses the naive idiom `flag = true; try: ... finally: flag = false`
  (the SDK's own uses set their state inside the try since the quota
  livelock; this copy doesn't), in an untrusted container, at every depth
  and word offset of a window around the stack overflow, and at every depth
  of a window with the heap filled to the quota, so that one of the attempts
  fails at each instruction that grows the stack, the TRY included. After
  every attempt the flag must be clear.
*/

import expect show *

import .sandbox

main args:
  sandbox-test args --quotas={"heap": 2_000_000} --error="SWEEP DONE": | arguments/Map |
    sweep-overflow
    sweep-quota
    throw "SWEEP DONE"

flag/bool := false

/** The idiom: a state change right before the try, undone in its finally. */
naive -> none:
  flag = true
  try:
    work 1
  finally:
    flag = false

work x/int -> int:
  return x + 1

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
Runs the idiom $n levels deep, the first $wide levels in larger frames.
Returns the exception, if any; the flag must be clear either way.
*/
attempt n/int wide/int -> any:
  exception := catch: descend n wide: naive
  expect-not flag
  return exception

sweep-overflow -> none:
  // The shallowest depth at which the idiom overflows.
  low := 0
  high := 1
  while (attempt high 0) == null:
    low = high
    high *= 2
  while high - low > 1:
    middle := (low + high) / 2
    if (attempt middle 0) != null:
      high = middle
    else:
      low = middle
  // Every depth and word offset around it (the frames of descend take
  // fewer than 24 words).
  overflowed := 0
  for n := high - 3; n <= high; n++:
    for wide := 0; wide <= 24; wide++:
      exception := attempt n wide
      if exception != null:
        expect-equals "STACK_OVERFLOW" exception
        overflowed++
  expect overflowed > 0

sweep-quota -> none:
  failed := 0
  for n := 0; n <= 40; n++:
    for wide := 0; wide <= 24; wide += 3:
      // Fill the heap to the quota, so that the stack can't grow, then
      // run the idiom.
      filler := []
      [4_000, 256, 16].do: | size/int |
        catch:
          while true: filler.add (ByteArray size)
      exception := attempt n wide
      filler = []
      if exception != null: failed++
  expect failed > 0
