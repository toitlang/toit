// Copyright (C) 2020 Toitware ApS.
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

#include <mbedtls/aes.h>

#include "resource.h"
#include "tags.h"

namespace toit {

/**
  Super context class of the AES ciphers.
  This superclass is used for ECB ciphers, as
  it uses nothing but the context_ supplied here.
  Other ciphers in the AES family also uses the
  context, but may need additional data to
  function. The other AES cipher context
  classes should therefore inherit from this one.
*/
class AesContext : public SimpleResource {
 public:
  TAG(AesContext);
  AesContext(SimpleResourceGroup* group, const Blob* key, bool encrypt);
  virtual ~AesContext();

  static constexpr uint8 AES_BLOCK_SIZE = 16;

  mbedtls_aes_context context_;
};

/*
  AES-CBC context class. 
  In addition to the base AES context,
  this cipher type also needs an initialization 
  vector.
*/
class AesCbcContext : public AesContext {
 public:
  TAG(AesCbcContext);
  AesCbcContext(SimpleResourceGroup* group, const Blob* key, const uint8* iv, bool encrypt);
  
  uint8 iv_[AES_BLOCK_SIZE];
};

}
