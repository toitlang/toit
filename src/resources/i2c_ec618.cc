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

#include "pad_table_ec618.h"

extern "C" {
  #include "Driver_I2C.h"
  #include "cmsis_os2.h"     // osDelay, for the completion guard.
  #include "driver_gpio.h"   // GPIO_PullConfig / GPIO_IomuxEC618.
  #include "gpio.h"          // OEM GPIO_pinConfig/pinRead, for the bus peek.

  // CMSIS I2C driver instances from the PLAT SDK. Both run in POLLING_MODE
  // (RTE_Device.h), so Master* calls block until the transfer is done.
  extern ARM_DRIVER_I2C Driver_I2C0;
  extern ARM_DRIVER_I2C Driver_I2C1;
}

namespace toit {

// Pin arguments are PAD numbers (the EC618 addressing model). Controller
// routings, all iomux ALT2 (the full set from the SDK's luat_i2c_ec618.c;
// the RTE_Device.h comments only document one per controller):
//   I2C0: SDA/SCL = 13/14, 27/28 (RTE default) or 31/32
//   I2C1: SDA/SCL = 19/20 (RTE default) or 23/24 (the Air780E's I2C1 pins)
static ARM_DRIVER_I2C* pads_to_driver(int sda, int scl) {
  if (sda == 13 && scl == 14) return &Driver_I2C0;
  if (sda == 27 && scl == 28) return &Driver_I2C0;
  if (sda == 31 && scl == 32) return &Driver_I2C0;
  if (sda == 19 && scl == 20) return &Driver_I2C1;
  if (sda == 23 && scl == 24) return &Driver_I2C1;
  return null;
}

static uint32_t frequency_to_speed(uint32_t frequency) {
  if (frequency <= 100000) return ARM_I2C_BUS_SPEED_STANDARD;
  if (frequency <= 400000) return ARM_I2C_BUS_SPEED_FAST;
  if (frequency <= 1000000) return ARM_I2C_BUS_SPEED_FAST_PLUS;
  return ARM_I2C_BUS_SPEED_HIGH;
}

// Reads the wire level of an I2C pad: direction input, briefly mux to
// plain GPIO, sample, restore the controller mux (ALT2).
static bool wire_high(int pad) {
  int gpio_bit = pad_to_gpio(pad);
  if (gpio_bit < 0) return true;  // Cannot peek; assume fine.
  GpioPinConfig_t config;
  memset(&config, 0, sizeof(config));
  config.pinDirection = GPIO_DIRECTION_INPUT;
  GPIO_pinConfig(gpio_bit >> 4, gpio_bit & 0xf, &config);
  GPIO_IomuxEC618(pad, 0, 0, 1);
  int level = GPIO_pinRead(gpio_bit >> 4, gpio_bit & 0xf) ? 1 : 0;
  GPIO_IomuxEC618(pad, 2, 1, 1);
  return level != 0;
}

class I2cBusResource : public Resource {
 public:
  TAG(I2cBusResource);
  I2cBusResource(ResourceGroup* group, ARM_DRIVER_I2C* driver, int sda, int scl)
    : Resource(group)
    , driver_(driver)
    , sda_(sda)
    , scl_(scl) {}

  ~I2cBusResource() override {
    driver_->PowerControl(ARM_POWER_OFF);
    driver_->Uninitialize();
  }

  ARM_DRIVER_I2C* driver() const { return driver_; }

  // Applies the bus speed for the given device frequency if it differs
  // from what the controller is currently configured for.
  void ensure_speed(uint32_t frequency) {
    uint32_t speed = frequency_to_speed(frequency);
    if (speed == current_speed_) return;
    driver_->Control(ARM_I2C_BUS_SPEED, speed);
    current_speed_ = speed;
  }

  // Whether both lines idle high. A dead bus (no pull-ups, e.g. the
  // peripheral powered off) MUST be caught before any transfer: the
  // blob's polling driver has no timeout and a transfer on a stuck-low
  // bus blocks the VM until the watchdog resets the chip (observed).
  bool bus_free() const {
    return (wire_high(sda_)) && (wire_high(scl_));
  }

