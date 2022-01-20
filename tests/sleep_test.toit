// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test_sleep
  test_sleep_many
  test_sleep_quick
  test_sleep_abort

test_sleep:
  before := Time.monotonic_us
  sleep --ms=10
  after := Time.monotonic_us
  expect after - before >= 10 * 1000


test_sleep_many:
  for i := 0; i < 10; i++:
    task:: sleep_often i

sleep_often n:
  for i := 0; i < 10; i++:
    duration := 10
    before := Time.monotonic_us
    sleep --ms=duration
    after := Time.monotonic_us
    expect after - before >= duration * 1000

test_sleep_quick:
  1000.repeat:
    task:: sleep --ms=0

test_sleep_abort:
  before := Time.monotonic_us
  expect_equals
    catch:
      with_timeout --ms=10:
        sleep --ms=10_000
    DEADLINE_EXCEEDED_ERROR
  after := Time.monotonic_us
  expect after - before < 10 * 1000 * 1000
