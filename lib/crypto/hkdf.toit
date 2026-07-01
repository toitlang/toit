// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .hmac
import .sha

/**
HMAC-based Extract-and-Expand Key Derivation Function (HKDF).
See RFC 5869.
*/

/**
Derives a key using HKDF-SHA256.
The $ikm is the input keying material.
The $salt is optional.
The $info is optional context information.
The $size is the desired size of the output key in bytes.
*/
hkdf-sha256 --ikm/ByteArray --salt/ByteArray?=null --info/ByteArray?=null --size/int -> ByteArray:
  return hkdf --ikm=ikm --salt=salt --info=info --size=size: HmacSha256 it

/**
Generic HKDF implementation.
The $hasher-creator is a block that creates an HMAC object for a given key.
The $size is the desired size of the output key in bytes.
*/
hkdf --ikm/ByteArray --salt/ByteArray? --info/ByteArray? --size/int [hasher-creator] -> ByteArray:
  prk := hkdf-extract --ikm=ikm --salt=salt hasher-creator
  return hkdf-expand --prk=prk --info=info --size=size hasher-creator

/**
HKDF-Extract step.
*/
hkdf-extract --ikm/ByteArray --salt/ByteArray? [hasher-creator] -> ByteArray:
  // We call the hasher-creator with an empty key to determine the hash size.
  actual-salt := salt or ByteArray (hasher-creator.call #[]).get.size
  hmac := hasher-creator.call actual-salt
  hmac.add ikm
  return hmac.get

/**
HKDF-Expand step.
The $size is the desired size of the output key in bytes.
*/
hkdf-expand --prk/ByteArray --info/ByteArray? --size/int [hasher-creator] -> ByteArray:
  hash-len := prk.size
  if size > 255 * hash-len: throw "OUT_OF_RANGE"
  
  n := (size + hash-len - 1) / hash-len
  okm := ByteArray size
  
  t := #[]
  info-bytes := info or #[]
  
  n.repeat: | i |
    hmac := hasher-creator.call prk
    hmac.add t
    hmac.add info-bytes
    hmac.add (ByteArray 1: i + 1)
    t = hmac.get
    
    copy-len := min hash-len (size - i * hash-len)
    okm.replace (i * hash-len) t 0 copy-len
    
  return okm
