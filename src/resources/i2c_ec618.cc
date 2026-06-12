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
  // I2C runs on the OPEN CMSIS driver (bsp_i2c.c) in IRQ mode — a mode the
  // vendor never finished or shipped (their production glue uses the
  // closed soc_i2c blob; the CMSIS branch of luat_i2c_ec618.c is #if 0).
  // Our submodule fork implements the IRQ-mode master engine: the command
  // engine runs the transfer in hardware, the IRQ handler feeds/drains the
  // 16-deep FIFO, completion comes through the event callback. No DMA
  // channels are consumed (the 7-channel MP pool is 6/7 committed when all
  // three UARTs are open). The Driver_I2Cn access structs are DATA (never
  // routed through the jump table — see gen-plat-jt's DATA-SYMBOLS).
  #include "Driver_I2C.h"
  extern ARM_DRIVER_I2C Driver_I2C0;
  extern ARM_DRIVER_I2C Driver_I2C1;
}

namespace toit {

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

static ARM_DRIVER_I2C* const kI2cDrivers[2] = { &Driver_I2C0, &Driver_I2C1 };
static I2C_TypeDef* const kI2cRegs[2] = { I2C0, I2C1 };
// The RTE pins that the driver's Initialize() muxes on its own (I2C0's are
// the "AUDIO" routing). Undone in bus_create when the user chose others.
static const uint8_t kRteSda[2] = { 27, 19 };
static const uint8_t kRteScl[2] = { 28, 20 };

// Transfer stages. A write+read transfer runs as two chained legs — the
// engine has no working repeated-start (the CMSIS xfer_pending flag is
// write-only in bsp_i2c.c), so the wire carries write,STOP,START,read,
// exactly like the vendor's shipped luat_i2c_transfer.
static const uint8_t kStageIdle = 0;
static const uint8_t kStageSingle = 1;            // One leg only.
static const uint8_t kStageWritePendingRead = 2;  // Write leg in flight.
static const uint8_t kStageReading = 3;           // Chained read leg.

// Per-controller state. The async transfer buffers are driver-owned
// copies: an asynchronous transfer outlives the primitive call, and the GC
// moves Toit heap objects, so the hardware must never see a Toit buffer.
// (The bounded synchronous paths use the caller's buffers directly — a
// primitive cannot GC mid-spin.)
struct I2cState {
  bool in_use;
  bool initialized;          // Our Initialize() ran (Initialize is a
                             // no-op on an initialized driver, and
                             // Uninitialize on a never-initialized one
                             // is undefined — the UART tracker lesson).
  uint32_t functional_clk;   // Inferred once; 0 = not yet calibrated.
  uint32_t current_hz;       // Applied divisor; 0 = must (re)apply.
  volatile bool transfer_active;
  volatile uint8_t stage;
  volatile uint32_t last_event;  // ARM_I2C_EVENT_* bits; 0 = running.
  uint8_t address;               // Target, for the chained read leg.
  bool owns_buffers;             // Async (malloc'd) vs sync (caller's).
  uint8_t* tx;
  uint32_t tx_len;
  uint8_t* rx;
  uint32_t rx_len;
};

static I2cState i2c_states[2] = {};

// Completion callback, registered at Initialize; runs from the I2C IRQ.
// Chains the read leg of a write+read transfer, and only signals the Toit
// event source for the FINAL leg.
static void i2c_cmsis_event(int id, uint32_t event) {
  I2cState* state = &i2c_states[id];
  if (!state->transfer_active) return;  // Stale (aborted under us).
  if (state->stage == kStageWritePendingRead &&
      event == ARM_I2C_EVENT_TRANSFER_DONE) {
    // The write leg landed clean — chain the read. The engine may still
    // be clocking out the STOP (TRANSFER_DONE leads it slightly and
    // MasterReceive rejects a busy bus); the wait is a bit-time, bounded.
    I2C_TypeDef* regs = kI2cRegs[id];
    int spin = 20000;
    while ((regs->STR & I2C_STR_BUSY_Msk) && --spin > 0) {}
    state->stage = kStageReading;
    int32_t rc = kI2cDrivers[id]->MasterReceive(
        state->address, state->rx, state->rx_len, false);
    if (rc == ARM_DRIVER_OK) return;  // Completion re-enters here.
    event = ARM_I2C_EVENT_BUS_ERROR | ARM_I2C_EVENT_TRANSFER_INCOMPLETE;
  }
  state->last_event = event;
  Ec618EventSource::send_event_from_isr(Event::i2c_type(id), event);
}

static void i2c0_event(uint32_t event) { i2c_cmsis_event(0, event); }
static void i2c1_event(uint32_t event) { i2c_cmsis_event(1, event); }
static const ARM_I2C_SignalEvent_t kI2cCallbacks[2] = { i2c0_event, i2c1_event };

// Applies an arbitrary bus frequency. The driver's Control(BUS_SPEED) only
// knows 100k/400k/1M and ORs the divisor into TPR (accumulating stale
// bits); we assign the SCLH/SCLL fields ourselves. The functional clock is
// not exported by the driver, so it is inferred ONCE from the divisor that
// Control() computes for 100 kHz — that call also sets the driver's
// internal SETUP flag, which gates Master*.
static void apply_speed(int controller, uint32_t hz) {
  I2cState* state = &i2c_states[controller];
  if (state->current_hz == hz) return;
  I2C_TypeDef* regs = kI2cRegs[controller];
  kI2cDrivers[controller]->Control(ARM_I2C_BUS_SPEED, ARM_I2C_BUS_SPEED_STANDARD);
  if (state->functional_clk == 0) {
    uint32_t sclh = (regs->TPR & I2C_TPR_SCLH_Msk) >> I2C_TPR_SCLH_Pos;
    state->functional_clk = sclh * 2 * 100000;
  }
  uint32_t half = (state->functional_clk / hz) / 2;
  if (half < 1) half = 1;
  if (half > 0xff) half = 0xff;
  uint32_t tpr = regs->TPR & ~(I2C_TPR_SCLH_Msk | I2C_TPR_SCLL_Msk);
  regs->TPR = tpr | (half << I2C_TPR_SCLH_Pos) | (half << I2C_TPR_SCLL_Pos);
  state->current_hz = hz;
}

// Hard recovery: the CMSIS abort and bus-clear entry points are empty
// stubs, so the reliable reset is a power cycle of the block (the UART
// recipe). Clears the engine, FIFOs and the TPR divisor.
static void quiesce(int controller) {
  ARM_DRIVER_I2C* driver = kI2cDrivers[controller];
  driver->PowerControl(ARM_POWER_OFF);
  driver->PowerControl(ARM_POWER_FULL);
  i2c_states[controller].current_hz = 0;
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
  GPIO_IomuxEC618(pad, pad_gpio_mux(pad), 0, 1);
  int level = GPIO_pinRead(gpio_bit >> 4, gpio_bit & 0xf) ? 1 : 0;
  GPIO_IomuxEC618(pad, 2, 1, 1);
  return level != 0;
}

// Releases a finished (or aborted) transfer's buffers.
static void release_transfer(I2cState* state) {
  if (state->owns_buffers) {
    free(state->tx);
    free(state->rx);
  }
  state->tx = null;
  state->rx = null;
  state->stage = kStageIdle;
  state->transfer_active = false;
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
      quiesce(controller_);
      release_transfer(state);
    }
    ARM_DRIVER_I2C* driver = kI2cDrivers[controller_];
    driver->PowerControl(ARM_POWER_OFF);
    driver->Uninitialize();
    state->initialized = false;
    state->current_hz = 0;
    state->in_use = false;
    // Hand the pads back disconnected (this also drops the pull-ups the
    // bus may have enabled) — a container must leave the wires the way it
    // found them, even when it is killed without closing the bus.
    pad_release(sda_);
    pad_release(scl_);
  }

  int controller() const { return controller_; }
  I2cState* state() const { return &i2c_states[controller_]; }

  // Whether both lines idle high. A dead bus (no pull-ups, e.g. the
  // peripheral powered off) fails every transfer; catching it up front
  // gives a clean fast error instead of timeout cascades.
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

  // Per-byte timeout for the bounded synchronous paths, in ms.
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

