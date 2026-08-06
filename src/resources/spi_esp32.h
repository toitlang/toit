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
#include "../event_sources/ev_queue_esp32.h"

#include "gpio_esp32.h"

namespace toit {

class SpiResourceGroup : public ResourceGroup {
 public:
  TAG(SpiResourceGroup);
  SpiResourceGroup(Process* process, EventSource* event_source, spi_host_device_t host_device);
  ~SpiResourceGroup() override;

  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    return state | data;
  }

  spi_host_device_t host_device() { return host_device_; }

  // GPIO pins reserved by this bus (mosi/miso/clock).
  GpioPins& owned_pins() { return owned_pins_; }

 private:
  spi_host_device_t host_device_;
  GpioPins owned_pins_;
};

const word kSpiControllerDoneState = 1 << 0;

class SpiDevice : public EventQueueResource {
 public:
  TAG(SpiDevice);
  static const size_t INLINE_TX_SIZE = 4;
  SpiDevice(ResourceGroup* group,
            spi_device_handle_t handle,
            QueueHandle_t event_queue,
            int dc)
    : EventQueueResource(group, event_queue)
    , handle_(handle)
    , dc_(dc) {}

  ~SpiDevice() override;

  spi_device_handle_t handle() { return handle_; }

  int dc() { return dc_; }
  int dc_value() const { return dc_value_; }

  bool operation_in_flight() const { return operation_in_flight_; }
  spi_transaction_t* transaction() { return &transaction_; }
  size_t transfer_size() const { return transfer_size_; }
  uint8_t* receive_buffer() const { return rx_buffer_; }

  void prepare_operation(const uint8_t* tx_data,
                         uint8_t* tx_buffer,
                         uint8_t* rx_buffer,
                         size_t transfer_size,
                         uint32_t flags,
                         uint16_t command,
                         uint64_t address,
                         int dc_value);
  void finish_operation();

  IRAM_ATTR void complete_from_isr();
  bool receive_event(word* data) override;

  // GPIO pins reserved by this device (cs/dc).
  GpioPins& owned_pins() { return owned_pins_; }

 private:
  spi_device_handle_t handle_;
  int dc_;
  GpioPins owned_pins_;
  bool operation_in_flight_ = false;
  spi_transaction_t transaction_ = {};
  uint8_t* tx_buffer_ = null;
  uint8_t* rx_buffer_ = null;
  size_t transfer_size_ = 0;
  int dc_value_ = 0;
};

} // namespace toit

#endif
