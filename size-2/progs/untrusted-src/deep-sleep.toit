// Copyright (C) 2026 Toit contributors.

// Untrusted programs may not stop the whole VM: the verifier rejects it.

import esp32

main:
  esp32.deep-sleep (Duration --ms=10)
