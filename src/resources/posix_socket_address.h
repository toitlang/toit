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

#pragma once

#include "../top.h"

#if defined(TOIT_WINDOWS) || defined(TOIT_POSIX)

#include "../process.h"
#if defined(TOIT_WINDOWS)
#include "winsock2.h"
#else
#include <sys/socket.h>
#endif
namespace toit {
class ToitSocketAddress {
 public:
  ToitSocketAddress(const uint8* address, int address_length, int port) {
    memcpy(&(as_socket_address_in()->sin_addr.s_addr), address, address_length);
    as_socket_address_in()->sin_port = htons(port);
    as_socket_address_in()->sin_family = AF_INET;
  }

  ToitSocketAddress() : socket_address_() {}

  int port() { return ntohs(as_socket_address_in()->sin_port); }
  uint8* address() { return reinterpret_cast<uint8*>(&(as_socket_address_in()->sin_addr.s_addr)); }
  int address_length() { return sizeof(in_addr); }
  inline sockaddr_in* as_socket_address_in() { return reinterpret_cast<sockaddr_in*>(&socket_address_); }
  inline sockaddr* as_socket_address() { return &socket_address_; }
  inline int* size_pointer() { return &socket_address_size_; }
  inline int size() const { return socket_address_size_; }

  toit::Object* as_toit_string(toit::Process* process) {
    char buffer[16];
    uint32_t addr_word = ntohl(as_socket_address_in()->sin_addr.s_addr);
    sprintf(buffer, "%d.%d.%d.%d",
            (addr_word >> 24) & 0xff,
            (addr_word >> 16) & 0xff,
            (addr_word >> 8) & 0xff,
            (addr_word >> 0) & 0xff);
    return process->allocate_string_or_error(buffer, static_cast<int>(strlen(buffer)));
  }

  int retrieve_address(SOCKET socket, bool peer) {
    return peer ?
        getpeername(socket, as_socket_address(), size_pointer()):
        getsockname(socket, as_socket_address(), size_pointer());
  }

  bool lookup_address(const char* host, int port) {
    if (strlen(host) == 0) {
      as_socket_address_in()->sin_family = AF_INET;
      as_socket_address_in()->sin_addr.s_addr = INADDR_ANY;
    } else {
      struct hostent* server = gethostbyname(host);
      if (server == null) return false;
      memcpy(&(as_socket_address_in()->sin_addr.s_addr), server->h_addr, server->h_length);
      as_socket_address_in()->sin_family = server->h_addrtype;
    }
    as_socket_address_in()->sin_port = htons(port);
    return true;
  }

 private:
  sockaddr socket_address_{};
  int socket_address_size_ = sizeof(sockaddr);
};
}

#endif // defined(TOIT_WINDOWS) || defined(TOIT_POSIX)
