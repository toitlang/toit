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
  #include "clock.h"         // GPR_setClockSrc: pin the I2C functional clock.
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
  extern void delay_us(uint32_t us);  // PLAT busy-wait (jump table).
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

class I2cDeviceResource;

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
  uint32_t current_hz;       // Programmed wire pace once SETUP ran; 0 =
                             // must rerun (cleared by quiesce/power
                             // cycles).
  uint32_t src_hz;           // Selected functional-clock source (26 MHz
                             // or 51.2 MHz); 0 = not yet pinned.
  uint32_t bus_hz;           // Pace for bus-level probes: the most recent
                             // device transfer's frequency (sticky across
                             // quiesce), else kBusDefaultHz.
  volatile bool transfer_active;
  volatile uint8_t stage;
  volatile bool notify_toit;     // Async transfer: completion must wake the
                                 // Toit event state. Spin-consumed transfers
                                 // (sync paths, probe) MUST NOT notify: the
                                 // stale dispatch would land after the NEXT
                                 // transfer's clear-state and wake it early
                                 // (finish then sees an incomplete transfer
                                 // -> phantom HARDWARE_ERROR on whichever
                                 // transfer follows a probe).
  volatile uint32_t last_event;  // ARM_I2C_EVENT_* bits; 0 = running.
  volatile uint16_t seq;         // Transfer sequence, bumped at every
                                 // start; the completion dispatch carries
                                 // it so on_event can DISCARD dispatches
                                 // from earlier transfers (e.g. an async
                                 // transfer the library deadline-aborted,
                                 // whose late completion would otherwise
                                 // claim the NEXT transfer's wait).
  uint8_t address;               // Target, for the chained read leg.
  I2cDeviceResource* active_device;  // Null for a bus-level probe.
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
  if (state->notify_toit) {
    // The dispatch word: event bits | originating transfer's sequence.
    Ec618EventSource::send_event_from_isr(
        Event::i2c_type(id), event | ((uint32_t)state->seq << 16));
  }
}

static void i2c0_event(uint32_t event) { i2c_cmsis_event(0, event); }
static void i2c1_event(uint32_t event) { i2c_cmsis_event(1, event); }
static const ARM_I2C_SignalEvent_t kI2cCallbacks[2] = { i2c0_event, i2c1_event };

// Wire pace (HW-calibrated 2026-07-18, ESP32 RMT): the automatic/control-
// mode engine counts SCL phases at the full functional clock and honors
// TPR. In its bounded linear region:
//   period_ticks = 2 * SCLx + kPaceOverheadTicks
// API sweeps on the 51.2 MHz source gave 253 kHz at SCLx=91 and 298..307
// kHz at 74..75. The earlier 305-tick model came from batch timing, where
// per-probe software/recovery time was incorrectly attributed to the
// controller.
//
// The 26 MHz source (always running with the AP) covers ~49..206 kHz; the
// gate-enabled 51.2 MHz root covers intermediate fast requests. Source
// switches use the SDK LCD driver's CLOCK_clockEnable(CLK_HF51M) recipe.
// A 400 kHz request uses the fastest bounded LuatOS-style timing word on
// 26 MHz: 363 kHz measured. Requests above 400 kHz use the same ceiling;
// requests below the floor are rejected.
static const uint32_t kPaceOverheadTicks = 20;
static const uint32_t kSrc26M = 26000000;
static const uint32_t kSrc51M = 51200000;
static const uint32_t kFastRequestHz = 400000;
// Separate measured-safe floors. On 51.2 MHz SCLx=62 is bounded while
// SCLx=53 free-runs an address-NACK command; do not enter that gap.
static const uint32_t kMinScl26 = 53;
static const uint32_t kMinScl51 = 62;
// Above this the 51.2 MHz source is selected: the fastest pace where the
// 26 MHz source keeps SCLH=SCLL >= kMinScl26. ~206 kHz.
static const uint32_t kMax26MHz =
    kSrc26M / (2 * kMinScl26 + kPaceOverheadTicks);
// The floor: SCLH=SCLL=255 at 26 MHz. ~48.9 kHz.
static const uint32_t kMinHz = kSrc26M / (510 + kPaceOverheadTicks);
// Pace for bus-level operations before a device transfer makes its pace
// sticky. This is the slowest round standard value the engine can honor.
static const uint32_t kBusDefaultHz = 50000;

