// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import bytes
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

  compressed := simple_encoder
  simple_decoder compressed
  squashed1 := big_encoder_no_wait
  squashed2 := big_encoder_with_wait

  expect_equals squashed1 squashed2

  big_decoder squashed1 get_sha

  rle_test

REPEATS ::= 10000
INPUT ::= "Now is the time for all good men to come to the aid of the party."

simple_encoder -> ByteArray:
  compressor := zlib.Encoder
  compressor.write INPUT
  compressor.close
  reader := compressor.reader
  compressed := reader.read
  reader.close
  return compressed

simple_decoder compressed/ByteArray -> none:
  decompressor := zlib.Decoder
  decompressor.write compressed
  decompressor.close
  reader := decompressor.reader
  round_trip := reader.read
  expect_equals INPUT round_trip.to_string

big_encoder_no_wait -> ByteArray:
  compressor := zlib.Encoder
  task::
    REPEATS.repeat:
      for pos := 0; pos < INPUT.size; pos += compressor.write --wait=false INPUT[pos..]:
        yield
    compressor.close
  squashed := #[]
  reader := compressor.reader
  while data := reader.read --wait=false:
    if data.size == 0:
      yield
    else:
      squashed += data

  print "squashed $((REPEATS * INPUT.size) >> 10)k down to $squashed.size bytes"
  return squashed

big_encoder_with_wait -> ByteArray:
  compressor := zlib.Encoder
  task::
    REPEATS.repeat:
      compressor.write INPUT
    compressor.close
  squashed2 := #[]
  reader := compressor.reader
  while data := reader.read:
    squashed2 += data
  reader.close

  print "squashed2 $((REPEATS * INPUT.size) >> 10)k down to $squashed2.size bytes"

  return squashed2

get_sha -> ByteArray:
  input_sha := sha.Sha256
  REPEATS.repeat:
    input_sha.add INPUT
  return input_sha.get

big_decoder squashed/ByteArray input_hash/ByteArray -> none:
  decompressor := zlib.Decoder
  task::
    decompressor.write squashed
    decompressor.close

  sha := sha.Sha256
  while data := decompressor.reader.read:
    sha.add data
  expect_equals
    sha.get
    input_hash

// Encode with the RLE encoder, decode with the full zlib decoder.
rle_test -> none:
  encoder := zlib.RunLengthZlibEncoder

  str := ""
  26.repeat:
    str += "$(%c 'A' + it)" * it

  task::
    encoder.write str
    encoder.close

  encoded := #[]
  while data := encoder.read:
    encoded += data

  decoder := zlib.Decoder
  task::
    decoder.write encoded
    decoder.close

  round_trip := #[]
  while data := decoder.reader.read:
    round_trip += data
  expect_equals str round_trip.to_string

