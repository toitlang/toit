// Copyright (C) 2021 Toitware ApS. All rights reserved.

/**
Shim to link the tests to the DNS library.
The UDP library lives in a different place in the OSS repository, and this way
  the tests don't need to be changed.
*/

import net.modules.dns show *

export *
