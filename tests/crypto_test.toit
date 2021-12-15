// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

import crypto show *
import crypto.sha256 show *
import crypto.sha1 show *
import crypto.crc16 show *
import crypto.crc32 show *
import crypto.hamming as hamming

import encoding.hex as hex
import encoding.base64 as base64

expect name [code]:
  expect_equals
    name
    catch code

expect_out_of_range [code]:
  expect "OUT_OF_RANGE" code

expect_wrong_type [code]:
  caught_exception := catch code
  expect_equals true (caught_exception == "WRONG_OBJECT_TYPE" or caught_exception == "AS_CHECK_FAILED")

expect_already_closed [code]:
  expect "ALREADY_CLOSED" code

expect_equal_arrays a b:
  expect_equals a.size b.size
  a.size.repeat:
    expect_equals a[it] b[it]

confuse x -> any: return x

main:
  hamming_test

  EMPTY_HEX ::= "da39a3ee5e6b4b0d3255bfef95601890afd80709"
  EMPTY_SHA2 ::= "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  EMPTY_CRC32 ::=  "00000000"
  EMPTY_CRC16 ::=  "0000"
  expect_equals EMPTY_HEX (hex.encode (sha1 ""))
  expect_equals EMPTY_SHA2 (hex.encode (sha256 ""))
  expect_equals EMPTY_CRC32 (hex.encode (crc32 ""))
  expect_equals "2jmj7l5rSw0yVb/vlWAYkK/YBwk=" (base64.encode (sha1 ""))

  PARTY ::= "Now is the time for all good men to come to the aid of the party"
  hash := sha1 PARTY
  expect_equals "02d2837a5cc31aa9feb8f66a2a3db9819464542b" (hex.encode hash)
  hash2 := sha256 PARTY
  hash3 := crc32 PARTY
  hash4 := crc16 PARTY
  expect_equals "f160938592eeac116451ebc4da23dbc17e29283aef99de0197d705ad4d4c43f1" (hex.encode hash2)
  expect_equals "852430d0" (hex.encode hash3)
  expect_equals "a87e" (hex.encode hash4)
  expect_equals "AtKDelzDGqn+uPZqKj25gZRkVCs=" (base64.encode hash)

  expect_equals EMPTY_HEX (hex.encode (sha1 ""))
  expect_equal_arrays (sha1 (ByteArray 0)) (sha1 "")
  expect_equal_arrays (sha256 (ByteArray 0)) (sha256 "")

  expect_equals "0a0a9f2a6772942557ab5355d76af442f8f65e01" (hex.encode (sha1 "Hello, World!"))
  expect_equals "dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f" (hex.encode (sha256 "Hello, World!"))
  expect_equal_arrays (sha1 ("Hello, World!".to_byte_array)) (sha1 "Hello, World!")

  sha1 := Sha1
  sha2 := Sha256
  crc32 := Crc32
  crc16 := Crc16
  expect_equals EMPTY_HEX (hex.encode (Sha1).get)
  expect_equals EMPTY_CRC32 (hex.encode (Crc32).get)
  expect_equals EMPTY_CRC16 (hex.encode (Crc16).get)
  GOLD_MEMBER := "Hey, everyone! I am from Holland! Isn't that weird?\n"
  sha1.add GOLD_MEMBER
  sha2.add GOLD_MEMBER
  crc32.add GOLD_MEMBER
  crc16.add GOLD_MEMBER
  4.repeat: sha1.add GOLD_MEMBER
  4.repeat: sha2.add GOLD_MEMBER
  4.repeat: crc32.add GOLD_MEMBER
  4.repeat: crc16.add GOLD_MEMBER
  expect_equals "7fd2b3793f46a174024e4fb78b17c0dc4c5bf2bc" (hex.encode sha1.get)
  expect_equals "56185f37" (hex.encode crc32.get)
  expect_equals "c25d" (hex.encode crc16.get)
  expect_equals "68ffcaadaabb22152c90cfbe4e0cd17ddf2f469d8ea9d021713f1b17c72705b8" (hex.encode sha2.get)
  expect_already_closed: (sha2.get)   // Can't do this twice.

  sha2 = Sha256
  crc32 = Crc32
  crc16 = Crc16

  // Takes a string or a byte array.
  expect_wrong_type: base64.decode (confuse 10000)
  expect_wrong_type: sha1.add 10000
  expect_wrong_type: sha2.add 10000
  expect_wrong_type: crc32.add 10000
  expect_wrong_type: crc16.add 10000

  // Missing trailing '=' signs.
  expect_out_of_range: base64.decode "aaa"
  expect_out_of_range: base64.decode "aa"
  expect_out_of_range: base64.decode "a"

  // Misplaced '=' sign
  expect_out_of_range: base64.decode "=AAA"
  expect_out_of_range: base64.decode "A=AA"
  expect_out_of_range: base64.decode "AA=A"

  // Illegal characters
  expect_out_of_range: base64.decode "aaa_"
  expect_out_of_range: base64.decode "aaa\n"
  expect_out_of_range: base64.decode "aaa."
  expect_out_of_range: base64.decode "aaa@"

  // Unused bits are not zero
  expect_out_of_range: base64.decode "AAa="
  expect_out_of_range: base64.decode "Aa=="
  expect_out_of_range: base64.decode "A4=="

hamming_test:
  // The Hamming test routine can encode any 11 bit number to a 16 bit number.
  // It can correct any bit flip in the 16 bit number and detect any two bit flips.
  (1 << 11).repeat: | input |
    correct := hamming.encode_16_11 input
    // No bit errors.
    expect_equals input (hamming.fix_16_11 correct)
    11.repeat: | bit_flip_1 |
      11.repeat: | bit_flip_2 |
        if bit_flip_1 == bit_flip_2:
          // Just flip one bit.  This should be correctable.
          expect_equals
            input
            hamming.fix_16_11 correct ^ (1 << bit_flip_1)
        else:
          // Flip two bits.  This should be detectable
          expect_equals
            null
            hamming.fix_16_11 correct ^ (1 << bit_flip_1) ^ (1 << bit_flip_2)
