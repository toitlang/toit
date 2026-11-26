// Copyright (C) 2026 Toit contributors.

// Firmware B that never validates itself (see otab.toit).

import .otab as b

main: b.run --validate=false
