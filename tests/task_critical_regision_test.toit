// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

main:
  test_cancel_before
  test_cancel_in_region
  test_cancel_can_timeout

test_cancel_before:
  task::
    task.cancel
    critical_do:
      sleep --ms=1
    expect_throw CANCELED_ERROR: sleep --ms=1

test_cancel_in_region:
  task::
    critical_do:
      task.cancel
      sleep --ms=1
    expect_throw CANCELED_ERROR: sleep --ms=1

test_cancel_can_timeout:
  task::
    expect_throw DEADLINE_EXCEEDED_ERROR:
      with_timeout --ms=1:
        critical_do:
          sleep --ms=10000
