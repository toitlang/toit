// Copyright (C) 2018 Toitware ApS.
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

#ifdef TOIT_ESP32

#include <unistd.h>

#include "event_sources/system_esp32.h"
#include "uart_esp32_hal.h"
#include "driver/gpio.h"
#include "soc/uart_periph.h"
#include "hal/gpio_hal.h"
#include "esp_rom_gpio.h"
#include "esp_timer.h"
#include "driver/periph_ctrl.h"
#include "freertos/FreeRTOS.h"

#include "../objects_inline.h"
#include "../resource_pool.h"
#include "../event_sources/ev_queue_esp32.h"

#define UART_ISR_INLINE inline __attribute__((always_inline))

// Valid UART port numbers.
#define UART_NUM_0             (static_cast<uart_port_t>(0)) /*!< UART port 0 */
#define UART_NUM_1             (static_cast<uart_port_t>(1)) /*!< UART port 1 */
#if SOC_UART_NUM > 2
#define UART_NUM_2             (static_cast<uart_port_t>(2)) /*!< UART port 2 */
#endif
#if SOC_UART_NUM > 3
#error "SOC_UART_NUM > 3"
#endif
#define UART_NUM_MAX           (SOC_UART_NUM) /*!< UART port max */

static periph_module_t module_from_port(uart_port_t port) {
  switch (port) {
    case UART_NUM_0: return PERIPH_UART0_MODULE;
    case UART_NUM_1: return PERIPH_UART1_MODULE;
#if SOC_UART_NUM > 2
    case UART_NUM_2: return PERIPH_UART2_MODULE;
#endif
#if SOC_UART_NUM > 3
#error "SOC_UART_NUM > 3"
#endif
    case UART_NUM_MAX:
      UNREACHABLE();
  }
  FATAL("Invalid UART port: %d", port);
}

namespace toit {

class UartResource;
static void uart_interrupt_handler(void* arg);

const uart_port_t kInvalidUartPort = static_cast<uart_port_t>(-1);

const int kReadState = 1 << 0;
const int kErrorState = 1 << 1;
const int kWriteState = 1 << 2;

static ResourcePool<uart_port_t, kInvalidUartPort> uart_ports(
    // Uart 0 is reserved for serial communication (stdout).
    UART_NUM_1
#if SOC_UART_NUM > 2
  , UART_NUM_2
#endif
);

typedef enum {
  UART_BUFFER_FULL,
  UART_FIFO_OVF,
  UART_DATA,
  UART_BREAK,
  UART_TX_EVENT,
  UART_EVENT_MAX
} uart_event_types_t;

class SpinLocker {
 public:
  UART_ISR_INLINE explicit SpinLocker(spinlock_t* spinlock) : spinlock_(spinlock) { portENTER_CRITICAL(spinlock_); }
  UART_ISR_INLINE ~SpinLocker() { portEXIT_CRITICAL(spinlock_); }
  UART_ISR_INLINE spinlock_t* spinlock() const { return spinlock_; }
 private:
  spinlock_t* spinlock_;
};

class RxTxBuffer {
 public:
  RxTxBuffer(uint8* buffer, uword capacity)
      : buffer_(buffer)
      , capacity_(capacity)
      , cursor_(buffer) {
    spinlock_initialize(&spinlock_);
    available_ = 0;
  }

  ~RxTxBuffer() {
    ::free(buffer_);
  }

  UART_ISR_INLINE bool is_empty() const { return available() == 0; }
  UART_ISR_INLINE uword capacity() const { return capacity_; }
  UART_ISR_INLINE uword available() const { return available_; }
  UART_ISR_INLINE uword free() const { return capacity_ - available_; }

 protected:
  uint8* const buffer_;
  uword const capacity_;
  spinlock_t spinlock_{};

  // The cursor points to the next data in the buffer that
  // can be read. It must be read and written while holding
  // the lock to ensure consistency.
  uint8* cursor_;

  // There is a number of bytes available for reading after
  // the cursor. The bytes may be split in two across the end
  // of the buffer. The number of bytes can be read without
  // holding the lock, but it must be updated while holding
  // the lock.
  volatile uword available_;

  UART_ISR_INLINE void read(const SpinLocker& locker, uint8* buffer, uword length);
  UART_ISR_INLINE void write(const SpinLocker& locker, const uint8* buffer, uword length);
};

struct TxTransferHeader {
  uint16 remaining_data_length;
  uint8 break_length;
};

class TxBuffer : public RxTxBuffer {
 public:
  TxBuffer(uint8* buffer, uword capacity)
      : RxTxBuffer(buffer, capacity) {}

  uint16 write(UartResource* uart, const uint8* buffer, uint16 length, uint8 break_length);
  UART_ISR_INLINE uword read_to_fifo(UartResource* uart, uword max);

 private:
  TxTransferHeader transfer_header_{};
};

class RxBuffer : public RxTxBuffer {
 public:
  RxBuffer(uint8* buffer, uword capacity)
      : RxTxBuffer(buffer, capacity) {}

