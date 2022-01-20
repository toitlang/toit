// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import reader_writer show ReaderWriter

main:
  print "regular_test"
  regular_test
  print "write_does_not_hang"
  write_does_not_hang
  print "read_does_not_hang"
  read_does_not_hang

write_does_not_hang:
  writer := ReaderWriter
  reader := writer.reader
  did_not_hang := false
  task::
    exception := catch:
      while true:
        writer.write "foo"
    did_not_hang = true

  sleep --ms=100
  reader.close
  while not did_not_hang: sleep --ms=10

read_does_not_hang:
  writer := ReaderWriter
  reader := writer.reader
  did_not_hang := false
  task::
    while bytes := reader.read:
      expect_equals
        bytes
        ByteArray 3: ['f', 'o', 'o'][it]
    did_not_hang = true

  writer.write "foo"
  sleep --ms=100
  writer.close
  while not did_not_hang: sleep --ms=10

regular_test:
  writer := ReaderWriter 2
  reader := writer.reader
  task::
    writer.write "012"
    sleep --ms=100
    writer.write "345"
    sleep --ms=100
    writer.write "67"
    sleep --ms=100
    writer.write "89"
    sleep --ms=100
    writer.close

  expect_equals
    ByteArray 2: ['0', '1'][it]
    reader.read

  expect_equals
    ByteArray 2: ['2', '3'][it]
    reader.read

  expect_equals
    ByteArray 2: ['4', '5'][it]
    reader.read

  expect_equals
    ByteArray 2: ['6', '7'][it]
    reader.read

  expect_equals
    ByteArray 2: ['8', '9'][it]
    reader.read

  expect_equals
    null
    reader.read
