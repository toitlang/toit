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

ALGORITHM_AES_GCM_SHA256 ::= 0

/**
Encryptor/decryptor for Galois/Counter Mode of AES, an encryption mode that is
  often used for TLS.

An instance of this class can encrypt or decrypt one message.

See https://en.wikipedia.org/wiki/Galois/Counter_Mode.
*/
class AesGcm:
  gcm_aes_ := ?
  initialization_vector_ /ByteArray := ?
  buffer_ /ByteArray? := null
  size /int := 0

  static IV_SIZE ::= 12
  static TAG_SIZE ::= 16
  static BLOCK_SIZE_ ::= 16

  /**
  Initialize a AesGcm AEAD class for encryption.
  The $key must be a 16, 24, or 32 bytes of AES key.
  The $initialization_vector must be 12 bytes of data.  It is extremely
    important that the initialization_vector is not reused with the same key.
    The initialization_vector must be known to the decrypting counterparty.
  */
  constructor.encryptor key/ByteArray initialization_vector/ByteArray --algorithm/int=ALGORITHM_AES_GCM_SHA256:
    gcm_aes_ = gcm_init_ resource_freeing_module_ key algorithm true
    initialization_vector_ = initialization_vector
    add_finalizer this:: this.close

  /**
  Initialize a AesGcm AEAD class for encryption or decryption.
  The $key must be a 16, 24, or 32 bit AES key.
  The $initialization_vector must be 12 bytes of data, obtained from the
    encrypting counterparty.
  */
  constructor.decryptor key/ByteArray initialization_vector/ByteArray --algorithm/int=ALGORITHM_AES_GCM_SHA256:
    gcm_aes_ = gcm_init_ resource_freeing_module_ key algorithm false
    initialization_vector_ = initialization_vector
    add_finalizer this:: this.close

  /**
  Encrypts the given $plain_text.
  The plain_text must be a ByteArray or a string.
  If provided, the $authenticated_data is data that takes part in the
    verification tag, but does not get encrypted.
  Returns the encrypted plain_text.  The verification tag, 16 bytes, is
    appended to the result.
  This method is equivalent to calling $start, $add, and $finish, and
    therefore it closes this instance.
  */
  encrypt plain_text --authenticated_data="" -> ByteArray:
    if not gcm_aes_: throw "ALREADY_CLOSED"

    result := ByteArray plain_text.size + TAG_SIZE

    gcm_start_message_ gcm_aes_ authenticated_data initialization_vector_
    number_of_bytes /int := gcm_add_ gcm_aes_ plain_text result
    if number_of_bytes != (round_down plain_text.size BLOCK_SIZE_): throw "UNKNOWN_ERROR"
    rest_and_tag := gcm_finish_ gcm_aes_
    if number_of_bytes + rest_and_tag.size != plain_text.size + TAG_SIZE: throw "UNKNOWN_ERROR"
    result.replace number_of_bytes rest_and_tag
    close
    return result

  /**
  Decrypts the given $cipher_text.
  The $verification_tag, 16 bytes, is checked and an exception is thrown if it
    fails.
  If the verification_tag is not provided, it is assumed to be appended to the
    $cipher_text.
  This method is equivalent to calling $start, $add, and $verify, and
    therefore it closes this instance.
  */
  decrypt cipher_text/ByteArray --authenticated_data="" --verification_tag/ByteArray?=null -> ByteArray:
    if not gcm_aes_: throw "ALREADY_CLOSED"

    if not verification_tag:
      edge := cipher_text.size - 16
      verification_tag = cipher_text[edge..]
      cipher_text = cipher_text[..edge]

    gcm_start_message_ gcm_aes_ authenticated_data initialization_vector_
    result := ByteArray cipher_text.size
    number_of_bytes /int := gcm_add_ gcm_aes_ cipher_text result
    if number_of_bytes != (round_down cipher_text.size BLOCK_SIZE_): throw "UNKNOWN_ERROR"

    check := gcm_verify_ gcm_aes_ verification_tag result[number_of_bytes..]
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
  start --authenticated_data="" -> none:
    gcm_start_message_ gcm_aes_ authenticated_data initialization_vector_

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
      number_of_bytes := gcm_add_ gcm_aes_ data buffer_
      if number_of_bytes:
        result := buffer_[0..number_of_bytes]
        buffer_ = data
        return result
    // Output buffer was too small.  Make one that is certainly big enough.
    result := ByteArray
        round_up data.size BLOCK_SIZE_
    number_of_bytes /int := gcm_add_ gcm_aes_ data result
    if not buffer_ or data.size > buffer_.size: buffer_ = data
    return result[..number_of_bytes]

  /**
  Finishes encrypting.
  Can be called after $start and $add.
  Returns a two-element list with the last encrypted bytes and the verification
    tag.  The last encrypted bytes will be a zero length ByteArray if the
    size of the plaintext was a multiple of 16.
  Closes this instance.
  */
  finish -> List:
    result := gcm_finish_ gcm_aes_
    close
    cut := result.size - BLOCK_SIZE_
    assert: cut == size % BLOCK_SIZE_
    return [result[..cut], result[cut..]]

  /**
  Finishes decrypting.
  Can be called after $start and $add.
  Throws an exception if the 16 byte $verification_tag does not match the
    decrypted data.
  It is vital that the decrypted data is not used in any way before this method
    has been called.
  It is vital that if this method throws an exception, the previously decrypted
    data is not used.
  Returns the last few bytes of the decrypted data.  This is an empty ByteArray
    if the size of the ciphertext was a multiple of 16.
  Closes this instance.
  */
  verify verification_tag/ByteArray -> ByteArray:
    result := ByteArray
        size & (BLOCK_SIZE_ - 1)
    check := gcm_verify_ gcm_aes_ verification_tag result
    close
    if check != 0: throw "INVALID_SIGNATURE"
    return result

  /** Closes this encrypter/decrypter and releases associated resources. */
  close -> none:
    if not gcm_aes_: return
    gcm_close_ gcm_aes_
    gcm_aes_ = null
    remove_finalizer this

gcm_init_ group key/ByteArray algorithm/int encrypt/bool:
  #primitive.crypto.gcm_init

gcm_close_ gcm:
  #primitive.crypto.gcm_close

gcm_start_message_ gcm authenticated_data initialization_vector/ByteArray -> none:
  #primitive.crypto.gcm_start_message

/**
If the result byte array was big enough, returns a Smi to indicate how much
  data was placed in it.
If the result byte array was not big enough, returns null.  In this case no
  data was consumed.
*/
gcm_add_ gcm data result/ByteArray -> int?:
  #primitive.crypto.gcm_add

/**
Returns the last ciphertext bytes and the tag, concatenated.
*/
gcm_finish_ gcm -> ByteArray:
  #primitive.crypto.gcm_finish

/**
The rest_of_decrypted_data should be at least the size of the added data %
  BLOCK_SIZE_.
*/
gcm_verify_ gcm verification_tag/ByteArray rest_of_decrypted_data/ByteArray -> int:
  #primitive.crypto.gcm_verify

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