  void read(UartResource* uart, uint8* buffer, uword length);
  UART_ISR_INLINE void write(const uint8* buffer, uword length);
};

class UartResource : public EventQueueResource {
public:
  TAG(UartResource);

  UartResource(ResourceGroup* group, uart_port_t port, QueueHandle_t queue,
               uart_hal_handle_t hal, uart_mode_t mode,
               uint8* rx_buffer_data, uword rx_buffer_size, uint8* tx_buffer_data, uword tx_buffer_size)
      : EventQueueResource(group, queue), port_(port), hal_(hal), mode_(mode)
      , rx_buffer_(rx_buffer_data, rx_buffer_size)
      , tx_buffer_(tx_buffer_data, tx_buffer_size) {
    spinlock_initialize(&spinlock_);
  }

  ~UartResource() override;

  uart_port_t port() const { return port_; }
  uint32 baud_rate() const;
  void set_baud_rate(uint32 baud_rate) { uart_toit_hal_set_baudrate(hal_, baud_rate); }
  UART_ISR_INLINE RxBuffer* rx_buffer() { return &rx_buffer_; }
  UART_ISR_INLINE TxBuffer* tx_buffer() { return &tx_buffer_; }

  void initialize();
  void enable(intr_handle_t handle);

  bool receive_event(word* data) override;
  void clear_data_event_in_queue();
  void clear_tx_event_in_queue();

  UART_ISR_INLINE void enable_rx_interrupts();
  UART_ISR_INLINE void disable_rx_interrupts();

  UART_ISR_INLINE void enable_tx_interrupts(bool begin);
  UART_ISR_INLINE void disable_tx_interrupts(bool done);

  /// Whether the tx fifo is empty and the last byte has been emitted.
  UART_ISR_INLINE bool is_empty_tx_fifo();
  UART_ISR_INLINE bool drain_tx_fifo();
  UART_ISR_INLINE void write_tx_break(uint8 length);
  UART_ISR_INLINE uint32 write_tx_fifo(const uint8* data, uint32 length);

 private:
  UART_ISR_INLINE uint32 interrupt_mask(uart_toit_interrupt_index_t toit_interrupt_index) {
    return hal_->interrupt_mask[toit_interrupt_index];
  }

  UART_ISR_INLINE void enable_interrupt_index(uart_toit_interrupt_index_t index) {
    enable_interrupt_mask(interrupt_mask(index));
  }

  UART_ISR_INLINE void disable_interrupt_index(uart_toit_interrupt_index_t index) {
    disable_interrupt_mask(interrupt_mask(index));
  }

  UART_ISR_INLINE void clear_interrupt_index(uart_toit_interrupt_index_t index) {
    clear_interrupt_mask(interrupt_mask(index));
  }

  UART_ISR_INLINE void disable_interrupt_mask(uint32 mask)  {
    // Disabling interrupts reads and writes the mask, so we must
    // do this in a critical region to ensure consistency.
    SpinLocker locker(&spinlock_);
    uart_toit_hal_disable_intr_mask(hal_, mask);
  }

  UART_ISR_INLINE void enable_interrupt_mask(uint32 mask) {
    // Enabling interrupts reads and writes the mask, so we must
    // do this in a critical region to ensure consistency.
    SpinLocker locker(&spinlock_);
    uart_toit_hal_ena_intr_mask(hal_, mask);
  }

  UART_ISR_INLINE void clear_interrupt_mask(uint32 mask) {
    uart_toit_hal_clr_intsts_mask(hal_, mask);
  }

  UART_ISR_INLINE void clear_tx_fifo() {
    uart_toit_hal_txfifo_rst(hal_);
  }

  UART_ISR_INLINE void clear_rx_fifo() {
    uart_toit_hal_rxfifo_rst(hal_);
  }

  UART_ISR_INLINE uint32 get_tx_fifo_free() {
    return uart_toit_hal_get_txfifo_len(hal_);
  }

  UART_ISR_INLINE bool is_rs485_half_duplex_mode() const {
    return mode_ == UART_MODE_RS485_HALF_DUPLEX;
  }

  friend void uart_interrupt_handler(void* arg);
  UART_ISR_INLINE void handle_isr();
  UART_ISR_INLINE uart_event_types_t handle_write_isr();
  UART_ISR_INLINE uart_event_types_t handle_read_isr();
  UART_ISR_INLINE void send_event_to_queue_isr(uart_event_types_t event, int* hp_task_awoken);

  const uart_port_t port_;
  const uart_hal_handle_t hal_;
  const uart_mode_t mode_;
  spinlock_t spinlock_{};
  RxBuffer rx_buffer_;
  TxBuffer tx_buffer_;
  intr_handle_t interrupt_handle_ = null;
  bool rts_active_ = false;
  bool data_event_in_queue_ = false;
  bool tx_event_in_queue_ = false;
};

class UartResourceGroup : public ResourceGroup {
 public:
  TAG(UartResourceGroup);
  UartResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source){}

  void on_unregister_resource(Resource* r) override {
    auto uart_res = reinterpret_cast<UartResource*>(r);
    uart_ports.put(uart_res->port());
  }