// Maps the recorded completion event to the primitive result code
// (0 = clean; the library turns nonzero into HARDWARE_ERROR).
static int event_to_result(uint32_t event) {
  if (event & ARM_I2C_EVENT_ADDRESS_NACK) return 1;
  if (event & ARM_I2C_EVENT_BUS_ERROR) return 2;
  if (event & ARM_I2C_EVENT_ARBITRATION_LOST) return 3;
  if (event & ARM_I2C_EVENT_TRANSFER_INCOMPLETE) return 4;
  return 0;
}

// Starts the hardware legs for a transfer whose state is already set up.
// Returns false when the driver rejected the start (state released).
static bool start_legs(I2cState* state, int controller) {
  ARM_DRIVER_I2C* driver = kI2cDrivers[controller];
  int32_t rc;
  if (state->tx != null && state->rx != null) {
    state->stage = kStageWritePendingRead;
    rc = driver->MasterTransmit(state->address, state->tx, state->tx_len, false);
  } else if (state->tx != null) {
    state->stage = kStageSingle;
    rc = driver->MasterTransmit(state->address, state->tx, state->tx_len, false);
  } else {
    state->stage = kStageSingle;
    rc = driver->MasterReceive(state->address, state->rx, state->rx_len, false);
  }
  if (rc != ARM_DRIVER_OK) {
    quiesce(controller);
    release_transfer(state);
    return false;
  }
  return true;
}

