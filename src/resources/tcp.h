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

enum TCPState {
  TCP_READ  = 1 << 0,
  TCP_WRITE = 1 << 1,
  TCP_CLOSE = 1 << 2,
  TCP_ERROR = 1 << 3,
  TCP_NEEDS_GC = 1 << 4,
};

enum TCPOption {
  TCP_PORT         = 1,
  TCP_PEER_PORT    = 2,
  TCP_ADDRESS      = 3,
  TCP_PEER_ADDRESS = 4,
  TCP_KEEP_ALIVE   = 5,
  TCP_NO_DELAY     = 6,
  TCP_WINDOW_SIZE  = 7,
  TCP_SEND_BUFFER  = 8,
};

} // namespace toit
