// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import crypto.sha256 show *
import services.wifi_leaker show *

prng_array:
  hash := sha256 NOISE_KEY_
  hash.size.repeat: hash[it] &= INDEX_MASK_
  return hash

class DataListenerTester extends DataListener:
  data_arrived := false

  constructor offset:
    super offset

  got_raw_packet data:
    data_arrived = true

  got_packet data:
    throw "Unused"

no_noise_data_test:
  prng := prng_array
  listener := OffsetListener
  offset := random 0 15
  10.repeat:
    16.repeat:
      listener.add prng[it] + offset + ((random 0 32) * 32)
  expect_equals offset listener.k

  data_listener := DataListenerTester offset

  5.repeat:
    16.repeat:
      data_listener.add prng[it] + offset + (("The correct data"[it] & 0x1f) << 5) + data_listener.coarse_offset_
  expect data_listener.data_arrived

inserted_random_data_test:
  prng := prng_array
  listener := OffsetListener
  offset := random 0 15
  10.repeat:
    16.repeat:
      listener.add prng[it] + offset + ((random 0 32) * 32)
      listener.add (random 0 1536)
  expect_equals offset listener.k

  data_listener := DataListenerTester offset

  5.repeat:
    16.repeat:
      data_listener.add prng[it] + offset + (("The correct data"[it] & 0x1f) << 5) + data_listener.coarse_offset_
      data_listener.add (random 0 1536)
  expect data_listener.data_arrived

main:
  set_random_seed "wifi"
  prng := prng_array
  test_no_noise prng
  test_no_noise_big_k prng
  test_present_present_missing_missing prng
  test_every_other_missing prng
  test_random_packets_missing prng
  test_every_other_packet_is_constant prng
  test_every_other_packet_is_random prng
  test_every_other_packet_is_random_and_one_quarter_are_missing prng
  test_every_other_packet_is_constant_and_one_quarter_are_missing prng
  no_noise_data_test
  inserted_random_data_test
  test_round_trip_x_percent_loss 17 0
  test_round_trip_x_percent_loss 0 51
  test_round_trip_x_percent_loss 17 51

test_no_noise prng:
  listener := OffsetListener
  10.repeat:
    16.repeat:
      listener.add prng[it] + 12 + ((random 0 32) * 32)
  expect_equals 12 listener.k

test_no_noise_big_k prng:
  listener := OffsetListener
  10.repeat:
    16.repeat:
      listener.add prng[it] + 44 + ((random 0 32) * 32)
  expect_equals 12 listener.k

test_present_present_missing_missing prng:
  listener := OffsetListener
  10.repeat:
    16.repeat:
      if (it % 4) < 2: listener.add prng[it] + 11 + ((random 0 32) * 32)
  expect_equals 11 listener.k

test_every_other_missing prng:
  // Only even packets get through.
  listener := OffsetListener
  10.repeat:
    16.repeat:
      if (it % 2) == 0: listener.add prng[it] + 15 + ((random 0 32) * 32)
  expect_equals 15 listener.k

  // Only odd packets get through.
  listener = OffsetListener
  10.repeat:
    16.repeat:
      if (it % 2) == 1: listener.add prng[it] + 0 + ((random 0 32) * 32)
  expect_equals 0 listener.k

test_random_packets_missing prng:
  // Only every second packet get through.
  listener := OffsetListener
  15.repeat:
    16.repeat:
      if (random 0 2) == 0: listener.add prng[it] + 15 + ((random 0 32) * 32)
  expect_equals 15 listener.k

  // Only every third packet gets through.
  listener = OffsetListener
  30.repeat:
    16.repeat:
      if (random 0 3) == 0: listener.add prng[it] + 1 + ((random 0 32) * 32)
  expect_equals 1 listener.k

  // Only every 4th packet gets through.
  listener = OffsetListener
  45.repeat:
    16.repeat:
      if (random 0 4) == 0: listener.add prng[it] + 1 + ((random 0 32) * 32)
  expect_equals 1 listener.k

  // Only every 5th packet gets through.
  listener = OffsetListener
  100.repeat:
    16.repeat:
      if (random 0 5) == 0: listener.add prng[it] + 1 + ((random 0 32) * 32)
  expect_equals 1 listener.k

test_every_other_packet_is_constant prng:
  listener := OffsetListener
  10.repeat:
    16.repeat:
      listener.add prng[it] + 6 + ((random 0 32) * 32)
      listener.add 44 + ((random 0 32) * 32)
  expect_equals 6 listener.k

test_every_other_packet_is_random prng:
  listener := OffsetListener
  10.repeat:
    16.repeat:
      listener.add prng[it] + 3 + ((random 0 32) * 32)
      listener.add (random 0 31) + ((random 0 32) * 32)
  expect_equals 3 listener.k

test_every_other_packet_is_random_and_one_quarter_are_missing prng:
  listener := OffsetListener
  14.repeat:  // Takes a bit longer.
    16.repeat:
      if (it % 4) != 2: listener.add prng[it] + 3 + ((random 0 32) * 32)
      listener.add (random 0 31) + ((random 0 32) * 32)
  expect_equals 3 listener.k

test_every_other_packet_is_constant_and_one_quarter_are_missing prng:
  listener := OffsetListener
  15.repeat:  // Takes a lot longer.
    16.repeat:
      if (it % 4) != 2: listener.add prng[it] + 3 + ((random 0 32) * 32)
      listener.add 12 + ((random 0 32) * 32)
  expect_equals 3 listener.k

class TestStringDecoder extends WifiDataDecoder:
  msg := null
  got := false

  got_message byte_array:
    got = true
    msg = byte_array.to_string

// Loses 'loss' percent of packets, tests we still get the message.
// Inserts random packets 'insertion' percent of the time
test_round_trip_x_percent_loss loss insertion:
  decoder := TestStringDecoder
  MSG ::= "The correct message at $loss% loss and $insertion% insertion!"
  encoder := WifiDataEncoder MSG

  prng := prng_array

  offset := random 0 15

  ctr := 0
  while not decoder.got:
    value := encoder.next_value
    if not value:
      encoder.reset
      value = encoder.next_value
    if (random 0 100) >= loss:
      decoder.add offset + value
    while (random 0 100) < insertion:
      decoder.add (random 0 1536)
    ctr++
  expect decoder.got
  expect decoder.msg == MSG
