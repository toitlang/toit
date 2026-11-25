// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The child program of boot-refused-test.toit:
//   install IMAGE: installs IMAGE in the flash registry flagged untrusted
//     and with FLAG-RUN-BOOT, and prints its id.
//   app: prints a marker (the program the VM boots after the boot
//     containers from flash have been started).

import host.file
import system.containers

main args:
  if args[0] == "install":
    bytes := file.read-contents args[1]
    writer := containers.ContainerImageWriter bytes.size
    writer.write bytes
    id := writer.commit --untrusted --run-boot
    print "id: $id"
  else:
    print "boot-refused app ran"