 private:
  ARM_DRIVER_I2C* driver_;
  int sda_;
  int scl_;
  uint32_t current_speed_ = 0;
};

class I2cDeviceResource : public Resource {
 public:
  TAG(I2cDeviceResource);
  I2cDeviceResource(ResourceGroup* group, I2cBusResource* bus, int address,
                    uint32_t frequency, uint32_t timeout_us, bool disable_ack_check)
    : Resource(group)
    , bus_(bus)
    , address_(address)
    , frequency_(frequency)
    , timeout_us_(timeout_us)
    , disable_ack_check_(disable_ack_check) {}

  I2cBusResource* bus() const { return bus_; }
  ARM_DRIVER_I2C* driver() const { return bus_->driver(); }
  int address() const { return address_; }
  uint32_t frequency() const { return frequency_; }
  uint32_t timeout_us() const { return timeout_us_; }
  bool disable_ack_check() const { return disable_ack_check_; }

 private:
  I2cBusResource* bus_;
  int address_;
  uint32_t frequency_;
  uint32_t timeout_us_;
  bool disable_ack_check_;
};

class I2cResourceGroup : public ResourceGroup {
 public:
  TAG(I2cResourceGroup);
  explicit I2cResourceGroup(Process* process)
    : ResourceGroup(process, null) {}
};

// Waits for the controller to go idle. In POLLING_MODE the Master* calls
// block until the transfer completes, so this is only a guard against the
// blob doing something unexpected; it should never actually spin.
static bool wait_idle(ARM_DRIVER_I2C* driver, uint32_t timeout_us) {
  uint32_t waited_us = 0;
  while (driver->GetStatus().busy) {
    if (waited_us >= timeout_us) return false;
    osDelay(1);
    waited_us += 1000;
  }
  return true;
}

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
  ARGS(I2cResourceGroup, group, int, sda, int, scl, bool, pullup);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  ARM_DRIVER_I2C* driver = pads_to_driver(sda, scl);
  if (driver == null) FAIL(INVALID_ARGUMENT);

  int32_t status = driver->Initialize(null);
  if (status != ARM_DRIVER_OK) FAIL(HARDWARE_ERROR);

  status = driver->PowerControl(ARM_POWER_FULL);
  if (status != ARM_DRIVER_OK) {
    driver->Uninitialize();
    FAIL(HARDWARE_ERROR);
  }

  status = driver->Control(ARM_I2C_BUS_SPEED, ARM_I2C_BUS_SPEED_STANDARD);
  if (status != ARM_DRIVER_OK) {
    driver->PowerControl(ARM_POWER_OFF);
    driver->Uninitialize();
    FAIL(HARDWARE_ERROR);
  }

  // The blob muxes its RTE-configured pads at init (I2C0: 27/28, I2C1:
  // 19/20). When the caller picked a different routing, route the RTE
  // pads back to plain GPIO: two pads muxed onto one controller leave
  // the input path reading the floating RTE pad, which makes the
  // controller see a busy bus — no SCL ever, transfers stall.
  int rte_sda = (driver == &Driver_I2C0) ? 27 : 19;
  if (sda != rte_sda) {
    GPIO_IomuxEC618(rte_sda, 0, 0, 0);
    GPIO_IomuxEC618(rte_sda + 1, 0, 0, 0);  // The matching SCL pad.
  }

  // Route the chosen pads to the controller (ALT2, input buffer on,
  // peripheral auto-pull).
  GPIO_IomuxEC618(sda, 2, 1, 1);
  GPIO_IomuxEC618(scl, 2, 1, 1);

  if (pullup) {
    // Pad-level pulls on top of the ALT2 iomux.
    GPIO_PullConfig(sda, 1, 1);
    GPIO_PullConfig(scl, 1, 1);
  }

  driver->Control(ARM_I2C_BUS_CLEAR, 0);

  I2cBusResource* bus = _new I2cBusResource(group, driver, sda, scl);
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
  ARGS(I2cBusResource, bus, uint16, address, int, timeout_ms);
  // Probe with a 1-byte receive (the SMBus "receive byte" idiom): the
  // blob's polling driver handles it uniformly, whereas a zero-length
  // write is not reliably supported. A present device ACKs its address
  // and one byte transfers; an empty address NACKs and the data count
  // stays 0.
  if (!bus->bus_free()) return BOOL(false);
  ARM_DRIVER_I2C* driver = bus->driver();
  uint8_t scratch;
  int32_t status = driver->MasterReceive(address, &scratch, 1, false);
  if (status != ARM_DRIVER_OK) return BOOL(false);
  if (!wait_idle(driver, timeout_ms * 1000)) {
    driver->Control(ARM_I2C_ABORT_TRANSFER, 0);
    return BOOL(false);
  }
  return BOOL(driver->GetDataCount() == 1);
}

