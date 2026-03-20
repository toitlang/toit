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

#include "../top.h"

#ifdef TOIT_EC618

#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"

extern "C" {
  #include "Driver_I2C.h"

  // CMSIS I2C driver instances from the PLAT SDK.
  extern ARM_DRIVER_I2C Driver_I2C0;
  extern ARM_DRIVER_I2C Driver_I2C1;
}

namespace toit {

// Map SDA/SCL pin pairs to I2C port.
static ARM_DRIVER_I2C* pin_to_driver(int sda, int scl) {
  // I2C0: pins 12(SDA)/13(SCL) or 16/17.
  if ((sda == 12 && scl == 13) || (sda == 16 && scl == 17)) return &Driver_I2C0;
  // I2C1: pins 4(SDA)/5(SCL) or 8/9.
  if ((sda == 4 && scl == 5) || (sda == 8 && scl == 9)) return &Driver_I2C1;
  return null;
}

static uint32_t frequency_to_speed(int frequency) {
  if (frequency <= 100000) return ARM_I2C_BUS_SPEED_STANDARD;
  if (frequency <= 400000) return ARM_I2C_BUS_SPEED_FAST;
  if (frequency <= 1000000) return ARM_I2C_BUS_SPEED_FAST_PLUS;
  return ARM_I2C_BUS_SPEED_HIGH;
}

class I2cBusResource : public Resource {
 public:
  TAG(I2cBusResource);
  I2cBusResource(ResourceGroup* group, ARM_DRIVER_I2C* driver)
    : Resource(group)
    , driver_(driver) {}

  ~I2cBusResource() {
    driver_->PowerControl(ARM_POWER_OFF);
    driver_->Uninitialize();
  }

  ARM_DRIVER_I2C* driver() const { return driver_; }

 private:
  ARM_DRIVER_I2C* driver_;
};

class I2cDeviceResource : public Resource {
 public:
  TAG(I2cDeviceResource);
  I2cDeviceResource(ResourceGroup* group, I2cBusResource* bus, int address)
    : Resource(group)
    , bus_(bus)
    , address_(address) {}

  ARM_DRIVER_I2C* driver() const { return bus_->driver(); }
  int address() const { return address_; }

