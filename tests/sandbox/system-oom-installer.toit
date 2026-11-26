// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The installer of system-oom-request-test.toit, run in a child VM whose
// system process fails allocations (-Xinject_system_oom=SITE:N): installs
// IMAGE (a second time if the first install fails), starts it (a second time
// if the first start fails) and prints every outcome. With "bucket": sets a
// key of a flash bucket (a second time if the first set fails) and prints
// what the bucket holds after each try.

import host.file
import system.containers
import system.storage
import uuid

main args:
  if args[0] == "bucket":
    bucket-set
    print "system alive"
    return
  id := install args[0]
  if not id: id = install args[0]
  if id:
    if not start id: start id
  print "images: $((containers.images.filter: it.id == id).size)"
  print "system alive"

install path/string -> uuid.Uuid?:
  // Read for every install: writing sends the bytes away (neutered).
  bytes := file.read-contents path
  exception := catch:
    writer := containers.ContainerImageWriter bytes.size
    writer.write bytes
    id := writer.commit --untrusted
    print "install: $id"
    return id
  print "install failed: $exception"
  return null

start id/uuid.Uuid -> bool:
  exception := catch:
    container := containers.start id
    print "exit: $container.wait"
    return true
  print "start failed: $exception"
  return false

bucket-set -> none:
  bucket := storage.Bucket.open --flash "system-oom"
  2.repeat:
    exception := catch: bucket["key"] = "value"
    print "set: $(exception or "ok"), get: $(bucket.get "key")"
