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
#include "../event_sources/uart_ec618.h"  // Ec618EventSource (shared).
#include "pad_table_ec618.h"

extern "C" {
  #include "bsp_common.h"
  #include "driver_gpio.h"   // GPIO_IomuxEC618.
  #include "gpio.h"          // OEM GPIO_pinConfig/pinWrite for CS/DC.
  #include "soc_spi.h"       // The luatos core SPI driver.
}

namespace toit {

// SPI master on the luatos core driver (soc_spi.h). The master drives the
// clock, so a transfer's duration is bounded by length/speed by
// construction (unlike I2C there is no peer that can stretch it). CS and
// DC are plain GPIOs handled here, which is what gives the library's
// keep-cs-active semantics.
//
// Small transfers run synchronously (SPI_BlockTransfer). Large ones can
// run ASYNCHRONOUSLY (transfer_start/transfer_finish): the bytes move by
// DMA while the VM keeps scheduling, and the completion callback wakes
// the waiting task through the shared event source — the same shape as
// the I2C async path.
//
// Pin arguments are PAD numbers. Controller routings (iomux ALT1):
//   SPI0: MOSI=PAD24, MISO=PAD25, CLK=PAD26 (the Air780E's SPI pins;
//         shared with I2C1/UART2 — one peripheral at a time)
//   SPI1: MOSI=PAD28, MISO=PAD29, CLK=PAD30 (shared with UART0 — unusable
//         while UART0 is the console; accepted but untested)
//
// Driver statics are fine since the reserved VM dram sections (frozen-base
// phase 3): the base's layout no longer depends on VM statics, so the
// historical zero-statics rule for this file is retired.

static int pads_to_controller(int mosi, int miso, int clock) {
  if (mosi == 24 && miso == 25 && clock == 26) return 0;
  if (mosi == 28 && miso == 29 && clock == 30) return 1;
  return -1;
}

static void pad_set(int pad, int level);

// Async-transfer state, one per controller. The DMA moves driver-owned
// (malloc'd) bytes — GC moves heap objects, so the Toit buffer is copied
// out at start and back at finish. The sequence tag keeps a late
// completion of an aborted transfer from claiming the next one's wait
// (the I2C lesson).
struct SpiState {
  volatile bool active;
  volatile uint8_t seq;
  volatile bool done;      // Set by the completion callback.
  bool read;               // Full duplex: received bytes replace sent ones.
  uint8_t* buffer;         // Driver-owned tx (and rx, in place) bytes.
  uint32_t length;
  int cs;                  // Pad to deselect on completion; -1 = none.
  bool keep_cs;
};

static SpiState spi_states[2] = {};

// Completion callback, registered before each async transfer; runs from
// the SPI/DMA IRQ. Deselects CS (unless keep-cs-active) as close to the
// last clock as possible — the same convention the SDK's own LCD path
// uses — and wakes the waiting task through the event source.
static int32_t spi_transfer_done(void* unused, void* param) {
  int id = (int)(uintptr_t)param;
  SpiState* state = &spi_states[id];
  if (!state->active) return 0;  // Stale (aborted under us).
  if (state->cs >= 0 && !state->keep_cs) pad_set(state->cs, 1);
  state->done = true;
  Ec618EventSource::send_event_from_isr(
      Event::spi_type(id), 1 | ((uint32_t)state->seq << 16));
  return 0;
}

// Drives a chip-select/data-command pad as a plain GPIO.
static bool pad_output(int pad, int level) {
  int gpio_bit = pad_to_gpio(pad);
  if (gpio_bit < 0) return false;
  GpioPinConfig_t config;
  memset(&config, 0, sizeof(config));
  config.pinDirection = GPIO_DIRECTION_OUTPUT;
  config.misc.initOutput = level;
  GPIO_IomuxEC618(pad, pad_gpio_mux(pad), 0, 0);
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
  SpiResourceGroup(Process* process, EventSource* event_source, int controller,
                   int mosi, int miso, int clock)
    : ResourceGroup(process, event_source), controller_(controller)
    , mosi_(mosi), miso_(miso), clock_(clock) {}

  // Hands the bus pads back disconnected — also on the forced teardown of
  // a killed container; the wires must not stay muxed to the controller.
  // An async transfer still in flight is abandoned: stop the engine and
  // release its buffer (the DMA must not keep writing freed memory).
  ~SpiResourceGroup() override {
    SpiState* state = &spi_states[controller_];
    if (state->active) {
      state->active = false;
      SPI_TransferStop(controller_);
      free(state->buffer);
      state->buffer = null;
    }
    pad_release(mosi_);
    pad_release(miso_);
    pad_release(clock_);
  }

  // Completion dispatch: only the CURRENT transfer's callback may set the
  // done bit (a late dispatch from an aborted transfer must not wake the
  // next one's wait).
  uint32_t on_event(Resource* r, word data, uint32_t state_bits) override {
    SpiState* state = &spi_states[controller_];
    uint8_t dispatch_seq = (data >> 16) & 0xff;
    if (dispatch_seq != state->seq) return state_bits;
    return state_bits | 1;  // Transfer-done bit, matching lib/spi.toit.
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

class SpiDevice : public EventResource {
 public:
  TAG(SpiDevice);
  SpiDevice(SpiResourceGroup* group, int cs, int dc,
            uint32_t frequency, uint8_t mode)
    : EventResource(group, Event::spi_type(group->controller()))
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

  Ec618EventSource* event_source = Ec618EventSource::instance();
  if (event_source == null) FAIL(ALREADY_CLOSED);

  SpiResourceGroup* group = _new SpiResourceGroup(process, event_source,
                                                  controller,
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

// --- Asynchronous transfers --------------------------------------------------
//
// transfer_start copies the Toit bytes into driver-owned memory, arms the
// completion callback and kicks a non-blocking DMA transfer; the library
// waits on the resource state without blocking the VM, and transfer_finish
// copies the (full-duplex) received bytes back and releases the buffer.

// DMA-transfer length guard. The SDK's own LCD path pushes hundreds of KB
// per TransferEx, so the engine has no small hardware cap; this bounds the
// driver-owned allocation to something a device heap can sensibly carry.
static const int kMaxAsyncTransfer = 0x10000;

PRIMITIVE(device_transfer_start) {
  ARGS(SpiDevice, device, Blob, tx, int, from, int, to, bool, read,
       int, dc, bool, keep_cs_active);
  if (from < 0 || from > to || to > tx.length()) FAIL(OUT_OF_BOUNDS);
  int length = to - from;
  if (length == 0 || length > kMaxAsyncTransfer) FAIL(OUT_OF_RANGE);

  int controller = device->controller();
  SpiState* state = &spi_states[controller];
  if (state->active) FAIL(ALREADY_IN_USE);

  uint8_t* buffer = unvoid_cast<uint8_t*>(malloc(length));
  if (buffer == null) FAIL(MALLOC_FAILED);
  memcpy(buffer, tx.address() + from, length);

  device->ensure_config();
  if (device->dc() >= 0) pad_set(device->dc(), dc);
  if (device->cs() >= 0) pad_set(device->cs(), 0);

  state->seq++;
  state->done = false;
  state->read = read;
  state->buffer = buffer;
  state->length = length;
  state->cs = device->cs();
  state->keep_cs = keep_cs_active;
  state->active = true;

  // The SDK's async recipe (mirrors its LCD path): callback, non-blocking
  // mode, then a DMA transfer. Full duplex in place, like the sync path.
  SPI_SetCallbackFun(controller, spi_transfer_done,
                     (void*)(uintptr_t)controller);
  SPI_SetNoBlock(controller);
  int32_t rc = SPI_TransferEx(controller, buffer, read ? buffer : null,
                              length, /*IsBlock=*/0, /*UseDMA=*/1);
  if (rc != 0) {
    state->active = false;
    free(buffer);
    state->buffer = null;
    SPI_TransferStop(controller);
    if (device->cs() >= 0 && !keep_cs_active) pad_set(device->cs(), 1);
    FAIL(HARDWARE_ERROR);
  }
  return process->true_object();
}

PRIMITIVE(device_transfer_finish) {
  ARGS(SpiDevice, device, MutableBlob, rx_out);
  int controller = device->controller();
  SpiState* state = &spi_states[controller];
  if (!state->active) FAIL(INVALID_ARGUMENT);

  int result = 0;
  if (!state->done) {
    // Not complete — the library's deadline fired first. Stop the engine
    // before releasing the buffer the DMA is still writing.
    SPI_TransferStop(controller);
    if (state->cs >= 0 && !state->keep_cs) pad_set(state->cs, 1);
    result = -1;
  } else if (state->read) {
    uint32_t n = state->length;
    if (n > (uint32_t)rx_out.length()) n = rx_out.length();
    memcpy(rx_out.address(), state->buffer, n);
  }
  state->active = false;
  free(state->buffer);
  state->buffer = null;
  return Primitive::integer(result, process);
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