// Programs the controller for the requested pace: functional-clock source
// (26 vs 51.2 MHz), the driver's internal SETUP flag (gates Master*; must
// rerun after every power cycle), and the TPR SCLH/SCLL divisor.
static void ensure_setup(int controller, uint32_t hz) {
  I2cState* state = &i2c_states[controller];
  if (state->current_hz == hz) return;
  ARM_DRIVER_I2C* driver = kI2cDrivers[controller];
  // LuatOS's production setup uses the complete 0x01882020 timing word on
  // 26 MHz and measures 344 kHz. SCLx=30 keeps the same setup/hold/filter
  // fields and is the HW-bisected fastest bounded variant: 1.25 us high +
  // 1.50 us low = 363 kHz. SCLx=28 free-runs the NACK path.
  bool luat_fast = hz >= kFastRequestHz;
  bool fast_src = !luat_fast && hz > kMax26MHz;
  uint32_t src = fast_src ? kSrc51M : kSrc26M;
  if (src != state->src_hz) {
    // Source switches happen in the unclocked window (the mux-droop
    // lesson — see quiesce), with the 51.2 MHz root gate-enabled first.
    driver->PowerControl(ARM_POWER_OFF);
    if (fast_src) CLOCK_clockEnable(CLK_HF51M);
    if (controller == 0) {
      GPR_setClockSrc(FCLK_I2C0, fast_src ? FCLK_I2C0_SEL_51M : FCLK_I2C0_SEL_26M);
    } else {
      GPR_setClockSrc(FCLK_I2C1, fast_src ? FCLK_I2C1_SEL_51M : FCLK_I2C1_SEL_26M);
    }
    driver->PowerControl(ARM_POWER_FULL);
    state->src_hz = src;
  }
  driver->Control(ARM_I2C_BUS_SPEED, ARM_I2C_BUS_SPEED_STANDARD);
  I2C_TypeDef* regs = kI2cRegs[controller];
  if (luat_fast) {
    static const uint32_t kFastScl = 30;
    regs->TPR = 0x01880000
              | (kFastScl << I2C_TPR_SCLH_Pos)
              | (kFastScl << I2C_TPR_SCLL_Pos);
    state->current_hz = hz;
    return;
  }
  uint32_t period = src / hz;
  uint32_t scl = period > kPaceOverheadTicks
      ? (period - kPaceOverheadTicks) / 2
      : (fast_src ? kMinScl51 : kMinScl26);
  uint32_t min_scl = fast_src ? kMinScl51 : kMinScl26;
  if (scl < min_scl) scl = min_scl;
  if (scl > 255) scl = 255;
  regs->TPR = (regs->TPR & ~(I2C_TPR_SCLH_Msk | I2C_TPR_SCLL_Msk))
            | (scl << I2C_TPR_SCLH_Pos) | (scl << I2C_TPR_SCLL_Pos);
  state->current_hz = hz;
}

// Hard recovery: the CMSIS abort and bus-clear entry points are empty
// stubs, so the reliable reset is a power cycle of the block (the UART
// recipe). Clears the engine, FIFOs and the SETUP flag. The functional
// clock source is RE-PINNED in the unclocked window between OFF and FULL:
// the disable/enable cycle can drop the mux back to its floating default,
// and the 51 MHz input it may land on is not reliably running (a transfer
// on a dead clock stalls the engine and can wedge the device) — observed
// as flaky HARDWARE_ERRORs that appeared with quiesce-heavy tests.
static void quiesce(int controller) {
  I2cState* state = &i2c_states[controller];
  // Make an IRQ that races the abort stale before power-down. In
  // particular, a late write-leg completion must not start the chained
  // read while the block is being reset.
  state->transfer_active = false;
  ARM_DRIVER_I2C* driver = kI2cDrivers[controller];
  // Let a dying transaction finish its STOP first: the completion event
  // (e.g. the NACK that brought us here) leads the STOP by up to a
  // bit-time, and power-cycling the engine mid-STOP abandons the wire
  // with a line held low — after which every transfer fails the
  // bus_free() peek and nothing ever recovers (observed: torture-test
  // HARDWARE_ERRORs whose register snapshot showed MCR=0 with the bus
  // monitor stuck busy; twice as frequent at the slower 46 kHz wire,
  // because the race window is a bit-time).
  I2C_TypeDef* regs = kI2cRegs[controller];
  for (int spin = 20000; (regs->STR & I2C_STR_BUSY_Msk) && spin > 0; spin--) {}
  driver->PowerControl(ARM_POWER_OFF);
  // Re-pin the CURRENT source selection (re-enabling the 51.2 MHz root
  // first when that is the selection): recovery must not silently change
  // the pace, and dropping to 26 MHz here would make every NACK on a
  // fast bus pay a double source-switch (measured ~104 us + two extra
  // power cycles per probe) when ensure_setup re-elevates.
  bool fast_src = state->src_hz == kSrc51M;
  if (fast_src) CLOCK_clockEnable(CLK_HF51M);
  if (controller == 0) {
    GPR_setClockSrc(FCLK_I2C0, fast_src ? FCLK_I2C0_SEL_51M : FCLK_I2C0_SEL_26M);
  } else {
    GPR_setClockSrc(FCLK_I2C1, fast_src ? FCLK_I2C1_SEL_51M : FCLK_I2C1_SEL_26M);
  }
  driver->PowerControl(ARM_POWER_FULL);
  state->current_hz = 0;
}

