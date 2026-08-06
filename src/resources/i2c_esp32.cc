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

#include "../top.h"

#ifdef TOIT_ESP32

#include <cmath>
#include <driver/i2c_master.h>
#include <driver/i2c_slave.h>
#include <esp_memory_utils.h>
#include <freertos/idf_additions.h>
#include <freertos/message_buffer.h>
#include <freertos/queue.h>

#include "../linked.h"
#include "../objects_inline.h"
#include "../process.h"
#include "../resource.h"
#include "../utils.h"
#include "../vm.h"

#include "gpio_esp32.h"

#include "../event_sources/ev_queue_esp32.h"

namespace toit {

static_assert(SOC_I2C_NUM <= I2C_EVENT_QUEUE_SIZE,
              "Increase I2C_EVENT_QUEUE_SIZE");

// Should be lower than PROCESS_MAX_RUNTIME_US of scheduler.cc.
// Synchronous operations should never take that long anyway.
const int TOIT_I2C_SYNCHRONOUS_TIMEOUT_MS = 1000;

class I2cResourceGroup : public ResourceGroup {
 public:
  TAG(I2cResourceGroup);
  explicit I2cResourceGroup(Process* process)
    : ResourceGroup(process) {}
};

const word kTargetReceiveState = 1 << 0;
const word kTargetRequestState = 1 << 1;
const word kTargetOverflowState = 1 << 2;

class I2cTargetResourceGroup : public ResourceGroup {
 public:
  TAG(I2cTargetResourceGroup);

  I2cTargetResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    return state | data;
  }
};

class I2cTargetResource : public EventQueueResource {
 public:
  TAG(I2cTargetResource);

  I2cTargetResource(I2cTargetResourceGroup* group,
                    i2c_slave_dev_handle_t handle,
                    QueueHandle_t event_queue,
                    MessageBufferHandle_t receive_buffer)
      : EventQueueResource(group, event_queue)
      , handle_(handle)
      , receive_buffer_(receive_buffer) {
    spinlock_initialize(&spinlock_);
  }

  ~I2cTargetResource() override {
    ESP_ERROR_CHECK(i2c_del_slave_device(handle_));
    vMessageBufferDeleteWithCaps(receive_buffer_);
    vQueueDeleteWithCaps(queue());
    owned_pins_.release();
  }

  i2c_slave_dev_handle_t handle() const { return handle_; }
  MessageBufferHandle_t receive_buffer() const { return receive_buffer_; }
  GpioPins& owned_pins() { return owned_pins_; }

  IRAM_ATTR bool receive_from_isr(const uint8_t* data, size_t length) {
    BaseType_t higher_was_woken = pdFALSE;
    size_t sent = xMessageBufferSendFromISR(receive_buffer_, data, length, &higher_was_woken);
    signal_from_isr(sent == length ? kTargetReceiveState : kTargetOverflowState,
                    &higher_was_woken);
    if (sent != length) {
      portENTER_CRITICAL_ISR(&spinlock_);
      if (dropped_receive_count_ != Smi::MAX_SMI_VALUE) dropped_receive_count_++;
      portEXIT_CRITICAL_ISR(&spinlock_);
    }
    return higher_was_woken == pdTRUE;
  }

  IRAM_ATTR bool receive_overflow_from_isr() {
    BaseType_t higher_was_woken = pdFALSE;
    portENTER_CRITICAL_ISR(&spinlock_);
    if (dropped_receive_count_ != Smi::MAX_SMI_VALUE) dropped_receive_count_++;
    portEXIT_CRITICAL_ISR(&spinlock_);
    signal_from_isr(kTargetOverflowState, &higher_was_woken);
    return higher_was_woken == pdTRUE;
  }

  IRAM_ATTR bool request_from_isr() {
    BaseType_t higher_was_woken = pdFALSE;
    portENTER_CRITICAL_ISR(&spinlock_);
    if (request_count_ != Smi::MAX_SMI_VALUE) request_count_++;
    portEXIT_CRITICAL_ISR(&spinlock_);
    signal_from_isr(kTargetRequestState, &higher_was_woken);
    return higher_was_woken == pdTRUE;
  }

  word take_request_count() {
    portENTER_CRITICAL(&spinlock_);
    word result = request_count_;
    request_count_ = 0;
    portEXIT_CRITICAL(&spinlock_);
    return result;
  }

