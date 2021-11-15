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

#include "objects.h"
#include "objects_inline.h"
#include "primitive.h"
#include "process.h"

namespace toit {

MODULE_IMPLEMENTATION(encoding, MODULE_ENCODING)

PRIMITIVE(base64_encode)  {
  ARGS(Blob, data);

  int out_len = Base64Encoder::output_size(data.length());

  Error* error = null;
  ByteArray* buffer = process->allocate_byte_array(out_len, &error);
  if (buffer == null) return error;
  ByteArray::Bytes buffer_bytes(buffer);

  word i = 0;
  Base64Encoder encoder;
  auto put = [&](uint8 c) {
    buffer_bytes.at_put(i++, c);
  };

  encoder.encode(data.address(), data.length(), put);
  encoder.finish(put);

  return process->allocate_string_or_error(char_cast(buffer_bytes.address()), out_len);
}

static int get_for_decode(String* string, int index) {
  String::Bytes bytes(string);
  const int ERROR = -1;
  uint8_t x = bytes.at(index);
  if (x >= 'a') {
    if (x > 'z') return ERROR;
    return x - 'a' + 26;
  }
  if (x >= 'A') {
    if (x > 'Z') return ERROR;
    return x - 'A';
  }
  if (x >= '0' && x <= '9') return x + 52 - '0';
  if (x == '+') return 62;
  if (x == '/') return 63;
  if (x == '=') {
    if (index == bytes.length() - 1) return 0;
    if (index == bytes.length() - 2 && bytes.at(index + 1) == '=') return 0;
    return ERROR; // '=' can't appear in other positions.
  }
  return ERROR;
}

PRIMITIVE(base64_decode)  {
  ARGS(String, string);
  String::Bytes bytes(string);

  int length = bytes.length();
  if ((length & 3) != 0) OUT_OF_RANGE;

  int out_len = (length >> 2) * 3;

  if (length > 0 && bytes.at(static_cast<unsigned>(length) - 1) == '=') out_len--;
  if (length > 1 && bytes.at(static_cast<unsigned>(length) - 2) == '=') out_len--;

  Error* error = null;
  ByteArray* result = process->allocate_byte_array(out_len, &error);
  if (result == null) return error;

  uint8* buffer = ByteArray::Bytes(result).address();
  for (int i = 0, j = 0; i < out_len; i += 3, j += 4) {
    uint32_t wrd =
      (get_for_decode(string, j + 0) << 18) |
      (get_for_decode(string, j + 1) << 12) |
      (get_for_decode(string, j + 2) << 6) |
      (get_for_decode(string, j + 3) << 0);
    // If any of the get_for_decode calls returned -1 then some of the high
    // bits will be set, indicating invalid input.
    if (wrd >> 24 != 0) {
      OUT_OF_RANGE;
    }
    buffer[i + 0] = (wrd >> 16) & 0xff;
    uint8_t byte2 = (wrd >> 8) & 0xff;
    if (i + 1 < out_len) {
      buffer[i + 1] = byte2;
    } else {
      // If there is padding at the end, then the unused bits must be zero.
      if (byte2 != 0) OUT_OF_RANGE;
    }
    uint8_t byte3 = wrd & 0xff;
    if (i + 2 < out_len) {
      buffer[i + 2] = byte3;
    } else {
      // If there is padding at the end, then the unused bits must be zero.
      if (byte3 != 0) OUT_OF_RANGE;
    }
  }
  return result;
}

static const uint8_t hex_map[16] = {
  '0', '1', '2', '3', '4', '5', '6', '7',
  '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
};

PRIMITIVE(hex_encode)  {
  ARGS(Blob, data);

  Error* error = null;
  String* result = process->allocate_string(data.length() * 2, &error);
  if (result == null) return error;
  // Initialize object.
  String::Bytes bytes(result);
  for (int i = 0; i < data.length(); i++) {
    uint8 byte = data.address()[i];
    bytes._at_put(i * 2 + 0, hex_map[byte >> 4]);
    bytes._at_put(i * 2 + 1, hex_map[byte & 0xf]);
  }
  return result;
}

static int from_hex(uint8 c) {
  if (c >= '0' && c <= '9') {
    return c - '0';
  } else if (c >= 'A' && c <= 'F') {
    return c - 'A' + 10;
  } else if (c >= 'a' && c <= 'f') {
    return c - 'a' + 10;
  }
  return -1;
}

PRIMITIVE(hex_decode)  {
  ARGS(Blob, str);  // Normally we expect a string, but any byte-object works.

  if (str.length() % 2 == 1) INVALID_ARGUMENT;
  int out_len = str.length() / 2;

  Error* error = null;
  ByteArray* out = process->allocate_byte_array(out_len, &error);
  if (out == null) return error;
  ByteArray::Bytes out_bytes(out);

  for (int i = 0; i < out_len; i++) {
    int h1 = from_hex(str.address()[i * 2 + 0]);
    if (h1 == -1) INVALID_ARGUMENT;
    int h2 = from_hex(str.address()[i * 2 + 1]);
    if (h2 == -1) INVALID_ARGUMENT;
    out_bytes.at_put(i, h1 << 4 | h2);
  }

  return out;
}

}
