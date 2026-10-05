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

#include "../top.h"

#if defined(TOIT_ESP32) && defined(CONFIG_TOIT_ENABLE_USB_HOST)

namespace toit {

// Installing the USB Serial/JTAG driver switches the shared USB PHY to
// USB Serial/JTAG, which would take it away from an open USB host.
// usb_host_lock_phy keeps the USB host from installing or uninstalling its
// stack until usb_host_unlock_phy, which must be called on the same thread
// (the driver install itself may run on another one). It returns whether
// the USB host has the PHY; the driver must then not be installed.
// The lock can be held for seconds while a USB host is torn down, so don't
// take it while holding other locks.
bool usb_host_lock_phy();
void usb_host_unlock_phy();

}  // namespace toit

#endif  // defined(TOIT_ESP32) && defined(CONFIG_TOIT_ENABLE_USB_HOST)