  word dropped_receive_count() const {
    portENTER_CRITICAL(&spinlock_);
    word result = dropped_receive_count_;
    portEXIT_CRITICAL(&spinlock_);
    return result;
  }

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
  IRAM_ATTR void signal_from_isr(word event, BaseType_t* higher_was_woken) {
    portENTER_CRITICAL_ISR(&spinlock_);
    pending_event_ |= event;
    portEXIT_CRITICAL_ISR(&spinlock_);

    word payload = 0;
    // A full queue already represents a pending notification. The event bits
    // above retain all event kinds until the event-source thread drains it.
    xQueueSendFromISR(queue(), &payload, higher_was_woken);
  }

  i2c_slave_dev_handle_t handle_;
  MessageBufferHandle_t receive_buffer_;
  mutable spinlock_t spinlock_;
  word pending_event_ = 0;
  word request_count_ = 0;
  word dropped_receive_count_ = 0;
  GpioPins owned_pins_;
};

class I2cRegisterTargetResource : public Resource {
 public:
  TAG(I2cRegisterTargetResource);

  I2cRegisterTargetResource(I2cResourceGroup* group,
                            i2c_slave_dev_handle_t handle,
                            uint8_t* registers,
                            uint32_t register_count,
                            uint32_t register_address_size)
      : Resource(group)
      , handle_(handle)
      , registers_(registers)
      , register_count_(register_count)
      , register_address_size_(register_address_size) {}

  ~I2cRegisterTargetResource() override {
    ESP_ERROR_CHECK(i2c_del_slave_device(handle_));
    free(registers_);
    owned_pins_.release();
  }

  IRAM_ATTR void receive_from_isr(const uint8_t* data, size_t length, bool overflow) {
    if (overflow) {
      if (dropped_write_count_ != Smi::MAX_SMI_VALUE) dropped_write_count_++;
      return;
    }
    if (length < register_address_size_) return;

    uint32_t pointer = 0;
    for (uint32_t i = 0; i < register_address_size_; i++) {
      pointer = (pointer << 8) | data[i];
    }
    register_pointer_ = pointer % register_count_;
    transmit_pointer_ = register_pointer_;
    for (size_t i = register_address_size_; i < length; i++) {
      registers_[register_pointer_] = data[i];
      register_pointer_++;
      if (register_pointer_ == register_count_) register_pointer_ = 0;
    }
  }

  IRAM_ATTR const uint8_t* transmit_from_isr(size_t capacity, size_t* length) {
    size_t remaining = register_count_ - transmit_pointer_;
    size_t result_length = capacity < remaining ? capacity : remaining;
    const uint8_t* result = registers_ + transmit_pointer_;
    transmit_pointer_ += result_length;
    if (transmit_pointer_ == register_count_) transmit_pointer_ = 0;
    *length = result_length;
    return result;
  }

  IRAM_ATTR void transmit_done_from_isr(size_t length) {
    uint32_t advance = length % register_count_;
    register_pointer_ = advance < register_count_ - register_pointer_
        ? register_pointer_ + advance
        : advance - (register_count_ - register_pointer_);
    transmit_pointer_ = register_pointer_;
  }

  int get(uint32_t index) const { return registers_[index]; }

  void set(uint32_t index, uint8_t value) { registers_[index] = value; }

  void read(uint32_t index, uint8_t* destination, uint32_t length) const {
    memcpy(destination, registers_ + index, length);
  }

  void write(uint32_t index, const uint8_t* source, uint32_t length) {
    memcpy(registers_ + index, source, length);
  }

  word dropped_write_count() const { return dropped_write_count_; }

  uint32_t register_count() const { return register_count_; }
  GpioPins& owned_pins() { return owned_pins_; }

 private:
  i2c_slave_dev_handle_t handle_;
  uint8_t* registers_;
  uint32_t register_count_;
  uint32_t register_address_size_;
  uint32_t register_pointer_ = 0;
  uint32_t transmit_pointer_ = 0;
  word dropped_write_count_ = 0;
  GpioPins owned_pins_;
};

class I2cBusResource;
class I2cDeviceResource;
typedef DoubleLinkedList<I2cDeviceResource, 99> DeviceList;

