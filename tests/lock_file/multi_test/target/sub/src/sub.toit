// Copyright (C) 2021 Toitware ApS. All rights reserved.

import foo.target as foo  // Actually goes to target.
import self.sub as self    // Actually goes back to here.

self_identity: return "still self"

identify:
  return "sub foo.target=$(foo.identify_target) self.sub=($(self.self_identity))"