  uint32 on_event(Resource* r, word data, uint32 state) override;
};

UART_ISR_INLINE void RxTxBuffer::read(const SpinLocker& locker, uint8* data, uword length) {
  ASSERT(locker.spinlock() == &spinlock_);
  ASSERT(length <= available());
  uint8* start = cursor_;
  uint8* buffer = buffer_;
  uint8* end = start + length;
  uint8* limit = buffer + capacity();
  word overflow = end - limit;
  if (overflow < 0) {
    memcpy(data, start, length);
    cursor_ = end;
  } else {
    uword head = length - overflow;
    memcpy(data, start, head);
    memcpy(data + head, buffer, overflow);
    cursor_ = buffer + overflow;
  }
  // Composite assignments are not allowed on volatile variables.
  available_ = available_ - length;
}

UART_ISR_INLINE void RxTxBuffer::write(const SpinLocker& locker, const uint8* data, uword length) {
  ASSERT(locker.spinlock() == &spinlock_);
  ASSERT(length <= free());
  uint8* start = cursor_ + available();
  uint8* buffer = buffer_;
  uint8* limit = buffer + capacity();
  if (start >= limit) start -= capacity();
  word overflow = start + length - limit;
  if (overflow <= 0) {
    memcpy(start, data, length);
  } else {
    uword head = length - overflow;
    memcpy(start, data, head);
    memcpy(buffer, data + head, overflow);
  }
  // Composite assignments are not allowed on volatile variables.
  available_ = available_ + length;
}

uint16 TxBuffer::write(UartResource* uart, const uint8* buffer, uint16 length, uint8 break_length) {
  SpinLocker locker(&spinlock_);

  word overflow = sizeof(TxTransferHeader) + length - free();
  if (overflow > 0) {
    if (overflow > length) return 0;  // Cannot even write header.
    length -= overflow;
    break_length = 0;
  }

  if (length == 0 && break_length == 0) {
    // We can write the header, but it will be completely
    // skipped by read_to_fifo, so we'd rather not.
    return 0;
  }

  TxTransferHeader header = {
    .remaining_data_length = length,
    .break_length = break_length
  };

  RxTxBuffer::write(locker, reinterpret_cast<uint8*>(&header), sizeof(TxTransferHeader));
  RxTxBuffer::write(locker, buffer, length);

  // Interrupts are disabled while we're in the critical section
  // holding the spinlock, so they will not fire before we leave
  // the critical section at the end of this function.
  uart->enable_tx_interrupts(true);
  return length;
}

UART_ISR_INLINE uword TxBuffer::read_to_fifo(UartResource* uart, uword max) {
  SpinLocker locker(&spinlock_);
  while (true) {
    uword remaining_data_length = transfer_header_.remaining_data_length;
    if (remaining_data_length > 0) {
      uword length = Utils::min(max, remaining_data_length);
      ASSERT(length <= available());
      uint8* start = cursor_;
      uint8* buffer = buffer_;
      uint8* end = start + length;
      uint8* limit = buffer + capacity();
      if (end < limit) {
        cursor_ = end;
      } else {
        length = limit - start;
        cursor_ = buffer;
      }
      // Composite assignments are not allowed on volatile variables.
      available_ = available_ - length;
      uart->write_tx_fifo(start, length);
      transfer_header_.remaining_data_length = remaining_data_length - length;
      return length;
    }

    uint8 break_length = transfer_header_.break_length;
    if (break_length > 0) {
      uart->write_tx_break(break_length);
      transfer_header_.break_length = 0;
      return 0;
    }

    // No more data in the latest packet. Need to read header.
    if (available() < sizeof(TxTransferHeader)) {
      uart->disable_tx_interrupts(true);
      return 0;
    }
    read(locker, reinterpret_cast<uint8*>(&transfer_header_), sizeof(TxTransferHeader));
  }
}

void RxBuffer::read(UartResource* uart, uint8* buffer, uword length) {
  SpinLocker locker(&spinlock_);
  RxTxBuffer::read(locker, buffer, length);
  uart->enable_rx_interrupts();
}

UART_ISR_INLINE void RxBuffer::write(const uint8* buffer, uword length) {
  SpinLocker locker(&spinlock_);
  RxTxBuffer::write(locker, buffer, length);
}

void UartResource::initialize() {
  disable_interrupt_index(UART_TOIT_ALL_INTR_MASK);
  clear_interrupt_index(UART_TOIT_ALL_INTR_MASK);
  clear_rx_fifo();
  clear_tx_fifo();
}

void UartResource::enable(intr_handle_t handle) {
  ASSERT(interrupt_handle_ == null);
  interrupt_handle_ = handle;
  enable_rx_interrupts();
  enable_interrupt_index(UART_TOIT_INTR_PARITY_ERR);
  enable_interrupt_index(UART_TOIT_INTR_RXFIFO_OVF);
  set_state(kWriteState);
}

