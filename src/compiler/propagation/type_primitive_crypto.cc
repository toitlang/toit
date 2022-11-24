// Copyright (C) 2022 Toitware ApS.
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

TYPE_PRIMITIVE_ANY(sha1_start)
TYPE_PRIMITIVE_ANY(sha1_add)
TYPE_PRIMITIVE_ANY(sha1_get)
TYPE_PRIMITIVE_ANY(sha_start)
TYPE_PRIMITIVE_ANY(sha_add)
TYPE_PRIMITIVE_ANY(sha_get)
TYPE_PRIMITIVE_ANY(siphash_start)
TYPE_PRIMITIVE_ANY(siphash_add)
TYPE_PRIMITIVE_ANY(siphash_get)
TYPE_PRIMITIVE_ANY(aes_init)
TYPE_PRIMITIVE_ANY(aes_cbc_crypt)
TYPE_PRIMITIVE_ANY(aes_ecb_crypt)
TYPE_PRIMITIVE_ANY(aes_cbc_close)
TYPE_PRIMITIVE_ANY(aes_ecb_close)
TYPE_PRIMITIVE_ANY(gcm_init)
TYPE_PRIMITIVE_ANY(gcm_close)
TYPE_PRIMITIVE_ANY(gcm_start_message)
TYPE_PRIMITIVE_ANY(gcm_add)
TYPE_PRIMITIVE_ANY(gcm_get_tag_size)
TYPE_PRIMITIVE_ANY(gcm_finish)
TYPE_PRIMITIVE_ANY(gcm_verify)

}  // namespace toit::compiler
}  // namespace toit
