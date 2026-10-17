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
// Holding a UsbHostPhyLock keeps the USB host from installing or
// uninstalling its stack. It says whether the USB host has the PHY; the
// driver must then not be installed. Destroy it on the thread that created
// it (the driver install itself may run on another one).
//
// One-sided on purpose: a Host takes the PHY from an installed driver, and
// stdin yields to an installed Host, rather than the second one failing.
// stdin opens the UART and USB Serial/JTAG consoles together, so failing it
// would lose UART stdin too. And stdin is a per-process singleton that is
// never closed, so a Host that refused while the driver is installed could
// not be created at all once any process has touched stdin. Both can't be
// in use at once anyway: the chips have one PHY on one pin pair.
//
// Lock order: a UsbHostPhyLock is taken before OS::global_mutex(), which
// stdio holds while it installs the driver. The USB host never takes the
// global mutex, directly or through what it calls under the stack lock
// (the IDF, its own spinlock, the event source mutex), so the order can't
// invert.
class UsbHostStack;

// Holds the stack lock, and is the only way to reach the UsbHostStack, so
// holding the lock is checked by the compiler: functions that need it take
// a UsbHostStackLocker&.
class UsbHostStackLocker {
 public:
  UsbHostStackLocker();
  ~UsbHostStackLocker();

  UsbHostStack* operator->();
};

class UsbHostPhyLock {
 public:
  UsbHostPhyLock();

  bool host_has_phy() const { return host_has_phy_; }

 private:
  UsbHostStackLocker lock_;
  bool host_has_phy_;
};

}  // namespace toit

#endif  // defined(TOIT_ESP32) && defined(CONFIG_TOIT_ENABLE_USB_HOST)
