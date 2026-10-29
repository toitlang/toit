// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
// Native qualification of the actual shared PSA provider, after the VM has
// installed its Mbed TLS mutex and entropy hooks. All fixed keys are public
// test vectors; generated private keys are never printed.
#include <errno.h>
#include <string.h>
#include <psa/crypto.h>
#include <zephyr/sys/printk.h>

#ifndef CONFIG_TOIT_PSA_CRYPTO
#error This qualification requires the shared Toit PSA provider.
#endif

#define CHECK(condition) do { \
  if (!(condition)) { printk("PSA qualification failed at line %d\n", __LINE__); return -EIO; } \
} while (0)

int toit_zephyr_startup_test(void) {
  CHECK(psa_crypto_init() == PSA_SUCCESS);
  CHECK(psa_crypto_init() == PSA_SUCCESS);
  psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
  psa_key_id_t key;
  uint8_t output[65];
  size_t length;
  // RFC 4493 example 1: CMAC of an empty message.
  const uint8_t cmac_key[16] = {
    0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
    0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c,
  };
  const uint8_t cmac[16] = {
    0xbb, 0x1d, 0x69, 0x29, 0xe9, 0x59, 0x37, 0x28,
    0x7f, 0xa3, 0x7d, 0x12, 0x9b, 0x75, 0x67, 0x46,
  };
  psa_set_key_type(&attributes, PSA_KEY_TYPE_AES);
  psa_set_key_bits(&attributes, 128);
  psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_SIGN_MESSAGE);
  psa_set_key_algorithm(&attributes, PSA_ALG_CMAC);
  CHECK(psa_import_key(&attributes, cmac_key, sizeof(cmac_key), &key) == PSA_SUCCESS);
  CHECK(psa_mac_compute(key, PSA_ALG_CMAC, NULL, 0, output, sizeof(output), &length) == PSA_SUCCESS);
  CHECK(length == sizeof(cmac) && memcmp(output, cmac, sizeof(cmac)) == 0);
  CHECK(psa_export_key(key, output, sizeof(output), &length) == PSA_ERROR_NOT_PERMITTED);
  CHECK(psa_destroy_key(key) == PSA_SUCCESS);
  CHECK(psa_mac_compute(key, PSA_ALG_CMAC, NULL, 0, output, sizeof(output), &length) != PSA_SUCCESS);

  const uint8_t zeros[32] = {0};
  const uint8_t encrypted_zero[16] = {
    0x66, 0xe9, 0x4b, 0xd4, 0xef, 0x8a, 0x2c, 0x3b,
    0x88, 0x4c, 0xfa, 0x59, 0xca, 0x34, 0x2b, 0x2e,
  };
  psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_ENCRYPT);
  psa_set_key_algorithm(&attributes, PSA_ALG_ECB_NO_PADDING);
  CHECK(psa_import_key(&attributes, zeros, 16, &key) == PSA_SUCCESS);
  CHECK(psa_cipher_encrypt(key, PSA_ALG_ECB_NO_PADDING, zeros, 16,
                          output, sizeof(output), &length) == PSA_SUCCESS);
  CHECK(length == 16 && memcmp(output, encrypted_zero, 16) == 0);
  CHECK(psa_destroy_key(key) == PSA_SUCCESS);
  psa_reset_key_attributes(&attributes);
  printk("PSA AES/CMAC vectors and key permissions PASS\n");

  // Multiplication by private scalar 1 leaves the standard P-256 generator
  // unchanged. ECDH returns its X coordinate, in big-endian byte order.
  uint8_t one[32] = {0};
  one[31] = 1;
  const uint8_t generator[65] = {
    0x04,
    0x6b,0x17,0xd1,0xf2,0xe1,0x2c,0x42,0x47,0xf8,0xbc,0xe6,0xe5,0x63,0xa4,0x40,0xf2,
    0x77,0x03,0x7d,0x81,0x2d,0xeb,0x33,0xa0,0xf4,0xa1,0x39,0x45,0xd8,0x98,0xc2,0x96,
    0x4f,0xe3,0x42,0xe2,0xfe,0x1a,0x7f,0x9b,0x8e,0xe7,0xeb,0x4a,0x7c,0x0f,0x9e,0x16,
    0x2b,0xce,0x33,0x57,0x6b,0x31,0x5e,0xce,0xcb,0xb6,0x40,0x68,0x37,0xbf,0x51,0xf5,
  };
  psa_set_key_type(&attributes, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
  psa_set_key_bits(&attributes, 256);
  psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_DERIVE | PSA_KEY_USAGE_EXPORT);
  psa_set_key_algorithm(&attributes, PSA_ALG_ECDH);
  CHECK(psa_import_key(&attributes, one, sizeof(one), &key) == PSA_SUCCESS);
  CHECK(psa_export_public_key(key, output, sizeof(output), &length) == PSA_SUCCESS);
  CHECK(length == sizeof(generator) && memcmp(output, generator, sizeof(generator)) == 0);
  CHECK(psa_raw_key_agreement(PSA_ALG_ECDH, key, generator, sizeof(generator),
                             output, sizeof(output), &length) == PSA_SUCCESS);
  CHECK(length == 32 && memcmp(output, generator + 1, 32) == 0);
  uint8_t invalid[65] = {4};
  CHECK(psa_raw_key_agreement(PSA_ALG_ECDH, key, invalid, sizeof(invalid),
                             output, sizeof(output), &length) != PSA_SUCCESS);
  CHECK(psa_destroy_key(key) == PSA_SUCCESS);

  // Exercise entropy, generation, both directions of ECDH, and key retirement.
  for (int cycle = 0; cycle < 4; cycle++) {
    psa_key_id_t a, b;
    uint8_t public_a[65], public_b[65], secret_a[32], secret_b[32];
    CHECK(psa_generate_key(&attributes, &a) == PSA_SUCCESS);
    CHECK(psa_generate_key(&attributes, &b) == PSA_SUCCESS);
    CHECK(psa_export_public_key(a, public_a, sizeof(public_a), &length) == PSA_SUCCESS && length == 65);
    CHECK(psa_export_public_key(b, public_b, sizeof(public_b), &length) == PSA_SUCCESS && length == 65);
    CHECK(memcmp(public_a, public_b, sizeof(public_a)) != 0);
    CHECK(psa_raw_key_agreement(PSA_ALG_ECDH, a, public_b, sizeof(public_b),
                               secret_a, sizeof(secret_a), &length) == PSA_SUCCESS && length == 32);
    CHECK(psa_raw_key_agreement(PSA_ALG_ECDH, b, public_a, sizeof(public_a),
                               secret_b, sizeof(secret_b), &length) == PSA_SUCCESS && length == 32);
    CHECK(memcmp(secret_a, secret_b, sizeof(secret_a)) == 0);
    CHECK(memcmp(secret_a, zeros, sizeof(secret_a)) != 0);
    CHECK(psa_destroy_key(a) == PSA_SUCCESS);
    CHECK(psa_destroy_key(b) == PSA_SUCCESS);
  }
  psa_reset_key_attributes(&attributes);
  printk("PSA P-256 vector, invalid peer, generated ECDH and cleanup PASS\n");

  // All sixteen volatile slots must be reclaimed, including after exhaustion.
  psa_set_key_type(&attributes, PSA_KEY_TYPE_AES);
  psa_set_key_bits(&attributes, 128);
  psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_ENCRYPT);
  psa_set_key_algorithm(&attributes, PSA_ALG_ECB_NO_PADDING);
  for (int cycle = 0; cycle < 2; cycle++) {
    psa_key_id_t slots[16];
    for (int i = 0; i < 16; i++) CHECK(psa_import_key(&attributes, zeros, 16, &slots[i]) == PSA_SUCCESS);
    CHECK(psa_import_key(&attributes, zeros, 16, &key) == PSA_ERROR_INSUFFICIENT_MEMORY);
    for (int i = 0; i < 16; i++) CHECK(psa_destroy_key(slots[i]) == PSA_SUCCESS);
  }
  psa_reset_key_attributes(&attributes);
  printk("NRF5340 PSA CRYPTO PASS: vectors, ECDH, permissions and slot exhaustion/reuse\n");
  return 0;
}
