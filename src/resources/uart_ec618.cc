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
  #include "driver_gpio.h"
  #include "driver_uart.h"
  #include "platform_define.h"
}

namespace toit {

// All pin arguments to PRIMITIVE(create) are PAD numbers (1..kMaxPadIndex).
// -1 means "not used". Pin/function validation goes through the pad table
// in `pad_table_ec618.h`, which is the single source of truth for which
// physical pad carries which UART role.

// Per-UART state.
struct UartState {
  bool in_use;          // Whether the controller currently has a Toit resource.
  uint32_t baud_rate;   // Cached baud rate, for `get_baud_rate` without register reads.
  uint32_t errors;      // Counter incremented from the driver callback on
                        // parity/overrun/break.
  int de_pad;           // RS485 direction pin (PAD number), or -1.
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
      Uart_DeInit(id);
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
      UartQcx216EventSource::send_event_from_isr(
          Event::uart_type(id), Event::UART_KIND_RX);
      break;

    case UART_CB_TX_ALL_DONE: {
      // RS485: drop the direction line once the last bit has left the shift
      // register. Software-timed but good enough for standard transceivers.
      int de = uart_states[id].de_pad;
      if (de >= 0) {
        int de_bit = pad_to_gpio(de);
        if (de_bit >= 0) GPIO_Output(de_bit, 0);
      }
      UartQcx216EventSource::send_event_from_isr(
          Event::uart_type(id), Event::UART_KIND_TX_DONE);
      break;
    }

    case UART_CB_TX_BUFFER_DONE:
      UartQcx216EventSource::send_event_from_isr(
          Event::uart_type(id), Event::UART_KIND_TX_DONE);
      break;

    case UART_CB_ERROR:
      uart_states[id].errors++;
      UartQcx216EventSource::send_event_from_isr(
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
  // GPIO. Set iomux to function 0 and configure as output starting low
  // (= RX direction).
  int gpio_bit = pad_to_gpio(pad);
  if (gpio_bit < 0) return;
  GPIO_IomuxEC618(pad, 0, 0, 0);
  GPIO_Config(gpio_bit, 0 /*output*/, 0 /*idle level*/);
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

  UartQcx216EventSource* event_source = UartQcx216EventSource::instance();
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

  if ((tx_flags & (kTxFlagInvertTx | kTxFlagInvertRx | kTxFlagHighPriority)) != 0) {
    // ESP32-only knobs; fail clean rather than silently drop.
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

  Uart_BaseInitEx(id, baud_rate, tx_cache, rx_cache,
                  static_cast<uint8_t>(data_bits),
                  to_plat_parity(parity),
                  to_plat_stop_bits(stop_bits),
                  uart_cb);

  // Drop any bytes that were already in the RX buffer when we opened
  // the controller — they come from before the application asked for
  // this UART, not from data the application is supposed to see.
  Uart_RxBufferClear(id);

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
  Uart_ChangeBR(id, static_cast<uint32_t>(baud_rate));
  uart_states[id].baud_rate = baud_rate;
  return process->null_object();
}

PRIMITIVE(write) {
  ARGS(UartResource, resource, Blob, data, int, from, int, to, int, break_length);
  USE(break_length);  // Not supported on EC618.
  if (from < 0 || to < from || to > data.length()) FAIL(OUT_OF_BOUNDS);

  int id = resource->uart_id();

  // Raise the RS485 direction line before the first byte goes out; the
  // TX-done callback drops it once the shift register drains.
  int de = uart_states[id].de_pad;
  if (de >= 0) {
    int de_bit = pad_to_gpio(de);
    if (de_bit >= 0) GPIO_Output(de_bit, 1);
  }

  // Uart_TxTaskSafe returns 0 on success, non-zero on error — it is a
  // status code, not a byte count. On success the full request was
  // accepted; on failure nothing was written.
  int len = to - from;
  int status = Uart_TxTaskSafe(id, data.address() + from, len);
  int written = (status == 0) ? len : 0;
  return Primitive::integer(written, process);
}

PRIMITIVE(read) {
  ARGS(UartResource, resource);
  int id = resource->uart_id();

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
  return BOOL(Uart_IsTSREmpty(id));
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
