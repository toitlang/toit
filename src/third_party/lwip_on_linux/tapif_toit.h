// Copyright (C) 2019 Toitware ApS.
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

#ifdef TOIT_USE_LWIP

#include <lwip/netif.h>

extern "C" {
#include <netif/ethernet.h>
#include <netif/tapif.h>
}

namespace toit {

extern netif global_netif;
extern int ip_addr_offset;
extern void init_on_tcpip_thread(void* closure);

}

#endif
