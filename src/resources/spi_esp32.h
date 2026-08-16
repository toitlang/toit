// Copyright (C) 2018 Toitware ApS.
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

#ifdef TOIT_FREERTOS

#include <driver/spi_master.h>

#include "../os.h"
#include "../objects.h"
#include "../resource.h"

#include "gpio_esp32.h"

namespace toit {

class SpiResourceGroup : public ResourceGroup {
 public:
  TAG(SpiResourceGroup);
  SpiResourceGroup(Process* process, EventSource* event_source, spi_host_device_t host_device);
  ~SpiResourceGroup() override;

  spi_host_device_t host_device() { return host_device_; }

  // GPIO pins reserved by this bus (mosi/miso/clock).
  GpioPins& owned_pins() { return owned_pins_; }

 private:
  spi_host_device_t host_device_;
  GpioPins owned_pins_;
};

class SpiDevice : public Resource {
 public:
  static const int BUFFER_SIZE = 16;

  TAG(SpiDevice);
  SpiDevice(ResourceGroup* group, spi_device_handle_t handle, int dc)
    : Resource(group)
    , handle_(handle)
    , dc_(dc) {}

  ~SpiDevice() {
    spi_bus_remove_device(handle_);
    // Release any GPIO pins this device reserved (cs/dc).
    owned_pins_.release();
  }

  spi_device_handle_t handle() { return handle_; }

  int dc() { return dc_; }

  // GPIO pins reserved by this device (cs/dc).
  GpioPins& owned_pins() { return owned_pins_; }

  uint8_t* buffer() {
    return buffer_;
  }

 private:
  spi_device_handle_t handle_;
  int dc_;
  GpioPins owned_pins_;

  // Pre-allocated buffer for small transfers. Must be 4-byte aligned.
  alignas(4) uint8_t buffer_[BUFFER_SIZE];
};

} // namespace toit

#endif
