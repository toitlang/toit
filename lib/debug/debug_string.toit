// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..encoding.ubjson as ubjson
// import pipe
import reader show BufferedReader

/// Decodes the given arguments, and invokes $dispatch_fun to
///   invoke the static `debug_string` function for each object.
do_debug_string args dispatch_fun/Lambda:
  /*
  // TODO(florian): reenable this code.
  reader := (BufferedReader pipe.stdin)
  reader.buffer_all
  bytes := reader.read_bytes reader.buffered
  decoded := ubjson.decode bytes
  nested_callback / Lambda? := null
  nested_callback = :: |nested_obj|
    dispatch_fun.call nested_obj["location_token"] nested_obj nested_callback

  nested_callback.call decoded
  */
