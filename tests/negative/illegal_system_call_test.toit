// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import uuid
import system.api.containers show ContainerServiceClient

main:
  client := ContainerServiceClient
  // This is an illegal call, which will cause the system process to throw
  // an exception. This exception is returned over the process boundary via
  // the RPC mechanism.
  client.image_writer_write 9999 #[]
