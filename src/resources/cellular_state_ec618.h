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

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

extern "C" {
  // These normally come from the platform's lwIP configuration.
  #ifndef NM_PDN_TYPE_MAX_DNS_NUM
  #define NM_PDN_TYPE_MAX_DNS_NUM 2
  #endif
  #ifndef NM_MAX_DNS_NUM
  #define NM_MAX_DNS_NUM 4
  #endif
  #include "networkmgr.h"
}

namespace toit {

// Connection state derived from the modem's network-interface notifications.
// Kept separate from VM resources so event ordering and malformed payloads can
// be tested without a SIM, radio, or scheduler. The caller provides locking.
class CellularNetworkState {
 public:
  enum { DETACHED = 1, ATTACHED = 2 };

  uint32_t ipv4_address() const { return ipv4_address_; }

  uint32_t on_net_info(const void* param, size_t length, uint32_t pending) {
    if (param == nullptr || length < sizeof(NmAtiNetInfoInd)) return pending;
    NmAtiNetInfoInd info;
    memcpy(&info, param, sizeof(info));
    switch (info.netifInfo.netStatus) {
      case NM_NETIF_ACTIVATED:
        // This provider exposes IPv4. IPv6-only activation is not a usable
        // connection, even if the modem reports its interface as activated.
        if ((info.netifInfo.ipType == NM_NET_TYPE_IPV4 ||
             info.netifInfo.ipType == NM_NET_TYPE_IPV4V6 ||
             info.netifInfo.ipType == NM_NET_TYPE_IPV4_IPV6preparing) &&
            info.netifInfo.ipv4Info.ipv4Addr.addr != 0) {
          ipv4_address_ = info.netifInfo.ipv4Info.ipv4Addr.addr;
          // Preserve the last disconnect cause until this resource closes.
          return (pending & ~DETACHED) | ATTACHED;
        }
        disconnect_cause_ = NO_IPV4;
        break;
      case NM_NO_NETIF_NOT_DIAL:
      case NM_NO_NETIF_OR_DEACTIVATED:
      case NM_NETIF_OOS:
        disconnect_cause_ = info.indCause;
        disconnected_status_ = info.netifInfo.netStatus;
        break;
      default:
        return pending;
    }
    ipv4_address_ = 0;
    return (pending & ~ATTACHED) | DETACHED;
  }

  // The vendor notification carries an interface-change cause, not a 3GPP
  // registration reject code. Keep unknown numeric causes in diagnostics.
  void format_disconnect_reason(char* buffer, size_t length) const {
    const char* reason = nullptr;
    switch (disconnect_cause_) {
      case NO_DISCONNECT: reason = "no disconnect reported"; break;
      case NO_IPV4: reason = "no IPv4 address"; break;
      case NM_STATUS_CHANGE_LINK_DOWN: reason = "link down"; break;
      case NM_STATUS_CHANGE_LINK_DOWN_IPV4: reason = "IPv4 link down"; break;
      case NM_STATUS_CHANGE_LINK_DOWN_IPV6: reason = "IPv6 link down"; break;
      case NM_STATUS_CHANGE_ENTER_OOS: reason = "out of service"; break;
      case NM_STATUS_CHANGE_RA_TIMEOUT: reason = "IPv6 router advertisement timeout"; break;
      default: break;
    }
    if (reason != nullptr) {
      snprintf(buffer, length, "%s", reason);
    } else {
      snprintf(buffer, length, "network status %d (cause %d)",
               disconnected_status_, disconnect_cause_);
    }
  }

 private:
  enum { NO_DISCONNECT = -1, NO_IPV4 = -2 };
  uint32_t ipv4_address_ = 0;
  int disconnect_cause_ = NO_DISCONNECT;
  int disconnected_status_ = NM_NO_NETIF_NOT_DIAL;
};

}  // namespace toit
