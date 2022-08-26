// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Advanced Encryption Standard Cipher Blocker Chaining (AES-CBC).

This implementation uses hardware accelerated primitives.

See https://tls.mbed.org/kb/how-to/encrypt-with-aes-cbc
*/

/**
AES-CBC state for encrypting and decrypting (https://tls.mbed.org/kb/how-to/encrypt-with-aes-cbc).

To encrypt, construct an AES encryption state with $AesCbc.encrypt and
  encrypt a block with $encrypt.

To decrypt, construct and AES decryption state with $AesCbc.decrypt and
  decrypt a block with $decrypt.

Close the AES state with $close to release system resources.
*/

abstract class Aes:
  aes_ := ?

  constructor.from_subclass key/ByteArray initialization_vector/ByteArray encrypt/bool:
    aes_ = aes_init_ resource_freeing_module_ key initialization_vector encrypt
    add_finalizer this:: this.close

  /**
  Encrypts the given $cleartext.

  The size of the $cleartext must be a multiple of 16.
  Returns a byte array with the encrypted data.
  */
  encrypt cleartext/ByteArray -> ByteArray:
    return crypt_ cleartext true

  /**
  Decrypts the given $ciphertext.
  The size of the $ciphertext must be a multiple of 16.
  Returns a byte array with the decrypted data.
  */
  decrypt ciphertext/ByteArray -> ByteArray:
    return crypt_ ciphertext false

  
  abstract crypt_ input/ByteArray encrypt/bool -> ByteArray


  /** Closes this encrypter and releases associated resources. */
  close -> none:
    aes_close_ aes_
    aes_ = null
    remove_finalizer this

class AesCbc extends Aes:
  /** Deprecated. Use $AesCbc.encryptor instead. */
  constructor.encrypt key/ByteArray initialization_vector/ByteArray:
    return AesCbc.encryptor key initialization_vector

  /**
  Creates an AES state for encryption.

  The $key must be 32 secret bytes and the $initialization_vector must be 16
    random bytes. The initialization vector must not be reused.
  */
  constructor.encryptor key/ByteArray initialization_vector/ByteArray:
    super.from_subclass key initialization_vector true

  /** Deprecated. Use $AesCbc.decryptor instead. */
  constructor.decrypt key/ByteArray initialization_vector/ByteArray:
    return AesCbc.decryptor key initialization_vector

  /**
  Creates an AES state for decryption.

  The $key must be 32 secret bytes and the $initialization_vector must be 16 bytes.
  */
  constructor.decryptor key/ByteArray initialization_vector/ByteArray:
    super.from_subclass key initialization_vector false


  crypt_ input/ByteArray encrypt/bool -> ByteArray:
    from := 0
    to := input.size
    if not aes_: throw "ALREADY_CLOSED"
    result := aes_cbc_crypt_ aes_ input from to encrypt
    return result

class AesEcb extends Aes:

  /**
  Creates an AES state for encryption.

  The $key must be 32 secret bytes
    random bytes. The initialization vector must not be reused.
  */
  constructor.encryptor key/ByteArray:
    super.from_subclass key (ByteArray 16) true

  /**
  Creates an AES state for decryption.

  The $key must be 32 secret bytes
  */
  constructor.decryptor key/ByteArray:
    super.from_subclass key (ByteArray 16) false

  crypt_ input/ByteArray encrypt/bool -> ByteArray:
    from := 0
    to := input.size
    if not aes_: throw "ALREADY_CLOSED"
    result := aes_ecb_crypt_ aes_ input from to encrypt
    return result


aes_init_ group key/ByteArray initialization_vector/ByteArray encrypt/bool:
  #primitive.crypto.aes_init

aes_cbc_crypt_ aes input/ByteArray from/int to/int encrypt/bool:
  #primitive.crypto.aes_cbc_crypt

aes_ecb_crypt_ aes input/ByteArray from/int to/int encrypt/bool:
  #primitive.crypto.aes_ecb_crypt

aes_close_ aes:
  #primitive.crypto.aes_close
