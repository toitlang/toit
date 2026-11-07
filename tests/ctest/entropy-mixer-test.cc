// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

#include <stdio.h>
#include <string.h>

#include "../../src/entropy_mixer.h"

static bool fail_entropy = false;
static int entropy_calls = 0;

extern "C" int __real_mbedtls_entropy_func(void*, unsigned char*, size_t);
extern "C" int __wrap_mbedtls_entropy_func(void* context, unsigned char* output, size_t size) {
  entropy_calls++;
  if (fail_entropy) return MBEDTLS_ERR_ENTROPY_SOURCE_FAILED;
  return __real_mbedtls_entropy_func(context, output, size);
}

namespace toit {

static void test_entropy_failures() {
  EntropyMixer mixer;
  uint8 bytes[MBEDTLS_CTR_DRBG_MAX_REQUEST + 1];
  memset(bytes, 0xa5, sizeof(bytes));

  fail_entropy = true;
  if (!mixer.get_random(bytes, 0) || entropy_calls != 0) FATAL("Empty request needs no entropy");
  if (mixer.get_random(bytes, sizeof(bytes))) FATAL("Seed failure must propagate");
  if (entropy_calls == 0) FATAL("Entropy injection was not exercised");
  for (uint8 byte : bytes) {
    if (byte != 0xa5) FATAL("Failed seed exposed output");
  }
  // Repeated failure must not leave a partially seeded generator usable.
  if (mixer.get_random(bytes, sizeof(bytes))) FATAL("Repeated seed failure must propagate");

  fail_entropy = false;
  if (!mixer.get_random(bytes, sizeof(bytes))) FATAL("Seed retry failed");
  bool changed = false;
  for (uint8 byte : bytes) changed |= byte != 0xa5;
  if (!changed) FATAL("Seed retry did not generate output");

  // A seeded generator can keep generating until its scheduled reseed. At
  // that point it must fail closed, then recover once entropy is available.
  fail_entropy = true;
  int calls_before = entropy_calls;
  int requests = 0;
  while (mixer.get_random(bytes, 32)) {
    if (++requests > MBEDTLS_CTR_DRBG_RESEED_INTERVAL) FATAL("Reseed never requested entropy");
  }
  if (entropy_calls <= calls_before) FATAL("Reseed failure was not exercised");
  if (mixer.get_random(bytes, 32)) FATAL("Failed reseed must not resume output");
  fail_entropy = false;
  if (!mixer.get_random(bytes, sizeof(bytes))) FATAL("Reseed retry failed");
}

}  // namespace toit

int main(int, char**) {
  toit::OS::set_up();
  toit::test_entropy_failures();
  toit::OS::tear_down();
  printf("PASS: entropy seed/reseed failures, retries and request boundaries\n");
  return 0;
}
