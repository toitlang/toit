// Copyright (C) 2020 Toitware ApS. All rights reserved.

import monitor show Latch
import expect show *

main:
  test_cancel_gives_exception
  test_cancel_in_sleep
  test_invoke_after_cancel_throws
  test_async_is_called_once
  test_cancel_no_trace
  test_cancel_in_catch

test_cancel_gives_exception:
  job ::= task::
    expect_equals
      "CANCELED"
      catch: sleep --ms=100000

  job.cancel

test_cancel_in_sleep:
  job ::= task::
    catch:
      before := Time.monotonic_us
      try:
        sleep --ms=100
      finally:
        expect Time.monotonic_us - before < 100_000

  job.cancel

test_invoke_after_cancel_throws:
  job ::= task::
    // Give it time to mark as canceled.
    yield

    expect_equals
      "CANCELED"
      catch: sleep --ms=100000

  job.cancel

test_async_is_called_once:
  a := A

  job ::= task::
    // Give it time to mark as canceled.
    yield

    expect_equals
      "CANCELED"
      catch: a.block

    expect_equals 1 a.count

  job.cancel

monitor A:
  count := 0

  block:
    await: count++; false
    return count

test_cancel_no_trace:
  job ::= task::
    // Verify we never trace CANCELED errors.
    e := catch --trace=(: throw "BAD STUFF"):
      sleep --ms=100000
    expect_equals e CANCELED_ERROR

  job.cancel


test_cancel_in_catch:
  task::
    task.cancel
    catch
      --trace=: expect false
      --unwind=: expect false
      : sleep --ms=1
