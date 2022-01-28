// Copyright (C) 2019 Toitware ApS.
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

#include <mbedtls/x509_crt.h>

#include "../heap.h"
#include "../resource.h"
#include "../sha256.h"

namespace toit {

class X509ResourceGroup : public ResourceGroup {
 public:
  TAG(X509ResourceGroup);
  explicit X509ResourceGroup(Process* process)
    : ResourceGroup(process) {
  }

  ~X509ResourceGroup() {
  }

  Object* parse(Process* process, const uint8_t *encoded, size_t encoded_size);
};

class X509Certificate : public Resource {
 public:
  TAG(X509Certificate);

  explicit X509Certificate(X509ResourceGroup* group) : Resource(group) {
    mbedtls_x509_crt_init(&_cert);
  }

  ~X509Certificate() {
    mbedtls_x509_crt_free(&_cert);
  }

  mbedtls_x509_crt* cert() {
    return &_cert;
  }

  Object* common_name_or_error(Process* process);

  uint8* checksum() { return &_checksum[0]; }

  void reference() { _references++; }
  bool dereference() { return --_references == 0; }

 private:
  mbedtls_x509_crt _cert;
  uint8 _checksum[Sha256::HASH_LENGTH];
  int _references = 1;
};

} // namespace toit
