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

#ifdef TOIT_FREERTOS

#include "event_sources/system_esp32.h"
#include "uart_esp32_hal.h"
#include "driver/gpio.h"
#include "soc/uart_periph.h"
#include "hal/gpio_hal.h"
#include "esp_rom_gpio.h"
#include "driver/periph_ctrl.h"
#include "freertos/FreeRTOS.h"
#include "freertos/ringbuf.h"

#include "../objects_inline.h"
#include "../resource_pool.h"
#include "../event_sources/ev_queue_esp32.h"

#define UART_ISR_INLINE inline __attribute__((always_inline))

// Valid UART port numbers.
#define UART_NUM_0             (0) /*!< UART port 0 */
#define UART_NUM_1             (1) /*!< UART port 1 */
#if SOC_UART_NUM > 2
#define UART_NUM_2             (2) /*!< UART port 2 */
#endif
#define UART_NUM_MAX           (SOC_UART_NUM) /*!< UART port max */

#if CONFIG_IDF_TARGET_ESP32C3 || CONFIG_IDF_TARGET_ESP32S2
    #define UART_PORT UART_NUM_1
#else
    #define UART_PORT UART_NUM_2
#endif

namespace toit {

const uart_port_t kInvalidUartPort = static_cast<uart_port_t>(-1);

const int kReadState = 1 << 0;
const int kErrorState = 1 << 1;
const int kWriteState = 1 << 2;

ResourcePool<uart_port_t, kInvalidUartPort> uart_ports(
  // Uart 0 is reserved serial communication (stdout).
#if SOC_UART_NUM > 2
  UART_NUM_2,
#endif
  UART_NUM_1
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

class UartResource;

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
  std::atomic<uword> available_;

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

  UartResource(ResourceGroup* group, uart_port_t port, QueueHandle_t queue, uart_hal_handle_t hal,
               uint8* rx_buffer_data, uword rx_buffer_size, uint8* tx_buffer_data, uword tx_buffer_size)
      : EventQueueResource(group, queue), port_(port), hal_(hal)
      , rx_buffer_(rx_buffer_data, rx_buffer_size)
      , tx_buffer_(tx_buffer_data, tx_buffer_size) {
    set_state(kWriteState);
    spinlock_initialize(&spinlock_);
  }

  ~UartResource() override;

  uart_port_t port() const { return port_; }
  UART_ISR_INLINE RxBuffer* rx_buffer() { return &rx_buffer_; }
  UART_ISR_INLINE TxBuffer* tx_buffer() { return &tx_buffer_; }

  bool receive_event(word* data) override;

  // ...
  UART_ISR_INLINE void enable_read_interrupts();

  UART_ISR_INLINE void drain_tx_fifo();
  UART_ISR_INLINE void write_tx_break(int length) { uart_toit_hal_tx_break(hal_, length); }
  UART_ISR_INLINE uint32 write_tx_fifo(const uint8* data, uint32 length);

  // ---------------------------
  void set_interrupt_handle(intr_handle_t interrupt_handle) { interrupt_handle_ = interrupt_handle; }
  void set_source_clock(uart_sclk_t source_clock) { uart_toit_hal_set_sclk(hal_, source_clock); }
  void set_baud_rate(uint32 baud_rate) { uart_toit_hal_set_baudrate(hal_, baud_rate); }
  uint32 get_baud_rate();
  void uart_set_mode(uart_mode_t mode) { uart_toit_hal_set_mode(hal_, mode); }
  void set_parity(uart_parity_t parity) { uart_toit_hal_set_parity(hal_, parity); }
  void set_word_length(uart_word_length_t word_length) { uart_toit_hal_set_data_bit_num(hal_, word_length); }
  void set_stop_bits(uart_stop_bits_t stop_bits) { uart_toit_hal_set_stop_bits(hal_, stop_bits); }
  void set_transmit_idle_num(uint32 idle_num) { uart_toit_hal_set_tx_idle_num(hal_, idle_num); }

  void set_hardware_flow_control(uart_hw_flowcontrol_t hardware_flow_control, uint8 transmit_threshold) {
    uart_toit_hal_set_hw_flow_ctrl(hal_, hardware_flow_control, transmit_threshold);
  }

  void set_line_inverse(uint32 inverse_mask) { uart_toit_hal_inverse_signal(hal_, inverse_mask); }

  void set_tx_pin(gpio_num_t tx_pin);
  void set_rx_pin(gpio_num_t rx_pin);
  void set_rts_pin(gpio_num_t rts_pin);
  void set_cts_pin(gpio_num_t cts_pin);

  void set_read_fifo_full_interrupt_threshold(uint8 threshold) {
    uart_toit_hal_set_rxfifo_full_thr(hal_, threshold);
  }

  void set_write_fifo_empty_interrupt_threshold(uint8 threshold) {
    uart_toit_hal_set_txfifo_empty_thr(hal_, threshold);
  }

  void set_read_fifo_timeout(uint8 timeout) { uart_toit_hal_set_rx_timeout(hal_, timeout); }
  // ---------------------------


  UART_ISR_INLINE void enable_interrupt_index(uart_toit_interrupt_index_t index);
  UART_ISR_INLINE void disable_interrupt_index(uart_toit_interrupt_index_t index);

  UART_ISR_INLINE void handle_isr();

  // TODO(kasper): Used from the outside only during setup.
  void clear_data_event_in_queue();
  void clear_tx_event_in_queue();
  UART_ISR_INLINE void clear_tx_fifo() { uart_toit_hal_txfifo_rst(hal_); }
  UART_ISR_INLINE void clear_rx_fifo() { uart_toit_hal_rxfifo_rst(hal_); }
  UART_ISR_INLINE void clear_interrupt_index(uart_toit_interrupt_index_t index);

 private:
  UART_ISR_INLINE uint32 interrupt_mask(uart_toit_interrupt_index_t toit_interrupt_index) {
    return hal_->interrupt_mask[toit_interrupt_index];
  }

  UART_ISR_INLINE void disable_interrupt_mask(uint32 mask)  {
    uart_toit_hal_disable_intr_mask(hal_, mask);
  }

  UART_ISR_INLINE void enable_interrupt_mask(uint32 mask) {
    uart_toit_hal_ena_intr_mask(hal_, mask);
  }

  UART_ISR_INLINE void clear_interrupt_mask(uint32 mask) {
    uart_toit_hal_clr_intsts_mask(hal_, mask);
  }

  UART_ISR_INLINE uint32 get_tx_fifo_free() {
    return uart_toit_hal_get_txfifo_len(hal_);
  }

  UART_ISR_INLINE void disable_read_interrupts();

  UART_ISR_INLINE uart_event_types_t handle_write_isr();
  UART_ISR_INLINE uart_event_types_t handle_read_isr();
  UART_ISR_INLINE void send_event_to_queue_isr(uart_event_types_t event, int* hp_task_awoken);

  bool try_set_iomux_pin(gpio_num_t pin, uint32 iomux_index) const;

  uart_port_t port_;
  uart_hal_handle_t hal_;
  spinlock_t spinlock_{};
  RxBuffer rx_buffer_;
  TxBuffer tx_buffer_;
  intr_handle_t interrupt_handle_ = null;
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
  available_ -= length;
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
  available_ += length;
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
  uart->enable_interrupt_index(UART_TOIT_INTR_TXFIFO_EMPTY);
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
      available_ -= length;
      uart->write_tx_fifo(start, length);  // TODO: Is the RS485 workaround necessary here?
      transfer_header_.remaining_data_length = remaining_data_length - length;
      return length;
    }

