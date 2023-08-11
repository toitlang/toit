// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

time := Time.epoch

main:
  counter := 0
  while true:
    print "counter = $counter"
    time = Time.now
    counter++
    sleep --ms=1_000
