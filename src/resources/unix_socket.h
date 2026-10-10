// Copyright (C) 2026 Toit contributors.
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

// Keep in sync with host.unix-socket.
enum UnixSocketState {
  UNIX_SOCKET_READ  = 1 << 0,
  UNIX_SOCKET_WRITE = 1 << 1,
  UNIX_SOCKET_CLOSE = 1 << 2,
  UNIX_SOCKET_ERROR = 1 << 3,
};

}  // namespace toit
