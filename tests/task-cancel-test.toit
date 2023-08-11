// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import monitor show Latch
import expect show *

main:
  test-cancel-gives-exception
  test-cancel-in-sleep
  test-invoke-after-cancel-throws
  test-async-is-called-once
  test-cancel-no-trace
  test-cancel-in-catch

test-cancel-gives-exception:
  job ::= task::
    expect-equals
      "CANCELED"
      catch: sleep --ms=100000

  job.cancel

test-cancel-in-sleep:
  job ::= task::
    catch:
      before := Time.monotonic-us
      try:
        sleep --ms=100
      finally:
        expect Time.monotonic-us - before < 100_000

  job.cancel

test-invoke-after-cancel-throws:
  job ::= task::
    // Give it time to mark as canceled.
    yield

    expect-equals
      "CANCELED"
      catch: sleep --ms=100000

  job.cancel

test-async-is-called-once:
  a := A

  job ::= task::
    // Give it time to mark as canceled.
    yield

    expect-equals
      "CANCELED"
      catch: a.block

    expect-equals 1 a.count

  job.cancel

monitor A:
  count := 0

  block:
    await: count++; false
    return count

test-cancel-no-trace:
  job ::= task::
    // Verify we never trace CANCELED errors.
    e := catch --trace=(: throw "BAD STUFF"):
      sleep --ms=100000
    expect-equals e CANCELED-ERROR

  job.cancel


test-cancel-in-catch:
  task::
    Task.current.cancel
    catch
      --trace=: expect false
      --unwind=: expect false
      : sleep --ms=1