UartResource::~UartResource() {
  disable_interrupt_index(UART_TOIT_ALL_INTR_MASK);
  if (interrupt_handle_) esp_intr_free(interrupt_handle_);

  vQueueDelete(queue());

  drain_tx_fifo();
  clear_rx_fifo();

  uart_toit_hal_deinit(hal_);

  periph_module_disable(module_from_port(port_));
}

uint32 UartResource::baud_rate() const {
  uint32 baud_rate;
  uart_toit_hal_get_baudrate(hal_, &baud_rate);
  return baud_rate;
}

UART_ISR_INLINE void UartResource::enable_rx_interrupts() {
  enable_interrupt_index(UART_TOIT_INTR_RXFIFO_FULL);
  enable_interrupt_index(UART_TOIT_INTR_RX_TIMEOUT);
}

UART_ISR_INLINE void UartResource::disable_rx_interrupts() {
  disable_interrupt_index(UART_TOIT_INTR_RXFIFO_FULL);
  disable_interrupt_index(UART_TOIT_INTR_RX_TIMEOUT);
}

UART_ISR_INLINE void UartResource::enable_tx_interrupts(bool begin) {
  enable_interrupt_index(UART_TOIT_INTR_TXFIFO_EMPTY);
  if (begin && is_rs485_half_duplex_mode()) {
    if (rts_active_) {
      // The RTS is already active, so we avoid de-activating
      // it until we've processed the new additional bytes
      // in the TX buffer. We achieve this by disabling the
      // TX_DONE interrupt. Once we're done with the bytes
      // in the TX buffer, the interrupt will get re-enabled
      // from TxBuffer::read_to_fifo() through a call to
      // disable_tx_interrupts(done = true).
      disable_interrupt_index(UART_TOIT_INTR_TX_DONE);
      clear_interrupt_index(UART_TOIT_INTR_TX_DONE);
    } else {
      // Set the RTS to active.
      uart_toit_hal_set_rts(hal_, true);
      rts_active_ = true;
    }
  }
}

UART_ISR_INLINE void UartResource::disable_tx_interrupts(bool done) {
  disable_interrupt_index(UART_TOIT_INTR_TXFIFO_EMPTY);
  if (done && rts_active_) {
    enable_interrupt_index(UART_TOIT_INTR_TX_DONE);
  }
}

UART_ISR_INLINE bool UartResource::is_empty_tx_fifo() {
  // Once the fifo is empty, one last byte is still being transmitted.
  // The check for is_tx_idle is necessary to ensure that this last byte is
  // completely transmitted.
  return get_tx_fifo_free() == SOC_UART_FIFO_LEN && uart_toit_hal_is_tx_idle(hal_);
}

UART_ISR_INLINE bool UartResource::drain_tx_fifo() {
  if (is_empty_tx_fifo()) return true;
  int64 start = esp_timer_get_time();
  while (!is_empty_tx_fifo()) {
    int64 now = esp_timer_get_time();
    if (now - start > 1000) return false;  // One ms.
  }
  return true;
}

UART_ISR_INLINE void UartResource::write_tx_break(uint8 length) {
  enable_interrupt_index(UART_TOIT_INTR_TX_BRK_DONE);
  uart_toit_hal_tx_break(hal_, length);
  disable_tx_interrupts(false);
}

UART_ISR_INLINE uint32 UartResource::write_tx_fifo(const uint8* data, uint32 length) {
  uint32 written;
  uart_toit_hal_write_txfifo(hal_, data, length, &written);
  return written;
}

UART_ISR_INLINE uart_event_types_t UartResource::handle_read_isr() {
  uword read_length = uart_toit_hal_get_rxfifo_len(hal_);
  if (read_length == 0) return UART_EVENT_MAX;

  uword rx_buffer_free = rx_buffer()->free();
  if (rx_buffer_free == 0) {
    disable_rx_interrupts();
    return UART_BUFFER_FULL;
  } else {
    if (rx_buffer_free < read_length) read_length = rx_buffer_free;
    ASSERT(read_length <= SOC_UART_FIFO_LEN)
    uint8 buffer[read_length];
    uart_toit_hal_read_rxfifo(hal_, buffer, reinterpret_cast<int*>(&read_length));
    rx_buffer()->write(buffer, read_length);
    return UART_DATA;
  }
}

UART_ISR_INLINE uart_event_types_t UartResource::handle_write_isr() {
  uint32 fifo_free = get_tx_fifo_free();
  uword consumed = tx_buffer()->read_to_fifo(this, fifo_free);
  return (consumed > 0) ? UART_TX_EVENT : UART_EVENT_MAX;
}

