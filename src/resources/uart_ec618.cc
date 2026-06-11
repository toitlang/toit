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
  #include "driver_uart.h"
  #include "gpio.h"
  #include "platform_define.h"
  // The OPEN CMSIS driver (bsp_usart.c) — UART2 runs on it instead of the
  // closed Uart_* blob (docs/ec618-uart-cmsis-rewrite.md): the blob's RX
  // ring silently discards everything on overflow and kills RX until
  // reopen (known-issues #4). The access struct is DATA (never routed
  // through the jump table — see gen-plat-jt's DATA-SYMBOLS).
  #include "Driver_USART.h"
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

  void on_unregister_resource(Resource* r) override {
    auto uart_res = static_cast<UartResource*>(r);
    int id = uart_res->uart_id();
    UartState& state = uart_states[id];
    if (state.in_use) {
#if CONFIG_TOIT_EC618_PRINT_UART
      // The print UART shares the controller with printf/monitor output;
      // Uart_DeInit tears down that print path and can block (the OTA-over-UART
      // close-hang). Leave the controller running — the print path keeps it.
      if (id == CONFIG_TOIT_EC618_PRINT_UART_ID) {
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
        Driver_USART2.Control(ARM_USART_CONTROL_RX, 0);
        Driver_USART2.Control(ARM_USART_CONTROL_TX, 0);
        Driver_USART2.PowerControl(ARM_POWER_OFF);
        Driver_USART2.Uninitialize();
        CmsisRx* rx = state.cmsis_rx;
        state.cmsis_rx = null;  // Unhook before freeing (the IRQ checks it).
        irq_restore(mask);
        free(rx->ring);
        free(rx);
      } else {
        Uart_DeInit(id);
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
        state |= kErrorState;
        break;
    }
    return state;
  }
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

static void cmsis_rx_event2(uint32_t event) {
  const int id = 2;
  uint32_t mask = irq_save();
  CmsisRx* rx = uart_states[id].cmsis_rx;
  if (rx == null) {
    irq_restore(mask);
    return;
  }
  rx->cb_events++;
  if (event & (ARM_USART_EVENT_RECEIVE_COMPLETE | ARM_USART_EVENT_RX_TIMEOUT)) {
    uint32_t n = Driver_USART2.GetRxCount();
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
      if (Driver_USART2.Receive(rx->chunk, sizeof(rx->chunk)) != ARM_DRIVER_OK) {
        rx->rearm_fails++;
      }
    }
  }
  if (event & ARM_USART_EVENT_RX_OVERFLOW) {
    uart_states[id].errors++;
    // Self-heal: the SDK irq handler is an else-if chain that services
    // LINE_STATUS (the overrun) INSTEAD of draining data, and with the
    // FIFO still full the overrun re-asserts on the next byte — RX
    // death-spirals delivering nothing until the line idles. Empty the
    // FIFO ourselves. Push the chunk delta first so byte order holds
    // (everything in the FIFO is newer than everything in the chunk).
    uint32_t n = Driver_USART2.GetRxCount();
    if (n > sizeof(rx->chunk)) n = sizeof(rx->chunk);
    if (n > rx->seen) {
      cmsis_ring_push(id, rx->chunk + rx->seen, n - rx->seen);
      rx->seen = n;
    }
    // Drain to ONE byte, never empty: the SDK's RX_DATA_REQ handler does
    // `i = bytes_in_fifo - 1` with no zero guard — an empty FIFO underflows
    // i to 0xFFFFFFFF and it reads RBR hundreds of times off an empty FIFO
    // (observed as a hard wedge only the WDT backstop clears). One byte
    // left still stops the overrun from re-asserting.
    USART_TypeDef* reg = reinterpret_cast<USART_TypeDef*>(MP_UART2_BASE_ADDR);
    uint8_t fifo_buf[32];
    uint32_t got = 0;
    while (got < sizeof(fifo_buf) &&
           EIGEN_FLD2VAL(USART_FCNR_RX_FIFO_NUM, reg->FCNR) > 1) {
      fifo_buf[got++] = (uint8_t)reg->RBR;
    }
    if (got > 0) cmsis_ring_push(id, fifo_buf, got);
    send_uart_event(id, got > 0 ? Event::UART_KIND_RX : Event::UART_KIND_ERROR);
  }
  if (event & (ARM_USART_EVENT_SEND_COMPLETE | ARM_USART_EVENT_TX_COMPLETE)) {
    int de = uart_states[id].de_pad;
    if (de >= 0 && (event & ARM_USART_EVENT_TX_COMPLETE)) set_de_level(de, 0);
    send_uart_event(id, Event::UART_KIND_TX_DONE);
  }
  if (event & (ARM_USART_EVENT_RX_FRAMING_ERROR | ARM_USART_EVENT_RX_PARITY_ERROR |
               ARM_USART_EVENT_RX_BREAK)) {
    uart_states[id].errors++;
    send_uart_event(id, Event::UART_KIND_ERROR);
  }
  irq_restore(mask);
}

