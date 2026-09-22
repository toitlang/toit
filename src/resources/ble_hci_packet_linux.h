// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only. See LICENSE in the repository root.

#pragma once

#include <errno.h>
#include <stdint.h>
#include <sys/socket.h>

namespace toit {
namespace ble_hci {

enum class ReceiveStatus { ready, empty, too_large, allocation_failed, os_error, invalid };

struct ReceiveResult {
  ReceiveResult(ReceiveStatus status, int error = 0) : status(status), error(error) {}
  ReceiveStatus status;
  int error;
};

// Shared by the primitive and socket tests. The allocator must return owned
// writable storage or nullptr, without consuming the packet. No pointer escapes
// this synchronous function. The socket must have exactly one reader.
template <typename Allocate>
ReceiveResult receive_packet(int fd, int limit, Allocate allocate) {
  uint8_t first;
  ssize_t length;
  do {
    length = recv(fd, &first, 1, MSG_PEEK | MSG_TRUNC | MSG_DONTWAIT);
  } while (length < 0 && errno == EINTR);
  if (length < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) return {ReceiveStatus::empty};
    return {ReceiveStatus::os_error, errno};
  }
  if (length == 0) return {ReceiveStatus::invalid};
  if (length > limit) return {ReceiveStatus::too_large};
  uint8_t* bytes = allocate(length);
  if (bytes == nullptr) return {ReceiveStatus::allocation_failed};

  iovec iov = {bytes, static_cast<size_t>(length)};
  msghdr message = {};
  message.msg_iov = &iov;
  message.msg_iovlen = 1;
  ssize_t received;
  do {
    received = recvmsg(fd, &message, MSG_DONTWAIT);
  } while (received < 0 && errno == EINTR);
  if (received < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) return {ReceiveStatus::empty};
    return {ReceiveStatus::os_error, errno};
  }
  if (received != length || (message.msg_flags & MSG_TRUNC)) return {ReceiveStatus::invalid};
  return {ReceiveStatus::ready};
}

} // namespace ble_hci
} // namespace toit
