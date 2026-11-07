// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum
import .ec

export *

/**
Cryptographic functions.
*/

/**
Generates a byte array of the given $size filled with random bytes.

# Advanced

On the ESP32, the function is mapped to `esp_random`
  (https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/system/random.html#_CPPv410esp_randomv).
  As such, the numbers are only truly random if the RF subsystem (WiFi or Bluetooth) is enabled.
  Otherwise, the numbers should be considered pseudo-random.

On Pico targets, the function uses mbedTLS CTR-DRBG seeded through the platform
  entropy collector. RP2040's source is the Pico SDK generator, which mixes
  ring-oscillator samples and system state; RP2350 also has a hardware TRNG.

On host platforms, the function uses `std::random_device` (see
  https://en.cppreference.com/w/cpp/numeric/random/random_device). On Linux
  and macOS, this uses `/dev/urandom` as a source of randomness. On Windows,
  it uses the Windows Cryptographic API (CAPI) to generate random numbers.
*/
random --size/int -> ByteArray:
  #primitive.crypto-random.random
