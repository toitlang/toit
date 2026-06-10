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

#include "../event_sources/uart_ec618.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "pad_table_ec618.h"

extern "C" {
  #include "bsp_common.h"
  #include "driver_gpio.h"   // GPIO_PullConfig / GPIO_IomuxEC618.
  #include "gpio.h"          // OEM GPIO_pinConfig/pinRead, for the bus peek.
  #include "soc_i2c.h"       // The luatos core I2C driver (IRQ-driven).

  // Not declared in soc_i2c.h (the SDK's own user declares it extern too):
  // arms the no-block completion machinery for the next I2C_MasterXfer.
  extern void I2C_SetNoBlock(uint8_t i2c_id);
}

namespace toit {

// This driver rides the luatos CORE I2C API (soc_i2c.h), not the CMSIS
// blob: the core driver is IRQ-driven with a PER-BYTE timeout on every
// transfer (so a clock-stretching or absent slave cannot stall forever)
// and reports completion through a callback, which feeds the Toit event
// source — transfers don't block the VM. The two stacks must not be mixed
// on a controller (soc_i2c.h's own warning).
//
// Pin arguments are PAD numbers (the EC618 addressing model). Controller
// routings, all iomux ALT2 (from the SDK's luat_i2c_ec618.c and the
// LuatOS Air780E iomux docs):
//   I2C0: SDA/SCL = 14/13 (the Air780E's I2C0 pins), 27/28 or 31/32
//   I2C1: SDA/SCL = 19/20 or 23/24 (the Air780E's I2C1 pins)
static int pads_to_controller(int sda, int scl) {
  if (sda == 14 && scl == 13) return 0;
  if (sda == 27 && scl == 28) return 0;
  if (sda == 31 && scl == 32) return 0;
  if (sda == 19 && scl == 20) return 1;
  if (sda == 23 && scl == 24) return 1;
  return -1;
}

// I2C_MasterXfer operations (soc_i2c.h).
static const uint8_t kOpReadReg = 0;  // Write reg address, repeated start, read.
static const uint8_t kOpRead    = 1;
static const uint8_t kOpWrite   = 2;

// The core driver supports 100 kHz and 400 kHz only.
static uint32_t frequency_to_speed(uint32_t frequency) {
  return frequency <= 100000 ? 100000 : 400000;
}

// Per-controller state. The transfer buffers are driver-owned copies: an
// asynchronous transfer outlives the primitive call, and the GC moves
// Toit heap objects, so the hardware must never see a Toit buffer.
struct I2cState {
  bool in_use;
  uint32_t current_speed;
  volatile bool transfer_active;
  uint8_t* tx;
  uint32_t tx_len;
  uint8_t* rx;
  uint32_t rx_len;
};

static I2cState i2c_states[2] = {};

// Completion callback, registered via I2C_Prepare; pParam carries the
// controller id. Runs from the driver's IRQ path.
static int32_t i2c_done_cb(void* p_data, void* p_param) {
  USE(p_data);
  uintptr_t id = reinterpret_cast<uintptr_t>(p_param);
  if (id > 1) return 0;
  UartQcx216EventSource::send_event_from_isr(Event::i2c_type(id), 0);
  return 0;
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
  I2cBusResource(ResourceGroup* group, int controller, int sda, int scl)
    : Resource(group)
    , controller_(controller)
    , sda_(sda)
    , scl_(scl) {}

  ~I2cBusResource() override {
    I2cState* state = &i2c_states[controller_];
    if (state->transfer_active) {
      I2C_Reset(controller_);
      free(state->tx);
      free(state->rx);
      state->tx = null;
      state->rx = null;
      state->transfer_active = false;
    }
    state->in_use = false;
  }

  int controller() const { return controller_; }
  I2cState* state() const { return &i2c_states[controller_]; }

  // Applies the bus speed for the given device frequency if it differs
  // from what the controller is currently configured for.
  void ensure_speed(uint32_t frequency) {
    uint32_t speed = frequency_to_speed(frequency);
    I2cState* s = state();
    if (speed == s->current_speed) return;
    I2C_ChangeBR(controller_, speed);
    s->current_speed = speed;
  }

  // Whether both lines idle high. A dead bus (no pull-ups, e.g. the
  // peripheral powered off) fails every transfer; catching it up front
  // gives a clean fast error instead of per-byte timeout cascades.
  bool bus_free() const {
    return (wire_high(sda_)) && (wire_high(scl_));
  }

 private:
  int controller_;
  int sda_;
  int scl_;
};

class I2cDeviceResource : public EventResource {
 public:
  TAG(I2cDeviceResource);
  I2cDeviceResource(ResourceGroup* group, I2cBusResource* bus, int address,
                    uint32_t frequency, uint32_t timeout_us)
    : EventResource(group, Event::i2c_type(bus->controller()))
    , bus_(bus)
    , address_(address)
    , frequency_(frequency)
    , timeout_us_(timeout_us) {}

