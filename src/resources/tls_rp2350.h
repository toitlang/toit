// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

#pragma once

#include <mbedtls/ssl.h>
#include <mbedtls/cipher.h>

// Keep mbedTLS's C-only private headers out of the C++ VM. These pointers
// borrow the active session's transforms and remain owned by mbedTLS.
typedef struct {
  mbedtls_cipher_context_t* encode;
  mbedtls_cipher_context_t* decode;
  const unsigned char* encode_iv;
  const unsigned char* decode_iv;
  size_t iv_length;
} ToitTlsTransforms;

#ifdef __cplusplus
extern "C" {
#endif

// Returns -1 before both transforms exist, 0 for unsupported transforms,
// and 1 for the TLS 1.2 AEAD transforms used by Toit's symmetric sessions.
int toit_tls_get_transforms(mbedtls_ssl_context* ssl, ToitTlsTransforms* result);

#ifdef __cplusplus
}
#endif