 private:
  I2cBusResource* bus_;
  int address_;
};

class I2cResourceGroup : public ResourceGroup {
 public:
  TAG(I2cResourceGroup);
  explicit I2cResourceGroup(Process* process)
    : ResourceGroup(process, null) {}
};

MODULE_IMPLEMENTATION(i2c, MODULE_I2C)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  I2cResourceGroup* group = _new I2cResourceGroup(process);
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(bus_create) {
  ARGS(I2cResourceGroup, group, int, sda, int, scl, int, frequency);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  ARM_DRIVER_I2C* driver = pin_to_driver(sda, scl);
  if (driver == null) FAIL(INVALID_ARGUMENT);

  int32_t status = driver->Initialize(null);
  if (status != ARM_DRIVER_OK) FAIL(HARDWARE_ERROR);

  status = driver->PowerControl(ARM_POWER_FULL);
  if (status != ARM_DRIVER_OK) {
    driver->Uninitialize();
    FAIL(HARDWARE_ERROR);
  }

  status = driver->Control(ARM_I2C_BUS_SPEED, frequency_to_speed(frequency));
  if (status != ARM_DRIVER_OK) {
    driver->PowerControl(ARM_POWER_OFF);
    driver->Uninitialize();
    FAIL(HARDWARE_ERROR);
  }

  driver->Control(ARM_I2C_BUS_CLEAR, 0);

  I2cBusResource* bus = _new I2cBusResource(group, driver);
  if (bus == null) {
    driver->PowerControl(ARM_POWER_OFF);
    driver->Uninitialize();
    FAIL(MALLOC_FAILED);
  }

  group->register_resource(bus);
  proxy->set_external_address(bus);
  return proxy;
}

PRIMITIVE(bus_close) {
  ARGS(I2cBusResource, bus);
  bus->resource_group()->unregister_resource(bus);
  bus_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(bus_probe) {
  ARGS(I2cBusResource, bus, int, address, bool, hold);
  USE(hold);
  // Try a zero-length write to detect device presence.
  uint8 dummy = 0;
  int32_t status = bus->driver()->MasterTransmit(address, &dummy, 0, false);
  return BOOL(status == ARM_DRIVER_OK);
}

PRIMITIVE(bus_reset) {
  ARGS(I2cBusResource, bus);
  bus->driver()->Control(ARM_I2C_BUS_CLEAR, 0);
  return process->null_object();
}

PRIMITIVE(device_create) {
  ARGS(I2cResourceGroup, group, I2cBusResource, bus, int, address,
       int, register_address_size, int, register_big_endian, int, frequency);
  USE(register_big_endian); USE(frequency);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  I2cDeviceResource* device = _new I2cDeviceResource(group, bus, address);
  if (device == null) FAIL(MALLOC_FAILED);

  group->register_resource(device);
  proxy->set_external_address(device);
  return proxy;
}

PRIMITIVE(device_close) {
  ARGS(I2cDeviceResource, device);
  device->resource_group()->unregister_resource(device);
  device_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(device_write) {
  ARGS(I2cDeviceResource, device, Blob, data);
  ARM_DRIVER_I2C* driver = device->driver();
  int32_t status = driver->MasterTransmit(
      device->address(),
      const_cast<uint8_t*>(data.address()),
      data.length(),
      false);
  if (status != ARM_DRIVER_OK) FAIL(HARDWARE_ERROR);
  while (driver->GetStatus().busy) {}
  return process->null_object();
}

PRIMITIVE(device_read) {
  ARGS(I2cDeviceResource, device, Blob, register_address, int, read_length);
  ARM_DRIVER_I2C* driver = device->driver();
  int address = device->address();

  // Write register address with repeated start.
  if (register_address.length() > 0) {
    int32_t status = driver->MasterTransmit(
        address,
        const_cast<uint8_t*>(register_address.address()),
        register_address.length(),
        true);  // pending = repeated start.
    if (status != ARM_DRIVER_OK) FAIL(HARDWARE_ERROR);
    while (driver->GetStatus().busy) {}
  }

  ByteArray* result = process->object_heap()->allocate_internal_byte_array(read_length);
  if (result == null) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes bytes(result);

  int32_t status = driver->MasterReceive(address, bytes.address(), read_length, false);
  if (status != ARM_DRIVER_OK) FAIL(HARDWARE_ERROR);
  while (driver->GetStatus().busy) {}

  return result;
}

PRIMITIVE(device_write_read) {
  ARGS(I2cDeviceResource, device, Blob, write_data, int, read_length, bool, repeated_start);
  ARM_DRIVER_I2C* driver = device->driver();
  int address = device->address();

  // Write phase.
  if (write_data.length() > 0) {
    bool pending = repeated_start && (read_length > 0);
    int32_t status = driver->MasterTransmit(
        address,
        const_cast<uint8_t*>(write_data.address()),
        write_data.length(),
        pending);
    if (status != ARM_DRIVER_OK) FAIL(HARDWARE_ERROR);
    // Wait for transfer to complete.
    while (driver->GetStatus().busy) {}
  }

  // Read phase.
  if (read_length > 0) {
    ByteArray* result = process->object_heap()->allocate_internal_byte_array(read_length);
    if (result == null) FAIL(ALLOCATION_FAILED);
    ByteArray::Bytes bytes(result);

    int32_t status = driver->MasterReceive(address, bytes.address(), read_length, false);
    if (status != ARM_DRIVER_OK) FAIL(HARDWARE_ERROR);
    while (driver->GetStatus().busy) {}

    return result;
  }

  return process->null_object();
}

}  // namespace toit

#endif  // TOIT_EC618
