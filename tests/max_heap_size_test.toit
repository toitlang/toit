// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

expect_ name [code]:
  expect_equals
    name
    catch code

expect_allocation_failed [code]:
  exception := catch code
  expect
      exception == "ALLOCATION_FAILED" or exception == "OUT_OF_MEMORY"

main:
  // We can limit ourselves to as little as a 4k heap (on 32 bit) which
  // means no old-space.
  for i := 12; i < 17; i++:
    doesnt_fail 1 << i
  for i := 14; i < 17; i++:
    doesnt_fail_external 1 << i
  spawn:: eventually_fails 70000 --external
  sleep --ms=2000
  spawn:: eventually_fails 0x10000 --external
  sleep --ms=2000
  spawn:: eventually_fails 50000 --external
  sleep --ms=1500
  spawn:: eventually_fails 0x8000 --external
  sleep --ms=1000
  spawn:: eventually_fails 30000 --external
  sleep --ms=1000

  spawn:: eventually_fails 70000 --no-external
  sleep --ms=2000
  spawn:: eventually_fails 0x10000 --no-external
  sleep --ms=2000
  spawn:: eventually_fails 50000 --no-external
  sleep --ms=1500
  spawn:: eventually_fails 0x8000 --no-external
  sleep --ms=1000
  spawn:: eventually_fails 30000 --no-external
  sleep --ms=1000

eventually_fails limit --external/bool:
  print_ "$limit eventually fails"
  set_max_heap_size_ limit
  expect_allocation_failed:
    a := []
    while true:
      s := "Abcdefghijklmnopqrstuvwxyz $a.size"
      if external:
        8.repeat: s += s  // Make garbage string so big it needs to be external.
      else:
        256.repeat: s + s  // Make internal garbage strings.
      a.add (ByteArray (256 + (a.size % 16)))
      if a.size % 10 == 0: print_ "  a.size=$a.size"
      sleep --ms=1

doesnt_fail limit:
  set_max_heap_size_ limit
  print_ "limit $limit"
  a := []
  for l := limit; l > 2000; l -= 270:
    print "  l=$l"
    s := ("#" * 200) + "$(random 1000)"
    a.add s
    sleep --ms=1
  print_ "end $limit"

doesnt_fail_external limit:
  set_max_heap_size_ limit
  print_ "limit $limit"
  a := []
  // On 32 bit we have a 4k chunk in old-space that we can't get
  // rid of at this point.  With the 4k chunk in new-space that's 8k that
  // can't be used for external allocations.
  for l := limit; l > 9000; l -= 5000:
    print_ "  l=$l a.size=$a.size"
    s := ByteArray 4096 // Goes to an external byte array on 32 bit.
    a.add s
    sleep --ms=1
  print_ "end $limit"
