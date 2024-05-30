// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file
import host.os
import io
import system.containers
import uuid
import .exit-codes

DO-NOTHING ::= "DO_NOTHING"
INSTALL-RUN-IMAGE ::= "TEST_INSTALL_RUN_IMAGE"
RUN-IMAGE ::= "TEST_RUN_IMAGE"
REMOVE-IMAGE ::= "TEST_REMOVE_IMAGE"

main:
  do-nothing := os.env.get DO-NOTHING
  install-run-image := os.env.get INSTALL-RUN-IMAGE
  run-image := os.env.get RUN-IMAGE
  remove-image := os.env.get REMOVE-IMAGE
  if do-nothing:
    // do nothing.
  else if install-run-image:
    install-run install-run-image
  else if run-image:
    run (uuid.parse run-image)
  else if remove-image:
    containers.uninstall (uuid.parse remove-image)
  else:
    throw "No action specified"
  exit EXIT-CODE-STOP

install-run image-path:
  image := file.read-content image-path
  image-writer := containers.ContainerImageWriter image.size
  image-writer.write image
  uuid := image-writer.commit
  run uuid

run uuid/uuid.Uuid:
  started := containers.start uuid
  started.wait
