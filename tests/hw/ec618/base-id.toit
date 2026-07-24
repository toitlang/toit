// Copyright (C) 2026 Toit contributors.

// Prints the flashed base's identity record. Fails
// if the reserved page carries no record — every base since the two-stage
// split is stamped by gen-base-id.toit.

import ec618

main:
  id := ec618.base-id
  print "base-id: $id"
  if id == "base-unknown":
    print "ERROR: no base-id record"
    exit 1
