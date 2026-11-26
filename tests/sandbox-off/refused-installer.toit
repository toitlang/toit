// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
The driver of refused-test.toit, run as a trusted program of a VM without
  sandboxes (CMake TOIT_SANDBOX=OFF):
  `install-untrusted IMAGE`: commits the image flagged untrusted;
  `install-trusted IMAGE`: commits it as a trusted image, starts it once
    trusted and once untrusted.
*/

import host.file
import system.containers

main args:
  bytes := file.read-contents args[1]
  before := containers.images.size
  writer := containers.ContainerImageWriter bytes.size
  writer.write bytes
  untrusted := args[0] == "install-untrusted"
  id := null
  exception := catch: id = writer.commit --untrusted=untrusted
  if exception:
    print "commit failed: $exception"
    print "images added: $(containers.images.size - before)"
    return
  print "id: $id"
  container := containers.start id
  print "trusted exit: $container.wait"
  exception = catch:
    container = containers.start id --untrusted
    print "untrusted exit: $container.wait"
  if exception: print "untrusted start failed: $exception"
  exception = catch:
    container = containers.start id --untrusted --quotas={"heap": 64 * 1024}
    print "untrusted exit: $container.wait"
  if exception: print "untrusted start with quotas failed: $exception"
  // Quotas alone keep the trusted policy: they still work.
  container = containers.start id --quotas={"heap": 1024 * 1024}
  print "trusted with quotas exit: $container.wait"
