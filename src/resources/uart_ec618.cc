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
  #include "cmsis_os2.h"  // osDelay, for the RS485 TX-drain poll.
  #include "driver_gpio.h"
  #include "gpio.h"
  #include "platform_define.h"
  #include "slpman.h"     // Sleep vote (via the jump table) — see uart_sleep_vote.
  // All three UARTs run on the OPEN CMSIS driver (bsp_usart.c) instead of
  // the closed Uart_* blob (docs/ec618-uart-cmsis-rewrite.md): the blob's
  // RX ring silently discarded everything on overflow and killed RX until
  // reopen, and its close path could hang container teardown
  // (known-issues #1/#4). The access structs are DATA (never routed
  // through the jump table — see gen-plat-jt's DATA-SYMBOLS).
  #include "Driver_USART.h"
  extern ARM_DRIVER_USART Driver_USART0;
  extern ARM_DRIVER_USART Driver_USART1;
  extern ARM_DRIVER_USART Driver_USART2;
}

namespace toit {

// All pin arguments to PRIMITIVE(create) are PAD numbers (1..kMaxPadIndex).
// -1 means "not used". Pin/function validation goes through the pad table
// in `pad_table_ec618.h`, which is the single source of truth for which
// physical pad carries which UART role.

// Per-UART state.
// CMSIS-path RX context (heap-allocated at open). The driver DMAs each
// armed transfer into `chunk`; the event callback copies it into `ring`.
// RX_TIMEOUT does NOT end the armed transfer on this driver — bsp_usart.c
// reloads the descriptor and keeps streaming into the same buffer — so the
// callback tracks how much of `chunk` it has already pushed (`seen`) and
// re-arms only on RECEIVE_COMPLETE. Between transfers the driver's own
// 32-byte staging FIFO catches the line, so the re-arm gap loses nothing
// at sane bauds.
struct CmsisRx {
  uint8_t* ring;            // malloc'd ring buffer.
  uint32_t ring_size;
  volatile uint32_t head;   // Write index — IRQ context only.
  volatile uint32_t tail;   // Read index — primitive only.
  uint32_t seen;            // Bytes of the CURRENT transfer already pushed.
  uint32_t dropped;         // Bytes discarded with the ring full (drop-newest).
  uint32_t control;         // The ARM_USART_CONTROL_* framing word (for set-baud).
  // TX staging: Send() is asynchronous in DMA mode and keeps reading the
  // buffer after the primitive returns, so the bytes are copied out of the
  // (movable) Toit heap object first. `tx_busy` is set when a Send is in
  // flight and cleared by the SEND_COMPLETE callback.
  uint8_t* tx_buf;
  uint32_t tx_buf_size;
  volatile bool tx_busy;
  // Diagnostic counters (kept cheap; exposed to debugging sessions).
  uint32_t cb_events;       // Callback invocations.
  uint32_t rearm_fails;     // Receive() re-arms that returned an error.
  uint8_t chunk[512];       // The armed receive target.
};

// PRIMASK guard, same pattern as bsp_usart.c's SaveAndSetIRQMask. The UART
// irq and the DMA-end irq are separate vectors that both walk the driver's
// transfer state; sections that read or reconfigure it must be atomic
// against both.
static inline uint32_t irq_save() {
  uint32_t m = __get_PRIMASK();
  __disable_irq();
  return m;
}
static inline void irq_restore(uint32_t m) {
  __DSB();
  __ISB();
  __set_PRIMASK(m);
}

struct UartState {
  bool in_use;          // Whether the controller currently has a Toit resource.
  uint32_t baud_rate;   // Cached baud rate, for `get_baud_rate` without register reads.
  uint32_t errors;      // Counter incremented from the driver callback on
                        // parity/overrun/break.
  int de_pad;           // RS485 direction pin (PAD number), or -1.
  CmsisRx* cmsis_rx;    // Non-null when this controller runs on the CMSIS driver.
};

static UartState uart_states[3] = {};

// Whether OUR code has run Initialize() on the controller (the boot-time
// console init is handled separately in create).
static bool cmsis_initialized[3] = {};

// Per-controller CMSIS access. The driver structs are DATA bindings into
// the base; the register pointers serve the few direct LSR/FCNR/RBR reads
// the driver has no API for.
static ARM_DRIVER_USART* const kDrivers[3] = {
  &Driver_USART0, &Driver_USART1, &Driver_USART2,
};
static USART_TypeDef* const kUartRegs[3] = {
  reinterpret_cast<USART_TypeDef*>(MP_UART0_BASE_ADDR),
  reinterpret_cast<USART_TypeDef*>(MP_UART1_BASE_ADDR),
  reinterpret_cast<USART_TypeDef*>(MP_UART2_BASE_ADDR),
};
// Which controllers run RX in DMA mode (must mirror RTE_UARTn_RX_IO_MODE
// in RTE_Device.h): the IRQ-mode controllers need the FIFO crutches
// below, and manual RBR reads would corrupt a DMA-owned FIFO.
static const bool kRxIsDma[3] = { true, true, true };

// --- Toit state bits (match lib/uart.toit). --------------------------------
static const uint32_t kReadState  = 1 << 0;
static const uint32_t kErrorState = 1 << 1;
static const uint32_t kWriteState = 1 << 2;

// --- Resource ---------------------------------------------------------------

class UartResource : public EventResource {
 public:
  TAG(UartResource);
  UartResource(ResourceGroup* group, int uart_id)
    : EventResource(group, Event::uart_type(uart_id))
    , uart_id_(uart_id) {}

