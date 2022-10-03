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
  ARGS(Blob, data, bool, url_mode);
  int out_len = Base64Encoder::output_size(data.length(), url_mode);

  ByteArray* buffer = process->allocate_byte_array(out_len);
  if (buffer == null) ALLOCATION_FAILED;
  ByteArray::Bytes buffer_bytes(buffer);

  word i = 0;
  Base64Encoder encoder(url_mode);
  auto put = [&](uint8 c) {
    buffer_bytes.at_put(i++, c);
  };

  encoder.encode(data.address(), data.length(), put);
  encoder.finish(put);
  return process->allocate_string_or_error(char_cast(buffer_bytes.address()), out_len);
}

static int get_for_decode(const Blob& bytes, int index, bool url_mode) {
  const int ERROR = -1;
  uint8_t x = bytes.address()[index];
  if (url_mode && x == '_') return 63;
  if (x >= 'a') {
    if (x > 'z') return ERROR;
    return x - 'a' + 26;
  }
  if (x >= 'A') {
    if (x > 'Z') return ERROR;
    return x - 'A';
  }
  if (x >= '0' && x <= '9') return x + 52 - '0';
  if (url_mode) {
    if (x == '-') return 62;
  } else {
    if (x == '+') return 62;
    if (x == '/') return 63;
  }
  return ERROR;
}

PRIMITIVE(base64_decode)  {
  ARGS(Blob, input, bool, url_mode);
  int length = input.length();
  int out_len;
  if (url_mode) {
    // Padding = signs not required.
    out_len = (length >> 2) * 3;
    int last_group_length = length & 3;  // Can be 0 if input length is a multiple of 4.
    if (last_group_length == 1) {
      OUT_OF_RANGE;  // 6 bits are not enough to encode another byte.
    } else if (last_group_length == 2) {
      out_len++;     // 12 bits for one more byte of output.
    } else if (last_group_length == 3) {
      out_len += 2;  // 18 bits for two more bytes of output.
    }
  } else {
    // Padding '=' signs required to make the input a multiple of 4 characters.
    if ((length & 3) != 0) OUT_OF_RANGE;
    out_len = (length >> 2) * 3;
    // Trailing "=" signs indicate a slightly shorter output.
    if (length > 0 && input.address()[static_cast<unsigned>(length) - 1] == '=') out_len--;
    if (length > 1 && input.address()[static_cast<unsigned>(length) - 2] == '=') out_len--;
  }


  ByteArray* result = process->allocate_byte_array(out_len);
  if (result == null) ALLOCATION_FAILED;

  uint8* buffer = ByteArray::Bytes(result).address();
  // Iterate over the groups of 3 output characters that have 4 regular input characters.
  for (int i = 0, j = 0; i <= out_len - 3; i += 3, j += 4) {
    uint32_t wrd =
      (get_for_decode(input, j + 0, url_mode) << 18) |
      (get_for_decode(input, j + 1, url_mode) << 12) |
      (get_for_decode(input, j + 2, url_mode) << 6) |
      (get_for_decode(input, j + 3, url_mode) << 0);
    // If any of the get_for_decode calls returned -1 then some of the high
    // bits will be set, indicating invalid input.
    if (wrd >> 24 != 0) OUT_OF_RANGE;
    buffer[i + 0] = (wrd >> 16) & 0xff;
    buffer[i + 1] = (wrd >> 8) & 0xff;
    buffer[i + 2] = wrd & 0xff;
  }
  int j = (out_len / 3) * 4;
  switch (out_len % 3) {
    case 1: {
      if (!url_mode) {
        if (input.address()[j + 2] != '=' || input.address()[j + 3] != '=') OUT_OF_RANGE;
      }
      uint32_t wrd =
        (get_for_decode(input, j + 0, url_mode) << 6) |
        (get_for_decode(input, j + 1, url_mode) << 0);
      if (wrd >> 24 != 0) OUT_OF_RANGE;
      if ((wrd & 0xf) != 0) OUT_OF_RANGE;  // Unused bits must be zero.
      buffer[out_len - 1] = (wrd >> 4) & 0xff;
      break;
    }
    case 2: {
      if (!url_mode) {
        if (input.address()[j + 3] != '=') OUT_OF_RANGE;
      }
      uint32_t wrd =
        (get_for_decode(input, j + 0, url_mode) << 12) |
        (get_for_decode(input, j + 1, url_mode) << 6) |
        (get_for_decode(input, j + 2, url_mode) << 0);
      if (wrd >> 24 != 0) OUT_OF_RANGE;
      if ((wrd & 0x3) != 0) OUT_OF_RANGE;  // Unused bits must be zero.
      buffer[out_len - 2] = (wrd >> 10) & 0xff;
      buffer[out_len - 1] = (wrd >> 2) & 0xff;
      break;
    }
  }
  return result;
}

PRIMITIVE(tison_encode) {
  ARGS(Object, object);

  unsigned size = 0;
  unsigned payload_size = 0;
  { TisonEncoder size_encoder(process);
    if (!size_encoder.encode(object)) {
      int id = size_encoder.problematic_class_id();
      if (id >= 0) {
        return Smi::from(id);
      }
      WRONG_TYPE;
    }
    size = size_encoder.size();
    payload_size = size_encoder.payload_size();
  }

  ByteArray* result = process->allocate_byte_array(size);
  if (!result) ALLOCATION_FAILED;
  ByteArray::Bytes bytes(result);
  TisonEncoder encoder(process, bytes.address(), payload_size);
  if (!encoder.encode(object)) OTHER_ERROR;
  return result;
}

PRIMITIVE(tison_decode) {
  ARGS(Blob, bytes);
  TisonDecoder decoder(process, bytes.address(), bytes.length());
  Object* decoded = decoder.decode();
  if (decoder.allocation_failed()) ALLOCATION_FAILED;
  if (decoder.malformed_input()) WRONG_TYPE;
  return decoded;
}

}
