// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import rpc
import .rpc

/**
Echoes the input value.

Returns $value.
*/
echo value/any -> any:
  return rpc.invoke RPC_ECHO [value]