  int uart_id() const { return uart_id_; }

 private:
  int uart_id_;
};

class UartResourceGroup : public ResourceGroup {
 public:
  TAG(UartResourceGroup);
  explicit UartResourceGroup(Process* process, EventSource* event_source)
    : ResourceGroup(process, event_source) {}

  ~UartResourceGroup() {
    // on_unregister_resource already ran per port; belt and braces.
    if (sleep_vote_held_) {
      slpManPlatVoteEnableSleep(sleep_vote_handle_, SLP_SLP1_STATE);
    }
    if (sleep_vote_handle_ != 0xff) {
      slpManGivebackPlatVoteHandle(sleep_vote_handle_);
    }
  }

  // Sleep vote: an open UART must keep the system out of SLEEP1. The
  // armed DMA receive does not survive the SLEEP1 power cycle (the SDK
  // restore callback restores registers, not in-flight transfers), so an
  // idle system with an open port goes DEAF on wake — reproduced with a
  // 35 s idle gap killing the agent; the byte-fed software watchdog then
  // starves and reboots ~60 s later, which is what every "PWRKEY-latch"
  // mystery actually was. The closed blob driver kept the system awake
  // implicitly. Proper per-driver suspend/resume belongs to the
  // deep-sleep work; until then any open port votes SLEEP1 away. The
  // vote state lives on the GROUP (heap) deliberately: new VM file
  // statics shift the shared-DRAM layout and would force a full flash.
  // Concurrent groups each hold their own handle; if the vote pool runs
  // dry the extra groups degrade gracefully (any one vote suffices).
  void sleep_vote(int delta) {
    open_ports_ += delta;
    if (sleep_vote_handle_ == 0xff) {
      if (open_ports_ <= 0) return;
      slpManApplyPlatVoteHandle("TOITUART", &sleep_vote_handle_);
      if (sleep_vote_handle_ == 0xff) return;
    }
    if (open_ports_ > 0 && !sleep_vote_held_) {
      slpManPlatVoteDisableSleep(sleep_vote_handle_, SLP_SLP1_STATE);
      sleep_vote_held_ = true;
    } else if (open_ports_ == 0 && sleep_vote_held_) {
      slpManPlatVoteEnableSleep(sleep_vote_handle_, SLP_SLP1_STATE);
      sleep_vote_held_ = false;
    }
  }

  void on_unregister_resource(Resource* r) override {
    auto uart_res = static_cast<UartResource*>(r);
    int id = uart_res->uart_id();
    UartState& state = uart_states[id];
    if (state.in_use) {
      sleep_vote(-1);
#if CONFIG_TOIT_EC618_PRINT_UART
      // The print UART shares the controller with printf/monitor output:
      // tear down OUR half only (RX irqs + buffers) and leave the
      // controller powered and configured so printf keeps flowing
      // (SendPolling needs only the CONFIGURED flag).
      if (id == CONFIG_TOIT_EC618_PRINT_UART_ID) {
        CmsisRx* rx = state.cmsis_rx;
        if (rx != null) {
          uint32_t mask = irq_save();
          kDrivers[id]->Control(ARM_USART_CONTROL_RX, 0);
          state.cmsis_rx = null;  // Unhook before freeing (the IRQ checks it).
          irq_restore(mask);
          // A DMA Send still in flight reads tx_buf: wait for it (bounded
          // by the staging-buffer drain time) before freeing.
          for (int spin = 0; rx->tx_busy && spin < 2000; spin++) osDelay(1);
          free(rx->tx_buf);
          free(rx->ring);
          free(rx);
        }
        state.in_use = false;
        state.de_pad = -1;
        return;
      }
#endif
      if (state.cmsis_rx != null) {
        // CMSIS teardown from a quiesced state — this is the path the
        // blob's Uart_DeInit hangs on (known-issues #1). CONTROL_RX 0 is
        // the supported abort (ABORT_RECEIVE is not): RX irqs masked, DMA
        // suspended, rx_busy cleared. POWER_OFF then resets the module
        // and stops+resets the RX DMA channel, so nothing references
        // `chunk` by the time it is freed below.
        uint32_t mask = irq_save();
        kDrivers[id]->Control(ARM_USART_CONTROL_RX, 0);
        kDrivers[id]->Control(ARM_USART_CONTROL_TX, 0);
        kDrivers[id]->PowerControl(ARM_POWER_OFF);
        kDrivers[id]->Uninitialize();
        cmsis_initialized[id] = false;
        CmsisRx* rx = state.cmsis_rx;
        state.cmsis_rx = null;  // Unhook before freeing (the IRQ checks it).
        irq_restore(mask);
        // POWER_OFF stopped the TX DMA channel and Uninitialize closed it,
        // so nothing references tx_buf (or chunk) past this point.
        free(rx->tx_buf);
        free(rx->ring);
        free(rx);
      }
      state.in_use = false;
      state.de_pad = -1;
    }
  }

  uint32_t on_event(Resource* r, word data, uint32_t state) override {
    switch (data) {
      case Event::UART_KIND_RX:
        state |= kReadState;
        break;
      case Event::UART_KIND_TX_DONE:
        state |= kWriteState;
        break;
      case Event::UART_KIND_ERROR:
        // Also wake blocked readers: after an overrun storm the final
        // event may be an ERROR while rescued bytes wait in the ring /
        // hardware FIFO (see the read primitive's FIFO rescue) — a
        // reader waiting only for kReadState would never look.
        state |= kErrorState | kReadState;
        break;
    }
    return state;
  }

