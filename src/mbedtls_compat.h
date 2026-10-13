// Copyright (C) 2026 Toit contributors.
// SPDX-License-Identifier: LGPL-2.1-only

#pragma once

#define MBEDTLS_ALLOW_PRIVATE_ACCESS
#include <mbedtls/version.h>

// IDF 6 uses Mbed TLS 4 and TF-PSA-Crypto. The built-in crypto interfaces
// used by Toit's streaming primitives are now private. Keep their dependency
// in one place; the IDF revision pins the matching implementation and headers.
#if MBEDTLS_VERSION_MAJOR >= 4
#include <mbedtls/private/aes.h>
#include <mbedtls/private/bignum.h>
#include <mbedtls/private/chachapoly.h>
#include <mbedtls/private/cipher.h>
#include <mbedtls/private/ctr_drbg.h>
#include <mbedtls/private/ecdsa.h>
#include <mbedtls/private/ecp.h>
#include <mbedtls/private/entropy.h>
#include <mbedtls/private/gcm.h>
#include <mbedtls/private/sha256.h>
#include <mbedtls/private/sha512.h>

#define mbedtls_sha256_starts_ret mbedtls_sha256_starts
#define mbedtls_sha256_update_ret mbedtls_sha256_update
#define mbedtls_sha256_finish_ret mbedtls_sha256_finish
#define mbedtls_sha512_starts_ret mbedtls_sha512_starts
#define mbedtls_sha512_update_ret mbedtls_sha512_update
#define mbedtls_sha512_finish_ret mbedtls_sha512_finish
#else
#include <mbedtls/aes.h>
#include <mbedtls/bignum.h>
#include <mbedtls/chachapoly.h>
#include <mbedtls/cipher.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/ecdsa.h>
#include <mbedtls/ecp.h>
#include <mbedtls/entropy.h>
#include <mbedtls/gcm.h>
#include <mbedtls/sha256.h>
#include <mbedtls/sha512.h>
#endif
