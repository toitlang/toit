// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .mixed-service-central as fixture

main args/List:
  if args.is-empty: fixture.run --secure
  else if args.size == 1: fixture.run --secure --peer-address=args[0]
  else: throw "INVALID_ARGUMENT"
