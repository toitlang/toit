// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file
import io
import encoding.hex
import crypto.aes show *
import crypto.blake2 show *
import crypto.sha1 show *
import crypto.sha256 show *

class Test:
  data /List
  line-number /string
  comment /string
  source /string

  constructor --.data --.line-number --.comment --.source:

BLAKE2S := "Blake2s"

main:
  map := {:}
  read-file map "third_party/boringssl/cipher_test.txt"
  read-file map "third_party/openssl/evptests.txt"
  read-blake-file map "third_party/BLAKE2/testvectors/blake2s-kat.txt"
  add-fragility-tests map

  map.do: | algorithm tests |
    tests.do: | test/Test |
      if algorithm == "AES-128-GCM" or algorithm == "AES-192-GCM" or algorithm == "AES-256-GCM":
        test-aes-gcm test
      else if algorithm == "AES-128-ECB" or algorithm == "AES-192-ECB" or algorithm == "AES-256-ECB":
        test-aes test --ecb
      else if algorithm == "AES-128-CBC" or algorithm == "AES-192-CBC" or algorithm == "AES-256-CBC":
        test-aes test --cbc
      else if algorithm == "SHA1":
        test-hash test: Sha1
      else if algorithm == "SHA256":
        test-hash test: Sha256
      else if algorithm == BLAKE2S:
        test-blake test

read-file map/Map filename/string -> none:
  stream := file.Stream.for-read filename
  reader := stream.in
  line-number := 0
  current-comment := ""
  while line := reader.read-line:
    line-number++
    if line != "":
      if line.starts-with "#":
        current-comment = line[1..].trim
      else:
        add-line line --source=filename --comment=current-comment --line-number="line $line-number" --to=map

read-blake-file map/Map filename/string -> none:
  stream := file.Stream.for-read filename
  reader := stream.in
  line-number := 0
  current-in := #[]
  current-key := #[]

  while line := reader.read-line:
    line-number++
    if line != "":
      parts := line.split "\t"
      key := parts[0]
      value := parts[1]
      if key == "in:":
        current-in = hex.decode value
      else if key == "key:":
        current-key = hex.decode value
      else if key == "hash:":
        data := [current-key, current-in, value]
        (map.get BLAKE2S --init=:[]).add (Test --data=data --source=filename --line-number="line $line-number" --comment="")
      else:
        throw "Unparsed: $filename:$line-number $line"
  expect-equals 256 map[BLAKE2S].size

add-line line/string --source/string --comment/string --line-number/string --to/Map -> none:
  line = line.trim
  colon := line.index-of ":"
  algorithm := line[..colon].to-ascii-upper
  vectors := line[colon + 1..]
  data := []
  vectors.split ":": data.add (hex.decode it)
  (to.get algorithm --init=:[]).add (Test --data=data --source=source --line-number=line-number --comment=comment)

test-blake test/Test -> none:
  input := test.data[1]
  expected-hash := test.data[2]

  hasher := Blake2s --key=test.data[0]
  hasher.add input
  hash := hex.encode hasher.get
  expect-equals expected-hash hash

test-hash test/Test [block] -> none:
  input := test.data[2]
  expected-hash := test.data[3]

  hasher := block.call
  hasher.add input
  hash := hasher.get
  expect-equals expected-hash hash

test-aes test/Test --ecb/bool=false --cbc/bool=false -> none:
  expect (ecb or cbc)
  expect (not (ecb and cbc))
  key := test.data[0]
  iv := test.data[1]
  expected-plaintext := test.data[2]
  expected-ciphertext := test.data[3]

  print "$test.source, $test.line-number, AES, $test.comment"

  encryptor := ?
  decryptor := ?
  if ecb:
    encryptor = AesEcb.encryptor key
    decryptor = AesEcb.decryptor key
  else:
    encryptor = AesCbc.encryptor key iv
    decryptor = AesCbc.decryptor key iv

  ciphertext := encryptor.encrypt expected-plaintext
  expect-equals expected-ciphertext ciphertext

  plaintext := decryptor.decrypt expected-ciphertext
  expect-equals expected-plaintext plaintext

