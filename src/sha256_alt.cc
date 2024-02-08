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

// An implementation of SHA256 (and SHA224) in C++.

// On an ARM Cortex M3, the speed of SHA256 is approximately doubled relative
// to the regular MbedTLS implementation, just by moving the K array from flash
// to RAM.  Another 20% speedup is achieved by unrolling the loop in the update
// function, removing a lot of register shuffling.  The net result is 2.5 times
// faster.  The unrolled update function is about 700 bytes in thumb mode.

#include "top.h"

#ifdef MBEDTLS_SHA256_ALT

#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "sha256_alt.h"
#include "utils.h"

extern "C" {

// Moves the K constants array to RAM.
#define DATA_SECTION __attribute__((section(".data")))

void mbedtls_sha256_init(mbedtls_sha256_context* ctx) {
  memset(ctx, 0, sizeof(*ctx));
}

void mbedtls_sha256_starts(mbedtls_sha256_context* ctx, int is224) {
  if (is224) {
    ctx->bit_length = 224;
    ctx->state[0] = 0xc1059ed8;
    ctx->state[1] = 0x367cd507;
    ctx->state[2] = 0x3070dd17;
    ctx->state[3] = 0xf70e5939;
    ctx->state[4] = 0xffc00b31;
    ctx->state[5] = 0x68581511;
    ctx->state[6] = 0x64f98fa7;
    ctx->state[7] = 0xbefa4fa4;
  } else {
    ctx->bit_length = 256;
    ctx->state[0] = 0x6a09e667;
    ctx->state[1] = 0xbb67ae85;
    ctx->state[2] = 0x3c6ef372;
    ctx->state[3] = 0xa54ff53a;
    ctx->state[4] = 0x510e527f;
    ctx->state[5] = 0x9b05688c;
    ctx->state[6] = 0x1f83d9ab;
    ctx->state[7] = 0x5be0cd19;
  }
}

static const DATA_SECTION uint32_t K[64] = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

void mbedtls_sha256_free(mbedtls_sha256_context* ctx) {
}

void mbedtls_sha256_clone(mbedtls_sha256_context *dst,
                          const mbedtls_sha256_context *src) {
  memcpy(dst, src, sizeof(*dst));
}

#define RIGHT_ROTATE(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void update(volatile uint32_t* state, const uint8_t* data);

int mbedtls_sha256_update(mbedtls_sha256_context *ctx,
                          const uint8_t* input,
                          size_t input_length) {
  ctx->length += input_length << 3;
  do {
    if (ctx->pending_fullness == SHA_BLOCK_LEN) {
      update(
          ctx->state,
          ctx->pending);
      ctx->pending_fullness = 0;
    }
    size_t to_copy = toit::Utils::min(SHA_BLOCK_LEN - ctx->pending_fullness, input_length);
    if (input) {
      memcpy(ctx->pending + ctx->pending_fullness, input, to_copy);
      input += to_copy;
    } else {
      memset(ctx->pending + ctx->pending_fullness, 0, to_copy);
    }
    ctx->pending_fullness += to_copy;
    input_length -= to_copy;
  } while (input_length != 0);
  return 0;
}

int mbedtls_sha256_finish(mbedtls_sha256_context *ctx, uint8_t* output) {
  uint64_t length = ctx->length;
  uint8_t terminator = 0x80;
  mbedtls_sha256_update(ctx, &terminator, 1);
  int remains = SHA_BLOCK_LEN - ctx->pending_fullness;
  if (remains < 8) remains += SHA_BLOCK_LEN;
  mbedtls_sha256_update(ctx, NULL, remains - 8);
  uint8_t length_bytes[8];
  for (int i = 7; i >= 0; i--) {
    length_bytes[i] = length & 0xff;
    length >>= 8;
  }
  mbedtls_sha256_update(ctx, length_bytes, 8);
  if (ctx->pending_fullness) {
    update(
        ctx->state,
        ctx->pending);
  }
  int out_words = ctx->bit_length == 256 ? 8 : 7;
  for (int i = 0; i < out_words; i++) {
    output[i * 4 + 0] = ctx->state[i] >> 24;
    output[i * 4 + 1] = ctx->state[i] >> 16;
    output[i * 4 + 2] = ctx->state[i] >> 8;
    output[i * 4 + 3] = ctx->state[i];
  }
  return 0;
}

__attribute__((noinline))
static void make_w(uint32_t* W, const uint8_t* data) {
  for (int j = 0; j < 16; j++) {
    W[j] = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
    data += 4;
  }
  for (int j = 16; j < 64; j++) {
    uint32_t j_15 = W[j - 15];
    uint32_t s0 = RIGHT_ROTATE(j_15, 7) ^ RIGHT_ROTATE(j_15, 18) ^ (j_15 >> 3);
    uint32_t j_2 = W[j - 2];
    uint32_t s1 = RIGHT_ROTATE(j_2, 17) ^ RIGHT_ROTATE(j_2, 19) ^ (j_2 >> 10);
    W[j] = W[j - 16] + s0 + s1 + W[j - 7];
  }
}

// The 'volatile' qualifier is used to prevent the compiler from
// optimizing the state array into synthetic locals, which are then
// spilled, due to register pressure. It's a very minor optimization.
static void update(volatile uint32_t* state, const uint8_t* data) {
  uint32_t W[64];
  make_w(W, data);
  uint32_t a = state[0];
  uint32_t b = state[1];
  uint32_t c = state[2];
  uint32_t d = state[3];
  uint32_t e = state[4];
  uint32_t f = state[5];
  uint32_t g = state[6];
  uint32_t h = state[7];
  uint32_t s0, s1, ch, maj, temp1, temp2;

  for (int j = 0; j < 64; j += 8) {
    s1 = RIGHT_ROTATE(e, 6) ^ RIGHT_ROTATE(e, 11) ^ RIGHT_ROTATE(e, 25);
    ch = g ^ (e & (g ^ f));
    temp1 = h + s1 + ch + K[j + 0] + W[j + 0];
    s0 = RIGHT_ROTATE(a, 2) ^ RIGHT_ROTATE(a, 13) ^ RIGHT_ROTATE(a, 22);
    maj = (a & b) ^ (c & (a ^ b));
    temp2 = s0 + maj;

    d += temp1;
    h = temp1 + temp2;

    s1 = RIGHT_ROTATE(d, 6) ^ RIGHT_ROTATE(d, 11) ^ RIGHT_ROTATE(d, 25);
    ch = f ^ (d & (f ^ e));
    temp1 = g + s1 + ch + K[j + 1] + W[j + 1];
    s0 = RIGHT_ROTATE(h, 2) ^ RIGHT_ROTATE(h, 13) ^ RIGHT_ROTATE(h, 22);
    maj = (h & a) ^ (b & (h ^ a));
    temp2 = s0 + maj;

    c += temp1;
    g = temp1 + temp2;

    s1 = RIGHT_ROTATE(c, 6) ^ RIGHT_ROTATE(c, 11) ^ RIGHT_ROTATE(c, 25);
    ch = e ^ (c & (e ^ d));
    temp1 = f + s1 + ch + K[j + 2] + W[j + 2];
    s0 = RIGHT_ROTATE(g, 2) ^ RIGHT_ROTATE(g, 13) ^ RIGHT_ROTATE(g, 22);
    maj = (g & h) ^ (a & (g ^ h));
    temp2 = s0 + maj;

    b += temp1;
    f = temp1 + temp2;

    s1 = RIGHT_ROTATE(b, 6) ^ RIGHT_ROTATE(b, 11) ^ RIGHT_ROTATE(b, 25);
    ch = d ^ (b & (d ^ c));
    temp1 = e + s1 + ch + K[j + 3] + W[j + 3];
    s0 = RIGHT_ROTATE(f, 2) ^ RIGHT_ROTATE(f, 13) ^ RIGHT_ROTATE(f, 22);
    maj = (f & g) ^ (h & (f ^ g));
    temp2 = s0 + maj;

    a += temp1;
    e = temp1 + temp2;

    s1 = RIGHT_ROTATE(a, 6) ^ RIGHT_ROTATE(a, 11) ^ RIGHT_ROTATE(a, 25);
    ch = c ^ (a & (c ^ b));
    temp1 = d + s1 + ch + K[j + 4] + W[j + 4];
    s0 = RIGHT_ROTATE(e, 2) ^ RIGHT_ROTATE(e, 13) ^ RIGHT_ROTATE(e, 22);
    maj = (e & f) ^ (g & (e ^ f));
    temp2 = s0 + maj;

    h += temp1;
    d = temp1 + temp2;

    s1 = RIGHT_ROTATE(h, 6) ^ RIGHT_ROTATE(h, 11) ^ RIGHT_ROTATE(h, 25);
    ch = b ^ (h & (b ^ a));
    temp1 = c + s1 + ch + K[j + 5] + W[j + 5];
    s0 = RIGHT_ROTATE(d, 2) ^ RIGHT_ROTATE(d, 13) ^ RIGHT_ROTATE(d, 22);
    maj = (d & e) ^ (f & (d ^ e));
    temp2 = s0 + maj;

    g += temp1;
    c = temp1 + temp2;

    s1 = RIGHT_ROTATE(g, 6) ^ RIGHT_ROTATE(g, 11) ^ RIGHT_ROTATE(g, 25);
    ch = a ^ (g & (a ^ h));
    temp1 = b + s1 + ch + K[j + 6] + W[j + 6];
    s0 = RIGHT_ROTATE(c, 2) ^ RIGHT_ROTATE(c, 13) ^ RIGHT_ROTATE(c, 22);
    maj = (c & d) ^ (e & (c ^ d));
    temp2 = s0 + maj;

    f += temp1;
    b = temp1 + temp2;

    s1 = RIGHT_ROTATE(f, 6) ^ RIGHT_ROTATE(f, 11) ^ RIGHT_ROTATE(f, 25);
    ch = h ^ (f & (h ^ g));
    temp1 = a + s1 + ch + K[j + 7] + W[j + 7];
    s0 = RIGHT_ROTATE(b, 2) ^ RIGHT_ROTATE(b, 13) ^ RIGHT_ROTATE(b, 22);
    maj = (b & c) ^ (d & (b ^ c));
    temp2 = s0 + maj;

    e += temp1;
    a = temp1 + temp2;

  }
  state[0] += a;
  state[1] += b;
  state[2] += c;
  state[3] += d;
  state[4] += e;
  state[5] += f;
  state[6] += g;
  state[7] += h;
}

}  // extern "C"

#endif  // MBEDTLS_SHA256_ALT

