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

#ifdef TOIT_RP2350

#include <atomic>
#include <stdlib.h>
#include <string.h>

#include "hardware/gpio.h"
#include "hardware/irq.h"
#include "hardware/regs/uart.h"
#include "hardware/uart.h"

#include "FreeRTOS.h"
#include "task.h"

#include "../event_sources/uart_rp2350.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../utils.h"

namespace toit {

bool gpio_pool_take(int pin);
void gpio_pool_put(int pin);

static ResourcePool<int, -1> uart_controllers(0, 1);

static const int kModeUart = 0;
static const int kModeRs485HalfDuplex = 1;
static const int kModeIrda = 2;

static const int kTxFlagInvertTx = 1;
static const int kTxFlagInvertRx = 2;
static const int kTxFlagLargeBuffers = 16;

static const uint32_t kUartErrorBits =
    UART_UARTDR_OE_BITS | UART_UARTDR_BE_BITS |
    UART_UARTDR_PE_BITS | UART_UARTDR_FE_BITS;
static const uint32_t kUartErrorInterruptBits =
    UART_UARTIMSC_OEIM_BITS | UART_UARTIMSC_BEIM_BITS |
    UART_UARTIMSC_PEIM_BITS | UART_UARTIMSC_FEIM_BITS;

static bool is_valid_pin(int pin) {
  return pin >= 0 && pin < static_cast<int>(NUM_BANK0_GPIOS);
}

static bool is_restricted_pin(int pin) {
#ifdef PICO_PSRAM_CS_PIN
  if (pin == PICO_PSRAM_CS_PIN) return true;
#endif
  return false;
}

enum UartPinRole {
  UART_PIN_TX,
  UART_PIN_RX,
  UART_PIN_RTS,
  UART_PIN_CTS,
};

struct UartPinMapping {
  int uart_id;
  gpio_function_t function;
};

// RP2350 repeats the UART pin groups every four GPIOs. Consecutive groups
// select UART0, UART1, UART1, UART0. TX/RX also have AUX alternatives on the
// primary CTS/RTS pins; flow-control roles always use the primary function.
static bool uart_pin_mapping(int pin, UartPinRole role,
                             UartPinMapping* mapping) {
  if (!is_valid_pin(pin)) return false;
  int position = pin & 3;
  gpio_function_t function;
  switch (role) {
    case UART_PIN_TX:
      if (position != 0 && position != 2) return false;
      function = position == 0 ? GPIO_FUNC_UART : GPIO_FUNC_UART_AUX;
      break;
    case UART_PIN_RX:
      if (position != 1 && position != 3) return false;
      function = position == 1 ? GPIO_FUNC_UART : GPIO_FUNC_UART_AUX;
      break;
    case UART_PIN_RTS:
      if (position != 3) return false;
      function = GPIO_FUNC_UART;
      break;
    case UART_PIN_CTS:
      if (position != 2) return false;
      function = GPIO_FUNC_UART;
      break;
    default:
      UNREACHABLE();
  }
  mapping->uart_id = (((pin >> 2) + 1) >> 1) & 1;
  mapping->function = function;
  return true;
}

static bool decode_pin(int encoded, int* pin) {
  if (encoded == -1) {
    *pin = -1;
  } else if (encoded >= 0) {
    *pin = encoded;
  } else {
    // Peripheral gpio.Pin arguments are deprecated and deliberately not
    // supported on RP2350. Pin arguments must be plain GPIO numbers.
    return false;
  }
  return true;
}

class PinReservations {
 public:
  ~PinReservations() { release(); }

  bool take(int pin) {
    if (pin < 0) return true;
    uint64_t bit = uint64_t{1} << pin;
    if (!gpio_pool_take(pin)) return false;
    owned_ |= bit;
    return true;
  }

  uint64_t keep() {
    uint64_t result = owned_;
    owned_ = 0;
    return result;
  }

 private:
  void release() {
    for (int pin = 0; owned_ != 0; pin++, owned_ >>= 1) {
      if (owned_ & 1) gpio_pool_put(pin);
    }
  }

