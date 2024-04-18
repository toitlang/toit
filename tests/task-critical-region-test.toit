// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test-cancel-before
  test-cancel-in-region
  test-cancel-can-timeout
  test-deadline-in-critical

test-cancel-before:
  task::
    Task_.current.cancel
    critical-do:
      sleep --ms=1
    expect-throw CANCELED-ERROR: sleep --ms=1

test-cancel-in-region:
  task::
    critical-do:
      Task_.current.cancel
      sleep --ms=1
    expect-throw CANCELED-ERROR: sleep --ms=1

test-cancel-can-timeout:
  task::
    expect-throw DEADLINE-EXCEEDED-ERROR:
      with-timeout --ms=1:
        critical-do:
          sleep --ms=10000

test-deadline-in-critical:
  with-timeout --ms=100:
    expect-not-null Task_.current.deadline
    critical-do:
      expect-not-null Task_.current.deadline

  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=100:
      expect-not-null Task_.current.deadline
      critical-do:
        sleep --ms=1000  // Deadline respected. Exception thrown!

  with-timeout --ms=100:
    expect-not-null Task_.current.deadline
    critical-do --no-respect-deadline:
      expect-null Task_.current.deadline

  with-timeout --ms=100:
    expect-not-null Task_.current.deadline
    critical-do --no-respect-deadline:
      expect-null Task_.current.deadline
      sleep --ms=1000  // No deadline exceeded error!
