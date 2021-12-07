// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Encodes the given $data as base64 or base64url.
The $data must be a string or byte array.
*/
encode data --url_mode/bool=false -> string:
  #primitive.encoding.base64_encode


/**
Takes a valid base64 encoding (without newlines or other non-base64 characters)
  and returns the binary data.
The @data must be a string or byte array.
In URL mode the data must be valid base64url encoding.
*/
decode data --url_mode/bool=false -> ByteArray:
  #primitive.encoding.base64_decode