  uint64_t owned_ = 0;
};

class UartResource : public Rp2350UartEventResource {
 public:
  TAG(UartResource);

  UartResource(ResourceGroup* group, int uart_id,
               int tx_pin, int rx_pin, int rts_pin, int cts_pin,
               bool rs485,
               uint64_t owned_pins, uint8_t* rx_ring, uint32_t rx_ring_size,
               uint8_t* tx_ring, uint32_t tx_ring_size)
      : Rp2350UartEventResource(group, uart_id)
      , uart_(uart_get_instance(uart_id))
      , tx_pin_(tx_pin)
      , rx_pin_(rx_pin)
      , rts_pin_(rts_pin)
      , cts_pin_(cts_pin)
      , rs485_(rs485)
      , owned_pins_(owned_pins)
      , rx_ring_(rx_ring)
      , rx_ring_size_(rx_ring_size)
      , tx_ring_(tx_ring)
      , tx_ring_size_(tx_ring_size) {}

  ~UartResource() override {
    if (rs485_) gpio_put(rts_pin_, false);
    uart_deinit(uart_);
    free(rx_ring_);
    free(tx_ring_);
    release_pins();
    uart_controllers.put(uart_id());
  }

  uart_inst_t* uart() const { return uart_; }
  uint32_t baud_rate() const { return baud_rate_; }
  void set_baud_rate(uint32_t value) { baud_rate_ = value; }
  uint32_t errors() const { return errors_.load(std::memory_order_acquire); }

  void set_interrupts_enabled(bool enabled) override {
    uint irq = UART_IRQ_NUM(uart_);
    uart_hw_t* hardware = uart_get_hw(uart_);
    if (!enabled) {
      irq_set_enabled(irq, false);
      hardware->imsc = 0;
      hardware->icr = UART_UARTICR_BITS;
      return;
    }

    hardware->icr = UART_UARTICR_BITS;
    uint32_t masks = 0;
    if (rx_pin_ >= 0) {
      masks = UART_UARTIMSC_RXIM_BITS | UART_UARTIMSC_RTIM_BITS |
          kUartErrorInterruptBits;
      // Four bytes for RX and 28 free slots for TX. The low RX threshold and
      // timeout interrupt preserve short packets without polling.
      hw_write_masked(&hardware->ifls, 0,
                      UART_UARTIFLS_RXIFLSEL_BITS |
                      UART_UARTIFLS_TXIFLSEL_BITS);
    }
    hardware->imsc = masks;
    irq_set_enabled(irq, true);
  }

