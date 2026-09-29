// Copyright (C) 2024 Toitware ApS.
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

#include <esp_private/wifi_os_adapter.h>
#include <esp_wifi.h>

#include "../resource_pool.h"

namespace toit {

const int kInvalidWifiEspnow = -1;

extern ResourcePool<int, kInvalidWifiEspnow> wifi_espnow_pool;

// Returns OS functions for the Wi-Fi driver, which make its tasks inherit
// the malloc tag of the thread that creates them. The driver allocates most
// of its memory on these tasks, and with the tag the allocations are
// attributed to Wi-Fi and to the process that initializes it.
wifi_osi_funcs_t* tagged_wifi_osi_funcs();

}  // namespace toit
