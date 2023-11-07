// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test-sleep
  test-sleep-many
  test-sleep-quick
  test-sleep-abort

test-sleep:
  before := Time.monotonic-us
  sleep --ms=10
  after := Time.monotonic-us
  expect after - before >= 10 * 1000


test-sleep-many:
  for i := 0; i < 10; i++:
    task:: sleep-often i

sleep-often n:
  for i := 0; i < 10; i++:
    duration := 10
    before := Time.monotonic-us
    sleep --ms=duration
    after := Time.monotonic-us
    expect after - before >= duration * 1000

test-sleep-quick:
  1000.repeat:
    task:: sleep --ms=0

test-sleep-abort:
  before := Time.monotonic-us
  expect-equals
    catch:
      with-timeout --ms=10:
        sleep --ms=10_000
    DEADLINE-EXCEEDED-ERROR
  after := Time.monotonic-us
  expect after - before < 10 * 1000 * 1000
