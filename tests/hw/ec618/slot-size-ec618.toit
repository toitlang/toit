// Copyright (C) 2026 Toit contributors.

// Proves the slot-size primitive: SLOT-SIZE is read from the running
// firmware (the partition layout it was built for,
// toolchains/ec618/partitions.yaml) instead of being a copy in the
// library. The expected value here is the CURRENT layout's slot size;
// update it when the table changes.

import ec618.slot as slot

main:
  size := slot.SLOT-SIZE
  print "slot-size: 0x$(%x size)"
  if size != 0xC0000:
    print "ERROR: expected 0xC0000"
    exit 1
  print "slot-size-ec618: PASS"
