// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file
import host.os
import io
import system.assets
import system.containers
import uuid
import .exit-codes

DO-NOTHING ::= "DO_NOTHING"
INSTALL-RUN-IMAGE ::= "TEST_INSTALL_RUN_IMAGE"
RUN-IMAGE ::= "TEST_RUN_IMAGE"
REMOVE-IMAGE ::= "TEST_REMOVE_IMAGE"
TMP-DIR ::= "TEST_TMP_DIR"

ASSETS ::= {
  "foo": "foo",
}

main:
  do-nothing := os.env.get DO-NOTHING
  install-run-image := os.env.get INSTALL-RUN-IMAGE
  run-image := os.env.get RUN-IMAGE
  remove-image := os.env.get REMOVE-IMAGE

  // Always check that the assets are available.
  decoded := assets.decode
  if not decoded.contains "foo" and decoded["foo"] == "foo":
    print "Assets not available"
    exit EXIT-CODE-STOP

  if do-nothing:
    // do nothing.
  else if install-run-image:
    install-run install-run-image
  else if run-image:
    run (uuid.Uuid.parse run-image)
  else if remove-image:
    containers.uninstall (uuid.Uuid.parse remove-image)
  else:
    throw "No action specified"
  exit EXIT-CODE-STOP

reboot:
  __deep_sleep__ 1  // Sleep 1 ms and restart.

install-run image-path:
  // 3 steps:
  // - Reboot. This way the system image is stored in the flash-registry and will be read from there.
  // - Install the image and run. Then reboot.
  // - Restart again and run the installed image. If the image was installed at a bad location (like
  //   on top of the system's assets), then this will lead to a crash.
  tmp-dir := os.env[TMP-DIR]
  mark-path := "$tmp-dir/mark"
  uuid-path := "$tmp-dir/uuid"
  if not file.is-file mark-path:
    file.write-content --path=mark-path "mark"
    reboot

  if file.is-file uuid-path:
    container-uuid := uuid.Uuid.parse (file.read-contents uuid-path).to-string
    run container-uuid
  else:
    // Install the image.
    image := file.read-contents image-path
    image-writer := containers.ContainerImageWriter image.size
    image-writer.write image
    container-uuid := image-writer.commit
    file.write-content --path=uuid-path "$container-uuid"
    // Run the image
    run container-uuid
    reboot

run uuid/uuid.Uuid:
  started := containers.start uuid
  started.wait