UART_ISR_INLINE void UartResource::handle_isr() {
  uint32 status = uart_toit_hal_get_intsts_mask(hal_);
  if (status == 0) return;

  uart_event_types_t event = UART_EVENT_MAX;
  if (status & interrupt_mask(UART_TOIT_INTR_TXFIFO_EMPTY)) {
    clear_interrupt_index(UART_TOIT_INTR_TXFIFO_EMPTY);
    event = handle_write_isr();
  } else if (status & interrupt_mask(UART_TOIT_INTR_TX_BRK_DONE)) {
    disable_interrupt_index(UART_TOIT_INTR_TX_BRK_DONE);
    clear_interrupt_index(UART_TOIT_INTR_TX_BRK_DONE);
    enable_tx_interrupts(false);
  } else if (status & interrupt_mask(UART_TOIT_INTR_TX_DONE)) {
    if (rts_active_) {
      // If the transmit is still active, we can't de-activate
      // the RTS just yet. Just postpone interrupt processing
      // for next TX_DONE interrupt which we leave enabled.
      if (!uart_toit_hal_is_tx_idle(hal_)) return;
      clear_rx_fifo();
      uart_toit_hal_set_rts(hal_, false);
      rts_active_ = false;
    }
    disable_interrupt_index(UART_TOIT_INTR_TX_DONE);
    clear_interrupt_index(UART_TOIT_INTR_TX_DONE);
  } else if (status & (interrupt_mask(UART_TOIT_INTR_RXFIFO_FULL) | interrupt_mask(UART_TOIT_INTR_RX_TIMEOUT))) {
    if (status & interrupt_mask(UART_TOIT_INTR_RXFIFO_FULL)) {
      clear_interrupt_index(UART_TOIT_INTR_RXFIFO_FULL);
    } else {
      clear_interrupt_index(UART_TOIT_INTR_RX_TIMEOUT);
    }
    event = handle_read_isr();
  } else if (status & interrupt_mask(UART_TOIT_INTR_RXFIFO_OVF)) {
    clear_interrupt_index(UART_TOIT_INTR_RXFIFO_OVF);
    clear_rx_fifo();
    event = UART_FIFO_OVF;
  } else {
    clear_interrupt_mask(status);
  }

  if (event != UART_EVENT_MAX) {
    portBASE_TYPE hp_task_awoken = 0;
    send_event_to_queue_isr(event, &hp_task_awoken);
    if (hp_task_awoken) portYIELD_FROM_ISR();
  }
}

bool UartResource::receive_event(word* data) {
  return xQueueReceive(queue(), data, 0);
}

UART_ISR_INLINE void UartResource::send_event_to_queue_isr(uart_event_types_t event, int* hp_task_awoken) {
  SpinLocker locker(&spinlock_);
  // Data and Tx Event receive special care, so as to not overflow the queue.
  if (event == UART_DATA) {
    if (data_event_in_queue_) return;
    data_event_in_queue_ = true;
  }

  if (event == UART_TX_EVENT) {
    if (tx_event_in_queue_) return;
    tx_event_in_queue_ = true;
  }

  if (xQueueSendToBackFromISR(queue(), &event, hp_task_awoken) != pdTRUE) {
    esp_rom_printf("[uart] warning: event queue is full\n");
  }
}

void UartResource::clear_data_event_in_queue() {
  SpinLocker locker(&spinlock_);
  data_event_in_queue_ = false;
}

void UartResource::clear_tx_event_in_queue() {
  SpinLocker locker(&spinlock_);
  tx_event_in_queue_ = false;
}

uint32 UartResourceGroup::on_event(Resource* r, word data, uint32 state) {
  switch (data) {
    case UART_DATA:
      state |= kReadState;
      reinterpret_cast<UartResource*>(r)->clear_data_event_in_queue();
      break;

    case UART_BREAK:
      // Ignore.
      break;

    case UART_TX_EVENT:
      state |= kWriteState;
      reinterpret_cast<UartResource*>(r)->clear_tx_event_in_queue();
      break;

    default:
      state |= kErrorState;
      break;
  }

  return state;
}

MODULE_IMPLEMENTATION(uart, MODULE_UART)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  UartResourceGroup* uart = _new UartResourceGroup(process, EventQueueEventSource::instance());
  if (!uart) FAIL(MALLOC_FAILED);

  proxy->set_external_address(uart);
  return proxy;
}

class UartInitialization {
 public:
  ~UartInitialization() {
    if (keep) return;

    if (!uart) {
      if (queue) vQueueDelete(queue);
      if (hal) uart_toit_hal_deinit(hal);
      if (rx_buffer) free(rx_buffer);
      if (tx_buffer) free(tx_buffer);
    } else {
      delete uart;
    }

    if (hardware_initialized) {
      periph_module_disable(module_from_port(port));
    }

    uart_ports.put(port);
  }

  void set_tx_pin(gpio_num_t tx_pin);
  void set_rx_pin(gpio_num_t rx_pin);
  void set_rts_pin(gpio_num_t rts_pin);
  void set_cts_pin(gpio_num_t cts_pin);

  QueueHandle_t queue = null;
  uart_hal_handle_t hal = null;
  bool hardware_initialized = false;
  UartResource* uart = null;
  uart_port_t port = UART_NUM_0;
  uint8* rx_buffer = null;
  uint8* tx_buffer = null;
  bool keep = false;

 private:
  bool try_set_iomux_pin(gpio_num_t pin, uint32 iomux_index) const;
};

