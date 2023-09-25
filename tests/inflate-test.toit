// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import expect show *
import zlib

main:
  simple-test
  // These tests don't check the output, but the checksum that is built into
  // the zlib format will do that for us.
  uncompressed-test
  rle-test
  zlib-test

simple-test:
  expect-equals 0 (zlib.reverse_ 0 1)
  expect-equals 1 (zlib.reverse_ 1 1)
  expect-equals 0b00 (zlib.reverse_ 0b00 2)
  expect-equals 0b10 (zlib.reverse_ 0b01 2)
  expect-equals 0b01 (zlib.reverse_ 0b10 2)
  expect-equals 0b11 (zlib.reverse_ 0b11 2)
  expect-equals 0b110100 (zlib.reverse_ 0b001011 6)
  expect-equals 0b0110100 (zlib.reverse_ 0b0010110 7)
  expect-equals 0b10100110 (zlib.reverse_ 0b01100101 8)
  expect-equals 0b110100110 (zlib.reverse_ 0b011001011 9)
  expect-equals 0b1110100110 (zlib.reverse_ 0b0110010111 10)
  expect-equals 0b11101001101 (zlib.reverse_ 0b10110010111 11)

  // From the RFC section 3.2.2.
  ex := [
      zlib.SymbolBitLen_ 'A' 2,
      zlib.SymbolBitLen_ 'B' 1,
      zlib.SymbolBitLen_ 'C' 3,
      zlib.SymbolBitLen_ 'D' 3,
  ]

  lookup := zlib.HuffmanTables_ ex

  for i := 0; i < 256; i++:
    value := lookup.first-level[i]
    if i & 1 == 0:
      expect-equals (('B' << 4) + 1) value
    else if i & 0b11 == 0b01:
      expect-equals (('A' << 4) + 2) value
    else if i & 0b111 == 0b011:
      expect-equals (('C' << 4) + 3) value
    else if i & 0b111 == 0b111:
      expect-equals (('D' << 4) + 3) value
    else:
      expect-equals 0 value

  // Reconstruct the static Huffman table from the RFC.
  zlib.create-fixed-symbol-and-length_
  zlib.create-fixed-distance_

uncompressed-test:
  print "***uncompressed-test"
  round-trip-test: zlib.UncompressedZlibEncoder

rle-test:
  print "***rle-test"
  round-trip-test: zlib.RunLengthZlibEncoder

zlib-test:
  enabled := false
  catch:
    zlib.Encoder
    print "Zlib support is compiled in."
    enabled = true
  if enabled:
    10.repeat: | i |
      print "***zlib-test --level=$i"
      round-trip-test: zlib.Encoder --level=i

round-trip-test [block]:
  2.repeat:
    buffering := it == 0
    compressor := block.call
    task::
      print-round-tripped_ compressor (buffering ? zlib.BufferingInflater : zlib.CopyingInflater)::
        expect-equals "Hello, World!" it

    compressor.write "Hello, World!"
    compressor.close

    compressor2 := block.call
    input2 := ("a" * 12) + ("b" * 25) + ("a" * 12)
    task::
      print-round-tripped_ compressor2 (buffering ? zlib.BufferingInflater : zlib.CopyingInflater)::
        expect-equals input2 it
    compressor2.write input2
    compressor2.close

    compressor3 := block.call
    input3 := "kdjflskdkldskdkdskdkdkdkdlskfjsalædkfjaæsldkfjaæsldkfjaæsldkfældjflsakdfjlaskdjflsadkfjsalædkfj"
    task::
      print-round-tripped_ compressor3 (buffering ? zlib.BufferingInflater : zlib.CopyingInflater)::
        expect-equals input3 it
    compressor3.write input3
    compressor3.close

    compressor4 := block.call
    input4a := "LSDLKFJLSDKFJLSDKJFLSDKJFLDSK"
    input4b := "OWIEUROIWEUROIUWEORIUWEORIUWEORIU"
    input4c := "X:C;MV:XCMV:XC;MV:;XCMV:;MXC:V;MXC:;V"
    unusual-chars := "abloidpolkbksadbahbieoaweighojlaskdaowgoakjsadlkjsal"
    unusual-chars2 := "opiogbjlvcjlakbjpoabapobhaowubnkscsvlkfdjasldkjblayweb"
    unusual-chars3 := "dpogsdapgosigpaosgmaslæ,ambæsaodgjaosdigjasopdgjpsaogd"
    unusual-chars4 := "opaiyyfahpoibhpaowbæaw.e-.!#%&/(awe,maaopgaeoibaweopawemobea"
    input4 := input4a + input4b + input4a + input4c
        + unusual-chars + unusual-chars2 + unusual-chars3 + unusual-chars4
        + "z"
        + (input4b * 10) + input4a + input4c + input4b + input4b
    // Add a lot of fairly random digits to get a nicely asymmetric Huffman
    // table.
    1000.repeat: input4 += "$it"
    task::
      print-round-tripped_ compressor4 (buffering ? zlib.BufferingInflater : zlib.CopyingInflater)::
        expect-equals input4 it
    compressor4.write input4
    compressor4.close

print-round-tripped_ compressor decompressor complete/Lambda:
  accumulator := []
  start/int? := null
  while round-tripped := decompressor.reader.read --wait=false:
    if round-tripped.size == 0:
      if not start: start = Time.monotonic-us
      compressed := compressor.reader.read
      if not compressed: break
      decompressor.write compressed
    else:
      accumulator.add round-tripped.to-string
  complete.call
    accumulator.join ""