  I2cBusResource* bus() const { return bus_; }
  int controller() const { return bus_->controller(); }
  int address() const { return address_; }
  uint32_t frequency() const { return frequency_; }

  // Per-byte timeout for the core driver, in ms.
  uint16_t toms() const {
    uint32_t ms = timeout_us_ / 1000;
    if (ms < 1) ms = 1;
    if (ms > 1000) ms = 1000;
    return (uint16_t)ms;
  }

 private:
  I2cBusResource* bus_;
  int address_;
  uint32_t frequency_;
  uint32_t timeout_us_;
};

class I2cResourceGroup : public ResourceGroup {
 public:
  TAG(I2cResourceGroup);
  explicit I2cResourceGroup(Process* process, EventSource* event_source)
    : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* r, word data, uint32_t state) override {
    USE(r);
    USE(data);
    return state | 1;  // Transfer-done bit, matching lib/i2c.toit.
  }
};

// Releases a finished (or aborted) transfer's driver-owned buffers.
static void release_transfer(I2cState* state) {
  free(state->tx);
  free(state->rx);
  state->tx = null;
  state->rx = null;
  state->transfer_active = false;
}

MODULE_IMPLEMENTATION(i2c, MODULE_I2C)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  UartQcx216EventSource* event_source = UartQcx216EventSource::instance();
  if (event_source == null) FAIL(ALREADY_CLOSED);

  I2cResourceGroup* group = _new I2cResourceGroup(process, event_source);
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(bus_create) {
  ARGS(I2cResourceGroup, group, int, sda, int, scl, bool, pullup);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  int controller = pads_to_controller(sda, scl);
  if (controller < 0) FAIL(INVALID_ARGUMENT);
  if (i2c_states[controller].in_use) FAIL(ALREADY_IN_USE);

  // Route the chosen pads to the controller (ALT2, input buffer on,
  // peripheral auto-pull). The core driver leaves pin muxing to the
  // caller, so there is no competing RTE routing to undo.
  GPIO_IomuxEC618(sda, 2, 1, 1);
  GPIO_IomuxEC618(scl, 2, 1, 1);

  if (pullup) {
    GPIO_PullConfig(sda, 1, 1);
    GPIO_PullConfig(scl, 1, 1);
  }

  I2C_MasterSetup(controller, 100000);
  I2C_UsePollingMode(controller, 0);  // IRQ-driven transfers.

  I2cBusResource* bus = _new I2cBusResource(group, controller, sda, scl);
  if (bus == null) FAIL(MALLOC_FAILED);

  i2c_states[controller].in_use = true;
  i2c_states[controller].current_speed = 100000;

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
  if (bus->state()->transfer_active) FAIL(ALREADY_IN_USE);
  if (!bus->bus_free()) return BOOL(false);
  // SMBus receive-byte probe: a present device ACKs its address and one
  // byte transfers. The Block call is bounded by the per-byte timeout.
  uint8_t scratch;
  uint16_t toms = timeout_ms < 1 ? 1 : (timeout_ms > 1000 ? 1000 : timeout_ms);
  int32_t result = I2C_BlockRead(bus->controller(), address, null, 0,
                                 &scratch, 1, toms, null, null);
  if (result != 0) I2C_Reset(bus->controller());
  return BOOL(result == 0);
}

PRIMITIVE(bus_reset) {
  ARGS(I2cBusResource, bus);
  I2C_Reset(bus->controller());
  return process->null_object();
}

