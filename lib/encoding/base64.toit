// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/// Encodes the given $data as Base64.
/// The $data must be a string or byte array.
encode data -> string:
  #primitive.encoding.base64_encode

/// Takes a valid base64 encoding (without newlines or other non-base64 characters)
///   and returns the binary data.
decode str/string -> ByteArray:
  #primitive.encoding.base64_decode
