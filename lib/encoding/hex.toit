// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

encode data -> string:
  #primitive.encoding.hex_encode

decode str/string -> ByteArray:
  #primitive.encoding.hex_decode
