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
  Error* error = null;
  ByteArray* result = process->allocate_byte_array(20, &error);
  if (result == null) return error;
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
  Error* error = null;
  ByteArray* result = process->allocate_byte_array(Sha256::HASH_LENGTH, &error);
  if (result == null) return error;
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
  Error* error = null;
  ByteArray* result = process->allocate_byte_array(siphash->output_length(), &error);
  if (result == null) return error;
  siphash->get_hash(ByteArray::Bytes(result).address());
  siphash->resource_group()->unregister_resource(siphash);
  siphash_proxy->clear_external_address();
  return result;
}

AesCbcContext::AesCbcContext(
    SimpleResourceGroup* group,
    const uint8* key,
    const uint8* iv,
    bool encrypt)
  : SimpleResource(group) {
  mbedtls_aes_init(&context_);
  if (encrypt) {
    mbedtls_aes_setkey_enc(&context_, key, 256);  // 32 byte key.
  } else {
    mbedtls_aes_setkey_dec(&context_, key, 256);  // 32 byte key.
  }
  memcpy(iv_, iv, 16);
}

AesCbcContext::~AesCbcContext() {
  mbedtls_aes_free(&context_);
}

PRIMITIVE(aes_cbc_init) {
  ARGS(SimpleResourceGroup, group, Blob, key, Blob, iv, bool, encrypt);

  if (key.length() != 32 || iv.length() != 16) INVALID_ARGUMENT;

  AesCbcContext* aes = _new AesCbcContext(group, key.address(), iv.address(), encrypt);
  if (!aes) MALLOC_FAILED;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  proxy->set_external_address(aes);
  return proxy;
}

PRIMITIVE(aes_cbc_crypt) {
  ARGS(AesCbcContext, context, Blob, input, int, from, int, to, bool, encrypt);
  if (from < 0 || to > input.length() || from > to || ((to - from) & 0xf) != 0) INVALID_ARGUMENT;

  Error* error = null;
  ByteArray* result = process->allocate_byte_array(to - from, &error);
  if (result == null) return error;

  ByteArray::Bytes output_bytes(result);
  mbedtls_aes_crypt_cbc(
      &context->context_,
      encrypt ? MBEDTLS_AES_ENCRYPT : MBEDTLS_AES_DECRYPT,
      to - from,
      context->iv_,
      input.address() + from,
      output_bytes.address());

  return result;
}

PRIMITIVE(aes_cbc_close) {
  ARGS(AesCbcContext, context);
  context->resource_group()->unregister_resource(context);
  context_proxy->clear_external_address();
  return process->program()->null_object();
}

}
