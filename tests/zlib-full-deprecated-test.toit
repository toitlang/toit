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
  compressor.write INPUT  // @no-warn
  compressor.close  // @no-warn
  reader := compressor.reader  // @no-warn
  compressed := reader.read
  reader.close
  return compressed

simple-decoder compressed/ByteArray -> none:
  decompressor := zlib.Decoder
  decompressor.write compressed  // @no-warn
  decompressor.close  // @no-warn
  reader := decompressor.reader  // @no-warn
  round-trip := reader.read
  expect-equals INPUT round-trip.to-string

big-encoder-no-wait -> ByteArray:
  compressor := zlib.Encoder
  task::
    REPEATS.repeat:
      for pos := 0; pos < INPUT.size; pos += compressor.write --wait=false INPUT[pos..]:  // @no-warn
        yield
    compressor.close  // @no-warn
  squashed := #[]
  reader := compressor.reader  // @no-warn
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
    REPEATS.repeat:
      compressor.write INPUT  // @no-warn
    compressor.close  // @no-warn
  squashed2 := #[]
  reader := compressor.reader  // @no-warn
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
    decompressor.write squashed  // @no-warn
    decompressor.close  // @no-warn

  sha := sha.Sha256
  while data := decompressor.reader.read:  // @no-warn
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
    encoder.write str  // @no-warn
    encoder.close  // @no-warn

  encoded := #[]
  while data := encoder.reader.read:  // @no-warn
    encoded += data

  decoder := zlib.Decoder
  task::
    decoder.write encoded  // @no-warn
    decoder.close  // @no-warn

  round-trip := #[]
  while data := decoder.reader.read:  // @no-warn
    round-trip += data
  expect-equals str round-trip.to-string
