// Copyright (C) 2021 Toitware ApS. All rights reserved.

import foo.sub as foo  // Actually goes to target.sub.

identify_target: return "target"

identify: return "target + foo.sub=($(foo.identify))"