 private:
  uint8_t sleep_vote_handle_ = 0xff;
  bool sleep_vote_held_ = false;
  int open_ports_ = 0;
};

// Drives the RS485 direction line. Uses the OEM GPIO_pin* API (like
// gpio_ec618.cc), NOT the luatos core-driver GPIO_Output/GPIO_Config:
// the two stacks must not be mixed (driver_gpio.h's own warning), and on
// hardware the core-driver calls silently failed to move the pad at all.
static void set_de_level(int pad, int level) {
  int gpio_bit = pad_to_gpio(pad);
  if (gpio_bit < 0) return;
  uint16_t mask = 1 << (gpio_bit & 0xf);
  GPIO_pinWrite(gpio_bit >> 4, mask, level ? mask : 0);
}

// --- CMSIS driver path (UART2) ----------------------------------------------
//
// Transfer protocol: only RECEIVE_COMPLETE ends an armed Receive(); on
// RX_TIMEOUT the driver reloads the DMA descriptor and the SAME transfer
// keeps filling `chunk`, with GetRxCount() growing monotonically. The
// callback therefore pushes the [seen..GetRxCount()) delta into the ring
// — dropping the NEWEST bytes when full, counted in `dropped` and
// `errors`, with RX staying alive — and re-arms only on completion.

// Posts a uart event from the driver callback. The callback usually runs
// in ISR context (UART irq, DMA-end irq) but the driver also invokes it
// from INSIDE Receive()/task context when bytes are already waiting —
// FromISR queue ops from a task lose the event, so pick by IPSR.
static void send_uart_event(int id, word kind) {
  if (__get_IPSR() != 0) {
    Ec618EventSource::send_event_from_isr(Event::uart_type(id), kind);
  } else {
    Ec618EventSource::send_event(Event::uart_type(id), kind);
  }
}

// Mostly runs in ISR context with a tight clock: at a 16-byte FIFO trigger
// and 921600 baud there are ~170 us before the hardware FIFO overruns, so
// the copy is two memcpys, not a byte loop.
static void cmsis_ring_push(int id, const uint8_t* data, uint32_t n) {
  CmsisRx* rx = uart_states[id].cmsis_rx;
  uint32_t head = rx->head;
  uint32_t tail = rx->tail;
  uint32_t used = head >= tail ? head - tail : rx->ring_size - tail + head;
  uint32_t free_space = rx->ring_size - 1 - used;  // One slot separates full from empty.
  uint32_t take = n < free_space ? n : free_space;
  if (take < n) {
    // Drop-NEWEST, counted; RX stays alive (known-issues #4 contract).
    rx->dropped += n - take;
    uart_states[id].errors += n - take;
    send_uart_event(id, Event::UART_KIND_ERROR);
  }
  uint32_t first = rx->ring_size - head;
  if (first > take) first = take;
  memcpy(rx->ring + head, data, first);
  if (take > first) memcpy(rx->ring, data + first, take - first);
  head += take;
  if (head >= rx->ring_size) head -= rx->ring_size;
  rx->head = head;
}

static void cmsis_uart_event(int id, uint32_t event) {
  uint32_t mask = irq_save();
  CmsisRx* rx = uart_states[id].cmsis_rx;
  if (rx == null) {
    irq_restore(mask);
    return;
  }
  rx->cb_events++;
  ARM_DRIVER_USART* driver = kDrivers[id];
  if (event & (ARM_USART_EVENT_RECEIVE_COMPLETE | ARM_USART_EVENT_RX_TIMEOUT)) {
    uint32_t n = driver->GetRxCount();
    if (n > sizeof(rx->chunk)) n = sizeof(rx->chunk);
    if (n > rx->seen) {
      cmsis_ring_push(id, rx->chunk + rx->seen, n - rx->seen);
      rx->seen = n;
      send_uart_event(id, Event::UART_KIND_RX);
    }
    if (event & ARM_USART_EVENT_RECEIVE_COMPLETE) {
      // Only RECEIVE_COMPLETE ends the armed transfer. RX_TIMEOUT leaves
      // it RUNNING — bsp_usart.c reloads the descriptor and keeps
      // streaming into the same buffer (and can fire this callback from
      // inside Receive() itself) — so a Receive() here re-enters the
      // driver's DMA state machine against a live transfer. Under flood
      // that re-entrancy wrote received bytes outside `chunk` and
      // corrupted the heap (hardfault in the interpreter). Push the
      // delta above; arm a new transfer only when the old one is over.
      rx->seen = 0;
      if (driver->Receive(rx->chunk, sizeof(rx->chunk)) != ARM_DRIVER_OK) {
        rx->rearm_fails++;
      }
    }
  }
  if (event & ARM_USART_EVENT_RX_OVERFLOW) {
    uart_states[id].errors++;
    if (!kRxIsDma[id]) {
      // IRQ-mode self-heal: the SDK irq handler is an else-if chain that
      // services LINE_STATUS (the overrun) INSTEAD of draining data; with
      // the FIFO still full the overrun re-asserts and RX delivers
      // nothing until the line idles. Drain the FIFO ourselves — to ONE
      // byte, never empty (the RX_DATA_REQ handler underflows
      // `i = bytes_in_fifo - 1` on an empty FIFO and hard-wedges reading
      // RBR). Push the chunk delta first so byte order holds.
      uint32_t n = driver->GetRxCount();
      if (n > sizeof(rx->chunk)) n = sizeof(rx->chunk);
      if (n > rx->seen) {
        cmsis_ring_push(id, rx->chunk + rx->seen, n - rx->seen);
        rx->seen = n;
      }
      USART_TypeDef* reg = kUartRegs[id];
      uint8_t fifo_buf[32];
      uint32_t got = 0;
      while (got < sizeof(fifo_buf) &&
             EIGEN_FLD2VAL(USART_FCNR_RX_FIFO_NUM, reg->FCNR) > 1) {
        fifo_buf[got++] = (uint8_t)reg->RBR;
      }
      if (got > 0) cmsis_ring_push(id, fifo_buf, got);
      send_uart_event(id, got > 0 ? Event::UART_KIND_RX : Event::UART_KIND_ERROR);
    } else {
      // DMA-owned FIFO: counted only; the engine captures through stalls.
      send_uart_event(id, Event::UART_KIND_ERROR);
    }
  }
  if (event & (ARM_USART_EVENT_SEND_COMPLETE | ARM_USART_EVENT_TX_COMPLETE)) {
    int de = uart_states[id].de_pad;
    if (de >= 0) {
      // RS485 direction: SEND_COMPLETE means the FIFO drained, but up to
      // one frame can still sit in the shift register. Spin for TEMT —
      // bounded by one frame time (~1 ms at 9600) and rare (RS485 only);
      // bsp_usart.c never fires TX_COMPLETE, so this is the only place
      // the DE line can drop with correct timing.
      USART_TypeDef* reg = kUartRegs[id];
      for (int spin = 0; spin < 2000000; spin++) {
        if ((reg->LSR & USART_LSR_TX_EMPTY_Msk) != 0) break;
      }
      set_de_level(de, 0);
    }
    rx->tx_busy = false;
    send_uart_event(id, Event::UART_KIND_TX_DONE);
  }
  if (event & (ARM_USART_EVENT_RX_FRAMING_ERROR | ARM_USART_EVENT_RX_PARITY_ERROR |
               ARM_USART_EVENT_RX_BREAK)) {
    uart_states[id].errors++;
    send_uart_event(id, Event::UART_KIND_ERROR);
  }
  irq_restore(mask);
}

// The CMSIS event callback carries no context argument — one thunk per
// controller.
static void cmsis_uart_event0(uint32_t event) { cmsis_uart_event(0, event); }
static void cmsis_uart_event1(uint32_t event) { cmsis_uart_event(1, event); }
static void cmsis_uart_event2(uint32_t event) { cmsis_uart_event(2, event); }
static void (* const kUartCallbacks[3])(uint32_t) = {
  cmsis_uart_event0, cmsis_uart_event1, cmsis_uart_event2,
};

// TX shift register + FIFO empty, read straight from the LSR (the driver
// has no API for it).
static bool tx_idle(int id) {
  CmsisRx* rx = uart_states[id].cmsis_rx;
  if (rx == null) return true;
  // tx_busy covers the armed-but-not-yet-started DMA gap, where the
  // FIFO is still empty and TEMT alone would report idle too early.
  if (rx->tx_busy) return false;
  return (kUartRegs[id]->LSR & USART_LSR_TX_EMPTY_Msk) != 0;
}

// Builds the ARM_USART_CONTROL word for mode + framing.
static uint32_t cmsis_control_word(int data_bits, int parity, int stop_bits) {
  uint32_t control = ARM_USART_MODE_ASYNCHRONOUS;
  switch (data_bits) {
    case 5: control |= ARM_USART_DATA_BITS_5; break;
    case 6: control |= ARM_USART_DATA_BITS_6; break;
    case 7: control |= ARM_USART_DATA_BITS_7; break;
    default: control |= ARM_USART_DATA_BITS_8; break;
  }
  // Toit parity: 1 disabled, 2 even, 3 odd (lib/uart.toit).
  if (parity == 2) control |= ARM_USART_PARITY_EVEN;
  else if (parity == 3) control |= ARM_USART_PARITY_ODD;
  else control |= ARM_USART_PARITY_NONE;
  // Toit stop bits: 1 one, 2 one-and-half, 3 two (StopBits.value_).
  if (stop_bits == 3) control |= ARM_USART_STOP_BITS_2;
  else if (stop_bits == 2) control |= ARM_USART_STOP_BITS_1_5;
  else control |= ARM_USART_STOP_BITS_1;
  return control;
}

// --- Pad-table-driven preset resolution ------------------------------------
//
// Walk every (controller, mapping) combination and pick the one that
// matches all of the user-supplied pads. Pads passed as -1 act as
// wildcards.

struct ResolvedPreset {
  int uart_id;
  int mapping;
  // Iomux selectors for the chosen pads, as returned by uart_pad().
  // -1 if the corresponding pad wasn't used.
  int tx_mux;
  int rx_mux;
  int rts_mux;
  int cts_mux;
};

static bool resolve_preset(int tx_pad, int rx_pad, int rts_pad, int cts_pad,
                           ResolvedPreset* out) {
  // 3 controllers × at most 2 mappings each (UART0:2, UART1:1, UART2:2).
  // We don't allow alt CTS mapping to be picked implicitly — that's only
  // selected by the caller passing the alt CTS pad.
  for (int uart_id = 0; uart_id <= 2; uart_id++) {
    for (int mapping = 0; mapping <= 1; mapping++) {
      int tx_mux = -1, rx_mux = -1;
      int expected_tx = uart_pad(uart_id, UartRole::TX, mapping, &tx_mux);
      int expected_rx = uart_pad(uart_id, UartRole::RX, mapping, &rx_mux);
      // A controller mapping must define both TX and RX pads.
      if (expected_tx < 0 || expected_rx < 0) continue;

      // The user-provided pads must match (or be -1).
      if (tx_pad >= 0 && tx_pad != expected_tx) continue;
      if (rx_pad >= 0 && rx_pad != expected_rx) continue;

      // Flow-control pads (if requested) must agree with this controller.
      // We try every CTS mapping in case the alt pad is in use.
      int rts_mux_found = -1, cts_mux_found = -1;
      if (rts_pad >= 0) {
        bool rts_ok = false;
        for (int rts_mapping = 0; rts_mapping <= 1; rts_mapping++) {
          int mux = -1;
          int p = uart_pad(uart_id, UartRole::RTS, rts_mapping, &mux);
          if (p == rts_pad) { rts_ok = true; rts_mux_found = mux; break; }
        }
        if (!rts_ok) continue;
      }
      if (cts_pad >= 0) {
        bool cts_ok = false;
        for (int cts_mapping = 0; cts_mapping <= 1; cts_mapping++) {
          int mux = -1;
          int p = uart_pad(uart_id, UartRole::CTS, cts_mapping, &mux);
          if (p == cts_pad) { cts_ok = true; cts_mux_found = mux; break; }
        }
        if (!cts_ok) continue;
      }

      out->uart_id = uart_id;
      out->mapping = mapping;
      out->tx_mux = tx_pad >= 0 ? tx_mux : -1;
      out->rx_mux = rx_pad >= 0 ? rx_mux : -1;
      out->rts_mux = rts_mux_found;
      out->cts_mux = cts_mux_found;
      return true;
    }
  }
  return false;
}

static void configure_uart_pad(int pad, int mux, bool pull_up) {
  GPIO_IomuxEC618(pad, mux, 0, 0);
  if (pull_up) GPIO_PullConfig(pad, 1, 1);
}

static void configure_de_pad(int pad) {
  // Any pad can serve as the RS485 direction line; we drive it as plain
  // GPIO, configured as output starting low (= RX direction).
  int gpio_bit = pad_to_gpio(pad);
  if (gpio_bit < 0) return;
  GPIO_IomuxEC618(pad, pad_gpio_mux(pad), 0, 0);
  GpioPinConfig_t config;
  memset(&config, 0, sizeof(config));
  config.pinDirection = GPIO_DIRECTION_OUTPUT;
  config.misc.initOutput = 0;  // Idle low = RX direction.
  GPIO_pinConfig(gpio_bit >> 4, gpio_bit & 0xf, &config);
}

// ---------------------------------------------------------------------------

MODULE_IMPLEMENTATION(uart, MODULE_UART)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  Ec618EventSource* event_source = Ec618EventSource::instance();
  if (event_source == null) FAIL(ALREADY_CLOSED);

