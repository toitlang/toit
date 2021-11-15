// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .session

/**
The locker can wrap a $Session, and ensure both exclusive access to the
  Session and a queue in case of concurrent requests.
*/
monitor Locker:
  session_/Session

  constructor .session_:

  do [block] -> any:
    return block.call session_