    uint8 break_length = transfer_header_.break_length;
    if (break_length > 0) {
      uart->enable_interrupt_index(UART_TOIT_INTR_TX_BRK_DONE);
      uart->write_tx_break(break_length);
      uart->disable_interrupt_index(UART_TOIT_INTR_TXFIFO_EMPTY);
      transfer_header_.break_length = 0;
      return 0;
    }

    // No more data in the latest packet. Need to read header.
    if (available() < sizeof(TxTransferHeader)) {
      uart->disable_interrupt_index(UART_TOIT_INTR_TXFIFO_EMPTY);
      return 0;
    }
    read(locker, reinterpret_cast<uint8*>(&transfer_header_), sizeof(TxTransferHeader));
  }
}

void RxBuffer::read(UartResource* uart, uint8* buffer, uword length) {
  SpinLocker locker(&spinlock_);
  RxTxBuffer::read(locker, buffer, length);
  uart->enable_read_interrupts();
}

UART_ISR_INLINE void RxBuffer::write(const uint8* buffer, uword length) {
  SpinLocker locker(&spinlock_);
  RxTxBuffer::write(locker, buffer, length);
}

bool UartResource::receive_event(word* data) {
  return xQueueReceive(queue(), data, 0);
}

UartResource::~UartResource() {
  disable_interrupt_index(UART_TOIT_ALL_INTR_MASK);
  if (interrupt_handle_) esp_intr_free(interrupt_handle_);

  vQueueDelete(queue());

  drain_tx_fifo();
  clear_rx_fifo();

  uart_toit_hal_deinit(hal_);

  periph_module_disable(uart_periph_signal[port_].module);
}