test-aes-gcm test/Test -> none:
  key := test.data[0]
  nonce := test.data[1]
  expected-plaintext := test.data[2]
  expected-ciphertext := test.data[3]
  authenticated := test.data[4]
  expected-verification-tag := test.data[5]

  // We don't currently support IVs that are not 96 bits.
  // The algorithm for this is no longer recommended.
  if nonce.size != 12:
    print "$test.source, $test.line-number, AES-$(key.size * 8)-GCM nonce has wrong size - $(nonce.size * 8) bits"
    return

  print "$test.source, $test.line-number, AES-$(key.size * 8)-GCM, $test.comment"

  // Use the simple all-at-once methods that just append the verification
  // tag to the ciphertext.
  ciphertext-and-tag := (AesGcm.encryptor key nonce).encrypt expected-plaintext --authenticated-data=authenticated
  end := ciphertext-and-tag.size - AesGcm.TAG-SIZE
  verification-tag := ciphertext-and-tag[end..]
  ciphertext := ciphertext-and-tag[..end]
  expect-equals expected-ciphertext ciphertext
  expect-equals expected-verification-tag verification-tag
  plaintext := (AesGcm.decryptor key nonce).decrypt ciphertext-and-tag --authenticated-data=authenticated
  expect-equals expected-plaintext plaintext

  // Test decryption again with separate verification tag.
  plaintext = (AesGcm.decryptor key nonce).decrypt ciphertext --authenticated-data=authenticated --verification-tag=verification-tag
  expect-equals expected-plaintext plaintext

  // Flip first bit in the verification tag and verify it fails.
  verification-tag[0] ^= 0x80
  expect-throw "INVALID_SIGNATURE": (AesGcm.decryptor key nonce).decrypt ciphertext --authenticated-data=authenticated --verification-tag=verification-tag

  // Flip last bit in the verification tag and verify it fails.
  verification-tag[0] ^= 0x80
  verification-tag[15] ^= 1
  expect-throw "INVALID_SIGNATURE": (AesGcm.decryptor key nonce).decrypt ciphertext --authenticated-data=authenticated --verification-tag=verification-tag

  for cut1 := 0; cut1 <= expected-plaintext.size; cut1++:
    for cut2 := cut1; cut2 <= expected-plaintext.size; cut2++:
      // Test in-place encryption.
      encryptor := AesGcm.encryptor key nonce
      encryptor.start --authenticated-data=authenticated
      parts := []
      part1 := expected-plaintext.copy 0 cut1
      part2 := expected-plaintext.copy cut1 cut2
      part3 := expected-plaintext.copy cut2
      parts.add (encryptor.add part1)
      parts.add (encryptor.add part2)
      parts.add (encryptor.add part3)
      finish := encryptor.finish
      end = finish.size - AesGcm.TAG-SIZE
      parts.add finish[0..end]
      verification-tag = finish[end..]
      ciphertext = parts.reduce: | a b | a + b  // Byte array concatenation.
      expect-equals expected-verification-tag verification-tag
      expect-equals expected-ciphertext ciphertext

      // Test in-place decryption.
      decryptor := AesGcm.decryptor key nonce
      decryptor.start --authenticated-data=authenticated
      parts = []
      part1 = expected-ciphertext.copy 0 cut1
      part2 = expected-ciphertext.copy cut1 cut2
      part3 = expected-ciphertext.copy cut2
      parts.add (decryptor.add part1)
      parts.add (decryptor.add part2)
      parts.add (decryptor.add part3)
      parts.add (decryptor.verify verification-tag)
      plaintext = parts.reduce: | a b | a + b  // Byte array concatenation.
      expect-equals expected-plaintext plaintext

      // Test in-place decryption failure.
      decryptor = AesGcm.decryptor key nonce
      decryptor.start --authenticated-data=authenticated
      parts = []
      part1 = expected-ciphertext.copy 0 cut1
      part2 = expected-ciphertext.copy cut1 cut2
      part3 = expected-ciphertext.copy cut2
      parts.add (decryptor.add part1)
      parts.add (decryptor.add part2)
      parts.add (decryptor.add part3)
      tag := verification-tag.copy
      tag[0] ^= 1
      expect-throw "INVALID_SIGNATURE": decryptor.verify tag

add-fragility-tests map/Map:
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
  add-line "AES-128-GCM:$key:$iv:::$aad:$tag" --comment=comment --line-number="figure 3" --source="Gueron & Krasnov" --to=map

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
  add-line "AES-128-GCM:$key:$iv:::$aad:$tag" --comment=comment --line-number="figure 5" --source="Gueron & Krasnov" --to=map
