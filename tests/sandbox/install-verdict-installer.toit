// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The installer of install-verdict-test.toit, run in a child VM:
//   install IMAGE: installs IMAGE flagged untrusted, prints its id, whether
//     the verdict is recorded (flags bit 6) and runs it.
//   start ID: whether the image is listed, and runs it.

import host.file
import system.containers
import uuid

main args:
  if args[0] == "install":
    bytes := file.read-contents args[1]
    writer := containers.ContainerImageWriter bytes.size
    writer.write bytes
    id := null
    exception := catch: id = writer.commit --untrusted
    if exception:
      print "commit failed: $exception"
      return
    print "id: $id"
    image := (containers.images.filter: it.id == id).first
    print "verified: $((image.flags >> 6) & 1)"
    print "untrusted: $((image.flags >> 2) & 1)"
    container := containers.start id
    print "exit: $container.wait"
  else:
    id := uuid.Uuid.parse args[1]
    listed := containers.images.any: it.id == id
    print "listed: $listed"
    exception := catch:
      container := containers.start id
      print "exit: $container.wait"
    if exception: print "start failed: $exception"
