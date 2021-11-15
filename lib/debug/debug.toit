// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .rpc
import rpc

// TODO(florian): where should we put this function?
serialize_ object -> ByteArray:
  #primitive.serialization.serialize

debug message/any:
  serialized_bytes := serialize_ message
  rpc.invoke RPC_SYSTEM_DEBUG [serialized_bytes]
