// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import zlib
import host.pipe
import io

main:
  test-gzip "Hello World"
  test-gzip ("A" * 10000)
  test-gzip ""

test-gzip str/string:
  print "Testing '$str[0..min 20 str.size]...'"
  // Create gzip data using external tool.
  gzip-data := gzip-compress str.to-byte-array

  // Decompress using GzipDecoder.
  decoder := zlib.GzipDecoder
  reader := decoder.in
  writer := decoder.out

  // Feed data in a separate task to avoid deadlock if buffer fills depending on implementation.
  task::
    writer.write gzip-data
    writer.close

  result := io.Buffer
  while chunk := reader.read:
    result.write chunk

  expect-equals str result.bytes.to-string

gzip-compress data/ByteArray -> ByteArray:
  // Use host 'gzip' to compress.
  proc := pipe.fork
      --use-path
      --create-stdin
      --create-stdout
      "gzip"
      ["gzip", "-c"]

  writer := proc.stdin.out
  writer.write data
  writer.close

  result := io.Buffer
  reader := proc.stdout.in
  while chunk := reader.read:
    result.write chunk

  proc.wait
  return result.bytes
