// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import foo.target as foo  // Actually goes to target.
import self.sub as self    // Actually goes back to here.

self_identity: return "still self"

identify:
  return "sub foo.target=$(foo.identify_target) self.sub=($(self.self_identity))"