  void handle_interrupt_from_isr() override {
    uart_hw_t* hardware = uart_get_hw(uart_);
    uint32_t masked = hardware->mis;
    uint32_t state = 0;

    if (rx_pin_ >= 0 &&
        (masked & (UART_UARTMIS_RXMIS_BITS | UART_UARTMIS_RTMIS_BITS |
                   UART_UARTMIS_OEMIS_BITS | UART_UARTMIS_BEMIS_BITS |
                   UART_UARTMIS_PEMIS_BITS | UART_UARTMIS_FEMIS_BITS))) {
      uint32_t head = rx_head_.load(std::memory_order_relaxed);
      uint32_t tail = rx_tail_.load(std::memory_order_acquire);
      uint32_t dropped = 0;
      uint32_t hardware_errors = 0;
      bool received = false;
      bool saw_break = false;

      while (!(hardware->fr & UART_UARTFR_RXFE_BITS)) {
        uint32_t value = hardware->dr;
        uint32_t errors = value & kUartErrorBits;
        if (errors & UART_UARTDR_BE_BITS) {
          saw_break = true;
          if (errors & UART_UARTDR_OE_BITS) hardware_errors++;
          // A break is signalling rather than a received NUL byte.
          continue;
        }
        if (errors != 0) hardware_errors++;

        uint32_t next = head + 1;
        if (next == rx_ring_size_) next = 0;
        if (next == tail) {
          dropped++;
        } else {
          rx_ring_[head] = static_cast<uint8_t>(value);
          head = next;
          received = true;
        }
      }

      rx_head_.store(head, std::memory_order_release);
      if (received) state |= kRp2350UartReadState;
      if (saw_break) state |= kRp2350UartBreakState;
      if (dropped != 0 || hardware_errors != 0) {
        errors_.fetch_add(dropped + hardware_errors,
                          std::memory_order_relaxed);
        state |= kRp2350UartErrorState | kRp2350UartReadState;
      }
      // An overrun can remain latched even if no surviving FIFO entry carries
      // its OE bit. Count the interrupt once in that case.
      if ((masked & UART_UARTMIS_OEMIS_BITS) != 0 &&
          hardware_errors == 0) {
        errors_.fetch_add(1, std::memory_order_relaxed);
        state |= kRp2350UartErrorState | kRp2350UartReadState;
      }
      hardware->rsr = UART_UARTRSR_BITS;
    }

    if (masked & UART_UARTMIS_TXMIS_BITS) {
      uint32_t tail = tx_tail_.load(std::memory_order_relaxed);
      uint32_t head = tx_head_.load(std::memory_order_acquire);
      bool moved = false;
      while (tail != head && !(hardware->fr & UART_UARTFR_TXFF_BITS)) {
        hardware->dr = tx_ring_[tail];
        if (++tail == tx_ring_size_) tail = 0;
        moved = true;
      }
      tx_tail_.store(tail, std::memory_order_release);
      if (moved) state |= kRp2350UartWriteState;
      if (tail == head) {
        hw_clear_bits(&hardware->imsc, UART_UARTIMSC_TXIM_BITS);
        Rp2350UartEventSource::request_tx_poll_from_isr(uart_id());
        // Wake the event task so it starts checking the physical line-idle
        // state. This bit also wakes writers waiting for ring space.
        state |= kRp2350UartWriteState;
      }
    }

    hardware->icr = masked;
    Rp2350UartEventSource::notify_from_isr(uart_id(), state);
  }

  bool finish_transmit_if_idle() override {
    taskENTER_CRITICAL();
    bool idle = tx_empty() &&
        (uart_get_hw(uart_)->fr & UART_UARTFR_BUSY_BITS) == 0;
    if (idle && rs485_) gpio_put(rts_pin_, false);
    taskEXIT_CRITICAL();
    return idle;
  }

  int write(const uint8_t* data, int length) {
    uint32_t head = tx_head_.load(std::memory_order_relaxed);
    uint32_t tail = tx_tail_.load(std::memory_order_acquire);
    uint32_t used = head >= tail
        ? head - tail
        : tx_ring_size_ - tail + head;
    uint32_t free_space = tx_ring_size_ - 1 - used;
    uint32_t count = static_cast<uint32_t>(length);
    if (count > free_space) count = free_space;

    uint32_t first = tx_ring_size_ - head;
    if (first > count) first = count;
    memcpy(tx_ring_ + head, data, first);
    if (count > first) memcpy(tx_ring_, data + first, count - first);
    head += count;
    if (head >= tx_ring_size_) head -= tx_ring_size_;
    if (count != 0) {
      // Publishing the ring head, raising RS485 DE, and feeding the FIFO must
      // be atomic against the event task's final line-idle check. Otherwise a
      // new write could race with that task lowering DE for the prior write.
      taskENTER_CRITICAL();
      tx_head_.store(head, std::memory_order_release);
      if (rs485_) gpio_put(rts_pin_, true);
      Rp2350UartEventSource::cancel_tx_poll(uart_id());
      // A PL011 TX interrupt is threshold driven and need not fire merely
      // because it is enabled while the FIFO is already empty. Seed the FIFO
      // here, then let the IRQ refill it after it crosses the threshold.
      uart_hw_t* hardware = uart_get_hw(uart_);
      uint32_t tail = tx_tail_.load(std::memory_order_relaxed);
      head = tx_head_.load(std::memory_order_acquire);
      while (tail != head && !(hardware->fr & UART_UARTFR_TXFF_BITS)) {
        hardware->dr = tx_ring_[tail];
        if (++tail == tx_ring_size_) tail = 0;
      }
      tx_tail_.store(tail, std::memory_order_release);
      bool ring_empty = tail == head;
      if (ring_empty) {
        hw_clear_bits(&hardware->imsc, UART_UARTIMSC_TXIM_BITS);
      } else {
        hw_set_bits(&hardware->imsc, UART_UARTIMSC_TXIM_BITS);
      }
      taskEXIT_CRITICAL();
      if (ring_empty) {
        Rp2350UartEventSource::request_tx_poll(uart_id());
      }
    }
    return static_cast<int>(count);
  }