PRIMITIVE(device_create) {
  ARGS(I2cBusResource, bus, int, address_bit_size, uint16, address,
       uint32, frequency_hz, uint32, timeout_us, bool, disable_ack_check);
  USE(disable_ack_check);  // The core driver always checks ACKs.
  // The core driver's address-length parameter exists, but 10-bit mode is
  // untested on this chip; reject until needed.
  if (address_bit_size != 7) FAIL(INVALID_ARGUMENT);
  if (frequency_hz == 0) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  I2cDeviceResource* device = _new I2cDeviceResource(
      bus->resource_group(), bus, address, frequency_hz, timeout_us);
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

// --- Synchronous paths (the lib's fallback; also bounded by toms) -----------

static bool sync_precheck(I2cDeviceResource* device) {
  if (device->bus()->state()->transfer_active) return false;
  if (!device->bus()->bus_free()) return false;
  device->bus()->ensure_speed(device->frequency());
  return true;
}

PRIMITIVE(device_write) {
  ARGS(I2cDeviceResource, device, Blob, buffer);
  if (!sync_precheck(device)) FAIL(HARDWARE_ERROR);
  int32_t result = I2C_BlockWrite(device->controller(), device->address(),
                                  const_cast<uint8_t*>(buffer.address()),
                                  buffer.length(), device->toms(), null, null);
  if (result != 0) {
    I2C_Reset(device->controller());
    FAIL(HARDWARE_ERROR);
  }
  return process->null_object();
}

PRIMITIVE(device_read) {
  ARGS(I2cDeviceResource, device, MutableBlob, buffer, int, length);
  if (length > buffer.length()) FAIL(OUT_OF_BOUNDS);
  if (!sync_precheck(device)) FAIL(HARDWARE_ERROR);
  int32_t result = I2C_BlockRead(device->controller(), device->address(),
                                 null, 0, buffer.address(), length,
                                 device->toms(), null, null);
  if (result != 0) {
    I2C_Reset(device->controller());
    FAIL(HARDWARE_ERROR);
  }
  return process->null_object();
}

PRIMITIVE(device_write_read) {
  ARGS(I2cDeviceResource, device, Blob, tx_buffer, MutableBlob, rx_buffer, int, length);
  if (length > rx_buffer.length()) FAIL(OUT_OF_BOUNDS);
  if (!sync_precheck(device)) FAIL(HARDWARE_ERROR);
  int32_t result = I2C_BlockRead(device->controller(), device->address(),
                                 const_cast<uint8_t*>(tx_buffer.address()),
                                 tx_buffer.length(), rx_buffer.address(),
                                 length, device->toms(), null, null);
  if (result != 0) {
    I2C_Reset(device->controller());
    FAIL(HARDWARE_ERROR);
  }
  return process->null_object();
}

// --- Asynchronous transfers --------------------------------------------------
//
// transfer_start copies the Toit buffers into driver-owned memory, kicks
// off an IRQ-driven I2C_MasterXfer and returns `true` immediately; the
// completion callback raises the resource state, the library waits for it
// without blocking the VM, and transfer_finish collects the result.

PRIMITIVE(device_transfer_start) {
  ARGS(I2cDeviceResource, device, Blob, tx, int, rx_length);
  if (rx_length < 0 || rx_length > 0x10000) FAIL(OUT_OF_RANGE);
  if (tx.length() == 0 && rx_length == 0) FAIL(INVALID_ARGUMENT);

  I2cState* state = device->bus()->state();
  if (state->transfer_active) FAIL(ALREADY_IN_USE);
  if (!device->bus()->bus_free()) FAIL(HARDWARE_ERROR);
  device->bus()->ensure_speed(device->frequency());

  uint8_t* tx_copy = null;
  if (tx.length() > 0) {
    tx_copy = unvoid_cast<uint8_t*>(malloc(tx.length()));
    if (tx_copy == null) FAIL(MALLOC_FAILED);
    memcpy(tx_copy, tx.address(), tx.length());
  }
  uint8_t* rx_buffer = null;
  if (rx_length > 0) {
    rx_buffer = unvoid_cast<uint8_t*>(malloc(rx_length));
    if (rx_buffer == null) {
      free(tx_copy);
      FAIL(MALLOC_FAILED);
    }
  }

  state->tx = tx_copy;
  state->tx_len = tx.length();
  state->rx = rx_buffer;
  state->rx_len = rx_length;
  state->transfer_active = true;

  int controller = device->controller();
  // Drain any stale completion state, then arm the no-block machinery —
  // I2C_SetNoBlock must precede EVERY I2C_MasterXfer (the SDK's
  // luat_i2c_no_block_transfer does the same); without it the transfer
  // runs in the internal blocking mode and the completion callback never
  // fires.
  int32_t stale;
  I2C_WaitResult(controller, &stale);
  I2C_Prepare(controller, device->address(), 2, i2c_done_cb,
              reinterpret_cast<void*>(static_cast<uintptr_t>(controller)));
  I2C_SetNoBlock(controller);
  if (tx_copy != null && rx_buffer != null) {
    // Write the "register address" bytes, repeated start, read.
    I2C_MasterXfer(controller, kOpReadReg, tx_copy, state->tx_len,
                   rx_buffer, rx_length, device->toms());
  } else if (tx_copy != null) {
    I2C_MasterXfer(controller, kOpWrite, null, 0, tx_copy, state->tx_len,
                   device->toms());
  } else {
    I2C_MasterXfer(controller, kOpRead, null, 0, rx_buffer, rx_length,
                   device->toms());
  }
  return process->true_object();
}

PRIMITIVE(device_transfer_finish) {
  ARGS(I2cDeviceResource, device, MutableBlob, rx_out);
  I2cState* state = device->bus()->state();
  if (!state->transfer_active) FAIL(INVALID_ARGUMENT);

  int32_t result = 0;
  if (!I2C_WaitResult(device->controller(), &result)) {
    // Not complete — the library's deadline fired first. Abort cleanly.
    I2C_Reset(device->controller());
    release_transfer(state);
    return Primitive::integer(-1, process);
  }
  if (result == 0 && state->rx != null) {
    uint32_t n = state->rx_len;
    if (n > (uint32_t)rx_out.length()) n = rx_out.length();
    memcpy(rx_out.address(), state->rx, n);
  }
  if (result != 0) I2C_Reset(device->controller());
  release_transfer(state);
  return Primitive::integer(result, process);
}

}  // namespace toit

#endif  // TOIT_EC618
