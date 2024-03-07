main:
  print """
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
          ctx->bit_len = 224;
          ctx->state[0] = 0xc1059ed8;
          ctx->state[1] = 0x367cd507;
          ctx->state[2] = 0x3070dd17;
          ctx->state[3] = 0xf70e5939;
          ctx->state[4] = 0xffc00b31;
          ctx->state[5] = 0x68581511;
          ctx->state[6] = 0x64f98fa7;
          ctx->state[7] = 0xbefa4fa4;
        } else {
          ctx->bit_len = 256;
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
        int out_words = ctx->bit_len == 256 ? 8 : 7;
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

        for (int j = 0; j < 64; j += 8) {"""
  // Mapping of the variables a-h.
  map := {:}
  8.repeat:
    map["$(%c 'a' + it)"] = "$(%c 'a' + it)"
  8.repeat: | i |
    map = generate-round map "j + $i"
  print """
    }
    state[0] += $map["a"];
    state[1] += $map["b"];
    state[2] += $map["c"];
    state[3] += $map["d"];
    state[4] += $map["e"];
    state[5] += $map["f"];
    state[6] += $map["g"];
    state[7] += $map["h"];
  }

  }  // extern "C"

  #endif  // MBEDTLS_SHA256_ALT
  """

generate-round map/Map k-index -> Map:
  print """
        s1 = RIGHT_ROTATE($map["e"], 6) ^ RIGHT_ROTATE($map["e"], 11) ^ RIGHT_ROTATE($map["e"], 25);
        ch = $map["g"] ^ ($map["e"] & ($map["g"] ^ $map["f"]));
        temp1 = $map["h"] + s1 + ch + K[$k-index] + W[$k-index];
        s0 = RIGHT_ROTATE($map["a"], 2) ^ RIGHT_ROTATE($map["a"], 13) ^ RIGHT_ROTATE($map["a"], 22);
        maj = ($map["a"] & $map["b"]) ^ ($map["c"] & ($map["a"] ^ $map["b"]));
        temp2 = s0 + maj;
    """
  new-map := {:}
  new-map["h"] = map["g"]
  new-map["g"] = map["f"]
  new-map["f"] = map["e"]
  new-map["d"] = map["c"]
  new-map["c"] = map["b"]
  new-map["b"] = map["a"]
  // The registers that had d and h are no longer used, so we use them for
  // the new values of e and a.
  // e := d + temp1
  new-map["e"] = map["d"]
  print """    $map["d"] += temp1;"""
  // a := temp1 + temp2
  new-map["a"] = map["h"]
  print """    $map["h"] = temp1 + temp2;"""
  print ""
  return new-map
