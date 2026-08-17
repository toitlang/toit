// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import crypto.aes show AesEcb

import ..io as io

BLOCK-SIZE_ ::= 16
SUBKEY-CONSTANT_ ::= 0x87

/**
Computes an AES-CMAC authentication code for $data using $key.

The $key must contain 16, 24, or 32 bytes.
*/
cmac -> ByteArray
    --key/ByteArray
    data/io.Data:
  bytes := ByteArray data.byte-size
  data.write-to-byte-array bytes --at=0 0 data.byte-size

  cipher := AesEcb.encryptor key
  try:
    zero := ByteArray BLOCK-SIZE_
    encrypted-zero := cipher.encrypt zero
    first-subkey := subkey_ encrypted-zero
    second-subkey := subkey_ first-subkey
    complete := bytes.size > 0 and bytes.size % BLOCK-SIZE_ == 0
    block-count := max 1 ((bytes.size + BLOCK-SIZE_ - 1) / BLOCK-SIZE_)

    last := ByteArray BLOCK-SIZE_
    if complete:
      last.replace 0 bytes bytes.size - BLOCK-SIZE_ bytes.size
      xor_ last first-subkey
    else:
      remainder := bytes.size % BLOCK-SIZE_
      if remainder > 0:
        last.replace 0 bytes bytes.size - remainder bytes.size
      last[remainder] = 0x80
      xor_ last second-subkey

    state := ByteArray BLOCK-SIZE_
    (block-count - 1).repeat: |index|
      block := bytes[index * BLOCK-SIZE_..(index + 1) * BLOCK-SIZE_]
      xor_ block state
      state = cipher.encrypt block
    xor_ last state
    return cipher.encrypt last
  finally:
    cipher.close

subkey_ -> ByteArray
    input/ByteArray:
  output := ByteArray BLOCK-SIZE_
  carry := 0
  BLOCK-SIZE_.repeat: |offset|
    index := BLOCK-SIZE_ - 1 - offset
    value := input[index]
    output[index] = (value << 1) & 0xff | carry
    carry = value >> 7
  if input[0] & 0x80 != 0:
    output[BLOCK-SIZE_ - 1] ^= SUBKEY-CONSTANT_
  return output

xor_ -> none
    target/ByteArray
    other/ByteArray:
  target.size.repeat: |index| target[index] ^= other[index]