// Bounded synchronous transfer (probe + the library's sync fallback).
// Spins on the completion event with a deadline scaled by the device's
// per-byte timeout; uses the caller's buffers directly (no GC inside a
// primitive). Returns the result code, or -1 on deadline (engine reset).
static int sync_transfer(I2cDeviceResource* device, const uint8_t* tx,
                         uint32_t tx_len, uint8_t* rx, uint32_t rx_len) {
  int controller = device->controller();
  I2cState* state = &i2c_states[controller];
  apply_speed(controller, device->frequency());

  state->address = device->address();
  state->owns_buffers = false;
  state->tx = const_cast<uint8_t*>(tx);
  state->tx_len = tx_len;
  state->rx = rx;
  state->rx_len = rx_len;
  state->last_event = 0;
  state->transfer_active = true;

  if (!start_legs(state, controller)) return 2;

  int64 deadline_us = OS::get_monotonic_time() +
      (int64)device->toms() * 1000 * (tx_len + rx_len + 2);
  while (state->last_event == 0) {
    if (OS::get_monotonic_time() > deadline_us) {
      quiesce(controller);
      release_transfer(state);
      return -1;
    }
  }
  uint32_t event = state->last_event;
  int result = event_to_result(event);
  if (result != 0) quiesce(controller);
  release_transfer(state);
  return result;
}

MODULE_IMPLEMENTATION(i2c, MODULE_I2C)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  Ec618EventSource* event_source = Ec618EventSource::instance();
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
  I2cState* state = &i2c_states[controller];
  if (state->in_use) FAIL(ALREADY_IN_USE);

  ARM_DRIVER_I2C* driver = kI2cDrivers[controller];
  if (state->initialized) driver->Uninitialize();
  driver->Initialize(kI2cCallbacks[controller]);
  state->initialized = true;
  driver->PowerControl(ARM_POWER_FULL);

  // Initialize() muxed the driver's RTE pins; release them when the user
  // chose a different routing, then route the chosen pads (ALT2, input
  // buffer on).
  if (kRteSda[controller] != sda) pad_release(kRteSda[controller]);
  if (kRteScl[controller] != scl) pad_release(kRteScl[controller]);
  GPIO_IomuxEC618(sda, 2, 1, 1);
  GPIO_IomuxEC618(scl, 2, 1, 1);

  if (pullup) {
    GPIO_PullConfig(sda, 1, 1);
    GPIO_PullConfig(scl, 1, 1);
  }

  state->current_hz = 0;
  apply_speed(controller, 100000);

  I2cBusResource* bus = _new I2cBusResource(group, controller, sda, scl);
  if (bus == null) {
    driver->PowerControl(ARM_POWER_OFF);
    driver->Uninitialize();
    state->initialized = false;
    pad_release(sda);
    pad_release(scl);
    FAIL(MALLOC_FAILED);
  }

  state->in_use = true;

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
  I2cState* state = bus->state();
  if (state->transfer_active) FAIL(ALREADY_IN_USE);
  if (!bus->bus_free()) return BOOL(false);
  // SMBus receive-byte probe: a present device ACKs its address and one
  // byte transfers; an absent one NACKs.
  uint8_t scratch;
  int controller = bus->controller();
  apply_speed(controller, 100000);
  state->address = address;
  state->owns_buffers = false;
  state->tx = null;
  state->tx_len = 0;
  state->rx = &scratch;
  state->rx_len = 1;
  state->last_event = 0;
  state->transfer_active = true;
  if (!start_legs(state, controller)) return BOOL(false);

  uint16_t toms = timeout_ms < 1 ? 1 : (timeout_ms > 1000 ? 1000 : timeout_ms);
  int64 deadline_us = OS::get_monotonic_time() + (int64)toms * 1000 * 3;
  while (state->last_event == 0) {
    if (OS::get_monotonic_time() > deadline_us) {
      quiesce(controller);
      release_transfer(state);
      return BOOL(false);
    }
  }
  int result = event_to_result(state->last_event);
  if (result != 0) quiesce(controller);
  release_transfer(state);
  return BOOL(result == 0);
}

