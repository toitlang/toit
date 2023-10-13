// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..io as io

/**
Encodes the given $data as base64 or base64url.
*/
encode data/io.Data --url-mode/bool=false -> string:
  #primitive.encoding.base64-encode:
    return io.primitive-redo-io-data_ it data: | bytes |
      encode bytes --url-mode=url-mode


/**
Takes a valid base64 encoding (without newlines or other non-base64 characters)
  and returns the binary data.
In URL mode the data must be valid base64url encoding.
*/
decode data/io.Data --url-mode/bool=false -> ByteArray:
  #primitive.encoding.base64-decode:
    return io.primitive-redo-io-data_ it data: | bytes |
      decode bytes --url-mode=url-mode
