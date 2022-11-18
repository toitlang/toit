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
#include "psa_crypto.h"
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

Object* handle_psa_error(Process* process, psa_status_t result) {
  if (result == PSA_ERROR_INSUFFICIENT_STORAGE ||
      result == PSA_ERROR_INSUFFICIENT_MEMORY) {
    MALLOC_FAILED;
  }
  if (result == PSA_ERROR_INVALID_ARGUMENT) {
    INVALID_ARGUMENT;
  }
  if (result == PSA_ERROR_BUFFER_TOO_SMALL) {
    OUT_OF_BOUNDS;
  }
  if (result == PSA_ERROR_INVALID_SIGNATURE) {
    INVALID_SIGNATURE;
  }
  OTHER_ERROR;
}

PsaKey::~PsaKey() {
  if (key_id_ != PSA_KEY_ID_NULL) psa_destroy_key(key_id_);
}

PRIMITIVE(psa_key_init) {
  ARGS(SimpleResourceGroup, group, Blob, key, int, algorithm, int, key_type, int, usage_flags);
  if (!(0 <= key_type && key_type < NUMBER_OF_KEY_TYPES) ||
      !(0 <= algorithm && algorithm < NUMBER_OF_ALGORITHM_TYPES) ||
      !(0 <= usage_flags && usage_flags <= MAX_USAGE_FLAGS)) {
    INVALID_ARGUMENT;
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  psa_algorithm_t psa_algorithm;
  psa_key_type_t psa_key_type;

  if (algorithm == ALGORITHM_GCM) {
    psa_algorithm = PSA_ALG_GCM;
  } else if (algorithm == ALGORITHM_CHACHA20_POLY1305) {
    psa_algorithm = PSA_ALG_CHACHA20_POLY1305;
  } else {
    INVALID_ARGUMENT;
  }

  if (key_type == KEY_TYPE_AES) {
    psa_key_type = PSA_KEY_TYPE_AES;
  } else if (key_type == KEY_TYPE_CHACHA20) {
    psa_key_type = PSA_KEY_TYPE_CHACHA20;
  } else {
    INVALID_ARGUMENT;
  }

  PsaKey* psa_key = _new PsaKey(group);
  if (!psa_key) MALLOC_FAILED;

  psa_key_attributes_t psa_attributes = PSA_KEY_ATTRIBUTES_INIT;
  psa_set_key_algorithm(&psa_attributes, psa_algorithm);
  psa_set_key_type(&psa_attributes, psa_key_type);
  psa_set_key_bits(&psa_attributes, key.length() * BYTE_BIT_SIZE);
  psa_key_usage_t psa_flags = 0;
  if ((usage_flags & USE_FOR_ENCRYPT) != 0) psa_flags |= PSA_KEY_USAGE_ENCRYPT;
  if ((usage_flags & USE_FOR_DECRYPT) != 0) psa_flags |= PSA_KEY_USAGE_DECRYPT;
  psa_set_key_usage_flags(&psa_attributes, psa_flags);

  psa_key_id_t psa_key_identity;
  psa_status_t result = psa_import_key(&psa_attributes, key.address(), key.length(), &psa_key_identity);
  if (result != PSA_SUCCESS) {
    delete psa_key;
    return handle_psa_error(process, result);
  }
  psa_key->set_key_id(psa_key_identity);
  proxy->set_external_address(psa_key);
  return proxy;
}

PRIMITIVE(psa_key_close) {
  ARGS(PsaKey, key);
  key->resource_group()->unregister_resource(context);
  key_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(psa_aead_init) {
  ARGS(SimpleResourceGroup, group, PsaKey key, Blob, nonce, int, key_type, int, algorithm, bool, encrypt);
  if (!(0 <= key_type && key_type < NUMBER_OF_KEY_TYPES) ||
      !(0 <= algorithm && algorithm < NUMBER_OF_ALGORITHM_TYPES)) {
    INVALID_ARGUMENT;
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  psa_algorithm_t psa_algorithm;
  psa_key_type_t psa_key_type;

  if (algorithm == ALGORITHM_GCM) {
    psa_algorithm = PSA_ALG_GCM;
  } else if (algorithm == ALGORITHM_CHACHA20_POLY1305) {
    psa_algorithm = PSA_ALG_CHACHA20_POLY1305;
  } else {
    INVALID_ARGUMENT;
  }

  if (key_type == KEY_TYPE_AES) {
    psa_key_type = PSA_KEY_TYPE_AES;
  } else if (key_type == KEY_TYPE_CHACHA20) {
    psa_key_type = PSA_KEY_TYPE_CHACHA20;
  } else {
    INVALID_ARGUMENT;
  }

  AeadContext* aead_context = _new AeadContext(
      group,
      key->get_key_id(),
      psa_key_type,
      key.length() * BYTE_BIT_SIZE,
      psa_algorithm,
      encrypt);
  if (!aead_context) MALLOC_FAILED;
  
  psa_status_t result;
  if (encrypt) {
    result = psa_aead_encrypt_setup(aead_context->psa_operation(), key->get_key_id(), psa_algorithm);
  } else {
    result = psa_aead_decrypt_setup(aead_context->psa_operation(), key->get_key_id(), psa_algorithm);
  }
  if (result != PSA_SUCCESS) {
    delete aead_context;
    return handle_psa_error(process, result);
  }
  result = psa_aead_set_nonce(aead_context->psa_operation(), nonce.address(), nonce.length());
  if (result != PSA_SUCCESS) {
    delete aead_context;
    return handle_psa_error(process, result);
  }
  proxy->set_external_address(aead_context);
  return proxy;
}

PRIMITIVE(psa_aead_set_length) {
  ARGS(AeadContext, context, int, length);
  if (context->remaining_length_in_current_message() != 0) INVALID_ARGUMENT;
  context->set_remaining_length_in_current_message(length);
  return process->program()->null_object();
}

/**
If the result byte array was big enough, returns a Smi to indicate how much data was placed in it.
If the result byte array was not big enough, returns null.  In this case no data was consumed.
*/
PRIMITIVE(psa_aead_add) {
  ARGS(AeadContext, context, Blob, data, MutableBlob, result);
  auto remains = context->remaining_length_in_current_message();
  if (remains < data.length()) OUT_OF_BOUNDS;
  if (result.address() <= data.address() && data.address() - result.address() < 16) {
    // It can be possible to give a write buffer that overlaps with the read
    // buffer.  This can be great for memory use, but they have to be offset by
    // at least 16 bytes.
    OUT_OF_BOUNDS;
  }
  size_t max_output_needed = PSA_AEAD_UPDATE_OUTPUT_SIZE(context->psa_key_type(), context->psa_algorithm(), data.length());
  if (max_output_needed > result.length) {
    return process->program()->null_object();
  }
  size_t output_length;
  psa_status_t result = psa_aead_update(
      context->psa_context(),
      data.address(),
      data.length(),
      result.address(),
      result.length(),
      &output_length),
  if (result != PSA_SUCCESS) {
    return handle_psa_error(process, result);
  }
  context->set_remaining_length_in_current_message(remains - data.length());
  return Smi::from(output_length);
}

PRIMITIVE(psa_aead_get_tag_size) {
  ARGS(AeadContext, context);
  return Smi::from(PSA_AEAD_TAG_LENGTH(context->psa_key_type(), context->key_bit_length(), context->psa_algorithm()));
}

/**
Ends the encryption of a message.
If the result byte array was big enough, returns a Smi to indicate how much
  data was placed in it.
If the result byte array was not big enough, returns null.  In this case no
  data was consumed.
The calculation for the size of the result array is conservative, so it may
  demand a byte array that is larger than it turns out to need.
The verification tag is just appended to the encrypted data.
*/
PRIMITIVE(psa_aead_finish) {
  ARGS(AeadContext, context, MutableBlob, result);
  if (!context->is_encrypt()) INVALID_ARGUMENT;
  if (context->remaining_length_in_current_message() != 0) INVALID_ARGUMENT;
  int last_data_length = PSA_AEAD_FINISH_OUTPUT_SIZE(context->key_type(), context->psa_algorithm());
  int tag_length = PSA_AEAD_TAG_LENGTH(context->psa_key_type(), context->key_bit_length(), context->psa_algorithm());
  if (result.length() < last_data_length + tag_length) {
    return process->program()->null_object();
  }

  size_t output_length = 0;
  size_t tag_output_length = 0;
  uint8 tag[PSA_AEAD_FINISH_OUTPUT_MAX_SIZE];
  result = psa_aead_finish(
      context->psa_context(),
      result.address(),
      result.length(),
      &output_length,
      &tag[0],
      sizeof(tag),
      &tag_output_length);
  if (result == PSA_SUCCESS) {
    return handle_psa_error(process, result);
  }
  if (output_length + tag_output_length > result.length()) {
    OUT_OF_BOUNDS;
  }
  memcpy(result.length() + output_length, tag, tag_output_length);
  return Smi::from(output_length + tag_output_length);
}

/**
Ends the decryption of a message.
If the result byte array was big enough, returns a Smi to indicate how much
  data was placed in it.
If the result byte array was not big enough, returns null.  In this case no
  data was consumed.
The calculation for the size of the result array is conservative, so it may
  demand a byte array that is larger than it turns out to need.
*/
PRIMITIVE(psa_aead_finish) {
  ARGS(AeadContext, context, Blob verification_tag, MutableBlob, result);
  if (context->is_encrypt()) INVALID_ARGUMENT;
  if (context->remaining_length_in_current_message() != 0) INVALID_ARGUMENT;
  int last_data_length = PSA_AEAD_VERIFY_OUTPUT_SIZE(context->key_type(), context->psa_algorithm());
  if (result.length() < last_data_length) {
    return process->program()->null_object();
  }

  size_t output_length = 0;
  result = psa_aead_verify(
      context->psa_context(),
      result.address(),
      result.length(),
      &output_length,
      verification_tag.address(),
      verification_tag.length());
  if (result == PSA_SUCCESS) {
    return handle_psa_error(process, result);
  }
  return Smi::from(output_length);
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
