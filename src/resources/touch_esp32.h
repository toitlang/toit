// Copyright (C) 2021 Toitware ApS.
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

#if defined(TOIT_FREERTOS) && (defined(CONFIG_IDF_TARGET_ESP32) || \
                               defined(CONFIG_IDF_TARGET_ESP32S2) || \
                               defined(CONFIG_IDF_TARGET_ESP32S3))

#include <driver/touch_sensor.h>

namespace toit {

int touch_pad_to_pin_num(touch_pad_t pad);

// Signals the touch-pad peripheral that it should not deinit when not used anymore.
// This is primarily used to allow wakeup from deep-sleep.
void keep_touch_active();

} // namespace toit

#endif