uint32 UartResource::get_baud_rate() {
  uint32 baud_rate;
  uart_toit_hal_get_baudrate(hal_, &baud_rate);
  return baud_rate;
}

void UartResource::set_tx_pin(gpio_num_t tx_pin) {
  if (try_set_iomux_pin(tx_pin, SOC_UART_TX_PIN_IDX)) return;
  gpio_hal_iomux_func_sel(GPIO_PIN_MUX_REG[tx_pin], PIN_FUNC_GPIO);
  gpio_set_level(tx_pin, 1);
  esp_rom_gpio_connect_out_signal(tx_pin, UART_PERIPH_SIGNAL(port_, SOC_UART_TX_PIN_IDX), false, false);
}

void UartResource::set_rx_pin(gpio_num_t rx_pin) {
  if (try_set_iomux_pin(rx_pin, SOC_UART_RX_PIN_IDX)) return;
  gpio_hal_iomux_func_sel(GPIO_PIN_MUX_REG[rx_pin], PIN_FUNC_GPIO);
  gpio_set_pull_mode(rx_pin, GPIO_PULLUP_ONLY);
  gpio_set_direction(rx_pin, GPIO_MODE_INPUT);
  esp_rom_gpio_connect_in_signal(rx_pin, UART_PERIPH_SIGNAL(port_, SOC_UART_RX_PIN_IDX), false);
}

void UartResource::set_rts_pin(gpio_num_t rts_pin) {
  if (try_set_iomux_pin(rts_pin, SOC_UART_RTS_PIN_IDX)) return;
  gpio_hal_iomux_func_sel(GPIO_PIN_MUX_REG[rts_pin], PIN_FUNC_GPIO);
  gpio_set_direction(rts_pin, GPIO_MODE_OUTPUT);
  esp_rom_gpio_connect_out_signal(rts_pin, UART_PERIPH_SIGNAL(port_, SOC_UART_RTS_PIN_IDX), false, false);
}

void UartResource::set_cts_pin(gpio_num_t cts_pin) {
  if (try_set_iomux_pin(cts_pin, SOC_UART_CTS_PIN_IDX)) return;
  gpio_hal_iomux_func_sel(GPIO_PIN_MUX_REG[cts_pin], PIN_FUNC_GPIO);
  gpio_set_pull_mode(cts_pin, GPIO_PULLUP_ONLY);
  gpio_set_direction(cts_pin, GPIO_MODE_INPUT);
  esp_rom_gpio_connect_in_signal(cts_pin, UART_PERIPH_SIGNAL(port_, SOC_UART_CTS_PIN_IDX), false);
}

UART_ISR_INLINE void UartResource::enable_interrupt_index(uart_toit_interrupt_index_t index) {
  SpinLocker locker(&spinlock_);
  enable_interrupt_mask(interrupt_mask(index));
}

UART_ISR_INLINE void UartResource::disable_interrupt_index(uart_toit_interrupt_index_t index) {
  SpinLocker locker(&spinlock_);
  disable_interrupt_mask(interrupt_mask(index));
}

UART_ISR_INLINE void UartResource::disable_read_interrupts() {
  disable_interrupt_index(UART_TOIT_INTR_RXFIFO_FULL);
  disable_interrupt_index(UART_TOIT_INTR_RX_TIMEOUT);
}

UART_ISR_INLINE void UartResource::enable_read_interrupts() {
  enable_interrupt_index(UART_TOIT_INTR_RXFIFO_FULL);
  enable_interrupt_index(UART_TOIT_INTR_RX_TIMEOUT);
}

UART_ISR_INLINE uint32 UartResource::write_tx_fifo(const uint8* data, uint32 length) {
  uint32 written;
  uart_toit_hal_write_txfifo(hal_, data, length, &written);
  return written;
}

UART_ISR_INLINE void UartResource::drain_tx_fifo() {
  while (get_tx_fifo_free() < SOC_UART_FIFO_LEN) {
    // Busy wait for the tx fifo to become empty.
  }
}

UART_ISR_INLINE void UartResource::clear_interrupt_index(uart_toit_interrupt_index_t index) {
  uart_toit_hal_clr_intsts_mask(hal_, interrupt_mask(index));
}

