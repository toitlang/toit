// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

#ifdef TOIT_RP2350
#define MBEDTLS_ALLOW_PRIVATE_ACCESS
#include "tls_rp2350.h"
#include <../library/ssl_misc.h>

int toit_tls_get_transforms(mbedtls_ssl_context* ssl, ToitTlsTransforms* result) {
  mbedtls_ssl_transform* out = ssl->transform_out;
  mbedtls_ssl_transform* in = ssl->transform_in;
  if (out == NULL || in == NULL) return -1;
  if (out->taglen != 16 || in->taglen != 16 ||
      out->ivlen != 12 || in->ivlen != 12) return 0;
  result->encode = &out->cipher_ctx_enc;
  result->decode = &in->cipher_ctx_dec;
  result->encode_iv = out->iv_enc;
  result->decode_iv = in->iv_dec;
  result->iv_length = out->ivlen;
  return 1;
}
#endif
