// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once

// Bluetooth host AES, SMP CMAC, and LE Secure Connections ECDH. The ordinary
// Toit crypto/TLS APIs continue using their existing Mbed TLS configuration.
#define PSA_WANT_ALG_ECB_NO_PADDING 1
#define PSA_WANT_ALG_CMAC 1
#define PSA_WANT_ALG_ECDH 1
#define PSA_WANT_KEY_TYPE_AES 1
#define PSA_WANT_KEY_TYPE_ECC_PUBLIC_KEY 1
#define PSA_WANT_KEY_TYPE_ECC_KEY_PAIR_BASIC 1
#define PSA_WANT_KEY_TYPE_ECC_KEY_PAIR_IMPORT 1
#define PSA_WANT_KEY_TYPE_ECC_KEY_PAIR_EXPORT 1
#define PSA_WANT_KEY_TYPE_ECC_KEY_PAIR_GENERATE 1
#define PSA_WANT_ECC_SECP_R1_256 1