void UartInitialization::set_tx_pin(gpio_num_t tx_pin) {
  if (try_set_iomux_pin(tx_pin, SOC_UART_TX_PIN_IDX)) return;
  gpio_hal_iomux_func_sel(GPIO_PIN_MUX_REG[tx_pin], PIN_FUNC_GPIO);
  gpio_set_level(tx_pin, 1);
  esp_rom_gpio_connect_out_signal(tx_pin, UART_PERIPH_SIGNAL(port, SOC_UART_TX_PIN_IDX), false, false);
}

void UartInitialization::set_rx_pin(gpio_num_t rx_pin) {
  if (try_set_iomux_pin(rx_pin, SOC_UART_RX_PIN_IDX)) return;
  gpio_hal_iomux_func_sel(GPIO_PIN_MUX_REG[rx_pin], PIN_FUNC_GPIO);
  gpio_set_pull_mode(rx_pin, GPIO_PULLUP_ONLY);
  gpio_set_direction(rx_pin, GPIO_MODE_INPUT);
  esp_rom_gpio_connect_in_signal(rx_pin, UART_PERIPH_SIGNAL(port, SOC_UART_RX_PIN_IDX), false);
}

void UartInitialization::set_rts_pin(gpio_num_t rts_pin) {
  if (try_set_iomux_pin(rts_pin, SOC_UART_RTS_PIN_IDX)) return;
  gpio_hal_iomux_func_sel(GPIO_PIN_MUX_REG[rts_pin], PIN_FUNC_GPIO);
  gpio_set_direction(rts_pin, GPIO_MODE_OUTPUT);
  esp_rom_gpio_connect_out_signal(rts_pin, UART_PERIPH_SIGNAL(port, SOC_UART_RTS_PIN_IDX), false, false);
}

void UartInitialization::set_cts_pin(gpio_num_t cts_pin) {
  if (try_set_iomux_pin(cts_pin, SOC_UART_CTS_PIN_IDX)) return;
  gpio_hal_iomux_func_sel(GPIO_PIN_MUX_REG[cts_pin], PIN_FUNC_GPIO);
  gpio_set_pull_mode(cts_pin, GPIO_PULLUP_ONLY);
  gpio_set_direction(cts_pin, GPIO_MODE_INPUT);
  esp_rom_gpio_connect_in_signal(cts_pin, UART_PERIPH_SIGNAL(port, SOC_UART_CTS_PIN_IDX), false);
}

// This method tries to set the pin via the direct IO MUX. Returns true upon success.
bool UartInitialization::try_set_iomux_pin(gpio_num_t pin, uint32 iomux_index) const {
  const uart_periph_sig_t* uart_pin = &uart_periph_signal[port].pins[iomux_index];
  if (uart_pin->default_gpio == -1 || uart_pin->default_gpio != pin) return false;
  gpio_iomux_out(pin, uart_pin->iomux_func, false);
  if (uart_pin->input) gpio_iomux_in(pin, uart_pin->signal);
  return true;
}

static uart_port_t determine_preferred_port(int tx, int rx, int rts, int cts) {
  for (int uart = UART_NUM_0; uart < SOC_UART_NUM; uart++) {
    if ((tx == -1 || tx == uart_periph_signal[uart].pins[SOC_UART_TX_PIN_IDX].default_gpio) &&
        (rx == -1 || rx == uart_periph_signal[uart].pins[SOC_UART_RX_PIN_IDX].default_gpio) &&
        (rts == -1 || rts == uart_periph_signal[uart].pins[SOC_UART_RTS_PIN_IDX].default_gpio) &&
        (cts == -1 || cts == uart_periph_signal[uart].pins[SOC_UART_CTS_PIN_IDX].default_gpio)) {
      return static_cast<uart_port_t>(uart);
    }
  }
  return kInvalidUartPort;
}

IRAM_ATTR static void uart_interrupt_handler(void* arg) {
  auto uart = unvoid_cast<UartResource*>(arg);
  uart->handle_isr();
}