PRIMITIVE(bus_reset) {
  ARGS(I2cBusResource, bus);
  bus->driver()->Control(ARM_I2C_BUS_CLEAR, 0);
  return process->null_object();
}

PRIMITIVE(device_create) {
  ARGS(I2cBusResource, bus, int, address_bit_size, uint16, address,
       uint32, frequency_hz, uint32, timeout_us, bool, disable_ack_check);
  // 10-bit addressing exists in the CMSIS API (ARM_I2C_ADDRESS_10BIT) but
  // is untested on this chip; reject until needed.
  if (address_bit_size != 7) FAIL(INVALID_ARGUMENT);
  if (frequency_hz == 0) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  I2cDeviceResource* device = _new I2cDeviceResource(
      bus->resource_group(), bus, address, frequency_hz, timeout_us,
      disable_ack_check);
  if (device == null) FAIL(MALLOC_FAILED);

  bus->resource_group()->register_resource(device);
  proxy->set_external_address(device);
  return proxy;
}

PRIMITIVE(device_close) {
  ARGS(I2cDeviceResource, device);
  device->resource_group()->unregister_resource(device);
  device_proxy->clear_external_address();
  return process->null_object();
}

// Runs one master transfer (transmit or receive) and applies the device's
// completion/ACK policy. Returns null on success, otherwise the failure to
// raise (as a primitive failure string handled by the callers).
static bool transfer_ok(I2cDeviceResource* device, int32_t status, int expected) {
  if (status != ARM_DRIVER_OK) return false;
  ARM_DRIVER_I2C* driver = device->driver();
  if (!wait_idle(driver, device->timeout_us())) {
    driver->Control(ARM_I2C_ABORT_TRANSFER, 0);
    return false;
  }
  if (device->disable_ack_check()) return true;
  // A NACK'd address or a short transfer shows up as a low data count.
  return driver->GetDataCount() == expected;
}

PRIMITIVE(device_write) {
  ARGS(I2cDeviceResource, device, Blob, buffer);
  if (!device->bus()->bus_free()) FAIL(HARDWARE_ERROR);
  device->bus()->ensure_speed(device->frequency());
  int32_t status = device->driver()->MasterTransmit(
      device->address(),
      const_cast<uint8_t*>(buffer.address()),
      buffer.length(),
      false);
  if (!transfer_ok(device, status, buffer.length())) FAIL(HARDWARE_ERROR);
  return process->null_object();
}

PRIMITIVE(device_read) {
  ARGS(I2cDeviceResource, device, MutableBlob, buffer, int, length);
  if (length > buffer.length()) FAIL(OUT_OF_BOUNDS);
  if (!device->bus()->bus_free()) FAIL(HARDWARE_ERROR);
  device->bus()->ensure_speed(device->frequency());
  int32_t status = device->driver()->MasterReceive(
      device->address(), buffer.address(), length, false);
  if (!transfer_ok(device, status, length)) FAIL(HARDWARE_ERROR);
  return process->null_object();
}

PRIMITIVE(device_write_read) {
  ARGS(I2cDeviceResource, device, Blob, tx_buffer, MutableBlob, rx_buffer, int, length);
  if (length > rx_buffer.length()) FAIL(OUT_OF_BOUNDS);
  if (!device->bus()->bus_free()) FAIL(HARDWARE_ERROR);
  device->bus()->ensure_speed(device->frequency());
  ARM_DRIVER_I2C* driver = device->driver();

  if (tx_buffer.length() > 0) {
    // pending=true keeps the bus claimed for a repeated start into the read.
    int32_t status = driver->MasterTransmit(
        device->address(),
        const_cast<uint8_t*>(tx_buffer.address()),
        tx_buffer.length(),
        length > 0);
    if (!transfer_ok(device, status, tx_buffer.length())) FAIL(HARDWARE_ERROR);
  }

  if (length > 0) {
    int32_t status = driver->MasterReceive(
        device->address(), rx_buffer.address(), length, false);
    if (!transfer_ok(device, status, length)) FAIL(HARDWARE_ERROR);
  }

  return process->null_object();
}

}  // namespace toit

#endif  // TOIT_EC618
