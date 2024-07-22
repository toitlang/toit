// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .aes

/**
Encryptor/decryptor for the ChaCha20 stream cipher with the Poly1305 message
  authentication code.
It is often used for TLS.

An instance of this class can encrypt or decrypt one message.

See https://en.wikipedia.org/wiki/ChaCha20-Poly1305.
*/
class ChaCha20Poly1305 extends Aead_:
  static IV-SIZE ::= 12
  static TAG-SIZE ::= 16
  static BLOCK-SIZE_ ::= 16

  /**
  Initialize a ChaCha20-Poly1305 AEAD class for encryption.
  The $key must be a 32 bytes ChaCha20 key.
  The $initialization-vector must be 12 bytes of data.  It is extremely
    important that the $initialization-vector is not reused with the same key.
  The $initialization-vector must be known to the decrypting counterparty.
  */
  constructor.encryptor key/ByteArray initialization-vector/ByteArray:
    super.encryptor key initialization-vector --algorithm=ALGORITHM-CHACHA20-POLY1305

  /**
  Initialize a ChaCha20-Poly1305 AEAD class for encryption or decryption.
  The $key must be a 32 byte ChaCha20 key.
  The $initialization-vector must be 12 bytes of data, obtained from the
    encrypting counterparty.
  */
  constructor.decryptor key/ByteArray initialization-vector/ByteArray:
    super.decryptor key initialization-vector --algorithm=ALGORITHM-CHACHA20-POLY1305