// This method tries to set the pin via the direct IO MUX. Returns true upon success.
bool UartResource::try_set_iomux_pin(gpio_num_t pin, uint32 iomux_index) const {
  const uart_periph_sig_t* uart_pin = &uart_periph_signal[port_].pins[iomux_index];
  if (uart_pin->default_gpio == -1 || uart_pin->default_gpio != pin) return false;
  gpio_iomux_out(pin, uart_pin->iomux_func, false);
  if (uart_pin->input) gpio_iomux_in(pin, uart_pin->signal);
  return true;
}

UART_ISR_INLINE uart_event_types_t UartResource::handle_read_isr() {
  uword read_length = uart_toit_hal_get_rxfifo_len(hal_);
  if (read_length == 0) return UART_EVENT_MAX;

  uword rx_buffer_free = rx_buffer()->free();
  if (rx_buffer_free == 0) {
    disable_read_interrupts();
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
    enable_interrupt_index(UART_TOIT_INTR_TXFIFO_EMPTY);
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
  if (proxy == null) {
    ALLOCATION_FAILED;
  }
  UartResourceGroup* uart = _new UartResourceGroup(process, EventQueueEventSource::instance());
  if (!uart) MALLOC_FAILED;

  proxy->set_external_address(uart);
  return proxy;
}

class UartInitialization {
 public:
  ~UartInitialization() {
    if (keep) return;

    if (!uart_resource) {
      if (queue) vQueueDelete(queue);
      if (hal) uart_toit_hal_deinit(hal);
      if (rx_buffer) free(rx_buffer);
      if (tx_buffer) free(tx_buffer);
    } else {
      delete uart_resource;
    }

    if (hardware_initialized) {
      periph_module_disable(uart_periph_signal[port].module);
    }

    uart_ports.put(port);
  }

  QueueHandle_t queue = null;
  uart_hal_handle_t hal = null;
  bool hardware_initialized = false;
  UartResource* uart_resource = null;
  uart_port_t port = 0;
  uint8* rx_buffer = null;
  uint8* tx_buffer = null;
  bool keep = false;
};

static uart_port_t determine_preferred_port(int tx, int rx, int rts, int cts) {
  for (int uart = UART_NUM_0; uart < SOC_UART_NUM; uart++) {
    if ((tx == -1 || tx == uart_periph_signal[uart].pins[SOC_UART_TX_PIN_IDX].default_gpio) &&
        (rx == -1 || rx == uart_periph_signal[uart].pins[SOC_UART_RX_PIN_IDX].default_gpio) &&
        (rts == -1 || rts == uart_periph_signal[uart].pins[SOC_UART_RTS_PIN_IDX].default_gpio) &&
        (cts == -1 || cts == uart_periph_signal[uart].pins[SOC_UART_CTS_PIN_IDX].default_gpio))
      return uart;
  }
  return kInvalidUartPort;
}

IRAM_ATTR static void interrupt_handler(void* arg) {
  auto uart = unvoid_cast<UartResource*>(arg);
  uart->handle_isr();
}

PRIMITIVE(create) {
  ARGS(UartResourceGroup, group, int, tx, int, rx, int, rts, int, cts,
       int, baud_rate, int, data_bits, int, stop_bits, int, parity,
       int, options, int, mode)

  if (data_bits < 5 || data_bits > 8) INVALID_ARGUMENT;
  if (stop_bits < 1 || stop_bits > 3) INVALID_ARGUMENT;
  if (parity < 1 || parity > 3) INVALID_ARGUMENT;
  if (options < 0 || options > 15) INVALID_ARGUMENT;
  if (mode < UART_MODE_UART || mode > UART_MODE_IRDA) INVALID_ARGUMENT;
  if (mode == UART_MODE_RS485_HALF_DUPLEX && cts != -1) INVALID_ARGUMENT;
  if (baud_rate < 0 || baud_rate > SOC_UART_BITRATE_MAX) INVALID_ARGUMENT;
  if (tx >= 0 && !GPIO_IS_VALID_OUTPUT_GPIO(tx)) INVALID_ARGUMENT;
  if (rx >= 0 && !GPIO_IS_VALID_GPIO(rx)) INVALID_ARGUMENT;
  if (rts >= 0 && !GPIO_IS_VALID_OUTPUT_GPIO(rts)) INVALID_ARGUMENT;
  if (cts >= 0 && !GPIO_IS_VALID_GPIO(cts)) INVALID_ARGUMENT;

  uint8 full_interrupt_threshold;
  uint16 rx_buffer_size, tx_buffer_size;
  int interrupt_flags = ESP_INTR_FLAG_IRAM | ESP_INTR_FLAG_SHARED;
  if ((options & 8) != 0) {
    // High speed setting.
    interrupt_flags |= ESP_INTR_FLAG_LEVEL3;
    full_interrupt_threshold = 35;
    tx_buffer_size = 1024;
    rx_buffer_size = 2048;
  } else if ((options & 4) != 0) {
    // Medium speed setting.
    interrupt_flags |= ESP_INTR_FLAG_LEVEL2 | ESP_INTR_FLAG_LEVEL3;
    full_interrupt_threshold = 92;
    tx_buffer_size = 512;
    rx_buffer_size = 1536;
  } else {
    // Low speed setting.
    interrupt_flags |= ESP_INTR_FLAG_LEVEL1 | ESP_INTR_FLAG_LEVEL2 | ESP_INTR_FLAG_LEVEL3;
    full_interrupt_threshold = 105;
    tx_buffer_size = 256;
    rx_buffer_size = 768;
  }

  UartInitialization init;
  uart_port_t port = determine_preferred_port(tx, rx, rts, cts);

  port = uart_ports.preferred(port);
  if (port == kInvalidUartPort) OUT_OF_RANGE;
  init.port = port;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) {
    ALLOCATION_FAILED;
  }

  init.queue = xQueueCreate(UART_QUEUE_SIZE, sizeof(uart_event_types_t));
  if (!init.queue) {
    MALLOC_FAILED;
  }

  init.hal = uart_toit_hal_init(port);
  if (!init.hal) {
    MALLOC_FAILED;
  }

  init.rx_buffer = static_cast<uint8*>(malloc(rx_buffer_size));
  if (!init.rx_buffer) {
    MALLOC_FAILED;
  }

  init.tx_buffer = static_cast<uint8*>(malloc(tx_buffer_size));
  if (!init.tx_buffer) {
    MALLOC_FAILED;
  }

  init.uart_resource = _new UartResource(group, port, init.queue, init.hal,
                                         init.rx_buffer, rx_buffer_size,
                                         init.tx_buffer, tx_buffer_size);
  if (!init.uart_resource) {
    MALLOC_FAILED;
  }

  periph_module_enable(uart_periph_signal[port].module);
    // Workaround for ESP32C3: enable core reset
    // before enabling uart module clock
    // to prevent uart from outputting garbage value.
#if SOC_UART_REQUIRE_CORE_RESET
    uart_toit_hal_set_reset_core(init.hal, true);
    periph_module_reset(uart_periph_signal[port].module);
    uart_toit_hal_set_reset_core(init.hal, false);
#else
    periph_module_reset(uart_periph_signal[port].module);
#endif
  init.hardware_initialized = true;

  init.uart_resource->set_source_clock(UART_SCLK_APB);
  init.uart_resource->set_baud_rate(baud_rate);
  init.uart_resource->uart_set_mode(static_cast<uart_mode_t>(mode));

  uart_parity_t uart_parity;
  switch (parity) {
    case 2: uart_parity = UART_PARITY_EVEN; break;
    case 3: uart_parity = UART_PARITY_ODD; break;
    default: uart_parity = UART_PARITY_DISABLE;
  }
  init.uart_resource->set_parity(uart_parity);

  auto uart_data_bits = static_cast<uart_word_length_t>(data_bits - 5);
  init.uart_resource->set_word_length(uart_data_bits);

  uart_stop_bits_t uart_stop_bits;
  switch (stop_bits) {
    case 2: uart_stop_bits = UART_STOP_BITS_1_5; break;
    case 3: uart_stop_bits = UART_STOP_BITS_2; break;
    default: uart_stop_bits = UART_STOP_BITS_1;
  }
  init.uart_resource->set_stop_bits(uart_stop_bits);

  init.uart_resource->set_transmit_idle_num(0);

  int flow_ctrl = 0;
  if (mode == UART_MODE_UART) {
    if (rts != -1) flow_ctrl += UART_HW_FLOWCTRL_RTS;
    if (cts != -1) flow_ctrl += UART_HW_FLOWCTRL_CTS;
  }
  init.uart_resource->set_hardware_flow_control(static_cast<uart_hw_flowcontrol_t>(flow_ctrl), 122);

  if (tx >= 0) init.uart_resource->set_tx_pin(static_cast<gpio_num_t>(tx));
  if (rx >= 0) init.uart_resource->set_rx_pin(static_cast<gpio_num_t>(rx));
  if (rts >= 0) init.uart_resource->set_rts_pin(static_cast<gpio_num_t>(rts));
  if (cts >= 0) init.uart_resource->set_cts_pin(static_cast<gpio_num_t>(cts));

  int flags = 0;
  if ((options & 1) != 0) flags |= UART_SIGNAL_TXD_INV;
  if ((options & 2) != 0) flags |= UART_SIGNAL_RXD_INV;
  init.uart_resource->set_line_inverse(flags);

  init.uart_resource->set_read_fifo_full_interrupt_threshold(full_interrupt_threshold);
  init.uart_resource->set_write_fifo_empty_interrupt_threshold(10);
  init.uart_resource->set_read_fifo_timeout(10);

  init.uart_resource->disable_interrupt_index(UART_TOIT_ALL_INTR_MASK);
  init.uart_resource->clear_interrupt_index(UART_TOIT_ALL_INTR_MASK);

  init.uart_resource->clear_rx_fifo();
  init.uart_resource->clear_tx_fifo();

  struct {
    intr_handle_t intr_handle;
    uint8 irq;
    int interrupt_flags;
    void* uart_resource;
    esp_err_t err;
  } args = {
      .intr_handle = null,
      .irq = uart_periph_signal[port].irq,
      .interrupt_flags = interrupt_flags,
      .uart_resource = init.uart_resource,
      .err = ESP_OK
  };

  // Install the ISR on the SystemEventSource's main thread that runs on core 0,
  // to allocate the interrupts on core 0.
  SystemEventSource::instance()->run([&]() -> void {
    args.err = esp_intr_alloc(args.irq, args.interrupt_flags, interrupt_handler,
                              args.uart_resource, &args.intr_handle);

  });

  if (args.err != ESP_OK) {
    return Primitive::os_error(args.err, process);
  }

  init.keep = true;

  init.uart_resource->set_interrupt_handle(args.intr_handle);

  // Enable read interrupts.
  init.uart_resource->enable_read_interrupts();
  init.uart_resource->enable_interrupt_index(UART_TOIT_INTR_PARITY_ERR);
  init.uart_resource->enable_interrupt_index(UART_TOIT_INTR_RXFIFO_OVF);

  group->register_resource(init.uart_resource);

  proxy->set_external_address(init.uart_resource);

  return proxy;
}

