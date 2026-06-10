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

#include <string.h>

#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "pad_table_ec618.h"

extern "C" {
  #include "bsp_common.h"
  #include "driver_gpio.h"   // GPIO_IomuxEC618.
  #include "gpio.h"          // OEM GPIO_pinConfig/pinWrite for CS/DC.
  #include "soc_spi.h"       // The luatos core SPI driver.
}

namespace toit {

// SPI master on the luatos core driver (soc_spi.h). Transfers are
// synchronous: the master drives the clock, so a transfer's duration is
// bounded by length/speed by construction (unlike I2C there is no peer
// that can stretch it). CS and DC are plain GPIOs handled here, which is
// what gives the library's keep-cs-active semantics.
//
// Pin arguments are PAD numbers. Controller routings (iomux ALT1):
//   SPI0: MOSI=PAD24, MISO=PAD25, CLK=PAD26 (the Air780E's SPI pins;
//         shared with I2C1/UART2 — one peripheral at a time)
//   SPI1: MOSI=PAD28, MISO=PAD29, CLK=PAD30 (shared with UART0 — unusable
//         while UART0 is the console; accepted but untested)
//
// NO driver statics at all — even a 4-byte static pointer lands in the
// SHARED dram section and shifts the layout the OTA contract freezes
// (measured). All state lives in the heap-allocated resource group; the
// cost is that double-opening a controller is not detected (the second
// open re-runs SPI_MasterInit — undefined results, documented user error).

static int pads_to_controller(int mosi, int miso, int clock) {
  if (mosi == 24 && miso == 25 && clock == 26) return 0;
  if (mosi == 28 && miso == 29 && clock == 30) return 1;
  return -1;
}

// Drives a chip-select/data-command pad as a plain GPIO.
static bool pad_output(int pad, int level) {
  int gpio_bit = pad_to_gpio(pad);
  if (gpio_bit < 0) return false;
  GpioPinConfig_t config;
  memset(&config, 0, sizeof(config));
  config.pinDirection = GPIO_DIRECTION_OUTPUT;
  config.misc.initOutput = level;
  GPIO_IomuxEC618(pad, 0, 0, 0);
  GPIO_pinConfig(gpio_bit >> 4, gpio_bit & 0xf, &config);
  return true;
}

static void pad_set(int pad, int level) {
  int gpio_bit = pad_to_gpio(pad);
  if (gpio_bit < 0) return;
  uint16_t mask = 1 << (gpio_bit & 0xf);
  GPIO_pinWrite(gpio_bit >> 4, mask, level ? mask : 0);
}

class SpiResourceGroup : public ResourceGroup {
 public:
  TAG(SpiResourceGroup);
  SpiResourceGroup(Process* process, int controller,
                   int mosi, int miso, int clock)
    : ResourceGroup(process), controller_(controller)
    , mosi_(mosi), miso_(miso), clock_(clock) {}

  // Hands the bus pads back disconnected — also on the forced teardown of
  // a killed container; the wires must not stay muxed to the controller.
  ~SpiResourceGroup() override {
    pad_release(mosi_);
    pad_release(miso_);
    pad_release(clock_);
  }

  int controller() const { return controller_; }

  // The controller's currently-applied configuration (devices on one bus
  // can differ; transfers reconfigure on change).
  void ensure_config(uint32_t frequency, uint8_t mode) {
    if (speed_ == frequency && mode_ == mode) return;
    SPI_SetNewConfig(controller_, frequency, mode);
    speed_ = frequency;
    mode_ = mode;
  }

 private:
  int controller_;
  int mosi_;
  int miso_;
  int clock_;
  uint32_t speed_ = 0;
  uint8_t mode_ = 0;
};

class SpiDevice : public Resource {
 public:
  TAG(SpiDevice);
  SpiDevice(SpiResourceGroup* group, int cs, int dc,
            uint32_t frequency, uint8_t mode)
    : Resource(group)
    , group_(group)
    , cs_(cs)
    , dc_(dc)
    , frequency_(frequency)
    , mode_(mode) {}