class I2cDeviceResource : public Resource, public DeviceList::Element {
 public:
  TAG(I2cDeviceResource);
  I2cDeviceResource(I2cResourceGroup* group,
                    I2cBusResource* bus,
                    i2c_master_dev_handle_t handle)
      : Resource(group)
      , bus_(bus)
      , handle_(handle) {}

  ~I2cDeviceResource() override;

  i2c_master_dev_handle_t handle() const { return handle_; }

 private:
  friend class I2cBusResource;
  I2cBusResource* bus_;
  i2c_master_dev_handle_t handle_;
};

class I2cBusResource : public Resource, public DeviceList {
 public:
  TAG(I2cBusResource);
  I2cBusResource(I2cResourceGroup* group, i2c_master_bus_handle_t handle)
      : Resource(group)
      , handle_(handle) {}

  ~I2cBusResource() override;

  i2c_master_bus_handle_t handle() const { return handle_; }

  void add_device(I2cDeviceResource* device);
  void remove_device(I2cDeviceResource* device);

  GpioPins& owned_pins() { return owned_pins_; }

  I2cResourceGroup* resource_group() const {
    return static_cast<I2cResourceGroup*>(Resource::resource_group());
  }

 private:
  i2c_master_bus_handle_t handle_;
  // GPIO pins reserved by this bus.
  GpioPins owned_pins_;
};

I2cDeviceResource::~I2cDeviceResource() {
  if (bus_ != null) {
    bus_->remove_device(this);
  }
}

I2cBusResource::~I2cBusResource() {
  while (!DeviceList::is_empty()) {
    // Removing the device doesn't delete the `I2cDeviceResource`, but only modifies
    // it so it doesn't have any handle anymore. The `I2cDeviceResource` still needs to
    // be deleted.
    remove_device(DeviceList::first());
  }
  ESP_ERROR_CHECK(i2c_del_master_bus(handle()));
  // Release any GPIO pins this bus reserved.
  owned_pins_.release();
}

void I2cBusResource::add_device(I2cDeviceResource* device) {
  DeviceList::append(device);
}

void I2cBusResource::remove_device(I2cDeviceResource* device) {
  ASSERT(device->bus_ == this);
  i2c_master_bus_rm_device(device->handle());
  device->bus_ = null;
  device->handle_ = null;
  DeviceList::unlink(device);
}


MODULE_IMPLEMENTATION(i2c, MODULE_I2C);

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  I2cResourceGroup* i2c = _new I2cResourceGroup(process);
  if (!i2c) {
    FAIL(MALLOC_FAILED);
  }

  proxy->set_external_address(i2c);
  return proxy;
}