  UartResourceGroup* group = _new UartResourceGroup(process, event_source);
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

// Toit mode values (from lib/uart.toit).
static const int kModeUart             = 0;
static const int kModeRs485HalfDuplex  = 1;
static const int kModeIrda             = 2;

// tx_flags bits (lib/uart.toit constructor):
//   1 = invert-tx, 2 = invert-rx, 8 = high-priority, 16 = large-buffers.
static const int kTxFlagInvertTx       = 1;
static const int kTxFlagInvertRx       = 2;
static const int kTxFlagHighPriority   = 8;
static const int kTxFlagLargeBuffers   = 16;

PRIMITIVE(create) {
  ARGS(UartResourceGroup, group,
       int, tx, int, rx, int, rts, int, cts,
       int, baud_rate, int, data_bits, int, stop_bits, int, parity,
       int, tx_flags, int, mode);

  // Both pin args may be -1 (TX-only or RX-only); but at least one must
  // be set, otherwise there's no UART direction at all.
  if (tx < 0 && rx < 0) FAIL(INVALID_ARGUMENT);
  if (data_bits < 5 || data_bits > 8) FAIL(INVALID_ARGUMENT);
  if (stop_bits < 1 || stop_bits > 3) FAIL(INVALID_ARGUMENT);
  if (parity < 1 || parity > 3) FAIL(INVALID_ARGUMENT);
  if (baud_rate <= 0 || baud_rate > 4000000) FAIL(INVALID_ARGUMENT);

  // TX/RX inversion has no EC618 equivalent — reject it rather than silently
  // dropping it. Note: kTxFlagHighPriority is also an ESP32-only knob, but the
  // generic uart library auto-sets it for baud >= 460800 (lib/uart.toit), so
  // rejecting it would make EVERY open at >= 460800 baud fail. It is only a task-
  // priority hint, so treat it as a harmless no-op here. (large-buffers, which the
  // library auto-sets alongside it, is honored below as a bigger RX cache.)
  if ((tx_flags & (kTxFlagInvertTx | kTxFlagInvertRx)) != 0) {
    FAIL(INVALID_ARGUMENT);
  }
  if (mode == kModeIrda) FAIL(INVALID_ARGUMENT);
  if (mode != kModeUart && mode != kModeRs485HalfDuplex) FAIL(INVALID_ARGUMENT);

  // Validate pad ranges up front so the rest of the code can assume they
  // either are -1 or refer to a known pad.
  auto valid_pad = [](int pad) {
    return pad < 0 || (pad > 0 && pad <= kMaxPadIndex);
  };
  if (!valid_pad(tx) || !valid_pad(rx) || !valid_pad(rts) || !valid_pad(cts)) {
    FAIL(INVALID_ARGUMENT);
  }

  // RS485: rts is the direction pin, not a flow-control pin. Take it out
  // of the preset matching and pass any GPIO-capable pad through.
  int de_pad = -1;
  int matched_rts = rts;
  if (mode == kModeRs485HalfDuplex) {
    if (cts != -1) FAIL(INVALID_ARGUMENT);
    if (rts < 0) FAIL(INVALID_ARGUMENT);
    if (pad_to_gpio(rts) < 0) FAIL(INVALID_ARGUMENT);
    de_pad = rts;
    matched_rts = -1;  // Keep the preset matcher away from this pin.
  }

  ResolvedPreset preset = {};
  if (!resolve_preset(tx, rx, matched_rts, cts, &preset)) FAIL(INVALID_ARGUMENT);

  int id = preset.uart_id;

  // Refuse to hand out the controller that's currently carrying the
  // firmware's print stream.
  //
  // Belt-and-suspenders, not load-bearing: a quick experiment with this
  // check disabled showed that interleaved use of the same UART by
  // `printf` (CMSIS Driver_USART<id>->SendPolling, the print path) and
  // by Toit's UART API (Uart_TxTaskSafe, after a fresh Uart_BaseInitEx)
  // produces clean, in-order output — neither side corrupts the other.
  // Re-initialising the controller from underneath the print path does
  // not break it on this chip / PLAT.
  //
  // We still refuse the open because:
  //   - The user almost never wants their data interleaved with [toit]
  //     log lines on the same wire.
  //   - We only verified TX; concurrent RX (both paths racing for the
  //     same incoming bytes) and heavy/bursty loads were not tested.
  //   - It surfaces the situation as an exception instead of producing
  //     mysterious mixed output at runtime.
  //
  // A user who really needs the print UART for application data should
  // rebuild with CONFIG_TOIT_EC618_PRINT_UART_ID pointing at a
  // different controller, or with CONFIG_TOIT_EC618_PRINT_UART=0 to
  // disable the print redirect entirely.
  //
  // CONFIG_TOIT_EC618_ALLOW_PRINT_UART_REUSE escapes this check; the
  // OTA-over-UART path on quirky-plenty needs to receive on the same
  // wire that's also carrying print output. We've observed it working
  // in practice (TX and RX paths don't fight on this chip).
#if CONFIG_TOIT_EC618_PRINT_UART && !CONFIG_TOIT_EC618_ALLOW_PRINT_UART_REUSE
  if (id == CONFIG_TOIT_EC618_PRINT_UART_ID) FAIL(ALREADY_IN_USE);
#endif

  if (uart_states[id].in_use) FAIL(ALREADY_IN_USE);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  UartResource* resource = _new UartResource(group, id);
  if (resource == null) FAIL(MALLOC_FAILED);

  // Pin muxing — only touch pads the user actually configured.
  if (tx >= 0)  configure_uart_pad(tx,  preset.tx_mux,  /*pull_up=*/false);
  if (rx >= 0)  configure_uart_pad(rx,  preset.rx_mux,  /*pull_up=*/true);
  if (matched_rts >= 0) configure_uart_pad(rts, preset.rts_mux, /*pull_up=*/false);
  if (cts >= 0) configure_uart_pad(cts, preset.cts_mux, /*pull_up=*/true);
  if (de_pad >= 0) configure_de_pad(de_pad);

  {
    // Every controller runs the open CMSIS driver (see the include
    // comment): TX is DMA mode (asynchronous Send from the malloc'd
    // staging buffer), RX is IRQ mode.
    uint32_t ring_size = (tx_flags & kTxFlagLargeBuffers) ? 32768 : 8192;
    uint32_t tx_buf_size = (tx_flags & kTxFlagLargeBuffers) ? 4096 : 2048;
    CmsisRx* rx = unvoid_cast<CmsisRx*>(calloc(1, sizeof(CmsisRx)));
    uint8_t* ring = rx ? unvoid_cast<uint8_t*>(malloc(ring_size)) : null;
    uint8_t* tx_buf = ring ? unvoid_cast<uint8_t*>(malloc(tx_buf_size)) : null;
    if (rx == null || ring == null || tx_buf == null) {
      free(ring);
      free(rx);
      delete resource;
      FAIL(MALLOC_FAILED);
    }
    rx->ring = ring;
    rx->ring_size = ring_size;
    rx->tx_buf = tx_buf;
    rx->tx_buf_size = tx_buf_size;
    rx->control = cmsis_control_word(data_bits, parity, stop_bits);
    uart_states[id].cmsis_rx = rx;  // Set before the first event can fire.
    ARM_DRIVER_USART* driver = kDrivers[id];
    // Uninitialize first — but ONLY if the driver is genuinely
    // initialized: Initialize() is a no-op on an INITIALIZED driver (the
    // console controller is initialized at boot by the print path, so our
    // event callback would silently never install), while Uninitialize()
    // on a NEVER-initialized driver closes DMA channels that were never
    // opened and wedges the device on the next open. Track it ourselves;
    // the print-uart teardown intentionally leaves its driver
    // initialized.
    bool was_initialized = cmsis_initialized[id];
#if CONFIG_TOIT_EC618_PRINT_UART
    if (id == CONFIG_TOIT_EC618_PRINT_UART_ID) was_initialized = true;
#endif
    if (was_initialized) driver->Uninitialize();
    driver->Initialize(kUartCallbacks[id]);
    cmsis_initialized[id] = true;
    // FULL -> OFF -> FULL: the OFF in the middle GPR-resets the UART block.
    // Every close does this reset, but the FIRST open since boot starts
    // from whatever state the ROM left the controller in — that first
    // session was consistently dead on the wire (echo 9600/reopen cell,
    // duplex round 1) until a close/reopen cycle had reset the block once.
    // The reset must run with the block CLOCKED (OFF before any FULL = bus
    // hang), hence the leading FULL.
    driver->PowerControl(ARM_POWER_FULL);
    driver->PowerControl(ARM_POWER_OFF);
    driver->PowerControl(ARM_POWER_FULL);
    // (The RX FIFO triggers are 16 via USARTn_RX_TRIG_LVL in RTE_Device.h
    // — the IRQ-mode default of 30-of-32 left 2 bytes of overrun
    // headroom.)
    driver->Control(rx->control, baud_rate);
    // Autobaud off, explicitly: the boot ROM leaves UART0 in autobaud
    // ("urc baud: 0") and SetBaudrate only clears ADCR for baud==0; with
    // ADCR live, the irq handler treats RX timeouts as autobaud events.
    kUartRegs[id]->ADCR = 0;
    driver->Control(ARM_USART_CONTROL_TX, 1);
    driver->Control(ARM_USART_CONTROL_RX, 1);
    // Masked: Receive() enables the RX irqs mid-call and can invoke the
    // event callback from THIS task context — an RX irq landing in that
    // window runs a second callback concurrently, and two ring pushes
    // racing on `head` turn the ring memcpy into a wild write.
    uint32_t arm_mask = irq_save();
    if (driver->Receive(rx->chunk, sizeof(rx->chunk)) != ARM_DRIVER_OK) {
      rx->rearm_fails++;
    }
    irq_restore(arm_mask);
  }

  uart_states[id].in_use = true;
  uart_states[id].baud_rate = baud_rate;
  uart_states[id].errors = 0;
  uart_states[id].de_pad = de_pad;

  group->register_resource(resource);
  group->sleep_vote(1);
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(create_path) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(close) {
  ARGS(UartResourceGroup, group, UartResource, resource);
  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(get_baud_rate) {
  ARGS(UartResource, resource);
  return Primitive::integer(uart_states[resource->uart_id()].baud_rate, process);
}

PRIMITIVE(set_baud_rate) {
  ARGS(UartResource, resource, int, baud_rate);
  if (baud_rate <= 0 || baud_rate > 4000000) FAIL(INVALID_ARGUMENT);
  int id = resource->uart_id();
  CmsisRx* rx = uart_states[id].cmsis_rx;
  if (rx == null) FAIL(ALREADY_CLOSED);
  {
    // Set-baud is a full power-cycle of the controller, mirroring the
    // create path exactly (one mental model, one tested sequence). A baud
    // change loses in-flight bytes by definition, so the FIFO/GPR reset
    // costs nothing semantically. ABORT_RECEIVE is a silent no-op in
    // bsp_usart.c; CONTROL_RX 0 is the supported abort, and Control()
    // with a mode word disables the whole UART while it swaps the
    // divisor, so the quiesce must come first.
    uint32_t mask = irq_save();
    ARM_DRIVER_USART* driver = kDrivers[id];
    driver->Control(ARM_USART_CONTROL_RX, 0);
    driver->Control(ARM_USART_CONTROL_TX, 0);
    driver->PowerControl(ARM_POWER_OFF);   // GPR block reset (clocked).
    driver->PowerControl(ARM_POWER_FULL);
    driver->Control(rx->control, static_cast<uint32_t>(baud_rate));
    driver->Control(ARM_USART_CONTROL_TX, 1);
    driver->Control(ARM_USART_CONTROL_RX, 1);
    rx->seen = 0;
    // The power cycle killed any in-flight Send (a baud change loses
    // in-flight bytes by definition); without this the writer would wait
    // forever for a SEND_COMPLETE that can no longer fire.
    rx->tx_busy = false;
    if (driver->Receive(rx->chunk, sizeof(rx->chunk)) != ARM_DRIVER_OK) {
      rx->rearm_fails++;
    }
    irq_restore(mask);
  }
  uart_states[id].baud_rate = baud_rate;
  return process->null_object();
}

PRIMITIVE(write) {
  ARGS(UartResource, resource, Blob, data, int, from, int, to, int, break_length);
  // The PLAT driver has no break-signal API. Reject rather than silently
  // sending the data without the requested break.
  if (break_length != 0) FAIL(UNIMPLEMENTED);
  if (from < 0 || to < from || to > data.length()) FAIL(OUT_OF_BOUNDS);

  int id = resource->uart_id();

  // Raise the RS485 direction line before the first byte goes out; the
  // TX-done callback drops it once the shift register drains.
  int de = uart_states[id].de_pad;
  if (de >= 0) set_de_level(de, 1);

  int len = to - from;
  int written;
  CmsisRx* rx = uart_states[id].cmsis_rx;
  if (rx == null) FAIL(ALREADY_CLOSED);
  {
    // CMSIS path: UART2 TX is DMA_MODE (RTE_Device.h) — Send is
    // ASYNCHRONOUS and keeps reading its buffer after this primitive
    // returns, so the bytes are staged in tx_buf first (a Toit heap
    // object can move under GC). One Send in flight at a time: while
    // busy, accept nothing — the SEND_COMPLETE callback posts the TX
    // event that makes the library retry the rest.
    if (rx->tx_busy) {
      written = 0;
    } else if (len == 1) {
      // Send() special-cases num==1 (no DMA: IER |= TX_DATA_REQ + a direct
      // THR write) and that byte was observed to VANISH from the wire under
      // load — a lost protocol ack stalls the whole test rig. SendPolling
      // is synchronous, drains the FIFO first, and is exercised constantly
      // by the print path; a single byte costs one frame time.
      int32_t status32 = kDrivers[id]->SendPolling(data.address() + from, 1);
      written = (status32 == ARM_DRIVER_OK) ? 1 : 0;
    } else {
      int chunk = len;
      if (chunk > (int)rx->tx_buf_size) chunk = (int)rx->tx_buf_size;
      memcpy(rx->tx_buf, data.address() + from, chunk);
      rx->tx_busy = true;
      int32_t status32 = kDrivers[id]->Send(rx->tx_buf, chunk);
      if (status32 != ARM_DRIVER_OK) {
        rx->tx_busy = false;
        written = 0;
      } else {
        written = chunk;
      }
    }
  }

  // (RS485: Send is asynchronous; the SEND_COMPLETE callback drops the DE
  // line after a TEMT spin — dropping it here would cut the line
  // mid-transfer.)
  return Primitive::integer(written, process);
}

PRIMITIVE(read) {
  ARGS(UartResource, resource);
  int id = resource->uart_id();

  CmsisRx* rx = uart_states[id].cmsis_rx;
  if (rx != null) {
    if (!kRxIsDma[id]) {
      // IRQ-mode rescue: a full-rate burst can end an overrun storm with
      // bytes stranded in the hardware FIFO and no interrupt edge left to
      // deliver them. Pull them in whenever the reader looks (to ONE
      // byte, see the overflow handler). Never on a DMA-owned FIFO.
      uint32_t mask = irq_save();
      USART_TypeDef* reg = kUartRegs[id];
      uint8_t fifo_buf[32];
      uint32_t got = 0;
      while (got < sizeof(fifo_buf) &&
             EIGEN_FLD2VAL(USART_FCNR_RX_FIFO_NUM, reg->FCNR) > 1) {
        fifo_buf[got++] = (uint8_t)reg->RBR;
      }
      if (got > 0) {
        uint32_t n = kDrivers[id]->GetRxCount();
        if (n > sizeof(rx->chunk)) n = sizeof(rx->chunk);
        if (n > rx->seen) {
          cmsis_ring_push(id, rx->chunk + rx->seen, n - rx->seen);
          rx->seen = n;
        }
        cmsis_ring_push(id, fifo_buf, got);
      }
      irq_restore(mask);
    }
    // Drain our ring (filled by cmsis_uart_event). Snapshot head once: the
    // IRQ only ever ADDS bytes, so the window we copy is stable.
    uint32_t head = rx->head;
    uint32_t tail = rx->tail;
    uint32_t available = head >= tail ? head - tail
                                      : rx->ring_size - tail + head;
    if (available == 0) return process->null_object();
    ByteArray* result = process->allocate_byte_array(available);
    if (result == null) FAIL(ALLOCATION_FAILED);
    ByteArray::Bytes bytes(result);
    for (uint32_t i = 0; i < available; i++) {
      bytes.address()[i] = rx->ring[tail];
      tail = tail + 1 == rx->ring_size ? 0 : tail + 1;
    }
    rx->tail = tail;
    return result;
  }
  FAIL(ALREADY_CLOSED);
}

PRIMITIVE(wait_tx) {
  ARGS(UartResource, resource);
  int id = resource->uart_id();
  if (tx_idle(id)) return BOOL(true);
  // There is no reliable line-idle event to retry on: the blob's
  // TX_ALL_DONE is best-effort (see uart_cb), so a plain non-blocking
  // TEMT check left flush waiting for an event that never comes — at
  // 9600 baud it hung forever (uart2-flush-ec618). Poll TEMT instead,
  // bounded by the drain time of everything that can still be in flight
  // (TX cache + FIFO) at the current baud. This blocks the VM like
  // Uart_TxTaskSafe itself does; the planned CMSIS rewrite gets a real
  // TX-idle interrupt. A concurrent writer can keep the line busy past
  // the bound; then we return false and the caller waits for that
  // writer's TX events.
  uint32_t baud = uart_states[id].baud_rate;
  uint32_t limit_ms = (1024 + 64) * 10 * 1000 / baud + 50;
  while (!tx_idle(id) && limit_ms-- > 0) osDelay(1);
  return BOOL(tx_idle(id));
}

PRIMITIVE(set_control_flags) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(get_control_flags) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(errors) {
  ARGS(UartResource, resource);
  return Primitive::integer(uart_states[resource->uart_id()].errors, process);
}

}  // namespace toit

#endif  // TOIT_EC618
