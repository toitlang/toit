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

namespace toit {

class SPIResourceGroup : public ResourceGroup {
 public:
  TAG(SPIResourceGroup);
  SPIResourceGroup(Process* process, EventSource* event_source, spi_host_device_t host_device, int dma_chan);
  ~SPIResourceGroup();
  spi_host_device_t host_device() { return _host_device; }

 private:
  spi_host_device_t _host_device;
  int _dma_chan;
};

class SPIDevice : public Resource {
 public:
  static const int BUFFER_SIZE = 16;

  TAG(SPIDevice);
  SPIDevice(ResourceGroup* group, spi_device_handle_t handle, int dc)
    : Resource(group)
    , _handle(handle)
    , _dc(dc) {
  }

  ~SPIDevice() {
    spi_bus_remove_device(_handle);
  }

  spi_device_handle_t handle() { return _handle; }

  int dc() { return _dc; }

  uint8_t* buffer() {
    return _buffer;
  }

 private:
  spi_device_handle_t _handle;
  int _dc;

  // Pre-allocated buffer for small transfers. Must be 4-byte aligned.
  alignas(4) uint8_t _buffer[BUFFER_SIZE];
};

} // namespace toit

#endif
