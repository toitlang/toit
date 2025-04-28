// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import zlib
import crypto.sha

main:
  // Test whether support is compiled into the VM.
  enabled := false
  catch:
    zlib.Decoder
    print "Zlib support is compiled in."
    enabled = true
  if not enabled:
    print "Zlib support is not compiled in."
    return

  compressed := simple-encoder
  simple-decoder compressed
  squashed1 := big-encoder-no-wait
  squashed2 := big-encoder-with-wait

  expect-equals squashed1 squashed2

  big-decoder squashed1 get-sha

  rle-test

REPEATS ::= 10000
INPUT ::= "Now is the time for all good men to come to the aid of the party."

simple-encoder -> ByteArray:
  compressor := zlib.Encoder
  compressor.out.write INPUT
  compressor.out.close
  reader := compressor.in
  compressed := reader.read
  reader.close
  return compressed

simple-decoder compressed/ByteArray -> none:
  decompressor := zlib.Decoder
  decompressor.out.write compressed
  decompressor.out.close
  reader := decompressor.in
  round-trip := reader.read
  expect-equals INPUT round-trip.to-string

big-encoder-no-wait -> ByteArray:
  compressor := zlib.Encoder
  task::
    writer := compressor.out
    REPEATS.repeat:
      for pos := 0; pos < INPUT.size; pos += writer.try-write INPUT[pos..]:
        yield
    writer.close
  squashed := #[]
  reader := compressor.in
  while data := reader.read --wait=false:
    if data.size == 0:
      yield
    else:
      squashed += data

  print "squashed $((REPEATS * INPUT.size) >> 10)k down to $squashed.size bytes"
  return squashed

big-encoder-with-wait -> ByteArray:
  compressor := zlib.Encoder
  task::
    writer := compressor.out
    REPEATS.repeat:
      writer.write INPUT
    writer.close
  squashed2 := #[]
  reader := compressor.in
  while data := reader.read:
    squashed2 += data
  reader.close

  print "squashed2 $((REPEATS * INPUT.size) >> 10)k down to $squashed2.size bytes"

  return squashed2

get-sha -> ByteArray:
  input-sha := sha.Sha256
  REPEATS.repeat:
    input-sha.add INPUT
  return input-sha.get

big-decoder squashed/ByteArray input-hash/ByteArray -> none:
  decompressor := zlib.Decoder
  task::
    decompressor.out.write squashed
    decompressor.out.close

  sha := sha.Sha256
  while data := decompressor.in.read:
    sha.add data
  expect-equals
    sha.get
    input-hash

// Encode with the RLE encoder, decode with the full zlib decoder.
rle-test -> none:
  encoder := zlib.RunLengthZlibEncoder

  str := ""
  26.repeat:
    str += "$(%c 'A' + it)" * it

  task::
    encoder.out.write str
    encoder.out.close

  encoded := #[]
  while data := encoder.in.read:
    encoded += data

  decoder := zlib.Decoder
  task::
    decoder.out.write encoded
    decoder.out.close

  round-trip := #[]
  while data := decoder.in.read:
    round-trip += data
  expect-equals str round-trip.to-string
