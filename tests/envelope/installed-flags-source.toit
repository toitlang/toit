// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The boot container of installed-flags-test.toit. Does one action, chosen
// by the TEST_ACTION environment variable, and stops the boot script:
//   install: installs the image TEST_IMAGE with the flags TEST_FLAGS (a
//     comma separated list of "untrusted", "boot" and "critical") and the
//     data TEST_DATA, prints its id and starts it (unless TEST_NO_START is
//     set).
//   run: starts the installed image TEST_ID.
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
NO-START ::= "TEST_NO_START"
ID ::= "TEST_ID"

main:
  action := os.env.get ACTION
  if action == "install":
    install
  else if action == "run":
    run (uuid.Uuid.parse os.env[ID])
  else if action == "uninstall":
    containers.uninstall (uuid.Uuid.parse os.env[ID])
  else if action == "list":
    // Give the boot containers that were started with us time to print.
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
  id := null
  exception := catch:
    id = writer.commit
        --data=data
        --untrusted=(flags.contains "untrusted")
        --run-boot=(flags.contains "boot")
        --run-critical=(flags.contains "critical")
  if exception:
    print "commit failed: $exception"
    return
  print "installed: $id"
  if os.env.get NO-START: return
  run id

run id/uuid.Uuid:
  exception := catch:
    container := containers.start id
    print "exit: $container.wait"
  if exception: print "start failed: $exception"

list:
  current := containers.current
  containers.images.do: | image/containers.ContainerImage |
    if image.id == current: continue.do
    print "image: $image.id flags: $(image.flags & 0x7) verified: $((image.flags >> 6) & 1) data: $image.data"

