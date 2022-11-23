// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file
import reader show BufferedReader
import encoding.hex
import crypto.aes show *
import crypto.sha1 show *
import crypto.sha256 show *

class Test:
  data /List
  line_number /string
  comment /string
  source /string

  constructor --.data --.line_number --.comment --.source:

main:
  map := {:}
  read_file map "third_party/boringssl/test_vectors.txt"
  read_file map "third_party/openssl/evptests.txt"
  add_fragility_tests map

  map.do: | algorithm tests |
    tests.do: | test/Test |
      if algorithm == "AES-128-GCM" or algorithm == "AES-192-GCM" or algorithm == "AES-256-GCM":
        test_aes_gcm test
      else if algorithm == "AES-128-ECB" or algorithm == "AES-192-ECB" or algorithm == "AES-256-ECB":
        test_aes test --ecb
      else if algorithm == "AES-128-CBC" or algorithm == "AES-192-CBC" or algorithm == "AES-256-CBC":
        test_aes test --cbc
      else if algorithm == "SHA1":
        test_hash test: Sha1
      else if algorithm == "SHA256":
        test_hash test: Sha256

read_file map/Map filename/string -> none:
  stream := file.Stream.for_read filename
  reader := BufferedReader stream
  line_number := 0
  current_comment := ""
  while line := reader.read_line:
    line_number++
    if line != "":
      if line.starts_with "#":
        current_comment = line[1..].trim
      else:
        add_line line --source=filename --comment=current_comment --line_number="line $line_number" --to=map

add_line line/string --source/string --comment/string --line_number/string --to/Map -> none:
  line = line.trim
  colon := line.index_of ":"
  algorithm := line[..colon].to_ascii_upper
  vectors := line[colon + 1..]
  data := []
  vectors.split ":": data.add (hex.decode it)
  (to.get algorithm --init=:[]).add (Test --data=data --source=source --line_number=line_number --comment=comment)

test_hash test/Test [block] -> none:
  input := test.data[2]
  expected_hash := test.data[3]

  hasher := block.call
  hasher.add input
  hash := hasher.get
  expect_equals expected_hash hash

test_aes test/Test --ecb/bool=false --cbc/bool=false -> none:
  expect (ecb or cbc)
  expect (not (ecb and cbc))
  key := test.data[0]
  iv := test.data[1]
  expected_plain_text := test.data[2]
  expected_cipher_text := test.data[3]

  print "$test.source, $test.line_number, AES, $test.comment"

  encryptor := ?
  decryptor := ?
  if ecb:
    encryptor = AesEcb.encryptor key
    decryptor = AesEcb.decryptor key
  else:
    encryptor = AesCbc.encryptor key iv
    decryptor = AesCbc.decryptor key iv

  cipher_text := encryptor.encrypt expected_plain_text
  expect_equals expected_cipher_text cipher_text

  plain_text := decryptor.decrypt expected_cipher_text
  expect_equals expected_plain_text plain_text