// The pad-GPIO tricks below (wire peek, 9-clock bus clear) commandeer the
// pad's GPIO controller bit: they reconfigure its direction and, for the
// clear, drive it. That is only safe while the bit is reachable from THIS
// pad alone — a GPIO number with an ALTERNATE pad may be in use by the
// user through that other pad, and reconfiguring the shared bit would
// hijack their pin (direction and drive). Skip this optional recovery path
// for shared controller bits; normal I2C transfers do not commandeer them.
static bool gpio_bit_exclusive(int pad) {
  int gpio_bit = pad_to_gpio(pad);
  if (gpio_bit < 0) return false;
  return gpio_to_pad(gpio_bit, 1) == -1;
}

// Reads the wire level of an I2C pad: direction input, briefly mux to
// plain GPIO, sample, restore the controller mux (ALT2).
static bool wire_high(int pad) {
  if (!gpio_bit_exclusive(pad)) return true;  // Cannot peek safely; assume fine.
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

// Standard 9-clock bus clear via the pad-GPIO trick: a slave (or an
// abandoned transaction) holding SDA low releases it once it sees enough
// SCL edges to finish whatever byte it believes it is transferring, and
// the closing STOP pattern resets every state machine on the wire. The
// CMSIS ARM_I2C_BUS_CLEAR entry point is an empty stub, so this is ours.
// Open-drain semantics by direction switching (drive low = output-0,
// release = input + pull-ups), so nothing ever fights the pull-ups.
static void drive_low(int pad, int gpio_bit) {
  GpioPinConfig_t config;
  memset(&config, 0, sizeof(config));
  config.pinDirection = GPIO_DIRECTION_OUTPUT;
  config.misc.initOutput = 0;
  GPIO_pinConfig(gpio_bit >> 4, gpio_bit & 0xf, &config);
  GPIO_IomuxEC618(pad, pad_gpio_mux(pad), 0, 1);
}

static void release_line(int pad, int gpio_bit) {
  GpioPinConfig_t config;
  memset(&config, 0, sizeof(config));
  config.pinDirection = GPIO_DIRECTION_INPUT;
  GPIO_pinConfig(gpio_bit >> 4, gpio_bit & 0xf, &config);
  GPIO_IomuxEC618(pad, pad_gpio_mux(pad), 0, 1);
}

static void bus_clear(int sda, int scl) {
  if (!gpio_bit_exclusive(sda) || !gpio_bit_exclusive(scl)) return;
  int sda_bit = pad_to_gpio(sda);
  int scl_bit = pad_to_gpio(scl);
  if (sda_bit < 0 || scl_bit < 0) return;
  release_line(sda, sda_bit);
  release_line(scl, scl_bit);
  delay_us(20);
  for (int i = 0; i < 9; i++) {        // ~25 kHz clearing clock.
    drive_low(scl, scl_bit);
    delay_us(20);
    release_line(scl, scl_bit);
    delay_us(20);
  }
  drive_low(sda, sda_bit);             // STOP: SDA low -> high with SCL high.
  delay_us(20);
  release_line(sda, sda_bit);
  delay_us(20);
  GPIO_IomuxEC618(sda, 2, 1, 1);       // Back to the controller (ALT2).
  GPIO_IomuxEC618(scl, 2, 1, 1);
}

// Releases a finished (or aborted) transfer's buffers.
static void release_transfer(I2cState* state) {
  // Make any late IRQ callback stale before releasing memory it could use.
  state->transfer_active = false;
  if (state->owns_buffers) {
    free(state->tx);
    free(state->rx);
  }
  state->owns_buffers = false;
  state->notify_toit = false;
  state->tx = null;
  state->tx_len = 0;
  state->rx = null;
  state->rx_len = 0;
  state->active_device = null;
  state->stage = kStageIdle;
}

class I2cBusResource : public EventResource {
 public:
  TAG(I2cBusResource);
  I2cBusResource(ResourceGroup* group, int controller, int sda, int scl)
    : EventResource(group, Event::none_type())
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

  // bus_free with one recovery attempt: a held-low line gets the standard
  // 9-clock bus clear (stuck slave, or a transaction the engine abandoned
  // mid-STOP) before the verdict.
  bool bus_usable() const {
    if (bus_free()) return true;
    printf("[i2c] bus stuck: sda=%d scl=%d - clearing\n",
           wire_high(sda_) ? 1 : 0, wire_high(scl_) ? 1 : 0);
    bus_clear(sda_, scl_);
    bool ok = bus_free();
    if (!ok) {
      printf("[i2c] clear failed: sda=%d scl=%d\n",
             wire_high(sda_) ? 1 : 0, wire_high(scl_) ? 1 : 0);
    }
    return ok;
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

  ~I2cDeviceResource() override {
    I2cState* state = &i2c_states[controller()];
    if (state->transfer_active && state->active_device == this) {
      quiesce(controller());
      release_transfer(state);
    }
  }

  I2cBusResource* bus() const { return bus_; }
  int controller() const { return bus_->controller(); }
  int address() const { return address_; }
  uint32_t frequency() const { return frequency_; }

  // Per-byte timeout for the bounded synchronous paths, in ms.
  uint16_t toms() const {
    uint32_t ms = timeout_us_ / 1000 + (timeout_us_ % 1000 != 0);
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
    // Only the CURRENT transfer's completion may set the done bit: a
    // dispatch from an earlier (aborted or spin-consumed) transfer
    // arriving late must not wake the next transfer's wait.
    auto device = static_cast<I2cDeviceResource*>(r);
    I2cState* i2c_state = &i2c_states[device->controller()];
    uint16_t dispatch_seq = (data >> 16) & 0xffff;
    if (device != i2c_state->active_device ||
        dispatch_seq != i2c_state->seq) return state;
    return state | 1;  // Transfer-done bit, matching lib/i2c.toit.
  }
};

// The hardware command register carries the transfer length in a 9-bit
// field: 512 bytes is the longest single transfer the engine can run.
// (Longer would silently truncate at the hardware; chunking would insert
// STOP/START between chunks and change the wire protocol, so reject.)
static const int kMaxTransfer = 512;

// Maps the recorded completion event to the primitive result code
// (0 = clean; the library turns nonzero into HARDWARE_ERROR).
static int event_to_result(uint32_t event) {
  if (event & ARM_I2C_EVENT_ADDRESS_NACK) return 1;
  if (event & ARM_I2C_EVENT_BUS_ERROR) return 2;
  if (event & ARM_I2C_EVENT_ARBITRATION_LOST) return 3;
  if (event & ARM_I2C_EVENT_TRANSFER_INCOMPLETE) return 4;
  if (!(event & ARM_I2C_EVENT_TRANSFER_DONE)) return 4;
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
    printf("[i2c] start_legs rc=%ld stage=%d tx=%lu rx=%lu STR=%08lx\n",
           (long)rc, (int)state->stage, (unsigned long)state->tx_len,
           (unsigned long)state->rx_len,
           (unsigned long)kI2cRegs[controller]->STR);
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
  state->bus_hz = device->frequency();
  ensure_setup(controller, device->frequency());

  state->address = device->address();
  state->active_device = device;
  state->seq++;
  state->notify_toit = false;
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
  if (state->initialized) {
    driver->Uninitialize();
    state->initialized = false;
  }
  if (driver->Initialize(kI2cCallbacks[controller]) != ARM_DRIVER_OK) {
    FAIL(HARDWARE_ERROR);
  }
  state->initialized = true;
  // Pin the functional clock to the always-running 26 MHz source BEFORE
  // the block gets clocked (PowerControl FULL): unpinned, the selection
  // floats, and a floating mux once dead-stalled every transfer (see the
  // pace-model comment at ensure_setup — the historic ~46/~85 kHz "drift"
  // was the two TPR states, and the 51.2 MHz stall was its ungated root).
  // ensure_setup elevates to the 51.2 MHz source when a device's pace
  // needs it.
  GPR_setClockSrc(controller == 0 ? FCLK_I2C0 : FCLK_I2C1,
                  controller == 0 ? FCLK_I2C0_SEL_26M : FCLK_I2C1_SEL_26M);
  if (driver->PowerControl(ARM_POWER_FULL) != ARM_DRIVER_OK) {
    driver->Uninitialize();
    state->initialized = false;
    FAIL(HARDWARE_ERROR);
  }
  state->src_hz = kSrc26M;

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
  state->bus_hz = kBusDefaultHz;
  ensure_setup(controller, kBusDefaultHz);

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
  if (address > 0x7f) FAIL(INVALID_ARGUMENT);
  if (!bus->bus_usable()) return BOOL(false);
  // SMBus receive-byte probe: a present device ACKs its address and one
  // byte transfers; an absent one NACKs.
  uint8_t scratch;
  int controller = bus->controller();
  ensure_setup(controller, state->bus_hz != 0 ? state->bus_hz : kBusDefaultHz);
  state->address = address;
  state->active_device = null;
  state->seq++;
  state->notify_toit = false;
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
  I2cState* state = bus->state();
  bool had_transfer = state->transfer_active;
  quiesce(bus->controller());
  if (had_transfer) release_transfer(state);
  return process->null_object();
}

PRIMITIVE(device_create) {
  ARGS(I2cBusResource, bus, int, address_bit_size, uint16, address,
       uint32, frequency_hz, uint32, timeout_us, bool, disable_ack_check);
  // 10-bit mode exists in the hardware but is untested; reject until
  // needed.
  if (address_bit_size != 7) FAIL(INVALID_ARGUMENT);
  if (address > 0x7f) FAIL(INVALID_ARGUMENT);
  // The controller always checks ACKs. Do not silently promise the caller
  // the opposite behavior.
  if (disable_ack_check) FAIL(INVALID_ARGUMENT);
  if (frequency_hz == 0) FAIL(INVALID_ARGUMENT);
  // Honorable requests span ~49 kHz upward (see ensure_setup). A nominal
  // 400 kHz request selects the measured-safe ~363 kHz wire ceiling.
  // Requests above the ceiling run AT the ceiling (slower than asked is
  // I2C-legal), but a request BELOW the floor cannot be honored — a
  // deliberately slow bus may be a hard requirement, so reject instead
  // of silently running faster.
  if (frequency_hz < kMinHz) FAIL(INVALID_ARGUMENT);

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
  if (!device->bus()->bus_usable()) return false;
  return true;
}

PRIMITIVE(device_write) {
  ARGS(I2cDeviceResource, device, Blob, buffer);
  if (buffer.length() > kMaxTransfer) FAIL(OUT_OF_RANGE);
  if (!sync_precheck(device)) FAIL(HARDWARE_ERROR);
  if (sync_transfer(device, buffer.address(), buffer.length(), null, 0) != 0) {
    FAIL(HARDWARE_ERROR);
  }
  return process->null_object();
}

PRIMITIVE(device_read) {
  ARGS(I2cDeviceResource, device, MutableBlob, buffer, int, length);
  if (length < 0) FAIL(OUT_OF_BOUNDS);
  if (length > buffer.length()) FAIL(OUT_OF_BOUNDS);
  if (length > kMaxTransfer) FAIL(OUT_OF_RANGE);
  if (!sync_precheck(device)) FAIL(HARDWARE_ERROR);
  if (sync_transfer(device, null, 0, buffer.address(), length) != 0) {
    FAIL(HARDWARE_ERROR);
  }
  return process->null_object();
}

PRIMITIVE(device_write_read) {
  ARGS(I2cDeviceResource, device, Blob, tx_buffer, MutableBlob, rx_buffer, int, length);
  if (length < 0) FAIL(OUT_OF_BOUNDS);
  if (length > rx_buffer.length()) FAIL(OUT_OF_BOUNDS);
  if (length > kMaxTransfer || tx_buffer.length() > kMaxTransfer) FAIL(OUT_OF_RANGE);
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
  if (rx_length < 0 || rx_length > kMaxTransfer) FAIL(OUT_OF_RANGE);
  if (tx.length() > kMaxTransfer) FAIL(OUT_OF_RANGE);
  if (tx.length() == 0 && rx_length == 0) FAIL(INVALID_ARGUMENT);

  I2cState* state = device->bus()->state();
  if (state->transfer_active) FAIL(ALREADY_IN_USE);
  if (!device->bus()->bus_usable()) FAIL(HARDWARE_ERROR);
  state->bus_hz = device->frequency();
  ensure_setup(device->controller(), device->frequency());

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
  state->active_device = device;
  state->seq++;
  state->notify_toit = true;
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
  if (!state->transfer_active || state->active_device != device) {
    FAIL(INVALID_ARGUMENT);
  }

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
  if (result != 0) {
    printf("[i2c] finish event=%08lx stage=%d tx=%lu rx=%lu\n",
           (unsigned long)event, (int)state->stage,
           (unsigned long)state->tx_len, (unsigned long)state->rx_len);
    quiesce(device->controller());
  }
  release_transfer(state);
  return Primitive::integer(result, process);
}

}  // namespace toit

#endif  // TOIT_EC618
