// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..io as io

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
  If the $initialization-vector is empty, then AES ECB mode is selected.
  If the $initialization-vector has length 16, then AES CBC mode is selected.
  */
  constructor.initialize_ key/ByteArray initialization-vector/ByteArray --encrypt/bool:
    aes_ = aes-init_ resource-freeing-module_ key initialization-vector encrypt
    add-finalizer this:: this.close

  /**
  Encrypts the given $plaintext.

  The size of the $plaintext must be a multiple of 16.
  Returns a byte array with the encrypted data.
  */
  encrypt plaintext/ByteArray -> ByteArray:
    if not aes_: throw "ALREADY_CLOSED"
    return crypt_ plaintext --encrypt

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
    close-aes_
    aes_ = null
    remove-finalizer this

  /**
  Calls the associated primitive for the selected AES mode.
  */
  abstract close-aes_ -> none

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
  /**
  Creates an AES-CBC state for encryption.

  The $key must be 16, 24 or 32 secret bytes and the
    $initialization-vector must be 16 random bytes.
  */
  constructor.encryptor key/ByteArray initialization-vector/ByteArray:
    super.initialize_ key initialization-vector --encrypt

  /**
  Creates an AES-CBC state for decryption.

  The $key must be 16, 24 or 32 secret bytes and the
    $initialization-vector must be 16 bytes.
  */
  constructor.decryptor key/ByteArray initialization-vector/ByteArray:
    super.initialize_ key initialization-vector --no-encrypt

  /** See $super. */
  crypt_ input/ByteArray --encrypt/bool -> ByteArray:
    return aes-cbc-crypt_ aes_ input encrypt

  /** See $super. */
  close-aes_ -> none:
    aes-cbc-close_ aes_

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
    return aes-ecb-crypt_ aes_ input encrypt

  /** See $super. */
  close-aes_ -> none:
    aes-ecb-close_ aes_

ALGORITHM-AES-GCM ::= 0
ALGORITHM-CHACHA20-POLY1305 ::= 1

/**
Encryptor/decryptor for Galois/Counter Mode of AES, an encryption mode that is
  often used for TLS.

An instance of this class can encrypt or decrypt one message.

See https://en.wikipedia.org/wiki/Galois/Counter_Mode.
*/
class AesGcm extends Aead_:
  static IV-SIZE ::= 12
  static TAG-SIZE ::= 16
  static BLOCK-SIZE_ ::= 16

  /**
  Initialize a AesGcm AEAD class for encryption.
  The $key must be 16, 24, or 32 bytes of AES key.
  The $initialization-vector must be 12 bytes of data.  It is extremely
    important that the $initialization-vector is not reused with the same key.
  The $initialization-vector must be known to the decrypting counterparty.
  */
  constructor.encryptor key/ByteArray initialization-vector/ByteArray:
    super.encryptor key initialization-vector --algorithm=ALGORITHM-AES-GCM

  /**
  Initialize a AesGcm AEAD class for encryption or decryption.
  The $key must be 16, 24, or 32 bytes of AES key.
  The $initialization-vector must be 12 bytes of data, obtained from the
    encrypting counterparty.
  */
  constructor.decryptor key/ByteArray initialization-vector/ByteArray:
    super.decryptor key initialization-vector --algorithm=ALGORITHM-AES-GCM

