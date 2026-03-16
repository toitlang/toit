// Copyright (C) 2024 Toitware ApS.
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

// mbedTLS configuration for EC618 (Cortex-M3, FreeRTOS).
// This is used instead of the ESP-IDF esp_config.h when cross-compiling
// for the EC618 target.

#ifndef MBEDTLS_CONFIG_TOIT_H
#define MBEDTLS_CONFIG_TOIT_H

// Platform
#define MBEDTLS_HAVE_ASM
#define MBEDTLS_HAVE_TIME

// Threading via FreeRTOS
#define MBEDTLS_THREADING_C
#define MBEDTLS_THREADING_ALT

// Hardware entropy
#define MBEDTLS_ENTROPY_HARDWARE_ALT
#define MBEDTLS_NO_PLATFORM_ENTROPY

// Memory
#define MBEDTLS_PLATFORM_C
#define MBEDTLS_PLATFORM_MEMORY

// Smaller SSL buffers for constrained RAM
#define MBEDTLS_SSL_IN_CONTENT_LEN  7800
#define MBEDTLS_SSL_OUT_CONTENT_LEN 3800
#define MBEDTLS_AES_FEWER_TABLES

// --- Crypto primitives ---
#define MBEDTLS_CIPHER_MODE_CBC
#define MBEDTLS_AES_C
#define MBEDTLS_ASN1_PARSE_C
#define MBEDTLS_ASN1_WRITE_C
#define MBEDTLS_BASE64_C
#define MBEDTLS_BIGNUM_C
#define MBEDTLS_CCM_C
#define MBEDTLS_CHACHA20_C
#define MBEDTLS_CHACHAPOLY_C
#define MBEDTLS_CIPHER_C
#define MBEDTLS_CTR_DRBG_C
#define MBEDTLS_ECDH_C
#define MBEDTLS_ECDSA_C
#define MBEDTLS_ECP_C
#define MBEDTLS_ENTROPY_C
#define MBEDTLS_ERROR_C
#define MBEDTLS_GCM_C
#define MBEDTLS_HKDF_C
#define MBEDTLS_HMAC_DRBG_C
#define MBEDTLS_MD_C
#define MBEDTLS_OID_C
#define MBEDTLS_PEM_PARSE_C
#define MBEDTLS_PK_C
#define MBEDTLS_PK_PARSE_C
#define MBEDTLS_PK_WRITE_C
#define MBEDTLS_PKCS1_V15
#define MBEDTLS_PKCS1_V21
#define MBEDTLS_PKCS5_C
#define MBEDTLS_POLY1305_C
#define MBEDTLS_RSA_C
#define MBEDTLS_SHA1_C
#define MBEDTLS_SHA224_C
#define MBEDTLS_SHA256_C
#define MBEDTLS_SHA384_C
#define MBEDTLS_SHA512_C
#define MBEDTLS_MD_CAN_SHA256

// --- ECP curves ---
#define MBEDTLS_ECP_DP_SECP256R1_ENABLED
#define MBEDTLS_ECP_DP_SECP384R1_ENABLED
#define MBEDTLS_ECP_DP_SECP521R1_ENABLED
#define MBEDTLS_ECP_DP_CURVE25519_ENABLED

// --- SSL/TLS ---
#define MBEDTLS_SSL_CLI_C
#define MBEDTLS_SSL_TLS_C
#define MBEDTLS_SSL_PROTO_TLS1_2
#define MBEDTLS_SSL_MAX_FRAGMENT_LENGTH
#define MBEDTLS_SSL_SESSION_TICKETS
#define MBEDTLS_SSL_SERVER_NAME_INDICATION

// --- X.509 ---
#define MBEDTLS_X509_USE_C
#define MBEDTLS_X509_CRT_PARSE_C
#define MBEDTLS_X509_TRUSTED_CERTIFICATE_CALLBACK

// --- Key exchange ---
#define MBEDTLS_KEY_EXCHANGE_ECDHE_RSA_ENABLED
#define MBEDTLS_KEY_EXCHANGE_ECDHE_ECDSA_ENABLED
#define MBEDTLS_KEY_EXCHANGE_RSA_ENABLED

// Allow direct struct access (3.x compatibility for 2.x-style code)
#define MBEDTLS_ALLOW_PRIVATE_ACCESS

// Note: do NOT include check_config.h here. In mbedtls 3.x, the config
// adjustment and checking is done by build_info.h after including this file.

#endif // MBEDTLS_CONFIG_TOIT_H
