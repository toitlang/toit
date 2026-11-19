// Copyright (C) 2022 Toit contributors.
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

#include "type_primitive.h"

namespace toit {
namespace compiler {

MODULE_TYPES(crypto, MODULE_CRYPTO)

TYPE_PRIMITIVE_BYTE_ARRAY(sha1_start)
TYPE_PRIMITIVE_BYTE_ARRAY(sha1_clone)
TYPE_PRIMITIVE_NULL(sha1_add)
TYPE_PRIMITIVE_BYTE_ARRAY(sha1_get)
TYPE_PRIMITIVE_BYTE_ARRAY(blake2s_start)
TYPE_PRIMITIVE_BYTE_ARRAY(blake2s_clone)
TYPE_PRIMITIVE_NULL(blake2s_add)
TYPE_PRIMITIVE_BYTE_ARRAY(blake2s_get)
TYPE_PRIMITIVE_BYTE_ARRAY(sha_start)
TYPE_PRIMITIVE_BYTE_ARRAY(sha_clone)
TYPE_PRIMITIVE_NULL(sha_add)
TYPE_PRIMITIVE_BYTE_ARRAY(sha_get)
TYPE_PRIMITIVE_BYTE_ARRAY(siphash_start)
TYPE_PRIMITIVE_BYTE_ARRAY(siphash_clone)
TYPE_PRIMITIVE_NULL(siphash_add)
TYPE_PRIMITIVE_BYTE_ARRAY(siphash_get)
TYPE_PRIMITIVE_BYTE_ARRAY(aes_init)
TYPE_PRIMITIVE_BYTE_ARRAY(aes_cbc_crypt)
TYPE_PRIMITIVE_BYTE_ARRAY(aes_ecb_crypt)
TYPE_PRIMITIVE_NULL(aes_cbc_close)
TYPE_PRIMITIVE_NULL(aes_ecb_close)
TYPE_PRIMITIVE_BYTE_ARRAY(aead_init)
TYPE_PRIMITIVE_NULL(aead_close)
TYPE_PRIMITIVE_NULL(aead_start_message)

TYPE_PRIMITIVE(aead_add) {
  result.add_smi(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_SMI(aead_get_tag_size)
TYPE_PRIMITIVE_BYTE_ARRAY(aead_finish)
TYPE_PRIMITIVE_SMI(aead_verify)
TYPE_PRIMITIVE_BYTE_ARRAY(rsa_get_private_key_der)
TYPE_PRIMITIVE_BYTE_ARRAY(rsa_get_public_key_der)
TYPE_PRIMITIVE_BYTE_ARRAY(rsa_sign)
TYPE_PRIMITIVE_BOOL(rsa_verify)
TYPE_PRIMITIVE_ARRAY(rsa_generate)
TYPE_PRIMITIVE_BYTE_ARRAY(rsa_encrypt)
TYPE_PRIMITIVE_BYTE_ARRAY(rsa_decrypt)
TYPE_PRIMITIVE_BYTE_ARRAY(rsa_generate_init)
TYPE_PRIMITIVE_BYTE_ARRAY(rsa_generate_start)
TYPE_PRIMITIVE_ARRAY(rsa_generate_finish)
TYPE_PRIMITIVE_NULL(rsa_generate_close)
TYPE_PRIMITIVE_ARRAY(ec_generate_key)
TYPE_PRIMITIVE_BYTE_ARRAY(ec_sign)
TYPE_PRIMITIVE_BOOL(ec_verify)
TYPE_PRIMITIVE_BYTE_ARRAY(ec_get_private_key_der)
TYPE_PRIMITIVE_BYTE_ARRAY(ec_get_public_key_der)
TYPE_PRIMITIVE_BYTE_ARRAY(ec_compute_shared_secret)

}  // namespace toit::compiler
}  // namespace toit
