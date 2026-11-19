// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Host regression using the actual vendor notification layout and enums.
#include "../../../src/resources/cellular_state_ec618.h"
#include <stdlib.h>
#include <initializer_list>

using toit::CellularNetworkState;

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #condition); \
    exit(1); \
  } \
} while (0)

static NmAtiNetInfoInd notification(int status, int cause) {
  NmAtiNetInfoInd info = {};
  info.indCause = cause;
  info.netifInfo.netStatus = status;
  info.netifInfo.ipType = NM_NET_TYPE_IPV4;
  info.netifInfo.ipv4Info.ipv4Addr.addr = 0x04030201;
  return info;
}

static bool reason_is(const CellularNetworkState& state, const char* expected) {
  char buffer[80];
  state.format_disconnect_reason(buffer, sizeof(buffer));
  return strcmp(buffer, expected) == 0;
}

int main() {
  CellularNetworkState state;
  const uint32_t unrelated = 0x80;
  uint32_t pending = unrelated;
  CHECK(state.ipv4_address() == 0);
  CHECK(reason_is(state, "no disconnect reported"));
  auto up = notification(NM_NETIF_ACTIVATED, NM_STATUS_CHANGE_LINK_UP_IPV4);
  auto down = notification(NM_NO_NETIF_OR_DEACTIVATED, NM_STATUS_CHANGE_LINK_DOWN);

  // Invalid payloads must not fabricate a connection or read out of bounds.
  CHECK(state.on_net_info(nullptr, sizeof(up), pending) == pending);
  for (size_t length = 0; length < sizeof(up); length++) {
    CHECK(state.on_net_info(&up, length, pending) == pending);
    CHECK(state.ipv4_address() == 0);
  }
  // The source need not be aligned to the vendor struct's alignment.
  unsigned char unaligned[sizeof(up) + 1];
  memcpy(unaligned + 1, &up, sizeof(up));
  pending = state.on_net_info(unaligned + 1, sizeof(up), pending);
  CHECK(pending == (unrelated | CellularNetworkState::ATTACHED));
  CHECK(state.ipv4_address() == 0x04030201);
  CHECK(state.on_net_info(&down, sizeof(down) - 1, pending) == pending);
  CHECK(state.ipv4_address() == 0x04030201);

  // Both orderings must retain only the latest connection state.
  pending = state.on_net_info(&down, sizeof(down), pending);
  CHECK(pending == (unrelated | CellularNetworkState::DETACHED));
  CHECK(state.ipv4_address() == 0);
  CHECK(reason_is(state, "link down"));
  pending = state.on_net_info(&up, sizeof(up), pending);
  CHECK(pending == (unrelated | CellularNetworkState::ATTACHED));
  CHECK(reason_is(state, "link down"));

  auto unknown = notification(255, 255);
  CHECK(state.on_net_info(&unknown, sizeof(unknown), pending) == pending);
  CHECK(state.ipv4_address() == 0x04030201);

  struct ReasonCase { int status; int cause; const char* reason; };
  const ReasonCase cases[] = {
    {NM_NO_NETIF_OR_DEACTIVATED, NM_STATUS_CHANGE_LINK_DOWN_IPV4, "IPv4 link down"},
    {NM_NO_NETIF_OR_DEACTIVATED, NM_STATUS_CHANGE_LINK_DOWN_IPV6, "IPv6 link down"},
    {NM_NETIF_OOS, NM_STATUS_CHANGE_ENTER_OOS, "out of service"},
    {NM_NO_NETIF_NOT_DIAL, NM_STATUS_CHANGE_RA_TIMEOUT, "IPv6 router advertisement timeout"},
  };
  for (auto test : cases) {
    auto info = notification(test.status, test.cause);
    pending = state.on_net_info(&info, sizeof(info), pending);
    CHECK(pending == (unrelated | CellularNetworkState::DETACHED));
    CHECK(state.ipv4_address() == 0);
    CHECK(reason_is(state, test.reason));
  }
  down.indCause = 253;
  state.on_net_info(&down, sizeof(down), pending);
  char expected[80];
  snprintf(expected, sizeof(expected), "network status %d (cause 253)", NM_NO_NETIF_OR_DEACTIVATED);
  CHECK(reason_is(state, expected));

  // IPv6-only notifications may contain stale IPv4 bytes. Do not expose them.
  up.netifInfo.ipType = NM_NET_TYPE_IPV6;
  pending = state.on_net_info(&up, sizeof(up), pending);
  CHECK(pending == (unrelated | CellularNetworkState::DETACHED));
  CHECK(state.ipv4_address() == 0);
  CHECK(reason_is(state, "no IPv4 address"));
  for (int type : {NM_NET_TYPE_IPV4, NM_NET_TYPE_IPV4V6, NM_NET_TYPE_IPV4_IPV6preparing}) {
    up.netifInfo.ipType = type;
    pending = state.on_net_info(&up, sizeof(up), pending);
    CHECK(pending == (unrelated | CellularNetworkState::ATTACHED));
    CHECK(state.ipv4_address() == 0x04030201);
  }
  up.netifInfo.ipv4Info.ipv4Addr.addr = 0;
  pending = state.on_net_info(&up, sizeof(up), pending);
  CHECK(pending == (unrelated | CellularNetworkState::DETACHED));
  CHECK(reason_is(state, "no IPv4 address"));

  CellularNetworkState fresh;
  CHECK(reason_is(fresh, "no disconnect reported"));
  puts("PASS cellular notifications: lengths, alignment, ordering, causes, IPv4 validity, fresh state");
}