PRIMITIVE(create_path) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(close) {
  ARGS(UartResourceGroup, uart, UartResource, res)
  uart->unregister_resource(res);
  res_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(get_baud_rate) {
  ARGS(UartResource, uart)
  return Primitive::integer(uart->get_baud_rate(), process);
}

PRIMITIVE(set_baud_rate) {
  ARGS(UartResource, uart, int, baud_rate)
  uart->set_baud_rate(baud_rate);
  return process->program()->null_object();
}

PRIMITIVE(write) {
  ARGS(UartResource, uart, Blob, data, int, from, int, to, int, break_length)

  if (from < 0 || from > to || to > data.length()) OUT_OF_RANGE;
  if (break_length < 0 || break_length >= 256) OUT_OF_RANGE;

  TxBuffer* buffer = uart->tx_buffer();
  uint16 written = buffer->write(uart, data.address() + from, to - from, break_length);
  return Smi::from(written);
}

PRIMITIVE(wait_tx) {
  ARGS(UartResource, uart)

  TxBuffer* buffer = uart->tx_buffer();
  if (buffer->is_empty()) return BOOL(false);
  uart->drain_tx_fifo();
  return BOOL(true);
}

PRIMITIVE(read) {
  ARGS(UartResource, uart)

  RxBuffer* buffer = uart->rx_buffer();
  uword available = buffer->available();
  if (available == 0) return process->program()->null_object();

  // TODO(kasper): It isn't obviously a good idea to just return
  // all the data in a potentially rather large external byte array.
  // For reads from TCP sockets, we chunk it up instead and prefer
  // to return multiple smaller byte arrays.
  ByteArray* data = process->allocate_byte_array(available);
  if (data == null) ALLOCATION_FAILED;

  ByteArray::Bytes rx(data);
  buffer->read(uart, rx.address(), available);
  return data;
}

PRIMITIVE(set_control_flags) {
  UNIMPLEMENTED_PRIMITIVE;
}

PRIMITIVE(get_control_flags) {
  UNIMPLEMENTED_PRIMITIVE;
}

} // namespace toit

#endif // TOIT_FREERTOS

