// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import .service-echo as echo

// At the Linux echo runner's 10 exchanges/second, this covers at least 24 hours.
// Every value is checked; only progress output is sampled.
main: echo.run 864_000 --log-every=1000
