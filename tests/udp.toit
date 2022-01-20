// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Shim to link the tests to the UDP library.
The UDP library lives in a different place in the OSS repository, and this way
  the tests don't need to be changed.
*/

import net.modules.udp show *

export *