  ByteArray* read(Process* process, bool* allocation_failed) {
    *allocation_failed = false;
    uint32_t head = rx_head_.load(std::memory_order_acquire);
    uint32_t tail = rx_tail_.load(std::memory_order_relaxed);
    uint32_t available = head >= tail
        ? head - tail
        : rx_ring_size_ - tail + head;
    if (available == 0) return null;

    ByteArray* result = process->allocate_byte_array(available);
    if (result == null) {
      *allocation_failed = true;
      return null;
    }
    ByteArray::Bytes bytes(result);
    uint32_t first = rx_ring_size_ - tail;
    if (first > available) first = available;
    memcpy(bytes.address(), rx_ring_ + tail, first);
    if (available > first) {
      memcpy(bytes.address() + first, rx_ring_, available - first);
    }
    tail += available;
    if (tail >= rx_ring_size_) tail -= rx_ring_size_;
    rx_tail_.store(tail, std::memory_order_release);
    return result;
  }

  bool tx_empty() const {
    return tx_head_.load(std::memory_order_acquire) ==
        tx_tail_.load(std::memory_order_acquire);
  }

 private:
  void release_pins() {
    int pins[] = { tx_pin_, rx_pin_, rts_pin_, cts_pin_ };
    for (int pin : pins) {
      if (pin < 0) continue;
      uint64_t bit = uint64_t{1} << pin;
      if (owned_pins_ & bit) {
        gpio_pool_put(pin);
      } else {
        UNREACHABLE();
      }
    }
  }

  uart_inst_t* uart_;
  int tx_pin_;
  int rx_pin_;
  int rts_pin_;
  int cts_pin_;
  bool rs485_;
  uint64_t owned_pins_;
  uint8_t* rx_ring_;
  uint32_t rx_ring_size_;
  std::atomic<uint32_t> rx_head_{0};
  std::atomic<uint32_t> rx_tail_{0};
  uint8_t* tx_ring_;
  uint32_t tx_ring_size_;
  std::atomic<uint32_t> tx_head_{0};
  std::atomic<uint32_t> tx_tail_{0};
  std::atomic<uint32_t> errors_{0};
  uint32_t baud_rate_ = 0;
};

class UartResourceGroup : public ResourceGroup {
 public:
  TAG(UartResourceGroup);

  UartResourceGroup(Process* process, Rp2350UartEventSource* event_source)
      : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* resource, word data,
                    uint32_t state) override {
    USE(resource);
    return state | static_cast<uint32_t>(data);
  }
};

