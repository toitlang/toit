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

#ifdef TOIT_WINDOWS

#include <winsock2.h>
#include <ws2tcpip.h>
#include <stdio.h>

#include "fs_connection_socket.h"

#include "../diagnostic.h"
#include "../windows.h"
#include "../../utils.h"

namespace toit {
namespace compiler {

void LspFsConnectionSocket::initialize(Diagnostics* diagnostics) {
  if (is_initialized_) return;
  is_initialized_ = true;

 // Initialize Winsock.
  WSADATA wsa_data;
  int status = WSAStartup(MAKEWORD(2, 2), &wsa_data);
  if (status != NO_ERROR) {
    FATAL("WSAStartup function failed with error: %d\n", status);
  }

  addrinfo hints;
  memset(&hints, 0, sizeof(struct addrinfo));
  hints.ai_family = AF_UNSPEC;     // Allow IPv4 or IPv6.
  hints.ai_socktype = SOCK_STREAM; // TCP.
  hints.ai_flags = 0;
  hints.ai_protocol = 0;           // Any protocol.

  addrinfo* head;
  status = getaddrinfo(null, port_, &hints, &head);
  if (status != 0) {
    fprintf(stderr, "getaddrinfo: %s\n", gai_strerror(status));
    exit(EXIT_FAILURE);
  }

  for (auto info = head; info != null; info = info->ai_next) {
    SOCKET sock = socket(info->ai_family, info->ai_socktype, info->ai_protocol);
    if (sock == INVALID_SOCKET) continue;
    BOOL value = TRUE;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, (const char*)&value, sizeof(value));
    if (connect(sock, info->ai_addr, info->ai_addrlen) == 0) {
      socket_ = sock;
      break;
    }
    closesocket(sock);
  }
}

LspFsConnectionSocket::~LspFsConnectionSocket() {
  if (socket_ != -1) {
    closesocket(socket_);
    socket_ = -1;
  }
  WSACleanup();
}

} // namespace compiler
} // namespace toit

#endif
