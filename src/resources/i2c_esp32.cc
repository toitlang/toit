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
#include <esp_memory_utils.h>

#include "../linked.h"
#include "../objects_inline.h"
#include "../process.h"
#include "../resource.h"
#include "../utils.h"
#include "../vm.h"

namespace toit {

// Should be lower than PROCESS_MAX_RUNTIME_US of scheduler.cc.
// Synchronous operations should never take that long anyway.
const int TOIT_I2C_SYNCHRONOUS_TIMEOUT_MS = 1000;

class I2cResourceGroup : public ResourceGroup {
 public:
  TAG(I2cResourceGroup);
  explicit I2cResourceGroup(Process* process)
    : ResourceGroup(process) {}
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

  I2cResourceGroup* resource_group() const {
    return static_cast<I2cResourceGroup*>(Resource::resource_group());
  }

 private:
  i2c_master_bus_handle_t handle_;
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

PRIMITIVE(bus_create) {
  ARGS(I2cResourceGroup, group, int, sda, int, scl, bool, pullup);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  bool handed_to_proxy = false;

  i2c_master_bus_config_t config = {
    .i2c_port = -1,  // Auto select.
    .sda_io_num = static_cast<gpio_num_t>(sda),
    .scl_io_num = static_cast<gpio_num_t>(scl),
    .clk_source = I2C_CLK_SRC_DEFAULT,
    .glitch_ignore_cnt = 7,
    .intr_priority = 0,
    .trans_queue_depth = 0,
    .flags = {
      .enable_internal_pullup = pullup,
    },
  };
  i2c_master_bus_handle_t handle;
  esp_err_t err = i2c_new_master_bus(&config, &handle);
  if (err == ESP_ERR_NOT_FOUND) FAIL(ALREADY_IN_USE);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  Defer del_bus { [&] { if (!handed_to_proxy) i2c_del_master_bus(handle); } };

  auto resource = _new I2cBusResource(group, handle);
  if (resource == null) FAIL(MALLOC_FAILED);

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
  if (address_bit_size == 7) {
    dev_addr_length = I2C_ADDR_BIT_LEN_7;
  #if SOC_I2C_SUPPORT_10BIT_ADDR
  } else if (address_bit_size == 10) {
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