  ~SpiDevice() override {
    if (cs_ >= 0) {
      pad_set(cs_, 1);  // Deselect before letting go of the pad.
      pad_release(cs_);
    }
    if (dc_ >= 0) pad_release(dc_);
  }

  int controller() const { return group_->controller(); }
  int cs() const { return cs_; }
  int dc() const { return dc_; }

  void ensure_config() { group_->ensure_config(frequency_, mode_); }

 private:
  SpiResourceGroup* group_;
  int cs_;
  int dc_;
  uint32_t frequency_;
  uint8_t mode_;
};

MODULE_IMPLEMENTATION(spi, MODULE_SPI)

PRIMITIVE(init) {
  ARGS(int, mosi, int, miso, int, clock);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  int controller = pads_to_controller(mosi, miso, clock);
  if (controller < 0) FAIL(INVALID_ARGUMENT);

  // Route the three bus pads to the controller (ALT1; input buffer for
  // MISO so reads see the wire).
  GPIO_IomuxEC618(mosi, 1, 0, 0);
  GPIO_IomuxEC618(miso, 1, 0, 1);
  GPIO_IomuxEC618(clock, 1, 0, 0);

  // Mode/speed are per-device; start with a safe default.
  SPI_MasterInit(controller, 8, 0, 1000000, null, null);

  SpiResourceGroup* group = _new SpiResourceGroup(process, controller,
                                                  mosi, miso, clock);
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(SpiResourceGroup, group);
  group->tear_down();
  group_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(device) {
  ARGS(SpiResourceGroup, group, int, cs, int, dc, int, command_bits,
       int, address_bits, int, frequency, int, mode);
  // Hardware command/address phases are an ESP32 feature; the EC618 path
  // sends everything as plain data.
  if (command_bits != 0 || address_bits != 0) FAIL(INVALID_ARGUMENT);
  if (mode < 0 || mode > 3) FAIL(INVALID_ARGUMENT);
  if (frequency <= 0) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  if (cs >= 0 && !pad_output(cs, 1)) FAIL(INVALID_ARGUMENT);
  if (dc >= 0 && !pad_output(dc, 0)) FAIL(INVALID_ARGUMENT);

  SpiDevice* device = _new SpiDevice(group, cs, dc, frequency, (uint8_t)mode);
  if (device == null) FAIL(MALLOC_FAILED);

  group->register_resource(device);
  proxy->set_external_address(device);
  return proxy;
}

PRIMITIVE(device_close) {
  ARGS(SpiResourceGroup, group, SpiDevice, device);
  group->unregister_resource(device);
  device_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(transfer) {
  ARGS(SpiDevice, device, MutableBlob, tx, int, command, int64, address,
       int, from, int, to, bool, read, int, dc, bool, keep_cs_active);
  if (command != 0 || address != 0) FAIL(INVALID_ARGUMENT);
  if (from < 0 || from > to || to > tx.length()) FAIL(OUT_OF_BOUNDS);

  device->ensure_config();
  if (device->dc() >= 0) pad_set(device->dc(), dc);
  if (device->cs() >= 0) pad_set(device->cs(), 0);

  // Full duplex; with --read the received bytes replace the transmitted
  // ones in place (the documented library semantics). The transfer is
  // synchronous, bounded by length/speed.
  uint8_t* data = tx.address() + from;
  int32_t result = SPI_BlockTransfer(device->controller(), data,
                                     read ? data : null, to - from);

  if (device->cs() >= 0 && !keep_cs_active) pad_set(device->cs(), 1);
  if (result != 0) {
    SPI_TransferStop(device->controller());
    FAIL(HARDWARE_ERROR);
  }
  return process->null_object();
}

PRIMITIVE(acquire_bus) {
  ARGS(SpiResourceGroup, group);
  USE(group);
  // Single-master, transfers serialize naturally; reservation is a no-op.
  return process->null_object();
}

PRIMITIVE(release_bus) {
  ARGS(SpiResourceGroup, group);
  USE(group);
  return process->null_object();
}

}  // namespace toit

#endif  // TOIT_EC618