PRIMITIVE(target_init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto group = _new I2cTargetResourceGroup(process, EventQueueEventSource::instance());
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

IRAM_ATTR static bool target_receive_handler(i2c_slave_dev_handle_t handle,
                                              const i2c_slave_rx_done_event_data_t* event,
                                              void* context) {
  auto resource = static_cast<I2cTargetResource*>(context);
  if (event->overflow) return resource->receive_overflow_from_isr();
  return resource->receive_from_isr(event->buffer, event->length);
}

IRAM_ATTR static bool target_request_handler(i2c_slave_dev_handle_t handle,
                                              const i2c_slave_request_event_data_t* event,
                                              void* context) {
  auto resource = static_cast<I2cTargetResource*>(context);
  return resource->request_from_isr();
}

PRIMITIVE(target_create) {
  ARGS(I2cTargetResourceGroup, group,
       int, sda,
       int, scl,
       int, address_bit_size,
       uint16, address,
       uint32, send_buffer_size,
       uint32, receive_buffer_size,
       bool, pullup,
       bool, allow_power_down,
       bool, broadcast);

  if (send_buffer_size == 0 || receive_buffer_size == 0) FAIL(INVALID_ARGUMENT);

  i2c_addr_bit_len_t address_length;
  if (address_bit_size == 7 && address <= 0x7f) {
    address_length = I2C_ADDR_BIT_LEN_7;
  #if SOC_I2C_SUPPORT_10BIT_ADDR
  } else if (address_bit_size == 10 && address <= 0x3ff) {
    address_length = I2C_ADDR_BIT_LEN_10;
  #endif
  } else {
    FAIL(INVALID_ARGUMENT);
  }

  #if !SOC_I2C_SLAVE_SUPPORT_BROADCAST
  if (broadcast) FAIL(UNSUPPORTED);
  #endif

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  GpioPinReserver reserver;
  bool reserve_ok = true;
  int sda_num = reserver.decode_and_take(sda, &reserve_ok);
  int scl_num = reserver.decode_and_take(scl, &reserve_ok);
  if (!reserve_ok) FAIL(ALREADY_IN_USE);

  bool handed_to_resource = false;

  QueueHandle_t event_queue = xQueueCreateWithCaps(
      1, sizeof(word), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  if (event_queue == null) FAIL(MALLOC_FAILED);
  Defer delete_event_queue {
    [&] { if (!handed_to_resource) vQueueDeleteWithCaps(event_queue); }
  };

  size_t message_buffer_size = receive_buffer_size + sizeof(size_t) + 1;
  if (message_buffer_size < receive_buffer_size) FAIL(INVALID_ARGUMENT);
  MessageBufferHandle_t receive_buffer = xMessageBufferCreateWithCaps(
      message_buffer_size, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  if (receive_buffer == null) FAIL(MALLOC_FAILED);
  Defer delete_receive_buffer {
    [&] { if (!handed_to_resource) vMessageBufferDeleteWithCaps(receive_buffer); }
  };

  i2c_slave_config_t config = {
    .i2c_port = -1,
    .sda_io_num = static_cast<gpio_num_t>(sda_num),
    .scl_io_num = static_cast<gpio_num_t>(scl_num),
    .clk_source = I2C_CLK_SRC_DEFAULT,
    .send_buf_depth = send_buffer_size,
    .receive_buf_depth = receive_buffer_size,
    .slave_addr = address,
    .addr_bit_len = address_length,
    .intr_priority = 0,
    .flags = {
      .allow_pd = allow_power_down,
      .enable_internal_pullup = pullup,
      #if SOC_I2C_SLAVE_SUPPORT_BROADCAST
      .broadcast_en = broadcast,
      #endif
    },
  };

  i2c_slave_dev_handle_t handle;
  esp_err_t err = i2c_new_slave_device(&config, &handle);
  if (err == ESP_ERR_NOT_FOUND) FAIL(ALREADY_IN_USE);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  Defer delete_target {
    [&] { if (!handed_to_resource) i2c_del_slave_device(handle); }
  };

  auto resource = _new I2cTargetResource(group, handle, event_queue, receive_buffer);
  if (resource == null) FAIL(MALLOC_FAILED);
  handed_to_resource = true;
  bool registered = false;
  Defer delete_resource { [&] { if (!registered) delete resource; } };

  i2c_slave_event_callbacks_t callbacks = {
    .on_request = target_request_handler,
    .on_receive = target_receive_handler,
    .on_transmit = null,
    .on_transmit_done = null,
  };
  err = i2c_slave_register_event_callbacks(handle, &callbacks, resource);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  resource->owned_pins().adopt(reserver);
  reserver.keep();
  group->register_resource(resource);
  proxy->set_external_address(resource);
  registered = true;
  return proxy;
}

PRIMITIVE(target_close) {
  ARGS(I2cTargetResourceGroup, group, I2cTargetResource, target);
  group->unregister_resource(target);
  target_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(target_receive) {
  ARGS(I2cTargetResource, target);

  auto receive_buffer = target->receive_buffer();
  size_t length = xMessageBufferNextLengthBytes(receive_buffer);
  if (length == 0) return process->null_object();

  ByteArray* result = process->allocate_byte_array(length);
  if (result == null) FAIL(ALLOCATION_FAILED);

  size_t received = xMessageBufferReceive(
      receive_buffer, ByteArray::Bytes(result).address(), length, 0);
  ASSERT(received == length);
  return result;
}

PRIMITIVE(target_write) {
  ARGS(I2cTargetResource, target, Blob, buffer, uint32, offset);
  if (offset > buffer.length()) FAIL(OUT_OF_BOUNDS);
  uint32_t length = buffer.length() - offset;
  if (length == 0) return Smi::zero();

  uint32_t written = 0;
  esp_err_t err = i2c_slave_write(
      target->handle(), buffer.address() + offset, length, &written, 0);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }
  ASSERT(Smi::is_valid(written));
  return Smi::from(written);
}

PRIMITIVE(target_take_request_count) {
  ARGS(I2cTargetResource, target);
  return Smi::from(target->take_request_count());
}

PRIMITIVE(target_dropped_receive_count) {
  ARGS(I2cTargetResource, target);
  return Smi::from(target->dropped_receive_count());
}

RTC_IRAM_ATTR static bool register_target_receive_handler(
    i2c_slave_dev_handle_t handle,
    const i2c_slave_rx_done_event_data_t* event,
    void* context) {
  auto resource = static_cast<I2cRegisterTargetResource*>(context);
  resource->receive_from_isr(event->buffer, event->length, event->overflow);
  return false;
}

RTC_IRAM_ATTR static bool register_target_transmit_handler(
    i2c_slave_dev_handle_t handle,
    i2c_slave_transmit_event_data_t* event,
    void* context) {
  auto resource = static_cast<I2cRegisterTargetResource*>(context);
  size_t length = 0;
  event->buffer = resource->transmit_from_isr(event->buffer_size, &length);
  event->length = length;
  return false;
}

RTC_IRAM_ATTR static bool register_target_transmit_done_handler(
    i2c_slave_dev_handle_t handle,
    const i2c_slave_transmit_done_event_data_t* event,
    void* context) {
  auto resource = static_cast<I2cRegisterTargetResource*>(context);
  resource->transmit_done_from_isr(event->length);
  return false;
}

PRIMITIVE(register_target_create) {
  ARGS(I2cResourceGroup, group,
       int, sda,
       int, scl,
       int, address_bit_size,
       uint16, address,
       uint32, register_count,
       uint32, register_address_size,
       uint32, receive_buffer_size,
       bool, pullup,
       bool, allow_power_down,
       bool, broadcast);

  if (register_count == 0 || receive_buffer_size == 0) FAIL(INVALID_ARGUMENT);
  if (register_address_size != 1 && register_address_size != 2) FAIL(INVALID_ARGUMENT);
  uint32_t addressable_register_count = 1u << (register_address_size * 8);
  if (register_count > addressable_register_count) FAIL(INVALID_ARGUMENT);

  i2c_addr_bit_len_t address_length;
  if (address_bit_size == 7 && address <= 0x7f) {
    address_length = I2C_ADDR_BIT_LEN_7;
  #if SOC_I2C_SUPPORT_10BIT_ADDR
  } else if (address_bit_size == 10 && address <= 0x3ff) {
    address_length = I2C_ADDR_BIT_LEN_10;
  #endif
  } else {
    FAIL(INVALID_ARGUMENT);
  }

  #if !SOC_I2C_SLAVE_SUPPORT_BROADCAST
  if (broadcast) FAIL(UNSUPPORTED);
  #endif

  #if !SOC_I2C_SLAVE_CAN_GET_STRETCH_CAUSE
  FAIL(UNSUPPORTED);
  #endif

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  uint8_t* registers = static_cast<uint8_t*>(heap_caps_calloc(
      register_count, sizeof(uint8_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
  if (registers == null) FAIL(MALLOC_FAILED);
  bool handed_to_resource = false;
  Defer free_registers { [&] { if (!handed_to_resource) free(registers); } };

  GpioPinReserver reserver;
  bool reserve_ok = true;
  int sda_num = reserver.decode_and_take(sda, &reserve_ok);
  int scl_num = reserver.decode_and_take(scl, &reserve_ok);
  if (!reserve_ok) FAIL(ALREADY_IN_USE);

  i2c_slave_config_t config = {
    .i2c_port = -1,
    .sda_io_num = static_cast<gpio_num_t>(sda_num),
    .scl_io_num = static_cast<gpio_num_t>(scl_num),
    .clk_source = I2C_CLK_SRC_DEFAULT,
    .send_buf_depth = SOC_I2C_FIFO_LEN,
    .receive_buf_depth = receive_buffer_size,
    .slave_addr = address,
    .addr_bit_len = address_length,
    .intr_priority = 0,
    .flags = {
      .allow_pd = allow_power_down,
      .enable_internal_pullup = pullup,
      #if SOC_I2C_SLAVE_SUPPORT_BROADCAST
      .broadcast_en = broadcast,
      #endif
    },
  };

  i2c_slave_dev_handle_t handle;
  esp_err_t err = i2c_new_slave_device(&config, &handle);
  if (err == ESP_ERR_NOT_FOUND) FAIL(ALREADY_IN_USE);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  Defer delete_target {
    [&] { if (!handed_to_resource) i2c_del_slave_device(handle); }
  };

  auto resource = _new I2cRegisterTargetResource(
      group, handle, registers, register_count, register_address_size);
  if (resource == null) FAIL(MALLOC_FAILED);
  handed_to_resource = true;
  bool registered = false;
  Defer delete_resource { [&] { if (!registered) delete resource; } };

  i2c_slave_event_callbacks_t callbacks = {
    .on_request = null,
    .on_receive = register_target_receive_handler,
    .on_transmit = register_target_transmit_handler,
    .on_transmit_done = register_target_transmit_done_handler,
  };
  err = i2c_slave_register_event_callbacks(handle, &callbacks, resource);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  resource->owned_pins().adopt(reserver);
  reserver.keep();
  group->register_resource(resource);
  proxy->set_external_address(resource);
  registered = true;
  return proxy;
}

PRIMITIVE(register_target_close) {
  ARGS(I2cResourceGroup, group, I2cRegisterTargetResource, target);
  group->unregister_resource(target);
  target_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(register_target_get) {
  ARGS(I2cRegisterTargetResource, target, uint32, index);
  if (index >= target->register_count()) FAIL(OUT_OF_BOUNDS);
  return Smi::from(target->get(index));
}

PRIMITIVE(register_target_set) {
  ARGS(I2cRegisterTargetResource, target, uint32, index, uint8, value);
  if (index >= target->register_count()) FAIL(OUT_OF_BOUNDS);
  target->set(index, value);
  return Smi::from(value);
}

PRIMITIVE(register_target_read) {
  ARGS(I2cRegisterTargetResource, target, uint32, index, uint32, length);
  if (index > target->register_count()) FAIL(OUT_OF_BOUNDS);
  if (length > target->register_count() - index) FAIL(OUT_OF_BOUNDS);
  ByteArray* result = process->allocate_byte_array(length);
  if (result == null) FAIL(ALLOCATION_FAILED);
  target->read(index, ByteArray::Bytes(result).address(), length);
  return result;
}

PRIMITIVE(register_target_write) {
  ARGS(I2cRegisterTargetResource, target, uint32, index, Blob, bytes);
  if (index > target->register_count()) FAIL(OUT_OF_BOUNDS);
  if (bytes.length() > target->register_count() - index) FAIL(OUT_OF_BOUNDS);
  target->write(index, bytes.address(), bytes.length());
  return process->null_object();
}

PRIMITIVE(register_target_dropped_write_count) {
  ARGS(I2cRegisterTargetResource, target);
  return Smi::from(target->dropped_write_count());
}

PRIMITIVE(bus_create) {
  ARGS(I2cResourceGroup, group, int, sda, int, scl, bool, pullup);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  // Decode the pins and reserve them from the shared
  // pool. The reserver releases everything again if we leave without calling
  // `keep()`.
  GpioPinReserver reserver;
  bool reserve_ok = true;
  int sda_num = reserver.decode_and_take(sda, &reserve_ok);
  int scl_num = reserver.decode_and_take(scl, &reserve_ok);
  if (!reserve_ok) FAIL(ALREADY_IN_USE);

  bool handed_to_proxy = false;

  i2c_master_bus_config_t config = {
    .i2c_port = -1,  // Auto select.
    .sda_io_num = static_cast<gpio_num_t>(sda_num),
    .scl_io_num = static_cast<gpio_num_t>(scl_num),
    .clk_source = I2C_CLK_SRC_DEFAULT,
    .glitch_ignore_cnt = 7,
    .intr_priority = 0,
    .trans_queue_depth = 0,
    .flags = {
      .enable_internal_pullup = pullup,
      .allow_pd = false,
    },
  };
  i2c_master_bus_handle_t handle;
  esp_err_t err = i2c_new_master_bus(&config, &handle);
  if (err == ESP_ERR_NOT_FOUND) FAIL(ALREADY_IN_USE);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  Defer del_bus { [&] { if (!handed_to_proxy) i2c_del_master_bus(handle); } };

  auto resource = _new I2cBusResource(group, handle);
  if (resource == null) FAIL(MALLOC_FAILED);

  // The reservation now belongs to the resource and is released on close.
  resource->owned_pins().adopt(reserver);
  reserver.keep();

  group->register_resource(resource);
  proxy->set_external_address(resource);
  handed_to_proxy = true;

  return proxy;
}

PRIMITIVE(bus_close) {
  ARGS(I2cBusResource, resource);
  resource->resource_group()->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(bus_probe) {
  ARGS(I2cBusResource, resource, uint16, address, int, timeout_ms);

  esp_err_t err = i2c_master_probe(resource->handle(), address, timeout_ms);
  return BOOL(err == ESP_OK);
}

PRIMITIVE(bus_reset) {
  ARGS(I2cBusResource, resource);

  esp_err_t err = i2c_master_bus_reset(resource->handle());
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->null_object();
}

PRIMITIVE(device_create) {
  ARGS(I2cBusResource, bus,
       int, address_bit_size,
       uint16, address,
       uint32, frequency_hz,
       uint32, timeout_us,
       bool, disable_ack_check)

  i2c_addr_bit_len_t dev_addr_length;
  if (address_bit_size == 7 && address <= 0x7f) {
    dev_addr_length = I2C_ADDR_BIT_LEN_7;
  #if SOC_I2C_SUPPORT_10BIT_ADDR
  } else if (address_bit_size == 10 && address <= 0x3ff) {
    dev_addr_length = I2C_ADDR_BIT_LEN_10;
  #endif
  } else {
    FAIL(INVALID_ARGUMENT);
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  bool handed_to_proxy = false;

  i2c_device_config_t config = {
    .dev_addr_length = dev_addr_length,
    .device_address = address,
    .scl_speed_hz = frequency_hz,
    .scl_wait_us = timeout_us,
    .flags = {
      .disable_ack_check = disable_ack_check,
    },
  };
  i2c_master_dev_handle_t handle;
  esp_err_t err = i2c_master_bus_add_device(bus->handle(), &config, &handle);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  Defer remove_device { [&] { if (!handed_to_proxy) i2c_master_bus_rm_device(handle); } };

  auto resource = _new I2cDeviceResource(bus->resource_group(),
                                         bus,
                                         handle);
  if (resource == null) FAIL(MALLOC_FAILED);

  bus->resource_group()->register_resource(resource);
  proxy->set_external_address(resource);
  handed_to_proxy = true;

  return proxy;
}

PRIMITIVE(device_close) {
  ARGS(I2cDeviceResource, resource);

  resource->resource_group()->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(device_write) {
  ARGS(I2cDeviceResource, resource, Blob, buffer);
  if (resource->handle() == null) FAIL(ALREADY_CLOSED);

  int timeout = TOIT_I2C_SYNCHRONOUS_TIMEOUT_MS;
  esp_err_t err = i2c_master_transmit(resource->handle(), buffer.address(), buffer.length(), timeout);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->null_object();
}

PRIMITIVE(device_read) {
  ARGS(I2cDeviceResource, resource, MutableBlob, buffer, int, length);
  if (resource->handle() == null) FAIL(ALREADY_CLOSED);
  if (length > buffer.length()) FAIL(OUT_OF_BOUNDS);

  int timeout = TOIT_I2C_SYNCHRONOUS_TIMEOUT_MS;
  esp_err_t err = i2c_master_receive(resource->handle(), buffer.address(), length, timeout);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->null_object();
}


PRIMITIVE(device_write_read) {
  ARGS(I2cDeviceResource, resource, Blob, tx_buffer, MutableBlob, rx_buffer, int, length)
  if (resource->handle() == null) FAIL(ALREADY_CLOSED);
  if (length > rx_buffer.length()) FAIL(OUT_OF_BOUNDS);

  int timeout = TOIT_I2C_SYNCHRONOUS_TIMEOUT_MS;
  esp_err_t err = i2c_master_transmit_receive(resource->handle(),
                                              tx_buffer.address(),
                                              tx_buffer.length(),
                                              rx_buffer.address(),
                                              length,
                                              timeout);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->null_object();
}

} // namespace toit

#endif // TOIT_ESP32
