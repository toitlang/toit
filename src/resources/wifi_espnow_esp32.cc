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

#include "../top.h"

#ifdef TOIT_ESP32
#if defined(CONFIG_TOIT_ENABLE_WIFI) || defined(CONFIG_TOIT_ENABLE_ESPNOW)

#include "wifi_espnow_esp32.h"
#include "../resource_pool.h"

namespace toit {

// Only allow one instance of WiFi or ESPNow running.
ResourcePool<int, kInvalidWifiEspnow> wifi_espnow_pool(
  0
);

} // namespace toit

#endif // CONFIG_TOIT_ENABLE_WIFI || CONFIG_TOIT_ENABLE_ESPNOW
#endif // TOIT_ESP32
