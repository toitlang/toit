// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *
import reader_writer show ReaderWriter
import monitor

main:
  print "regular tests"
  regular_test
  regular_test2
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
  write_sem := monitor.Semaphore

  writer := ReaderWriter 2
  reader := writer.reader
  task::
    writer.write "012"

    write_sem.down
    writer.write "345"
    writer.write "67"

    write_sem.down
    writer.write "89"
    writer.close

  expect_equals #['0', '1'] reader.read

  // The read succeeds without waiting to fill the buffer fully.
  expect_equals #['2'] reader.read

  // Ask for new data and wait until it has been written
  write_sem.up
  // Writes immediately "345", but is then blocked as the buffer is full.
  // Still has to write "5".
  expect_equals #['3', '4'] reader.read
  // Once the '3' and '4' have been read the writer task is activated again,
  // filling in the remaining '5' and starting to write the "67"
  expect_equals #['5', '6'] reader.read
  // Since we don't allow the writer task to continue writing "89", we get a single
  // '7' now.
  expect_equals #['7'] reader.read

  write_sem.up
  // The writer is able to write "89" now.
  expect_equals #['8', '9'] reader.read
  expect_equals null reader.read

regular_test2:
  writer := ReaderWriter 2
  reader := writer.reader
  task::
    writer.write "012"
    writer.close

  expect_equals #['0', '1'] reader.read
  expect_equals #['2'] reader.read
  expect_equals null reader.read