PRIMITIVE(create) {
  ARGS(UartResourceGroup, group, int, tx, int, rx, int, rts, int, cts,
       int, baud_rate, int, data_bits, int, stop_bits, int, parity,
       int, options, int, mode)

  if (data_bits < 5 || data_bits > 8) FAIL(INVALID_ARGUMENT);
  if (stop_bits < 1 || stop_bits > 3) FAIL(INVALID_ARGUMENT);
  if (parity < 1 || parity > 3) FAIL(INVALID_ARGUMENT);
  if (options < 0 || options > 31) FAIL(INVALID_ARGUMENT);
  if (mode < UART_MODE_UART || mode > UART_MODE_IRDA) FAIL(INVALID_ARGUMENT);
  if (mode == UART_MODE_RS485_HALF_DUPLEX && (rts == -1 || cts != -1)) FAIL(INVALID_ARGUMENT);
  if (baud_rate < 0 || baud_rate > SOC_UART_BITRATE_MAX) FAIL(INVALID_ARGUMENT);
  if (tx >= 0 && !GPIO_IS_VALID_OUTPUT_GPIO(tx)) FAIL(INVALID_ARGUMENT);
  if (rx >= 0 && !GPIO_IS_VALID_GPIO(rx)) FAIL(INVALID_ARGUMENT);
  if (rts >= 0 && !GPIO_IS_VALID_OUTPUT_GPIO(rts)) FAIL(INVALID_ARGUMENT);
  if (cts >= 0 && !GPIO_IS_VALID_GPIO(cts)) FAIL(INVALID_ARGUMENT);

  uint8 full_interrupt_threshold;
  uint16 rx_buffer_size, tx_buffer_size;
  int interrupt_flags = ESP_INTR_FLAG_IRAM | ESP_INTR_FLAG_SHARED;
#ifdef CONFIG_IDF_TARGET_ESP32C3
  // Level 3 interrupts hang the C3 for some reason.
  static const int HI  = ESP_INTR_FLAG_LEVEL2;
  static const int MED = ESP_INTR_FLAG_LEVEL2;
  static const int LO  = ESP_INTR_FLAG_LEVEL2 | ESP_INTR_FLAG_LEVEL1;
#else
  static const int HI  = ESP_INTR_FLAG_LEVEL3;
  static const int MED = ESP_INTR_FLAG_LEVEL3 | ESP_INTR_FLAG_LEVEL2;
  static const int LO  = ESP_INTR_FLAG_LEVEL3 | ESP_INTR_FLAG_LEVEL2 | ESP_INTR_FLAG_LEVEL1;
#endif
  if ((options & 8) != 0) {
    // High speed setting.
    interrupt_flags |= HI;
    full_interrupt_threshold = 35;
    tx_buffer_size = 2048;
    rx_buffer_size = 2048;
  } else if ((options & 4) != 0) {
    // Medium speed setting.
    interrupt_flags |= MED;
    full_interrupt_threshold = 92;
    tx_buffer_size = 512;
    rx_buffer_size = 1536;
  } else {
    // Low speed setting.
    interrupt_flags |= LO;
    full_interrupt_threshold = 105;
    tx_buffer_size = 256;
    rx_buffer_size = 768;
  }
  if ((options & 16) != 0) {
    tx_buffer_size *= 2;
    rx_buffer_size *= 2;
  }

  UartInitialization init;
  uart_port_t port = determine_preferred_port(tx, rx, rts, cts);

  port = uart_ports.preferred(port);
  if (port == kInvalidUartPort) FAIL(ALREADY_IN_USE);
  init.port = port;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  init.queue = xQueueCreate(UART_QUEUE_SIZE, sizeof(uart_event_types_t));
  if (!init.queue) {
    FAIL(MALLOC_FAILED);
  }

  init.hal = uart_toit_hal_init(port);
  if (!init.hal) {
    FAIL(MALLOC_FAILED);
  }

  const int caps_flags = MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT;
  init.rx_buffer = static_cast<uint8*>(heap_caps_malloc(rx_buffer_size, caps_flags));
  if (!init.rx_buffer) {
    FAIL(MALLOC_FAILED);
  }

  init.tx_buffer = static_cast<uint8*>(heap_caps_malloc(tx_buffer_size, caps_flags));
  if (!init.tx_buffer) {
    FAIL(MALLOC_FAILED);
  }

  init.uart = _new UartResource(group, port, init.queue,
                                init.hal, static_cast<uart_mode_t>(mode),
                                init.rx_buffer, rx_buffer_size,
                                init.tx_buffer, tx_buffer_size);
  if (!init.uart) {
    FAIL(MALLOC_FAILED);
  }

  periph_module_enable(module_from_port(port));

  // Workaround for ESP32C3: enable core reset
  // before enabling uart module clock
  // to prevent uart from outputting garbage value.
#if SOC_UART_REQUIRE_CORE_RESET
  uart_toit_hal_set_reset_core(init.hal, true);
  periph_module_reset(module_from_port(port));
  uart_toit_hal_set_reset_core(init.hal, false);
#else
  periph_module_reset(module_from_port(port));
#endif
  init.hardware_initialized = true;

  uart_toit_hal_set_sclk(init.hal, UART_SCLK_APB);
  init.uart->set_baud_rate(baud_rate);
  uart_toit_hal_set_mode(init.hal, static_cast<uart_mode_t>(mode));

  uart_parity_t uart_parity;
  switch (parity) {
    case 2: uart_parity = UART_PARITY_EVEN; break;
    case 3: uart_parity = UART_PARITY_ODD; break;
    default: uart_parity = UART_PARITY_DISABLE;
  }
  uart_toit_hal_set_parity(init.hal, uart_parity);

  auto uart_data_bits = static_cast<uart_word_length_t>(data_bits - 5);
  uart_toit_hal_set_data_bit_num(init.hal, uart_data_bits);

  uart_stop_bits_t uart_stop_bits;
  switch (stop_bits) {
    case 2: uart_stop_bits = UART_STOP_BITS_1_5; break;
    case 3: uart_stop_bits = UART_STOP_BITS_2; break;
    default: uart_stop_bits = UART_STOP_BITS_1;
  }
  uart_toit_hal_set_stop_bits(init.hal, uart_stop_bits);
  uart_toit_hal_set_tx_idle_num(init.hal, 0);

  int flow_ctrl = 0;
  if (mode == UART_MODE_UART) {
    if (rts != -1) flow_ctrl += UART_HW_FLOWCTRL_RTS;
    if (cts != -1) flow_ctrl += UART_HW_FLOWCTRL_CTS;
  }
  uart_toit_hal_set_hw_flow_ctrl(init.hal, static_cast<uart_hw_flowcontrol_t>(flow_ctrl), 122);

  if (tx >= 0) init.set_tx_pin(static_cast<gpio_num_t>(tx));
  if (rx >= 0) init.set_rx_pin(static_cast<gpio_num_t>(rx));
  if (rts >= 0) init.set_rts_pin(static_cast<gpio_num_t>(rts));
  if (cts >= 0) init.set_cts_pin(static_cast<gpio_num_t>(cts));

  int flags = 0;
  if ((options & 1) != 0) flags |= UART_SIGNAL_TXD_INV;
  if ((options & 2) != 0) flags |= UART_SIGNAL_RXD_INV;
  uart_toit_hal_inverse_signal(init.hal, flags);

  uart_toit_hal_set_rxfifo_full_thr(init.hal, full_interrupt_threshold);
  uart_toit_hal_set_txfifo_empty_thr(init.hal, 10);
  uart_toit_hal_set_rx_timeout(init.hal, 10);

  if (GPIO_IS_VALID_GPIO(rx)) {
    // On some chips (specifically the S3) we have received up to a byte of
    // 1-bits when the UART is enabled.
    // To avoid this, we wait for the time of one byte at the baud rate, and
    // then clear the RX FIFO.
    // The stop-bits value is too large for STOP-BITS-1_5 and STOP-BITS-2, but
    // waiting longer is OK.
    int wait_us = 1 + (1000000 * (data_bits + stop_bits) - 1) / baud_rate;
    usleep(wait_us);
  }

  init.uart->initialize();

  struct {
    intr_handle_t intr_handle;
    uint8 irq;
    int interrupt_flags;
    void* uart;
    esp_err_t err;
  } args = {
      .intr_handle = null,
      .irq = uart_periph_signal[port].irq,
      .interrupt_flags = interrupt_flags,
      .uart = init.uart,
      .err = ESP_OK
  };

  // Install the ISR on the SystemEventSource's main thread that runs on core 0,
  // to allocate the interrupts on core 0.
  SystemEventSource::instance()->run([&]() -> void {
    args.err = esp_intr_alloc(args.irq,
                              args.interrupt_flags,
                              uart_interrupt_handler,
                              args.uart,
                              &args.intr_handle);
  });

  if (args.err != ESP_OK) {
    return Primitive::os_error(args.err, process);
  }

  init.keep = true;
  group->register_resource(init.uart);
  init.uart->enable(args.intr_handle);

  proxy->set_external_address(init.uart);
  return proxy;
}

