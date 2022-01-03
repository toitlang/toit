// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import encoding.base64 as base64

print_for_manually_decoding_ message/ByteArray --from=0 --to=message.size:
  // Print a message on output so that that you can easily decode.
  // The message is base64 encoded to limit the output size.
  print_ "----"
  print_ "Received a Toit system message. Executing the command below will"
  print_ "make it human readable:"
  print_ "----"
  // Block size must be a multiple of 3 for this to work, due to the 3/4 nature
  // of base64 encoding.
  BLOCK_SIZE := 1500
  for i := from; i < to; i += BLOCK_SIZE:
    end := i >= to - BLOCK_SIZE
    prefix := i == from ? "build/host/sdk/bin/toit.run tools/system_message.toit build/snapshot -b " : ""
    base64_text := base64.encode (message.copy i (end ? to : i + BLOCK_SIZE))
    postfix := end ? "" : "\\"
    print_ "$prefix$base64_text$postfix"
