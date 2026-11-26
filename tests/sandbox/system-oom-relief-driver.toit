// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The driver of system-oom-relief-test.toit, run in a child VM whose system
// process fails allocations of the container start or of the commit
// (-Xinject_system_oom=spawn:N, commit:N): starts a sandboxed container from
// its own image (which waits), installs IMAGE as a trusted image and starts
// it, and prints the outcomes of the install and the start and the exit code
// of the sandbox (stopped by the driver if it still runs).

import host.file
import system.containers
import uuid

main args:
  if args is Map:
    // The sandbox: waits to be stopped.
    sleep --ms=30_000
    return
  sandbox := containers.start containers.current {"role": "wait"} --untrusted
  id := null
  exception := catch: id = install args[0]
  if exception: print "install failed: $exception"
  if id:
    exception = catch:
      container := containers.start id
      print "exit: $container.wait"
    if exception: print "start failed: $exception"
  // Stops the sandbox unless the system stopped it (stopping a stopped
  // container throws).
  catch: sandbox.stop
  print "sandbox: $sandbox.wait"
  print "system alive"

install path/string -> uuid.Uuid:
  bytes := file.read-contents path
  writer := containers.ContainerImageWriter bytes.size
  writer.write bytes
  // Trusted: the start may stop sandboxes for memory.
  return writer.commit
