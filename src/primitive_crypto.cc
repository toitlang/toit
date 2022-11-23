// Copyright (C) 2018 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "aes.h"
#include "objects.h"
#include "objects_inline.h"
#include "primitive.h"
#include "process.h"
#include "gcm_crypto.h"
#include "resource.h"
#include "sha1.h"
#include "sha256.h"
#include "siphash.h"

namespace toit {

MODULE_IMPLEMENTATION(crypto, MODULE_CRYPTO)

PRIMITIVE(sha1_start) {
  ARGS(SimpleResourceGroup, group);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  Sha1* sha1 = _new Sha1(group);
  if (!sha1) MALLOC_FAILED;
  proxy->set_external_address(sha1);
  return proxy;
}

PRIMITIVE(sha1_add) {
  ARGS(Sha1, sha1, Blob, data, int, from, int, to);

  if (from < 0 || from > to || to > data.length()) OUT_OF_RANGE;
  sha1->add(data.address() + from, to - from);
  return process->program()->null_object();
}

PRIMITIVE(sha1_get) {
  ARGS(Sha1, sha1);
  ByteArray* result = process->allocate_byte_array(20);
  if (result == null) ALLOCATION_FAILED;
  uint8 hash[20];
  sha1->get_hash(hash);
  memcpy(ByteArray::Bytes(result).address(), hash, 20);
  sha1->resource_group()->unregister_resource(sha1);
  sha1_proxy->clear_external_address();
  return result;
}

PRIMITIVE(sha256_start) {
  ARGS(SimpleResourceGroup, group)
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  Sha256* sha256 = _new Sha256(group);
  if (!sha256) MALLOC_FAILED;
  proxy->set_external_address(sha256);
  return proxy;
}

PRIMITIVE(sha256_add) {
  ARGS(Sha256, sha256, Blob, data, int, from, int, to);
  if (!sha256) INVALID_ARGUMENT;
  if (from < 0 || from > to || to > data.length()) OUT_OF_RANGE;
  sha256->add(data.address() + from, to - from);
  return process->program()->null_object();
}

PRIMITIVE(sha256_get) {
  ARGS(Sha256, sha256);
  ByteArray* result = process->allocate_byte_array(Sha256::HASH_LENGTH);
  if (result == null) ALLOCATION_FAILED;
  ByteArray::Bytes bytes(result);
  sha256->get(bytes.address());
  sha256->resource_group()->unregister_resource(sha256);
  sha256_proxy->clear_external_address();
  return result;
}

PRIMITIVE(siphash_start) {
  ARGS(SimpleResourceGroup, group, Blob, key, int, output_length, int, c_rounds, int, d_rounds);
  if (output_length != 8 && output_length != 16) INVALID_ARGUMENT;
  if (key.length() < 16) INVALID_ARGUMENT;
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  Siphash* siphash = _new Siphash(group, key.address(), output_length, c_rounds, d_rounds);
  if (!siphash) MALLOC_FAILED;
  proxy->set_external_address(siphash);
  return proxy;
}

PRIMITIVE(siphash_add) {
  ARGS(Siphash, siphash, Blob, data, int, from, int, to);

  if (from < 0 || from > to || to > data.length()) OUT_OF_RANGE;
  siphash->add(data.address() + from, to - from);
  return process->program()->null_object();
}

PRIMITIVE(siphash_get) {
  ARGS(Siphash, siphash);
  ByteArray* result = process->allocate_byte_array(siphash->output_length());
  if (result == null) ALLOCATION_FAILED;
  siphash->get_hash(ByteArray::Bytes(result).address());
  siphash->resource_group()->unregister_resource(siphash);
  siphash_proxy->clear_external_address();
  return result;
}

GcmContext::~GcmContext(){
  mbedtls_gcm_free(&context_);
}

PRIMITIVE(gcm_init) {
  ARGS(SimpleResourceGroup, group, Blob, key, int, algorithm, bool, encrypt);
  if (!(0 <= algorithm && algorithm < NUMBER_OF_ALGORITHM_TYPES)) {
    INVALID_ARGUMENT;
  }

  if (key.length() != 16 && key.length() != 24 && key.length() != 32) INVALID_ARGUMENT;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  mbedtls_cipher_id_t mbedtls_cipher;

  if (algorithm == ALGORITHM_AES_GCM_SHA256) {
    mbedtls_cipher = MBEDTLS_CIPHER_ID_AES;
  } else {
    INVALID_ARGUMENT;
  }

  GcmContext* gcm_context = _new GcmContext(
      group,
      mbedtls_cipher,
      encrypt);

  if (!gcm_context) {
    MALLOC_FAILED;
  }

  int err = mbedtls_gcm_setkey(gcm_context->gcm_context(), mbedtls_cipher, key.address(), key.length() * BYTE_BIT_SIZE);
  if (err != 0) {
    group->unregister_resource(gcm_context);
    return tls_error(null, process, err);
  }
  
  proxy->set_external_address(gcm_context);
  return proxy;
}

PRIMITIVE(gcm_close) {
  ARGS(GcmContext, context);
  context->resource_group()->unregister_resource(context);
  context_proxy->clear_external_address();
  return process->program()->null_object();
}

// Start the encryption of a message.  Takes a 12 byte nonce.
// It is vital that the nonce is not reused with the same key.
// Internally the gcm_* primitives will add 4 more bytes of block counter,
//   starting at 1, to form a 16 byte IV.
//
// TLS:
// In TLS each record corresponds to one message, and it is the responsiblity
//   of the TLS layer to supply a fresh nonce per message.
// As described in RFC5288 section 3, the first 4 bytes of the nonce are kept
//   secret, and the next 8 bytes are transmitted along with each record.
// In order to avoid reuse of the nonce, the explicit part is normally counted
//   up by one for each record that is encrypted.  This means that this part of
//   the nonce corresponds to the sequence number of the record.
PRIMITIVE(gcm_start_message) {
  ARGS(GcmContext, context, Blob, authenticated_data, Blob, nonce);
  if (context->currently_generating_message() != 0) INVALID_ARGUMENT;
  if (nonce.length() != GcmContext::NONCE_SIZE) INVALID_ARGUMENT;
  context->set_currently_generating_message();
  int mode = context->is_encrypt() ? MBEDTLS_GCM_ENCRYPT : MBEDTLS_GCM_DECRYPT;
  int result = mbedtls_gcm_starts(
      context->gcm_context(),
      mode,
      nonce.address(),
      nonce.length(),
      authenticated_data.address(),
      authenticated_data.length());
  if (result != 0) return tls_error(null, process, result);

  return process->program()->null_object();
}

/**
If the out byte array was big enough, returns a Smi to indicate how much
  data was placed in it.
If the out byte array was not big enough, returns null.  In this case no
  data was consumed.
*/
PRIMITIVE(gcm_add) {
  ARGS(GcmContext, context, Blob, in, MutableBlob, out);
  if (!context->currently_generating_message()) INVALID_ARGUMENT;

  static const int BLOCK_SIZE = GcmContext::BLOCK_SIZE;

  uint8*       out_address = out.address();
  const uint8* in_address  = in.address();
  int          in_length   = in.length();

  int output_length = Utils::round_down(
      context->number_of_buffered_bytes() + in_length,
      BLOCK_SIZE);
  if (output_length > out.length()) {
    // Output byte array not big enough.
    return process->program()->null_object();
  }

  int buffered = context->number_of_buffered_bytes();
  // We cache buffered above because the next line changes the result of
  // context->number_of_buffered_bytes().
  context->increment_length(in.length());

  if (buffered != 0) {
    // Copy into the temporary buffer in the context.
    const int to_copy = Utils::min(
        BLOCK_SIZE - buffered,
        in_length);
    memcpy(context->buffered_data() + buffered, in_address, to_copy);
    in_address += to_copy;
    in_length -= to_copy;
    if (buffered + to_copy == BLOCK_SIZE) {
      // We filled the temporary buffer.
      mbedtls_gcm_update(
          context->gcm_context(),
          BLOCK_SIZE,
          context->buffered_data(),
          out_address);
      out_address += BLOCK_SIZE;
    }
  }

  int to_process = Utils::round_down(in_length, BLOCK_SIZE);
  ASSERT(out_address + to_process <= out.address() + out.length());

  mbedtls_gcm_update(
      context->gcm_context(),
      to_process,
      in_address,
      out_address);

  in_address  += to_process;
  in_length   -= to_process;
  out_address += to_process;

  memcpy(context->buffered_data(), in_address, in_length);

  // Return the amount of data output.
  return Smi::from(out_address - out.address());
}

PRIMITIVE(gcm_get_tag_size) {
  ARGS(GcmContext, context);
  return Smi::from(GcmContext::TAG_SIZE);
}

/**
Ends the encryption of a message.
Returns the last data encrypted, followed by the encryption tag
*/
PRIMITIVE(gcm_finish) {
  ARGS(GcmContext, context);
  if (!context->is_encrypt()) INVALID_ARGUMENT;
  if (!context->currently_generating_message()) INVALID_ARGUMENT;
  int rest = context->number_of_buffered_bytes();
  ByteArray* result = process->allocate_byte_array(rest + GcmContext::TAG_SIZE);
  if (result == null) ALLOCATION_FAILED;
  ByteArray::Bytes result_bytes(result);

  int ok = mbedtls_gcm_update(
    context->gcm_context(),
    rest,
    context->buffered_data(),
    result_bytes.address());
  if (ok != 0) return tls_error(null, process, ok);

  ok = mbedtls_gcm_finish(
      context->gcm_context(),
      result_bytes.address() + rest,
      result_bytes.length() - rest);
  if (ok != 0) return tls_error(null, process, ok);

  return result;
}

/**
Ends the decryption of a message.
Returns zero if the tag matches the calculated one.
Returns non-zero if the tag does not match.
*/
PRIMITIVE(gcm_verify) {
  ARGS(GcmContext, context, Blob, verification_tag, MutableBlob, rest);
  if (context->is_encrypt()) INVALID_ARGUMENT;
  if (verification_tag.length() != GcmContext::TAG_SIZE) INVALID_ARGUMENT;
  if (rest.length() < context->number_of_buffered_bytes()) INVALID_ARGUMENT;

  int ok = mbedtls_gcm_update(
    context->gcm_context(),
    context->number_of_buffered_bytes(),
    context->buffered_data(),
    rest.address());
  if (ok != 0) return tls_error(null, process, ok);

  uint8 calculated_tag[GcmContext::TAG_SIZE];
  ok = mbedtls_gcm_finish(
      context->gcm_context(),
      calculated_tag,
      GcmContext::TAG_SIZE);
  if (ok != 0) {
    return tls_error(null, process, ok);
  }
  uint8 zero = 0;
  // Constant time calculation.
  for (int i = 0; i < GcmContext::TAG_SIZE; i++) {
    zero |= calculated_tag[i] ^ verification_tag.address()[i];
  }
  return Smi::from(zero);
}

AesContext::AesContext(
    SimpleResourceGroup* group,
    const Blob* key,
    bool encrypt) : SimpleResource(group) {
  mbedtls_aes_init(&context_);
  if (encrypt) {
    mbedtls_aes_setkey_enc(&context_, key->address(), key->length() * BYTE_BIT_SIZE);
  } else {
    mbedtls_aes_setkey_dec(&context_, key->address(), key->length() * BYTE_BIT_SIZE);
  }
}

AesContext::~AesContext() {
  mbedtls_aes_free(&context_);
}

AesCbcContext::AesCbcContext(
    SimpleResourceGroup* group,
    const Blob* key,
    const uint8* iv,
    bool encrypt) : AesContext(group, key, encrypt) {
  memcpy(iv_, iv, sizeof(iv_));
}

PRIMITIVE(aes_init) {
  ARGS(SimpleResourceGroup, group, Blob, key, Blob, iv, bool, encrypt);

  if (key.length() != AesContext::AES_BLOCK_SIZE * 2 &&
      key.length() != AesContext::AES_BLOCK_SIZE + 8 &&
      key.length() != AesContext::AES_BLOCK_SIZE) {
    INVALID_ARGUMENT;
  }

  if (iv.length() != AesContext::AES_BLOCK_SIZE &&
      iv.length() != 0) {
    INVALID_ARGUMENT;
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  if (iv.length() == 0) {
    AesContext* aes = _new AesContext(group, &key, encrypt);
    if (!aes) MALLOC_FAILED;
    proxy->set_external_address(aes);
  } else {
    AesCbcContext* aes = _new AesCbcContext(group, &key, iv.address(), encrypt);
    if (!aes) MALLOC_FAILED;
    proxy->set_external_address(aes);
  }

  return proxy;
}

PRIMITIVE(aes_cbc_crypt) {
  ARGS(AesCbcContext, context, Blob, input, bool, encrypt);
  if ((input.length() % AesContext::AES_BLOCK_SIZE) != 0) INVALID_ARGUMENT;

  ByteArray* result = process->allocate_byte_array(input.length());
  if (result == null) ALLOCATION_FAILED;

  ByteArray::Bytes output_bytes(result);

  mbedtls_aes_crypt_cbc(
      &context->context_,
      encrypt ? MBEDTLS_AES_ENCRYPT : MBEDTLS_AES_DECRYPT,
      input.length(),
      static_cast<AesCbcContext*>(context)->iv_,
      input.address(),
      output_bytes.address());

  return result;
}

PRIMITIVE(aes_ecb_crypt) {
  ARGS(AesContext, context, Blob, input, bool, encrypt);
  if ((input.length() % AesContext::AES_BLOCK_SIZE) != 0) INVALID_ARGUMENT;

  ByteArray* result = process->allocate_byte_array(input.length());
  if (result == null) ALLOCATION_FAILED;

  ByteArray::Bytes output_bytes(result);

  mbedtls_aes_crypt_ecb(
      &context->context_,
      encrypt ? MBEDTLS_AES_ENCRYPT : MBEDTLS_AES_DECRYPT,
      input.address(),
      output_bytes.address());

  return result;
}

PRIMITIVE(aes_cbc_close) {
  ARGS(AesCbcContext, context);
  context->resource_group()->unregister_resource(context);
  context_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(aes_ecb_close) {
  ARGS(AesContext, context);
  context->resource_group()->unregister_resource(context);
  context_proxy->clear_external_address();
  return process->program()->null_object();
}


}
