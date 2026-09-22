// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import .vhci-provider-recovery as fixture

main arguments:
  with-timeout --ms=90_000:
    if arguments is Map:
      fixture.provider-main --oom=arguments["oom"]
    else:
      fixture.run --pending-reads --oom --provider-containers
