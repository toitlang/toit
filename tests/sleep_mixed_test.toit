// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

main:
  task:: sleep_ms 10
  sleep_ms 40

sleep_ms ms:
  for i := 0; i < 10; i++:
    before := Time.monotonic_us
    sleep --ms=ms
    took := (Time.monotonic_us - before) / 1000
    expect took >= ms
