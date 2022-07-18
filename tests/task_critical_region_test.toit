// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test_cancel_before
  test_cancel_in_region
  test_cancel_can_timeout
  test_deadline_in_critical

test_cancel_before:
  task::
    Task_.current.cancel
    critical_do:
      sleep --ms=1
    expect_throw CANCELED_ERROR: sleep --ms=1

test_cancel_in_region:
  task::
    critical_do:
      Task_.current.cancel
      sleep --ms=1
    expect_throw CANCELED_ERROR: sleep --ms=1

test_cancel_can_timeout:
  task::
    expect_throw DEADLINE_EXCEEDED_ERROR:
      with_timeout --ms=1:
        critical_do:
          sleep --ms=10000

test_deadline_in_critical:
  with_timeout --ms=100:
    expect_not_null Task_.current.deadline
    critical_do:
      expect_not_null Task_.current.deadline

  expect_throw DEADLINE_EXCEEDED_ERROR:
    with_timeout --ms=100:
      expect_not_null Task_.current.deadline
      critical_do:
        sleep --ms=1000  // Deadline respected. Exception thrown!

  with_timeout --ms=100:
    expect_not_null Task_.current.deadline
    critical_do --no-respect_deadline:
      expect_null Task_.current.deadline

  with_timeout --ms=100:
    expect_not_null Task_.current.deadline
    critical_do --no-respect_deadline:
      expect_null Task_.current.deadline
      sleep --ms=1000  // No deadline exceeded error!