MODULE_IMPLEMENTATION(uart, MODULE_UART)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  Rp2350UartEventSource* event_source = Rp2350UartEventSource::instance();
  if (event_source == null) FAIL(ALREADY_CLOSED);
  UartResourceGroup* group = _new UartResourceGroup(process, event_source);
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(create) {
  ARGS(UartResourceGroup, group,
       int, encoded_tx, int, encoded_rx, int, encoded_rts, int, encoded_cts,
       int, baud_rate, int, data_bits, int, stop_bits, int, parity,
       int, tx_flags, int, mode);

  if (baud_rate <= 0 || baud_rate > 4000000) FAIL(INVALID_ARGUMENT);
  if (data_bits < 5 || data_bits > 8) FAIL(INVALID_ARGUMENT);
  if (stop_bits < 1 || stop_bits > 3) FAIL(INVALID_ARGUMENT);
  if (parity < 1 || parity > 3) FAIL(INVALID_ARGUMENT);
  if (stop_bits == 2) FAIL(UNIMPLEMENTED);  // PL011 has no 1.5-stop mode.
  if (mode == kModeIrda) FAIL(INVALID_ARGUMENT);
  if (mode != kModeUart && mode != kModeRs485HalfDuplex) {
    FAIL(INVALID_ARGUMENT);
  }

  int pins[4];
  int encoded[] = { encoded_tx, encoded_rx, encoded_rts, encoded_cts };
  for (int i = 0; i < 4; i++) {
    if (!decode_pin(encoded[i], &pins[i])) FAIL(INVALID_ARGUMENT);
    if (pins[i] >= 0 && !is_valid_pin(pins[i])) FAIL(INVALID_ARGUMENT);
    if (pins[i] >= 0 && is_restricted_pin(pins[i])) FAIL(PERMISSION_DENIED);
    for (int previous = 0; previous < i; previous++) {
      if (pins[i] >= 0 && pins[i] == pins[previous]) FAIL(INVALID_ARGUMENT);
    }
  }
  int tx = pins[0];
  int rx = pins[1];
  int rts = pins[2];
  int cts = pins[3];
  if (tx < 0 && rx < 0) FAIL(INVALID_ARGUMENT);
  bool rs485 = mode == kModeRs485HalfDuplex;
  if (rs485 && (tx < 0 || rts < 0 || cts >= 0)) FAIL(INVALID_ARGUMENT);

  UartPinMapping mappings[4];
  UartPinRole roles[] = {
    UART_PIN_TX, UART_PIN_RX, UART_PIN_RTS, UART_PIN_CTS,
  };
  int uart_id = -1;
  for (int i = 0; i < 4; i++) {
    if (pins[i] < 0) continue;
    // In RS485 mode RTS is an arbitrary GPIO used for driver enable, rather
    // than the PL011 flow-control signal.
    if (rs485 && roles[i] == UART_PIN_RTS) continue;
    if (!uart_pin_mapping(pins[i], roles[i], &mappings[i])) {
      FAIL(INVALID_ARGUMENT);
    }
    if (uart_id < 0) uart_id = mappings[i].uart_id;
    if (mappings[i].uart_id != uart_id) FAIL(INVALID_ARGUMENT);
  }
  ASSERT(uart_id >= 0);

  PinReservations reservations;
  for (int i = 0; i < 4; i++) {
    if (!reservations.take(pins[i])) FAIL(ALREADY_IN_USE);
  }
  if (!uart_controllers.take(uart_id)) FAIL(ALREADY_IN_USE);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) {
    uart_controllers.put(uart_id);
    FAIL(ALLOCATION_FAILED);
  }

  uint32_t rx_capacity =
      (tx_flags & kTxFlagLargeBuffers) != 0 ? 4096 : 768;
  uint32_t tx_capacity =
      (tx_flags & kTxFlagLargeBuffers) != 0 ? 4096 : 512;
  uint8_t* rx_ring = unvoid_cast<uint8_t*>(malloc(rx_capacity + 1));
  uint8_t* tx_ring = unvoid_cast<uint8_t*>(malloc(tx_capacity + 1));
  if (rx_ring == null || tx_ring == null) {
    free(rx_ring);
    free(tx_ring);
    uart_controllers.put(uart_id);
    FAIL(MALLOC_FAILED);
  }

  uint64_t owned_pins = reservations.keep();
  UartResource* resource = _new UartResource(
      group, uart_id, tx, rx, rts, cts, rs485, owned_pins,
      rx_ring, rx_capacity + 1, tx_ring, tx_capacity + 1);
  if (resource == null) {
    free(rx_ring);
    free(tx_ring);
    for (int pin = 0; owned_pins != 0; pin++, owned_pins >>= 1) {
      if (owned_pins & 1) gpio_pool_put(pin);
    }
    uart_controllers.put(uart_id);
    FAIL(MALLOC_FAILED);
  }

  for (int i = 0; i < 4; i++) {
    if (pins[i] < 0) continue;
    if (rs485 && roles[i] == UART_PIN_RTS) continue;
    if (roles[i] == UART_PIN_RX || roles[i] == UART_PIN_CTS) {
      gpio_pull_up(pins[i]);
    } else {
      gpio_disable_pulls(pins[i]);
    }
    gpio_set_function(pins[i], mappings[i].function);
  }
  if (rs485) {
    gpio_init(rts);
    gpio_put(rts, false);
    gpio_set_dir(rts, GPIO_OUT);
  }
  if ((tx_flags & kTxFlagInvertTx) != 0 && tx >= 0) {
    gpio_set_outover(tx, GPIO_OVERRIDE_INVERT);
  }
  if ((tx_flags & kTxFlagInvertRx) != 0 && rx >= 0) {
    gpio_set_inover(rx, GPIO_OVERRIDE_INVERT);
  }

  uart_inst_t* uart = resource->uart();
  uint32_t actual_baud = uart_init(uart, static_cast<uint>(baud_rate));
  uart_parity_t uart_parity = parity == 2
      ? UART_PARITY_EVEN
      : parity == 3 ? UART_PARITY_ODD : UART_PARITY_NONE;
  uart_set_format(uart, data_bits, stop_bits == 3 ? 2 : 1, uart_parity);
  uart_set_hw_flow(uart, cts >= 0, rts >= 0 && !rs485);
  resource->set_baud_rate(actual_baud);

  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(create_path) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(create_console) {
  FAIL(UNSUPPORTED);
}

