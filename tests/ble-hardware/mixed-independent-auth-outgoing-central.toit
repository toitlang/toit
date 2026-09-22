// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .mixed-service-central as fixture

main args/List:
  if args.size != 1: throw "INVALID_ARGUMENT"
  // Pinned Bumble includes more standard GATT attributes than the Toit fixture.
  fixture.run --secure --peer-address=args[0] --value-handle=16
