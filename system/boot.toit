// Copyright (C) 2022 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import .containers

/**
Boot the system and run the necessary containers. Returns when the
  containers have run to completion or an error has occurred.

Returns an error code which is 0 when no errors occurred.
*/
boot container-manager/ContainerManager -> int:
  // Always start the system image which is technically already
  // running. This allows the container manager to correctly keep
  // track of the number of running processes.
  container-manager.system-image.load.start
  container-manager.images.do: | image/ContainerImage |
    if image.run-boot:
      // A container the VM refuses to run (for example an untrusted
      // program the verifier rejects) must not keep the others from
      // booting. The container manager decides whether the refusal is
      // fatal (see ContainerManager.on-container-refused_).
      exception := catch: image.load.start
      if exception:
        print-on-stderr_ "Failed to start container $image.id: $exception"
  return container-manager.wait-until-done
