// Copyright (C) 2020 Toitware ApS.
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

#include "../../top.h"

#ifdef TOIT_POSIX

#include <limits.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

#include "fs_connection_socket.h"

#include "../diagnostic.h"
#include "../../utils.h"

namespace toit {
namespace compiler {

void LspFsConnectionSocket::initialize(Diagnostics* diagnostics) {
  if (_is_initialized) return;
  _is_initialized = true;
  addrinfo hints;
  memset(&hints, 0, sizeof(struct addrinfo));
  hints.ai_family = AF_UNSPEC;     // Allow IPv4 or IPv6.
  hints.ai_socktype = SOCK_STREAM; // TCP.
  hints.ai_flags = 0;
  hints.ai_protocol = 0;           // Any protocol.

  addrinfo* result;
  int status = getaddrinfo(null, _port, &hints, &result);
  if (status != 0) {
    fprintf(stderr, "getaddrinfo: %s\n", gai_strerror(status));
    exit(EXIT_FAILURE);
  }

  for (auto info = result; info != null; info = info->ai_next) {
    int socket_fd = socket(info->ai_family, info->ai_socktype, info->ai_protocol);
    if (socket_fd == -1) continue;
    int one = 1;
    setsockopt(socket_fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    if (connect(socket_fd, info->ai_addr, info->ai_addrlen) != -1) {
      _socket = socket_fd;
      break;
    }
    close(socket_fd);
  }
}

LspFsConnectionSocket::~LspFsConnectionSocket() {
  if (_socket != -1) {
    close(_socket);
    _socket = -1;
  }
}

} // namespace compiler
} // namespace toit

#endif
