// Copyright (C) 2018 Toitware ApS.
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

#pragma once

namespace toit {

enum UDPState {
  UDP_READ  = 1 << 0,
  UDP_WRITE = 1 << 1,
  UDP_ERROR = 1 << 2,
};

enum UDPOption {
  UDP_PORT        = 1,
  UDP_ADDRESS     = 2,
  UDP_BROADCAST   = 3,
};

} // namespace toit