PRIMITIVE(close) {
  ARGS(UartResourceGroup, group, UartResource, resource);
  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(get_baud_rate) {
  ARGS(UartResource, resource);
  return Primitive::integer(resource->baud_rate(), process);
}

PRIMITIVE(set_baud_rate) {
  ARGS(UartResource, resource, int, baud_rate);
  if (baud_rate <= 0 || baud_rate > 4000000) FAIL(INVALID_ARGUMENT);

  uart_inst_t* uart = resource->uart();
  uint irq = UART_IRQ_NUM(uart);
  uart_hw_t* hardware = uart_get_hw(uart);
  irq_set_enabled(irq, false);
  uint32_t interrupt_masks = hardware->imsc;
  hardware->imsc = 0;
  uint32_t actual = uart_set_baudrate(uart, static_cast<uint>(baud_rate));
  hardware->icr = UART_UARTICR_BITS;
  hardware->imsc = interrupt_masks;
  irq_set_enabled(irq, true);
  resource->set_baud_rate(actual);
  return process->null_object();
}

PRIMITIVE(write) {
  ARGS(UartResource, resource, Blob, data, int, from, int, to,
       int, break_length);
  if (from < 0 || to < from || to > data.length()) FAIL(OUT_OF_BOUNDS);
  if (break_length != 0) FAIL(UNIMPLEMENTED);

  int written = resource->write(data.address() + from, to - from);
  return Primitive::integer(written, process);
}

PRIMITIVE(read) {
  ARGS(UartResource, resource);
  bool allocation_failed;
  ByteArray* result = resource->read(process, &allocation_failed);
  if (allocation_failed) FAIL(ALLOCATION_FAILED);
  if (result == null) return process->null_object();
  return result;
}

PRIMITIVE(wait_tx) {
  ARGS(UartResource, resource);
  return BOOL(resource->finish_transmit_if_idle());
}

PRIMITIVE(set_control_flags) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(get_control_flags) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(errors) {
  ARGS(UartResource, resource);
  return Primitive::integer(resource->errors(), process);
}

}  // namespace toit

#endif  // TOIT_RP2350
