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
#include "../os.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../event_sources/uart_ec618.h"  // Ec618EventSource (shared).
#include "pad_table_ec618.h"

extern "C" {
  #include "bsp_common.h"
  #include "clock.h"        // GPR_swReset: make vendor DMA cleanup nonblocking.
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
// All transfers run asynchronously: DMA moves driver-owned bytes while the
// VM continues scheduling. Prefix and payload share one CS assertion.
//
// Pin arguments are PAD numbers. Controller routings (iomux ALT1):
//   SPI0: MOSI=PAD24, MISO=PAD25, CLK=PAD26 (the Air780E's SPI pins;
//         shared with I2C1/UART2 — one peripheral at a time)
//   SPI1: MOSI=PAD28, MISO=PAD29, CLK=PAD30 (shared with UART0 — unusable
//         while UART0 is the console; accepted but untested)
//
// Driver statics are safe because VM writable data lives in reserved
// per-slot sections; the base layout does not depend on these statics.

static int pads_to_controller(int mosi, int miso, int clock) {
  if (mosi == 24 && miso == 25 && clock == 26) return 0;
  if (mosi == 28 && miso == 29 && clock == 30) return 1;
  return -1;
}

static ResourcePool<int, -1> spi_controllers(0, 1);
static SPI_TypeDef* const kSpiRegs[2] = {SPI0, SPI1};

static void pad_set(int pad, int level);

// Async-transfer state, one per controller. The DMA moves driver-owned
// (malloc'd) bytes — GC moves heap objects, so the Toit buffer is copied
// out at start and back at finish. The sequence tag keeps a late
// completion of an aborted transfer from claiming the next one's wait.
class SpiDevice;

struct SpiState {
  EventResource* owner;
  uint32_t prefix_length;
  volatile bool active;
  volatile uint8_t seq;
  volatile bool done;      // Set by the completion callback.
  bool read;               // Full duplex: received bytes replace sent ones.
  uint8_t* buffer;         // Driver-owned tx (and rx, in place) bytes.
  uint32_t from;           // Copy-back offset in the caller's ByteArray.
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

// Makes callbacks for this transfer stale before stopping DMA, then leaves
// the target deselected unless the caller explicitly retained CS.
static void stop_transfer(int controller, SpiState* state) {
  state->active = false;
  // The vendor function named SPI_TransferStop first waits for the entire
  // wire transfer to drain, and only then disables its DMA channels. Turn
  // off peripheral DMA requests and the shift engine first so that it is a
  // real cancellation rather than a length-dependent blocking wait.
  SPI_TypeDef* regs = kSpiRegs[controller];
  regs->DMACR = 0;
  regs->CR1 &= ~SPI_CR1_SSE_Msk;
  GPR_swReset(controller == 0 ? RST_PCLK_SPI0 : RST_PCLK_SPI1);
  GPR_swReset(controller == 0 ? RST_FCLK_SPI0 : RST_FCLK_SPI1);
  SPI_TransferStop(controller);
  if (state->cs >= 0 && !state->keep_cs) pad_set(state->cs, 1);
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
  // Stop the engine even when it appears idle, detach the callback, and
  // release any async buffer only after DMA can no longer write it.
  ~SpiResourceGroup() override {
    SpiState* state = &spi_states[controller_];
    stop_transfer(controller_, state);
    SPI_SetCallbackFun(controller_, null, null);
    if (state->buffer != null) {
      free(state->buffer);
      state->buffer = null;
    }
    state->done = false;
    state->from = 0;
    state->length = 0;
    state->cs = -1;
    state->keep_cs = false;
    spi_controllers.put(controller_);
  }

  void adopt_pads(const PadReserver& reserver) { pads_.adopt(reserver); }

  // Completion dispatch: only the CURRENT transfer's callback may set the
  // done bit (a late dispatch from an aborted transfer must not wake the
  // next one's wait).
  uint32_t on_event(Resource* r, word data, uint32_t state_bits) override {
    SpiState* state = &spi_states[controller_];
    uint8_t dispatch_seq = (data >> 16) & 0xff;
    if (!state->active || r != state->owner || dispatch_seq != state->seq) return state_bits;
    return state_bits | 1;  // Transfer-done bit, matching lib/spi.toit.
  }

  int controller() const { return controller_; }
  SpiDevice* reserved_device = null;

  // The controller's currently-applied configuration (devices on one bus
  // can differ; transfers reconfigure on change).
  void ensure_config(uint32_t frequency, uint8_t mode) {
    if (speed_ == frequency && mode_ == mode) return;
    SPI_SetNewConfig(controller_, frequency, mode);
    speed_ = frequency;
    mode_ = mode;
  }

  void invalidate_config() {
    speed_ = 0;
  }

 private:
  int controller_;
  int mosi_;
  int miso_;
  int clock_;
  uint32_t speed_ = 0;
  uint8_t mode_ = 0;
  Pads pads_;
};

class SpiDevice : public EventResource {
 public:
  TAG(SpiDevice);
  SpiDevice(SpiResourceGroup* group, int cs, int dc,
            uint32_t frequency, uint8_t mode,
            uint8_t command_bits, uint8_t address_bits)
    : EventResource(group, Event::spi_type(group->controller()))
    , group_(group)
    , cs_(cs)
    , dc_(dc)
    , frequency_(frequency)
    , mode_(mode)
    , command_bits_(command_bits)
    , address_bits_(address_bits) {}

  ~SpiDevice() override {
    SpiState* state = &spi_states[controller()];
    if (state->owner == this) {
      stop_transfer(controller(), state);
      SPI_SetCallbackFun(controller(), null, null);
      if (cs_ >= 0) pad_set(cs_, 1);
      free(state->buffer);
      state->buffer = null;
      state->owner = null;
    }
    if (group_->reserved_device == this) group_->reserved_device = null;
    if (cs_ >= 0) pad_set(cs_, 1);  // Deselect before letting go of the pad.
  }

  void adopt_pads(const PadReserver& reserver) { pads_.adopt(reserver); }

  int controller() const { return group_->controller(); }
  SpiResourceGroup* group() const { return group_; }
  int cs() const { return cs_; }
  int dc() const { return dc_; }
  int command_bits() const { return command_bits_; }
  int address_bits() const { return address_bits_; }

  void ensure_config() { group_->ensure_config(frequency_, mode_); }

  void recover_after_abort() {
    SPI_MasterInit(controller(), 8, 0, 1000000, null, null);
    group_->invalidate_config();
  }

 private:
  SpiResourceGroup* group_;
  int cs_;
  int dc_;
  uint32_t frequency_;
  uint8_t mode_;
  uint8_t command_bits_;
  uint8_t address_bits_;
  Pads pads_;
};

MODULE_IMPLEMENTATION(spi, MODULE_SPI)

PRIMITIVE(init) {
  ARGS(int, mosi, int, miso, int, clock);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  int controller = pads_to_controller(mosi, miso, clock);
  if (controller < 0) FAIL(INVALID_ARGUMENT);

  Ec618EventSource* event_source = Ec618EventSource::instance();
  if (event_source == null) FAIL(ALREADY_CLOSED);
  if (!spi_controllers.take(controller)) FAIL(ALREADY_IN_USE);

  PadReserver pads;
  if (!pads.take(mosi) || !pads.take(miso) || !pads.take(clock)) {
    spi_controllers.put(controller);
    FAIL(ALREADY_IN_USE);
  }

  SpiResourceGroup* group = _new SpiResourceGroup(process, event_source,
                                                  controller,
                                                  mosi, miso, clock);
  if (group == null) {
    spi_controllers.put(controller);
    FAIL(MALLOC_FAILED);
  }
  group->adopt_pads(pads);
  pads.keep();

  // Route the three bus pads to the controller (ALT1; input buffer for
  // MISO so reads see the wire).
  GPIO_IomuxEC618(mosi, 1, 0, 0);
  GPIO_IomuxEC618(miso, 1, 0, 1);
  GPIO_IomuxEC618(clock, 1, 0, 0);

  // Mode/speed are per-device; start with a safe default.
  SPI_MasterInit(controller, 8, 0, 1000000, null, null);

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
       int, address_bits, int, frequency, int, mode, int, cs_setup_cycles, int, cs_hold_cycles);
  if (cs_setup_cycles != 0 || cs_hold_cycles != 0) FAIL(UNIMPLEMENTED);
  if (command_bits < 0 || command_bits > 16) FAIL(INVALID_ARGUMENT);
  if (address_bits < 0 || address_bits > 64) FAIL(INVALID_ARGUMENT);
  // The core driver transfers complete 8-bit frames. A byte-aligned combined
  // prefix can be packed exactly under one CS assertion; any other total
  // would require extra trailing clocks and is rejected rather than rounded.
  if ((command_bits + address_bits) % 8 != 0) FAIL(INVALID_ARGUMENT);
  if (mode < 0 || mode > 3) FAIL(INVALID_ARGUMENT);
  if (frequency <= 0) FAIL(INVALID_ARGUMENT);
  if (cs >= 0 && pad_to_gpio(cs) < 0) FAIL(INVALID_ARGUMENT);
  if (dc >= 0 && pad_to_gpio(dc) < 0) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  PadReserver pads;
  if (!pads.take(cs) || !pads.take(dc)) FAIL(ALREADY_IN_USE);

  SpiDevice* device = _new SpiDevice(
      group, cs, dc, frequency, (uint8_t)mode,
      (uint8_t)command_bits, (uint8_t)address_bits);
  if (device == null) FAIL(MALLOC_FAILED);
  device->adopt_pads(pads);
  pads.keep();

  if (cs >= 0) {
    bool configured = pad_output(cs, 1);
    ASSERT(configured);
  }
  if (dc >= 0) {
    bool configured = pad_output(dc, 0);
    ASSERT(configured);
  }

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

static void append_bits(uint8_t* out, int* offset,
                        uint64_t value, int bit_count) {
  for (int source_bit = bit_count - 1; source_bit >= 0; source_bit--) {
    int target_bit = *offset;
    if ((value >> source_bit) & 1) {
      out[target_bit >> 3] |= 1 << (7 - (target_bit & 7));
    }
    (*offset)++;
  }
}

static const int kMaxAsyncTransfer = 0x10000;

PRIMITIVE(transfer_start) {
  ARGS(SpiDevice, device, Blob, tx, int, command, int64, address,
       int, from, int, to, bool, read, int, dc, bool, keep_cs_active);
  if (device->group()->reserved_device != null &&
      device->group()->reserved_device != device) FAIL(INVALID_STATE);
  if (keep_cs_active && device->group()->reserved_device != device) FAIL(INVALID_STATE);
  if (from < 0 || from > to || to > tx.length()) FAIL(OUT_OF_BOUNDS);
  int length = to - from;
  int prefix_length = (device->command_bits() + device->address_bits()) / 8;
  if (length > kMaxAsyncTransfer - prefix_length) FAIL(OUT_OF_RANGE);
  int total_length = prefix_length + length;
  if (total_length == 0) FAIL(INVALID_ARGUMENT);

  int controller = device->controller();
  SpiState* state = &spi_states[controller];
  if (state->active) FAIL(ALREADY_IN_USE);

  uint8_t* buffer = unvoid_cast<uint8_t*>(malloc(total_length));
  if (buffer == null) FAIL(MALLOC_FAILED);
  memset(buffer, 0, prefix_length);
  int offset = 0;
  append_bits(buffer, &offset, static_cast<uint32_t>(command), device->command_bits());
  append_bits(buffer, &offset, static_cast<uint64_t>(address), device->address_bits());
  memcpy(buffer + prefix_length, tx.address() + from, length);

  device->ensure_config();
  if (device->dc() >= 0) pad_set(device->dc(), dc);
  if (device->cs() >= 0) pad_set(device->cs(), 0);

  state->owner = device;
  state->prefix_length = prefix_length;
  state->seq++;
  state->done = false;
  state->read = read;
  state->buffer = buffer;
  state->from = from;
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
                              total_length, /*IsBlock=*/0, /*UseDMA=*/1);
  if (rc != 0) {
    stop_transfer(controller, state);
    device->recover_after_abort();
    free(buffer);
    state->buffer = null;
    state->owner = null;
    state->done = false;
    state->from = 0;
    state->length = 0;
    state->cs = -1;
    state->keep_cs = false;
    FAIL(HARDWARE_ERROR);
  }
  return process->null_object();
}

static void release_transfer(SpiState* state) {
  state->active = false;
  free(state->buffer);
  state->buffer = null;
  state->owner = null;
  state->done = false;
  state->length = 0;
  state->cs = -1;
  state->keep_cs = false;
}

PRIMITIVE(transfer_finish) {
  ARGS(SpiDevice, device, MutableBlob, rx_out, int, from, bool, read);
  SpiState* state = &spi_states[device->controller()];
  if (!state->active || state->owner != device) FAIL(INVALID_STATE);
  if (from < 0 || from > rx_out.length() ||
      state->length > static_cast<uint32_t>(rx_out.length() - from)) FAIL(OUT_OF_BOUNDS);
  if (!state->done) return process->false_object();
  if (read && state->read) {
    memcpy(rx_out.address() + from, state->buffer + state->prefix_length, state->length);
  }
  release_transfer(state);
  return process->true_object();
}

PRIMITIVE(transfer_abort) {
  ARGS(SpiDevice, device);
  SpiState* state = &spi_states[device->controller()];
  if (!state->active || state->owner != device) return process->true_object();
  stop_transfer(device->controller(), state);
  if (device->cs() >= 0) pad_set(device->cs(), 1);
  device->recover_after_abort();
  release_transfer(state);
  return process->true_object();
}

PRIMITIVE(acquire_bus) {
  ARGS(SpiDevice, device);
  auto group = device->group();
  SpiState* state = &spi_states[device->controller()];
  if (state->active || group->reserved_device != null) return process->false_object();
  group->reserved_device = device;
  return process->true_object();
}

PRIMITIVE(release_bus) {
  ARGS(SpiDevice, device);
  if (device->group()->reserved_device != device) FAIL(INVALID_STATE);
  device->group()->reserved_device = null;
  if (device->cs() >= 0) pad_set(device->cs(), 1);
  return process->null_object();
}

PRIMITIVE(target_init) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(target_create) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(target_close) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(target_transfer_start) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(target_transfer_finish) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_create) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_arm) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_close) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_get) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_set) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_read) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_write) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_receive) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_dropped_receive_count) { FAIL(UNIMPLEMENTED); }

}  // namespace toit

#endif  // TOIT_EC618