// TX shift register + FIFO empty. The blob's Uart_IsTSREmpty consults
// ITS OWN per-uart state, which is garbage for a controller the blob
// never initialized (the CMSIS-owned UART2) — flush hung forever on it.
// Read the hardware LSR directly for the CMSIS path.
static bool tx_idle(int id) {
  if (uart_states[id].cmsis_rx != null) {
    USART_TypeDef* reg = reinterpret_cast<USART_TypeDef*>(MP_UART2_BASE_ADDR);
    return (reg->LSR & USART_LSR_TX_EMPTY_Msk) != 0;
  }
  return Uart_IsTSREmpty(id) != 0;
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

// --- Driver callback (called by the PLAT UART ISR) --------------------------
//
// pData carries the UART id; pParam carries the UART_CB_* event kind.

static int32_t uart_cb(void* p_data, void* p_param) {
  uintptr_t id = reinterpret_cast<uintptr_t>(p_data);
  uintptr_t kind = reinterpret_cast<uintptr_t>(p_param);
  if (id > 2) return 0;

  switch (kind) {
    case UART_CB_RX_NEW:
    case UART_CB_RX_TIMEOUT:
    case UART_CB_RX_BUFFER_FULL:
      Ec618EventSource::send_event_from_isr(
          Event::uart_type(id), Event::UART_KIND_RX);
      break;

    case UART_CB_TX_ALL_DONE: {
      // RS485: drop the direction line once the last bit has left the shift
      // register. This is only a zero-latency FAST PATH: the PLAT blob
      // samples LSR.TEMT exactly once when it processes the TX-DMA-done
      // event and reports ALL_DONE only if the line already drained by then
      // (disassembly of prvUart_TxDone in libcore_airm2m.a). That race is
      // won at high baud and lost at low baud (e.g. 115200: FIFO drain
      // outlives the event dispatch, only TX_BUFFER_DONE arrives, ever).
      // The write primitive therefore drains synchronously as the
      // correctness path; dropping DE twice is harmless.
      int de = uart_states[id].de_pad;
      if (de >= 0) set_de_level(de, 0);
      Ec618EventSource::send_event_from_isr(
          Event::uart_type(id), Event::UART_KIND_TX_DONE);
      break;
    }

    case UART_CB_TX_BUFFER_DONE:
      Ec618EventSource::send_event_from_isr(
          Event::uart_type(id), Event::UART_KIND_TX_DONE);
      break;

    case UART_CB_ERROR:
      uart_states[id].errors++;
      Ec618EventSource::send_event_from_isr(
          Event::uart_type(id), Event::UART_KIND_ERROR);
      break;
  }
  return 0;
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

// --- Arg translation --------------------------------------------------------

static uint8_t to_plat_parity(int parity) {
  switch (parity) {
    case 1: return UART_PARITY_NONE;  // Toit PARITY-DISABLED
    case 2: return UART_PARITY_EVEN;
    case 3: return UART_PARITY_ODD;
    default: return UART_PARITY_NONE;
  }
}

static uint8_t to_plat_stop_bits(int stop_bits) {
  switch (stop_bits) {
    case 1: return UART_STOP_BIT1;
    case 2: return UART_STOP_BIT1_5;
    case 3: return UART_STOP_BIT2;
    default: return UART_STOP_BIT1;
  }
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

  uint32_t rx_cache = (tx_flags & kTxFlagLargeBuffers) ? 4096 : 2048;
  uint32_t tx_cache = 1024;

  if (id == 2) {
    // UART2 runs on the open CMSIS driver (see the include comment).
    // Both TX (polling mode per RTE_Device.h — Send is synchronous like
    // Uart_TxTaskSafe) and RX move together: the two stacks fight over
    // the same registers, so they are never mixed on one controller.
    uint32_t ring_size = (tx_flags & kTxFlagLargeBuffers) ? 32768 : 8192;
    CmsisRx* rx = unvoid_cast<CmsisRx*>(calloc(1, sizeof(CmsisRx)));
    uint8_t* ring = rx ? unvoid_cast<uint8_t*>(malloc(ring_size)) : null;
    if (rx == null || ring == null) {
      free(rx);
      delete resource;
      FAIL(MALLOC_FAILED);
    }
    rx->ring = ring;
    rx->ring_size = ring_size;
    rx->control = cmsis_control_word(data_bits, parity, stop_bits);
    uart_states[id].cmsis_rx = rx;  // Set before the first event can fire.
    Driver_USART2.Initialize(cmsis_rx_event2);
    // FULL -> OFF -> FULL: the OFF in the middle GPR-resets the UART block.
    // Every close does this reset, but the FIRST open since boot starts
    // from whatever state the ROM left the controller in — that first
    // session was consistently dead on the wire (echo 9600/reopen cell,
    // duplex round 1) until a close/reopen cycle had reset the block once.
    // The reset must run with the block CLOCKED (OFF before any FULL = bus
    // hang), hence the leading FULL.
    Driver_USART2.PowerControl(ARM_POWER_FULL);
    Driver_USART2.PowerControl(ARM_POWER_OFF);
    Driver_USART2.PowerControl(ARM_POWER_FULL);
    {
      // RX FIFO trigger 16, not the IRQ-mode default 30: the default
      // leaves 2 bytes (22 us at 921600) of headroom before a hardware
      // overrun, which one COMPLETE-event ring copy already overshoots.
      // 16 gives 16 bytes (~170 us) at ~2x the irq rate. Slot-side poke;
      // the clean RTE override (USART2_RX_TRIG_LVL) is a base change,
      // bundled with the next full flash.
      USART_TypeDef* reg = reinterpret_cast<USART_TypeDef*>(MP_UART2_BASE_ADDR);
      reg->FCR = USART_FCR_FIFO_EN_Msk |
                 (2U << USART_FCR_RX_FIFO_AVAIL_TRIG_LEVEL_Pos);
    }
    Driver_USART2.Control(rx->control, baud_rate);
    Driver_USART2.Control(ARM_USART_CONTROL_TX, 1);
    Driver_USART2.Control(ARM_USART_CONTROL_RX, 1);
    // Masked: Receive() enables the RX irqs mid-call and can invoke the
    // event callback from THIS task context — an RX irq landing in that
    // window runs a second callback concurrently, and two ring pushes
    // racing on `head` turn the ring memcpy into a wild write.
    uint32_t arm_mask = irq_save();
    if (Driver_USART2.Receive(rx->chunk, sizeof(rx->chunk)) != ARM_DRIVER_OK) {
      rx->rearm_fails++;
    }
    irq_restore(arm_mask);
  } else {
    Uart_BaseInitEx(id, baud_rate, tx_cache, rx_cache,
                    static_cast<uint8_t>(data_bits),
                    to_plat_parity(parity),
                    to_plat_stop_bits(stop_bits),
                    uart_cb);

    // Drop any bytes that were already in the RX buffer when we opened
    // the controller — they come from before the application asked for
    // this UART, not from data the application is supposed to see.
    Uart_RxBufferClear(id);
  }

  uart_states[id].in_use = true;
  uart_states[id].baud_rate = baud_rate;
  uart_states[id].errors = 0;
  uart_states[id].de_pad = de_pad;

  group->register_resource(resource);
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
  if (rx != null) {
    // Quiesce before reconfiguring: Control() with a mode word DISABLES
    // the whole UART while it swaps the divisor (USART_SetBaudrate), so
    // it must never run against a live transfer — and ABORT_RECEIVE is
    // unsupported in bsp_usart.c (returns ERROR_UNSUPPORTED, a no-op).
    // CONTROL_RX 0 is the real abort: RX irqs masked + cleared, DMA
    // channel suspended, rx_busy forced 0. Masked so neither uart nor
    // DMA irq interleaves with the reconfigure.
    uint32_t mask = irq_save();
    Driver_USART2.Control(ARM_USART_CONTROL_RX, 0);
    Driver_USART2.Control(rx->control, static_cast<uint32_t>(baud_rate));
    Driver_USART2.Control(ARM_USART_CONTROL_RX, 1);
    rx->seen = 0;
    if (Driver_USART2.Receive(rx->chunk, sizeof(rx->chunk)) != ARM_DRIVER_OK) {
      rx->rearm_fails++;
    }
    irq_restore(mask);
  } else {
    Uart_ChangeBR(id, static_cast<uint32_t>(baud_rate));
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
  if (uart_states[id].cmsis_rx != null) {
    // CMSIS path: UART2 TX is POLLING_MODE (RTE_Device.h), so Send is
    // synchronous. Cap each call so a large write cannot stall the VM
    // (and starve the readers a full-duplex peer depends on) — the
    // library loops on the partial count, re-entering between chunks.
    int chunk = len > 512 ? 512 : len;
    int32_t status32 = Driver_USART2.Send(data.address() + from, chunk);
    written = (status32 == ARM_DRIVER_OK) ? chunk : 0;
    if (written > 0 && written < len) {
      // The library waits for a TX event before retrying the rest;
      // polling-mode Send completes inline and may not signal one. This
      // runs in task context — the FromISR variant would be unsafe here
      // (and a lost event leaves the library waiting forever).
      Ec618EventSource::send_event(
          Event::uart_type(id), Event::UART_KIND_TX_DONE);
    }
  } else {
    // Uart_TxTaskSafe returns 0 on success, non-zero on error — it is a
    // status code, not a byte count. On success the full request was
    // accepted; on failure nothing was written.
    int status = Uart_TxTaskSafe(id, data.address() + from, len);
    written = (status == 0) ? len : 0;
  }

  // RS485: drop the direction line once the line is idle. The TX_ALL_DONE
  // fast path in uart_cb cannot be relied on (see the comment there), so
  // poll the transmitter-empty flag here. Cost: Uart_TxTaskSafe already
  // blocks for everything beyond its TX cache, so what remains in flight
  // is at most the cache (1024) plus the hardware FIFO — bound the poll
  // by that drain time at the current baud. RS485 writes are thereby
  // synchronous: when write returns, the bus has been released.
  if (de >= 0 && written > 0) {
    uint32_t baud = uart_states[id].baud_rate;
    uint32_t limit_ms = (1024 + 64) * 10 * 1000 / baud + 50;
    while (!tx_idle(id) && limit_ms-- > 0) osDelay(1);
    set_de_level(de, 0);
  }
  return Primitive::integer(written, process);
}

PRIMITIVE(read) {
  ARGS(UartResource, resource);
  int id = resource->uart_id();

  CmsisRx* rx = uart_states[id].cmsis_rx;
  if (rx != null) {
    // Drain our ring (filled by cmsis_rx_event2). Snapshot head once: the
    // IRQ only ever ADDS bytes, so the window we copy is stable.
    uint32_t head = rx->head;
    uint32_t tail = rx->tail;
    uint32_t available = head >= tail ? head - tail
                                      : rx->ring_size - tail + head;
    if (available == 0) return process->null_object();
    ByteArray* result = process->object_heap()->allocate_internal_byte_array(available);
    if (result == null) FAIL(ALLOCATION_FAILED);
    ByteArray::Bytes bytes(result);
    for (uint32_t i = 0; i < available; i++) {
      bytes.address()[i] = rx->ring[tail];
      tail = tail + 1 == rx->ring_size ? 0 : tail + 1;
    }
    rx->tail = tail;
    return result;
  }

  // Peek the available byte count first so we can size the buffer right.
  int available = Uart_RxBufferRead(id, null, 0);
  if (available <= 0) return process->null_object();

  ByteArray* result = process->object_heap()->allocate_internal_byte_array(available);
  if (result == null) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes bytes(result);

  int read = Uart_RxBufferRead(id, bytes.address(), available);
  if (read <= 0) return process->null_object();
  if (read < available) {
    // The driver drained fewer bytes than it reported; trim the result.
    ByteArray* trimmed = process->object_heap()->allocate_internal_byte_array(read);
    if (trimmed == null) FAIL(ALLOCATION_FAILED);
    ByteArray::Bytes tbytes(trimmed);
    memcpy(tbytes.address(), bytes.address(), read);
    return trimmed;
  }
  return result;
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
