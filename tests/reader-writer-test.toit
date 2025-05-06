// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import reader-writer show ReaderWriter
import monitor

main:
  print "regular tests"
  regular-test
  regular-test2
  print "write_does_not_hang"
  write-does-not-hang
  print "read_does_not_hang"
  read-does-not-hang

write-does-not-hang:
  writer := ReaderWriter
  reader := writer.reader
  did-not-hang := false
  task::
    exception := catch:
      while true:
        writer.write "foo"
    did-not-hang = true

  sleep --ms=100
  reader.close
  while not did-not-hang: sleep --ms=10

read-does-not-hang:
  writer := ReaderWriter
  reader := writer.reader
  did-not-hang := false
  task::
    while bytes := reader.read:
      expect-equals
        bytes
        ByteArray 3: ['f', 'o', 'o'][it]
    did-not-hang = true

  writer.write "foo"
  sleep --ms=100
  writer.close
  while not did-not-hang: sleep --ms=10

regular-test:
  write-sem := monitor.Semaphore

  writer := ReaderWriter 2
  reader := writer.reader
  task::
    writer.write "012"

    write-sem.down
    writer.write "345"
    writer.write "67"

    write-sem.down
    writer.write "89"
    writer.close

  all-chunks := []
  // Keep all read data, to make sure the returned byte arrays are not
  // overwritten.
  read-next := :
    data := reader.read
    if data: all-chunks.add data
    data

  expect-equals #['0', '1'] read-next.call

  // The read succeeds without waiting to fill the buffer fully.
  expect-equals #['2'] read-next.call

  // Ask for new data and wait until it has been written
  write-sem.up
  // Writes immediately "345", but is then blocked as the buffer is full.
  // Still has to write "5".
  expect-equals #['3', '4'] read-next.call
  // Once the '3' and '4' have been read the writer task is activated again,
  // filling in the remaining '5'. Once the caller yields it starts to write
  // the "67", but without the yield, we would only see '5' here.
  yield
  expect-equals #['5', '6'] read-next.call
  // Since we don't allow the writer task to continue writing "89", we get a single
  // '7' now.
  expect-equals #['7'] read-next.call

  write-sem.up
  // The writer is able to write "89" now.
  expect-equals #['8', '9'] read-next.call
  expect-equals null read-next.call

  // Ensure the returned byte-arrays haven't been modified.
  all-bytes := all-chunks.reduce: | a b | a + b
  expect-equals "0123456789" all-bytes.to-string

regular-test2:
  writer := ReaderWriter 2
  reader := writer.reader
  task::
    writer.write "012"
    writer.close

  data1 := reader.read
  data2 := reader.read
  expect-equals #['0', '1'] data1
  expect-equals #['2'] data2
  expect-equals null reader.read

  // Ensure the returned byte-arrays haven't been modified.
  expect-equals "012" (data1 + data2).to-string