PRIMITIVE(bus_reset) {
  ARGS(I2cBusResource, bus);
  quiesce(bus->controller());
  return process->null_object();
}

PRIMITIVE(device_create) {
  ARGS(I2cBusResource, bus, int, address_bit_size, uint16, address,
       uint32, frequency_hz, uint32, timeout_us, bool, disable_ack_check);
  USE(disable_ack_check);  // The engine always checks ACKs.
  // 10-bit mode exists in the hardware but is untested; reject until
  // needed.
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

// --- Synchronous paths (the lib's fallback; bounded by toms) ----------------

static bool sync_precheck(I2cDeviceResource* device) {
  if (device->bus()->state()->transfer_active) return false;
  if (!device->bus()->bus_free()) return false;
  return true;
}

PRIMITIVE(device_write) {
  ARGS(I2cDeviceResource, device, Blob, buffer);
  if (!sync_precheck(device)) FAIL(HARDWARE_ERROR);
  if (sync_transfer(device, buffer.address(), buffer.length(), null, 0) != 0) {
    FAIL(HARDWARE_ERROR);
  }
  return process->null_object();
}

PRIMITIVE(device_read) {
  ARGS(I2cDeviceResource, device, MutableBlob, buffer, int, length);
  if (length > buffer.length()) FAIL(OUT_OF_BOUNDS);
  if (!sync_precheck(device)) FAIL(HARDWARE_ERROR);
  if (sync_transfer(device, null, 0, buffer.address(), length) != 0) {
    FAIL(HARDWARE_ERROR);
  }
  return process->null_object();
}

PRIMITIVE(device_write_read) {
  ARGS(I2cDeviceResource, device, Blob, tx_buffer, MutableBlob, rx_buffer, int, length);
  if (length > rx_buffer.length()) FAIL(OUT_OF_BOUNDS);
  if (!sync_precheck(device)) FAIL(HARDWARE_ERROR);
  if (sync_transfer(device, tx_buffer.address(), tx_buffer.length(),
                    rx_buffer.address(), length) != 0) {
    FAIL(HARDWARE_ERROR);
  }
  return process->null_object();
}

// --- Asynchronous transfers --------------------------------------------------
//
// transfer_start copies the Toit buffers into driver-owned memory, kicks
// off the IRQ-driven legs and returns `true` immediately; the completion
// callback raises the resource state, the library waits for it without
// blocking the VM, and transfer_finish collects the result.

PRIMITIVE(device_transfer_start) {
  ARGS(I2cDeviceResource, device, Blob, tx, int, rx_length);
  if (rx_length < 0 || rx_length > 0x10000) FAIL(OUT_OF_RANGE);
  if (tx.length() == 0 && rx_length == 0) FAIL(INVALID_ARGUMENT);

  I2cState* state = device->bus()->state();
  if (state->transfer_active) FAIL(ALREADY_IN_USE);
  if (!device->bus()->bus_free()) FAIL(HARDWARE_ERROR);
  apply_speed(device->controller(), device->frequency());

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

  state->address = device->address();
  state->owns_buffers = true;
  state->tx = tx_copy;
  state->tx_len = tx.length();
  state->rx = rx_buffer;
  state->rx_len = rx_length;
  state->last_event = 0;
  state->transfer_active = true;

  if (!start_legs(state, device->controller())) FAIL(HARDWARE_ERROR);
  return process->true_object();
}

PRIMITIVE(device_transfer_finish) {
  ARGS(I2cDeviceResource, device, MutableBlob, rx_out);
  I2cState* state = device->bus()->state();
  if (!state->transfer_active) FAIL(INVALID_ARGUMENT);

  uint32_t event = state->last_event;
  if (event == 0) {
    // Not complete — the library's deadline fired first. Abort cleanly.
    quiesce(device->controller());
    release_transfer(state);
    return Primitive::integer(-1, process);
  }
  int result = event_to_result(event);
  if (result == 0 && state->rx != null) {
    uint32_t n = state->rx_len;
    if (n > (uint32_t)rx_out.length()) n = rx_out.length();
    memcpy(rx_out.address(), state->rx, n);
  }
  if (result != 0) quiesce(device->controller());
  release_transfer(state);
  return Primitive::integer(result, process);
}

}  // namespace toit

#endif  // TOIT_EC618
