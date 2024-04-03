// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum
import ..io as io

/**
Secure Hash Algorithm (SHA-224, SHA-256, SHA-384, and SHA-512).

This implementation uses hardware accelerated primitives.

See https://en.wikipedia.org/wiki/SHA-256.
*/

/**
Computes the SHA224 hash of the given $data.
*/
sha224 data/io.Data from/int=0 to/int=data.byte-size -> ByteArray:
  return checksum Sha224 data from to

/**
Computes the SHA256 hash of the given $data.
*/
sha256 data/io.Data from/int=0 to/int=data.byte-size -> ByteArray:
  return checksum Sha256 data from to

/**
Computes the SHA384 hash of the given $data.

The $data must be a string or byte array.
*/
sha384 data/io.Data from/int=0 to/int=data.byte-size -> ByteArray:
  return checksum Sha384 data from to

/**
Computes the SHA512 hash of the given $data.

The $data must be a string or byte array.
*/
sha512 data/io.Data from/int=0 to/int=data.byte-size -> ByteArray:
  return checksum Sha512 data from to

/** SHA-224+ hash state. */
class Sha_ extends Checksum:
  sha-state_ := ?

  /** Constructs an empty SHA-224+ state */
  constructor bits/int:
    sha-state_ = sha-start_ resource-freeing-module_ bits
    add-finalizer this:: finalize-checksum_ this

  constructor.private_ .sha-state_:
    add-finalizer this:: finalize-checksum_ this

  /** See $super. */
  add data/io.Data from/int to/int -> none:
    sha-add_ sha-state_ data from to

  /**
  See $super.

  Calculates the SHA224+ hash.
  */
  get -> ByteArray:
    remove-finalizer this
    return sha-get_ sha-state_

  clone -> Sha_:
    return Sha_.private_ (sha-clone_ sha-state_)

/** SHA-224 hash state. */
class Sha224 extends Sha_:
  static BLOCK-SIZE ::= 64
  constructor:
    super 224

/** SHA-256 hash state. */
class Sha256 extends Sha_:
  static BLOCK-SIZE ::= 64
  constructor:
    super 256

/** SHA-384 hash state. */
class Sha384 extends Sha_:
  static BLOCK-SIZE ::= 128
  constructor:
    super 384

/** SHA-512 hash state. */
class Sha512 extends Sha_:
  static BLOCK-SIZE ::= 128
  constructor:
    super 512

// Gets a new empty Sha224+ object.
sha-start_ group bits/int:
  #primitive.crypto.sha-start

// Clones a Sha224+ object.
sha-clone_ sha:
  #primitive.crypto.sha-clone

// Adds a UTF-8 string or a byte array to the sha224+ hash.
sha-add_ sha data/io.Data from/int to/int -> none:
  #primitive.crypto.sha-add:
    io.primitive-redo-chunked-io-data_ it data from to: | bytes |
      sha-add_ sha bytes 0 bytes.size

// Rounds off a sha224+ hash and returns the hash.
sha-get_ sha -> ByteArray:
  #primitive.crypto.sha-get