test_aes_gcm test/Test -> none:
  key := test.data[0]
  nonce := test.data[1]
  expected_plain_text := test.data[2]
  expected_cipher_text := test.data[3]
  authenticated := test.data[4]
  expected_verification_tag := test.data[5]

  // We don't currently support IVs that are not 96 bits.
  // The algorithm for this is no longer recommended.
  if nonce.size != 12:
    print "$test.source, $test.line_number, AES-$(key.size * 8)-GCM nonce has wrong size - $(nonce.size * 8) bits"
    return

  print "$test.source, $test.line_number, AES-$(key.size * 8)-GCM, $test.comment"

  // Use the simple all-at-once methods that just append the verification
  // tag to the ciphertext.
  cipher_text_and_tag := (AesGcm.encryptor key nonce).encrypt expected_plain_text --authenticated_data=authenticated
  cut := cipher_text_and_tag.size - 16
  verification_tag := cipher_text_and_tag[cut..]
  cipher_text := cipher_text_and_tag[..cut]
  expect_equals expected_cipher_text cipher_text
  expect_equals expected_verification_tag verification_tag
  plain_text := (AesGcm.decryptor key nonce).decrypt cipher_text_and_tag --authenticated_data=authenticated
  expect_equals expected_plain_text plain_text

  // Test decryption again with separate verification tag.
  plain_text = (AesGcm.decryptor key nonce).decrypt cipher_text --authenticated_data=authenticated --verification_tag=verification_tag
  expect_equals expected_plain_text plain_text

  // Flip first bit in the verification tag and verify it fails.
  verification_tag[0] ^= 0x80
  expect_throw "INVALID_SIGNATURE": (AesGcm.decryptor key nonce).decrypt cipher_text --authenticated_data=authenticated --verification_tag=verification_tag

  // Flip last bit in the verification tag and verify it fails.
  verification_tag[0] ^= 0x80
  verification_tag[15] ^= 1
  expect_throw "INVALID_SIGNATURE": (AesGcm.decryptor key nonce).decrypt cipher_text --authenticated_data=authenticated --verification_tag=verification_tag

  for cut1 := 0; cut1 <= expected_plain_text.size; cut1++:
    for cut2 := cut1; cut2 <= expected_plain_text.size; cut2++:
      // Test in-place encryption.
      encryptor := AesGcm.encryptor key nonce
      encryptor.start --authenticated_data=authenticated
      parts := []
      part1 := expected_plain_text.copy 0 cut1
      part2 := expected_plain_text.copy cut1 cut2
      part3 := expected_plain_text.copy cut2
      parts.add (encryptor.add part1)
      parts.add (encryptor.add part2)
      parts.add (encryptor.add part3)
      finish := encryptor.finish
      parts.add finish[0]
      verification_tag = finish[1]
      cipher_text = parts.reduce: | a b | a + b  // Byte array concatenation.
      expect_equals expected_verification_tag verification_tag
      expect_equals expected_cipher_text cipher_text

      // Test in-place decryption.
      decryptor := AesGcm.decryptor key nonce
      decryptor.start --authenticated_data=authenticated
      parts = []
      part1 = expected_cipher_text.copy 0 cut1
      part2 = expected_cipher_text.copy cut1 cut2
      part3 = expected_cipher_text.copy cut2
      parts.add (decryptor.add part1)
      parts.add (decryptor.add part2)
      parts.add (decryptor.add part3)
      parts.add (decryptor.verify verification_tag)
      plain_text = parts.reduce: | a b | a + b  // Byte array concatenation.
      expect_equals expected_plain_text plain_text

      // Test in-place decryption failure.
      decryptor = AesGcm.decryptor key nonce
      decryptor.start --authenticated_data=authenticated
      parts = []
      part1 = expected_cipher_text.copy 0 cut1
      part2 = expected_cipher_text.copy cut1 cut2
      part3 = expected_cipher_text.copy cut2
      parts.add (decryptor.add part1)
      parts.add (decryptor.add part2)
      parts.add (decryptor.add part3)
      tag := verification_tag.copy
      tag[0] ^= 1
      expect_throw "INVALID_SIGNATURE": decryptor.verify tag

add_fragility_tests map/Map:
  comment := "From 'The fragility of AES-GCM authentication algorithm' by Shay Gueron and Vlad Krasnov"
  key := "3da6c536d6295579c0959a7043efb503"
  iv := "2b926197d34e091ef722db94"
  aad := """
      00000000000000000000000000000000\
      000102030405060708090a0b0c0d0e0f\
      101112131415161718191a1b1c1d1e1f\
      202122232425262728292a2b2c2d2e2f\
      303132333435363738393a3b3c3d3e3f"""
  tag := "69dd586555ce3fcc89663801a71d957b"
  add_line "AES-128-GCM:$key:$iv:::$aad:$tag" --comment=comment --line_number="figure 3" --source="Gueron & Krasnov" --to=map

  key = "84d5733dc8b6f9184dcb9eba2f2cb9f0"
  iv = "35d319a903b6f43adbe915a8"
  aad = """
      000102030405060708090a0b0c0d0e0f\
      101112131415161718191a1b1c1d1e1f\
      202122232425262728292a2b2c2d2e2f\
      303132333435363738393a3b3c3d3e3f\
      404142434445464748494a4b4c4d4e4f\
      505152535455565758595a5b5c5d5e5f\
      00000000000000000000000000000000\
      707172737475767778797a7b7c7d7e7f"""
  tag = "ed1b32c63ee51ea90320235df0b93cdc"
  add_line "AES-128-GCM:$key:$iv:::$aad:$tag" --comment=comment --line_number="figure 5" --source="Gueron & Krasnov" --to=map
