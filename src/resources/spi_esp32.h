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
#include <driver/spi_slave.h>
#include <freertos/queue.h>

#include "../os.h"
#include "../objects.h"
#include "../resource.h"

#include "gpio_esp32.h"

#include "../event_sources/ev_queue_esp32.h"

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

const word kSpiTargetReadyState = 1 << 0;
const word kSpiTargetDoneState = 1 << 1;

class SpiTargetResourceGroup : public ResourceGroup {
 public:
  TAG(SpiTargetResourceGroup);

  SpiTargetResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    return state | data;
  }
};

class SpiTargetResource : public EventQueueResource {
 public:
  TAG(SpiTargetResource);

  SpiTargetResource(SpiTargetResourceGroup* group,
                    spi_host_device_t host_device,
                    QueueHandle_t event_queue,
                    size_t max_transfer_size,
                    size_t buffer_alignment,
                    bool dma)
      : EventQueueResource(group, event_queue)
      , host_device_(host_device)
      , max_transfer_size_(max_transfer_size)
      , buffer_alignment_(buffer_alignment)
      , dma_(dma) {
    spinlock_initialize(&spinlock_);
  }

  ~SpiTargetResource() override;

  spi_host_device_t host_device() const { return host_device_; }
  size_t max_transfer_size() const { return max_transfer_size_; }
  size_t buffer_alignment() const { return buffer_alignment_; }
  GpioPins& owned_pins() { return owned_pins_; }

  bool initialized() const { return initialized_; }
  void set_initialized() { initialized_ = true; }

  bool operation_in_flight() const { return operation_in_flight_; }
  spi_slave_transaction_t* transaction() { return &transaction_; }

  void prepare_operation(uint8_t* tx_buffer,
                         uint8_t* rx_buffer,
                         size_t receive_size,
                         size_t transfer_size);
  void finish_operation();

  uint8_t* receive_buffer() const { return rx_buffer_; }
  size_t receive_size() const { return receive_size_; }
  size_t transferred_bits() const { return transaction_.trans_len; }
  bool dma() const { return dma_; }

  IRAM_ATTR void ready_from_isr() { signal_from_isr(kSpiTargetReadyState); }
  IRAM_ATTR void complete_from_isr() { signal_from_isr(kSpiTargetDoneState); }

  bool receive_event(word* data) override {
    word unused;
    if (xQueueReceive(queue(), &unused, 0) != pdTRUE) return false;
    portENTER_CRITICAL(&spinlock_);
    *data = pending_event_;
    pending_event_ = 0;
    portEXIT_CRITICAL(&spinlock_);
    return true;
  }

 private:
  IRAM_ATTR void signal_from_isr(word event) {
    BaseType_t higher_was_woken = pdFALSE;
    portENTER_CRITICAL_ISR(&spinlock_);
    pending_event_ |= event;
    portEXIT_CRITICAL_ISR(&spinlock_);
    word payload = 0;
    xQueueSendFromISR(queue(), &payload, &higher_was_woken);
  }

  spi_host_device_t host_device_;
  const size_t max_transfer_size_;
  const size_t buffer_alignment_;
  const bool dma_;
  bool initialized_ = false;
  bool operation_in_flight_ = false;
  spi_slave_transaction_t transaction_ = {};
  uint8_t* tx_buffer_ = null;
  uint8_t* rx_buffer_ = null;
  size_t receive_size_ = 0;
  spinlock_t spinlock_;
  word pending_event_ = 0;
  GpioPins owned_pins_;
};

} // namespace toit

#endif
