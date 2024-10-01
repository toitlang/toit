// Copyright (C) 2018 Toitware ApS.
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

#include "top.h"

#ifdef TOIT_ESP32
#include <esp_random.h>
#else
#include <random>
#endif

#include "objects.h"
#include "objects_inline.h"
#include "primitive.h"
#include "process.h"
#include "tags.h"


namespace toit {

MODULE_IMPLEMENTATION(crypto_random, MODULE_CRYPTO_RANDOM)

PRIMITIVE(random) {
  ARGS(int, size);

  if (size < 0) FAIL(INVALID_ARGUMENT);

  ByteArray* result = process->allocate_byte_array(size);
  if (result == null) FAIL(ALLOCATION_FAILED);

  ByteArray::Bytes bytes(result);

#ifdef TOIT_ESP32
  // We should eventually try to use std::random_device here too.
  // https://github.com/espressif/esp-idf/issues/11398
  esp_fill_random(bytes.address(), size);
#else
  // The std::random_device is mapped to /dev/urandom on Linux/macOS and to
  // a cryptographic API on Windows.
  std::random_device device;
  std::uniform_int_distribution<> distribution(0, 255);
  auto address = bytes.address();
  for (int i = 0; i < size; i++) {
    address[i] = distribution(device);
  }
#endif

  return result;
}

}
