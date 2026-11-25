// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The boot container of installed-flags-test.toit. Does one action, chosen
// by the TEST_ACTION environment variable, and stops the boot script:
//   install: installs the image TEST_IMAGE with the flags TEST_FLAGS (a
//     comma separated list of "boot" and "critical") and the data
//     TEST_DATA, prints its id and lists the installed images.
//   uninstall: uninstalls the image TEST_ID.
//   list: prints the installed images with their flags and data.

import host.file
import host.os
import system.containers
import uuid
import .exit-codes

ACTION ::= "TEST_ACTION"
IMAGE ::= "TEST_IMAGE"
FLAGS ::= "TEST_FLAGS"
DATA ::= "TEST_DATA"
ID ::= "TEST_ID"

main:
  action := os.env.get ACTION
  if action == "install":
    install
  else if action == "uninstall":
    containers.uninstall (uuid.Uuid.parse os.env[ID])
  else if action == "list":
    // Give the containers that were started at boot time to print.
    sleep --ms=500
    list
  else:
    throw "No action specified"
  exit EXIT-CODE-STOP

install:
  flags := (os.env.get FLAGS or "").split ","
  data := int.parse (os.env.get DATA or "0")
  bytes := file.read-contents os.env[IMAGE]
  writer := containers.ContainerImageWriter bytes.size
  writer.write bytes
  id := writer.commit
      --data=data
      --run-boot=(flags.contains "boot")
      --run-critical=(flags.contains "critical")
  print "installed: $id"
  list

list:
  current := containers.current
  containers.images.do: | image/containers.ContainerImage |
    if image.id == current: continue.do
    print "image: $image.id flags: $image.flags data: $image.data"
