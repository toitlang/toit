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
boot container_manager/ContainerManager -> int:
  // TODO(kasper): Only start containers that should run on boot.
  container_manager.images.do: | image/ContainerImage |
    image.start
  return container_manager.wait_until_done
