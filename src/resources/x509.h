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
#include "../sha.h"

namespace toit {

class X509ResourceGroup : public ResourceGroup {
 public:
  TAG(X509ResourceGroup);
  explicit X509ResourceGroup(Process* process)
    : ResourceGroup(process) {}

  ~X509ResourceGroup() {}

  static bool is_pem_format(const uint8* data, size_t length);
  static Object* get_certificate_data(Process* process, Object* object, bool* needs_free, const uint8** data, size_t* length);

  Object* parse(Process* process, const uint8_t* encoded, size_t encoded_size, bool in_flash);
};

class X509Certificate : public Resource {
 public:
  TAG(X509Certificate);

  explicit X509Certificate(X509ResourceGroup* group) : Resource(group) {
    mbedtls_x509_crt_init(&cert_);
  }

  ~X509Certificate() {
    mbedtls_x509_crt_free(&cert_);
  }

  mbedtls_x509_crt* cert() {
    return &cert_;
  }

  Object* common_name_or_error(Process* process);

  uint8* checksum() { return &checksum_[0]; }

  void reference() { references_++; }
  bool dereference() { return --references_ == 0; }

 private:
  mbedtls_x509_crt cert_;
  uint8 checksum_[Sha::HASH_LENGTH_256];
  int references_ = 1;
};

} // namespace toit
