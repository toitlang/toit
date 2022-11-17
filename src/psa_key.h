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

#pragma once

#include "top.h"

#include "psa/crypto.h"

#include "resource.h"
#include "tags.h"

namespace toit {

enum PsaKeyType {
  KEY_TYPE_AES           = 0,
  KEY_TYPE_CHACHA20      = 1,
  NUMBER_OF_KEY_TYPES    = 2
};

enum PsaAlgorithmType {
  ALGORITHM_GCM               = 0,
  ALGORITHM_CHACHA20_POLY1305 = 1,
  NUMBER_OF_ALGORITHM_TYPES   = 2
};

// Flags that can be 'or'ed together.
static const int USE_FOR_ENCRYPT = (1 << 0);
static const int USE_FOR_DECRYPT = (1 << 1);
static const int MAX_USAGE_FLAGS = (1 << 2) - 1;

enum PsaKeyUsage {


/**
  The PSA library requires that crypto keys are registered
  in a vault and manually deleted.  This code supports
  entering keys (eg for the symmetric phase of TLS) into
  the vault, so that they can be used for other operations.
*/
class PsaKey : public SimpleResource {
 public:
  TAG(PsaKey);
  PsaKey(SimpleResourceGroup* group, psa_key_type_ key_type)
      : SimpleResource(group)
      , key_type_(key_type)
      , key_id_(PSA_KEY_ID_NULL) {}
  virtual ~PsaKey();

  psa_key_id_t get_key_id() const {
    return key_id_;
  }

  void set_key_id(psa_key_id_t key_id) {
    key_id_ = key_id;
  }

  psa_algorithm_type_ algorithm_type_;
  psa_key_type_ key_type_;
  psa_key_id_t key_id_;
};

}
