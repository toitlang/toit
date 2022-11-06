// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Base class for the hardware accelerated Advanced Encryption Standard (AES).

See https://en.wikipedia.org/wiki/Advanced_Encryption_Standard.

AES has multiple different modes it can use.
  The ones implemented here are CBC and ECB.
*/
abstract class Aes:
  aes_ := ?

  /**
  Initialize an Aes class from a subclass.
  If the $initialization_vector is empty, then AES ECB mode is selected.
  If the $initialization_vector has length 16, then AES CBC mode is selected.
  */
  constructor.initialize_ key/ByteArray initialization_vector/ByteArray --encrypt/bool:
    aes_ = aes_init_ resource_freeing_module_ key initialization_vector encrypt
    add_finalizer this:: this.close

  /**
  Encrypts the given $cleartext.

  The size of the $cleartext must be a multiple of 16.
  Returns a byte array with the encrypted data.
  */
  encrypt cleartext/ByteArray -> ByteArray:
    if not aes_: throw "ALREADY_CLOSED"
    return crypt_ cleartext --encrypt

  /**
  Decrypts the given $ciphertext.

  The size of the $ciphertext must be a multiple of 16.
  Returns a byte array with the decrypted data.
  */
  decrypt ciphertext/ByteArray -> ByteArray:
    if not aes_: throw "ALREADY_CLOSED"
    return crypt_ ciphertext --no-encrypt

  /**
  Calls the associated primitive for the selected AES mode.
  */
  abstract crypt_ input/ByteArray --encrypt/bool -> ByteArray

  /** Closes this encrypter and releases associated resources. */
  close -> none:
    if not aes_: return
    close_aes_
    aes_ = null
    remove_finalizer this

  /**
  Calls the associated primitive for the selected AES mode.
  */
  abstract close_aes_ -> none

/**
Advanced Encryption Standard Cipher Blocker Chaining (AES-CBC).

This implementation uses hardware accelerated primitives.

See https://tls.mbed.org/kb/how-to/encrypt-with-aes-cbc

AES-CBC state for encrypting and decrypting (https://tls.mbed.org/kb/how-to/encrypt-with-aes-cbc).

To encrypt, construct an AES encryption state with $AesCbc.encryptor and
  encrypt a block with $encrypt.

To decrypt, construct and AES decryption state with $AesCbc.decryptor and
  decrypt a block with $decrypt.

Close the AES state with $close to release system resources.
*/
class AesCbc extends Aes:
  /** Deprecated. Use $AesCbc.encryptor instead. */
  constructor.encrypt key/ByteArray initialization_vector/ByteArray:
    return AesCbc.encryptor key initialization_vector

  /**
  Creates an AES-CBC state for encryption.

  The $key must be 16, 24 or 32 secret bytes and the
    $initialization_vector must be 16 random bytes.
  */
  constructor.encryptor key/ByteArray initialization_vector/ByteArray:
    super.initialize_ key initialization_vector --encrypt

  /** Deprecated. Use $AesCbc.decryptor instead. */
  constructor.decrypt key/ByteArray initialization_vector/ByteArray:
    return AesCbc.decryptor key initialization_vector

  /**
  Creates an AES-CBC state for decryption.

  The $key must be 16, 24 or 32 secret bytes and the
    $initialization_vector must be 16 bytes.
  */
  constructor.decryptor key/ByteArray initialization_vector/ByteArray:
    super.initialize_ key initialization_vector --no-encrypt

  /** See $super. */
  crypt_ input/ByteArray --encrypt/bool -> ByteArray:
    return aes_cbc_crypt_ aes_ input encrypt

  /** See $super. */
  close_aes_ -> none:
    aes_cbc_close_ aes_

/**
Advanced Encryption Standard Electronic codebook (AES-ECB).

# Warning

This encryption mode is no longer recommended, due to flaws
  in its security.  Use only for interfacing with legacy
  systems that require it.

This implementation uses hardware accelerated primitives.

AES-ECB state for encrypting and decrypting

To encrypt, construct an AES encryption state with $AesEcb.encryptor and
  encrypt a block with $encrypt.

To decrypt, construct and AES decryption state with $AesEcb.decryptor and
  decrypt a block with $decrypt.

Close the AES state with $close to release system resources.
*/
class AesEcb extends Aes:

  /**
  Creates an AES-ECB state for encryption.

  The $key must be either 16, 24 or 32 secret bytes.
  */
  constructor.encryptor key/ByteArray:
    super.initialize_ key (ByteArray 0) --encrypt

  /**
  Creates an AES-ECB state for decryption.

  The $key must be either 16, 24 or 32 secret bytes.
  */
  constructor.decryptor key/ByteArray:
    super.initialize_ key (ByteArray 0) --no-encrypt

  /** See $super. */
  crypt_ input/ByteArray --encrypt/bool -> ByteArray:
    from := 0
    to := input.size
    return aes_ecb_crypt_ aes_ input encrypt

  /** See $super. */
  close_aes_ -> none:
    aes_ecb_close_ aes_



aes_init_ group key/ByteArray initialization_vector/ByteArray? encrypt/bool:
  #primitive.crypto.aes_init

aes_cbc_crypt_ aes input/ByteArray encrypt/bool:
  #primitive.crypto.aes_cbc_crypt

aes_ecb_crypt_ aes input/ByteArray encrypt/bool:
  #primitive.crypto.aes_ecb_crypt

aes_cbc_close_ aes:
  #primitive.crypto.aes_cbc_close

aes_ecb_close_ aes:
  #primitive.crypto.aes_ecb_close
