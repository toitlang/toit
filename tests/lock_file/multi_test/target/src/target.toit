// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import foo.sub as foo  // Actually goes to target.sub.

identify_target: return "target"

identify: return "target + foo.sub=($(foo.identify))"