/**
Encryptor/decryptor for authenicated encryption with AEAD, an encryption mode
  that is often used for TLS.
Subclasses include $AesGcm and ChaCha20Poly1305.

An instance of this class can encrypt or decrypt one message.

See https://en.wikipedia.org/wiki/Authenticated_encryption
*/
class Aead_:
  aead_ := ?
  initialization-vector_ /ByteArray := ?
  buffer_ /ByteArray? := null
  size /int := 0

  static IV-SIZE ::= 12
  static TAG-SIZE ::= 16
  static BLOCK-SIZE_ ::= 16

  /**
  Initialize an AEAD class for encryption.
  The $key must be of an appropriate size for the algorithm.
  The $initialization-vector must be 12 bytes of data.  It is extremely
    important that the initialization_vector is not reused with the same key.
    The initialization_vector must be known to the decrypting counterparty.
  The $algorithm must be $ALGORITHM-AES-GCM or ALGORITHM_CHACHA20_POLY1305.
  */
  constructor.encryptor key/ByteArray initialization-vector/ByteArray --algorithm/int:
    aead_ = aead-init_ resource-freeing-module_ key algorithm true
    initialization-vector_ = initialization-vector
    add-finalizer this:: this.close

  /**
  Initialize an AEAD class for decryption.
  The $key must be of an appropriate size for the algorithm.
  The $initialization-vector must be 12 bytes of data, obtained from the
    encrypting counterparty.
  The $algorithm must be $ALGORITHM-AES-GCM or ALGORITHM_CHACHA20_POLY1305.
  */
  constructor.decryptor key/ByteArray initialization-vector/ByteArray --algorithm/int:
    aead_ = aead-init_ resource-freeing-module_ key algorithm false
    initialization-vector_ = initialization-vector
    add-finalizer this:: this.close

  /**
  Encrypts the given $plaintext.
  The plaintext must be a ByteArray or a string.
  If provided, the $authenticated-data is data that takes part in the
    verification tag, but does not get encrypted.
  Returns the encrypted plaintext.  The verification tag, 16 bytes, is
    appended to the result.
  This method is equivalent to calling $start, $add, and $finish, and
    therefore it closes this instance.
  */
  encrypt plaintext/io.Data --authenticated-data="" -> ByteArray:
    if not aead_: throw "ALREADY_CLOSED"

    result := ByteArray plaintext.byte-size + TAG-SIZE

    aead-start-message_ aead_ authenticated-data initialization-vector_
    number-of-bytes /int := aead-add_ aead_ plaintext result
    if number-of-bytes != (round-down plaintext.byte-size BLOCK-SIZE_): throw "UNKNOWN_ERROR"
    rest-and-tag := aead-finish_ aead_
    if number-of-bytes + rest-and-tag.size != plaintext.byte-size + TAG-SIZE: throw "UNKNOWN_ERROR"
    result.replace number-of-bytes rest-and-tag
    close
    return result

  /**
  Decrypts the given $ciphertext.
  The $verification-tag, 16 bytes, is checked and an exception is thrown if it
    fails.
  If the $verification-tag is not provided, it is assumed to be appended to the
    $ciphertext.
  This method is equivalent to calling $start, $add, and $verify, and
    therefore it closes this instance.
  */
  decrypt ciphertext/ByteArray --authenticated-data="" --verification-tag/ByteArray?=null -> ByteArray:
    if not aead_: throw "ALREADY_CLOSED"

    if not verification-tag:
      edge := ciphertext.size - 16
      verification-tag = ciphertext[edge..]
      ciphertext = ciphertext[..edge]

    aead-start-message_ aead_ authenticated-data initialization-vector_
    result := ByteArray ciphertext.size
    number-of-bytes /int := aead-add_ aead_ ciphertext result
    if number-of-bytes != (round-down ciphertext.size BLOCK-SIZE_): throw "UNKNOWN_ERROR"

    check := aead-verify_ aead_ verification-tag result[number-of-bytes..]
    if check != 0:
      throw "INVALID_SIGNATURE"

    return result

  /**
  Starts an encryption or decryption.
  After calling this method, the $add method can be used to encrypt or decrypt
    a ByteArray.
  When decrypting, it is vital that the decrypted data is not used in any way
    before the verification tag has been verified with a call to $verify.
  */
  start --authenticated-data="" -> none:
    aead-start-message_ aead_ authenticated-data initialization-vector_

  /**
  Encrypts or decrypts some data.
  Can be called after calling $start.
  The $data argument is consumed by this operation:  After this call, the given
    ByteArray can no longer be used.
  The returned ByteArray can be regarded as fresh, though it may be one of the
    ByteArrays previously passed to this function.
  When decrypting it is vital that the decrypted data is not used in any way
    before the verification tag has been verified with a call to $verify.
  */
  add data/ByteArray -> ByteArray:
    size += data.size
    if buffer_:
      number-of-bytes := aead-add_ aead_ data buffer_
      if number-of-bytes:
        result := buffer_[0..number-of-bytes]
        buffer_ = data
        return result
    // Output buffer was too small.  Make one that is certainly big enough.
    result := ByteArray
        round-up data.size BLOCK-SIZE_
    number-of-bytes /int := aead-add_ aead_ data result
    if not buffer_ or data.size > buffer_.size: buffer_ = data
    return result[..number-of-bytes]

  /**
  Finishes encrypting.
  Can be called after $start and $add.
  Returns a concatenation of the last encrypted bytes and the verification
    tag.  The last encrypted bytes will have zero length if the size of the
    plaintext was a multiple of 16.
  Closes this instance.
  */
  finish -> ByteArray:
    result := aead-finish_ aead_
    close
    return result

  /**
  Finishes decrypting.
  Can be called after $start and $add.
  Throws an exception if the 16 byte $verification-tag does not match the
    decrypted data.
  It is vital that the decrypted data is not used in any way before this method
    has been called.
  It is vital that if this method throws an exception, the previously decrypted
    data is not used.
  Returns the last few bytes of the decrypted data.  This is an empty ByteArray
    if the size of the ciphertext was a multiple of 16.
  Closes this instance.
  */
  verify verification-tag/ByteArray -> ByteArray:
    result := ByteArray
        size & (BLOCK-SIZE_ - 1)
    check := aead-verify_ aead_ verification-tag result
    close
    if check != 0: throw "INVALID_SIGNATURE"
    return result

  /** Closes this encrypter/decrypter and releases associated resources. */
  close -> none:
    if not aead_: return
    aead-close_ aead_
    aead_ = null
    remove-finalizer this

aead-init_ group key/ByteArray algorithm/int encrypt/bool:
  #primitive.crypto.aead-init

aead-close_ aead:
  #primitive.crypto.aead-close

aead-start-message_ aead authenticated-data initialization-vector/ByteArray -> none:
  #primitive.crypto.aead-start-message

/**
If the result byte array was big enough, returns a Smi to indicate how much
  data was placed in it.
If the result byte array was not big enough, returns null.  In this case no
  data was consumed.
*/
aead-add_ aead data/io.Data result/ByteArray -> int?:
  #primitive.crypto.aead-add:
    return io.primitive-redo-io-data_ it data: | bytes |
      aead-add_ aead bytes result

/**
Returns the last ciphertext bytes and the tag, concatenated.
*/
aead-finish_ aead -> ByteArray:
  #primitive.crypto.aead-finish

/**
The $rest-of-decrypted-data should be at least the size of the added data %
  BLOCK_SIZE_.
*/
aead-verify_ aead verification-tag/ByteArray rest-of-decrypted-data/ByteArray -> int:
  #primitive.crypto.aead-verify

aes-init_ group key/ByteArray initialization-vector/ByteArray? encrypt/bool:
  #primitive.crypto.aes-init

aes-cbc-crypt_ aes input/ByteArray encrypt/bool:
  #primitive.crypto.aes-cbc-crypt

aes-ecb-crypt_ aes input/ByteArray encrypt/bool:
  #primitive.crypto.aes-ecb-crypt

aes-cbc-close_ aes:
  #primitive.crypto.aes-cbc-close

aes-ecb-close_ aes:
  #primitive.crypto.aes-ecb-close