PRIMITIVE(create_path) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(close) {
  ARGS(UartResourceGroup, uart, UartResource, res)
  uart->unregister_resource(res);
  res_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(get_baud_rate) {
  ARGS(UartResource, uart)
  return Primitive::integer(uart->baud_rate(), process);
}

PRIMITIVE(set_baud_rate) {
  ARGS(UartResource, uart, int, baud_rate)
  uart->set_baud_rate(baud_rate);
  return process->null_object();
}

PRIMITIVE(write) {
  ARGS(UartResource, uart, Blob, data, int, from, int, to, int, break_length)

  if (from < 0 || from > to || to > data.length()) FAIL(OUT_OF_RANGE);
  if (break_length < 0 || break_length >= 256) FAIL(OUT_OF_RANGE);

  TxBuffer* buffer = uart->tx_buffer();
  uint16 written = buffer->write(uart, data.address() + from, to - from, break_length);
  return Smi::from(written);
}

PRIMITIVE(wait_tx) {
  ARGS(UartResource, uart)

  TxBuffer* buffer = uart->tx_buffer();
  if (!buffer->is_empty()) return BOOL(false);
  return BOOL(uart->drain_tx_fifo());
}

PRIMITIVE(read) {
  ARGS(UartResource, uart)

  RxBuffer* buffer = uart->rx_buffer();
  uword available = buffer->available();
  if (available == 0) return process->null_object();

  // For high-speed UART communication, it is important
  // that we consume as much as we can when we read.
  // This immediately gives the ISR more available space
  // in the RX buffer.
  ByteArray* data = process->allocate_byte_array(available);
  if (data == null) FAIL(ALLOCATION_FAILED);

  ByteArray::Bytes rx(data);
  buffer->read(uart, rx.address(), available);
  return data;
}

PRIMITIVE(set_control_flags) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(get_control_flags) {
  FAIL(UNIMPLEMENTED);
}

} // namespace toit

#endif // TOIT_ESP32
