// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include "../../src/top.h"

#ifdef TOIT_LINUX
#include <string.h>
#include <unistd.h>
#include <sys/epoll.h>
#include "../../src/resources/ble_hci_packet_linux.h"

using toit::ble_hci::ReceiveStatus;

static void check(bool condition, const char* message) {
  if (!condition) FATAL("%s (errno=%d: %s)", message, errno, strerror(errno));
}

static void test_packets(int socket_type) {
  int fds[2];
  check(socketpair(AF_UNIX, socket_type | SOCK_NONBLOCK | SOCK_CLOEXEC, 0, fds) == 0, "socketpair");
  int epoll = epoll_create1(EPOLL_CLOEXEC);
  check(epoll >= 0, "epoll_create1");
  epoll_event watch = {};
  watch.events = EPOLLIN;
  check(epoll_ctl(epoll, EPOLL_CTL_ADD, fds[1], &watch) == 0, "epoll_ctl");

  uint8_t storage[64];
  int allocations = 0;
  auto allocate = [&](ssize_t size) -> uint8_t* {
    check(size <= 64, "allocation exceeded limit");
    allocations++;
    memset(storage, 0xcc, sizeof(storage));
    return storage;
  };
  auto receive = [&]() { return toit::ble_hci::receive_packet(fds[1], 64, allocate); };
  check(receive().status == ReceiveStatus::empty, "empty socket");
  check(allocations == 0, "empty receive must not allocate");

  const uint8_t first[] = {4, 14, 4, 1, 3, 12, 0};
  const uint8_t second[] = {2, 1, 0, 1, 0, 0xaa};
  check(send(fds[0], first, sizeof(first), 0) == sizeof(first), "send first");
  check(send(fds[0], second, sizeof(second), 0) == sizeof(second), "send second");
  for (int i = 0; i < 3; i++) {
    auto result = toit::ble_hci::receive_packet(fds[1], 64, [&](ssize_t size) -> uint8_t* {
      check(size == sizeof(first), "allocation failure changed packet order");
      return nullptr;
    });
    check(result.status == ReceiveStatus::allocation_failed, "injected allocation failure");
    epoll_event ready;
    check(epoll_wait(epoll, &ready, 1, 0) == 1, "failed allocation lost readiness");
  }
  auto oversized = toit::ble_hci::receive_packet(fds[1], 4, allocate);
  check(oversized.status == ReceiveStatus::too_large, "oversize limit");
  check(allocations == 0, "oversize receive allocated");
  check(receive().status == ReceiveStatus::ready, "retry first");
  check(memcmp(storage, first, sizeof(first)) == 0, "first packet changed");
  check(storage[sizeof(first)] == 0xcc, "write exceeded allocation");
  check(receive().status == ReceiveStatus::ready, "receive second");
  check(memcmp(storage, second, sizeof(second)) == 0, "second packet changed");
  check(receive().status == ReceiveStatus::empty, "packets duplicated");
  check(allocations == 2, "unexpected allocation count");
  epoll_event ready;
  check(epoll_wait(epoll, &ready, 1, 0) == 0, "drained socket remained readable");
  close(fds[0]);
  close(fds[1]);
  close(epoll);
}
#endif

int main(int argc, char** argv) {
#ifdef TOIT_LINUX
  test_packets(SOCK_DGRAM);
  test_packets(SOCK_SEQPACKET);
#endif
  return 0;
}
