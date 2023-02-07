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

#define UART_ISR_INLINE  inline __attribute__((always_inline))

// Valid UART port number
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

#define EVENT_QUEUE_SIZE 32

namespace toit {

const uart_port_t kInvalidUartPort = uart_port_t(-1);

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
  explicit SpinLocker(portMUX_TYPE* spinlock): spinlock_(spinlock) { portENTER_CRITICAL(spinlock_); }
  ~SpinLocker() { portEXIT_CRITICAL(spinlock_); }
 private:
  portMUX_TYPE* spinlock_;
};

class IsrSpinLocker {
 public:
  UART_ISR_INLINE explicit IsrSpinLocker(portMUX_TYPE* spinlock): spinlock_(spinlock) {
    portENTER_CRITICAL_ISR(spinlock_);
  }
  UART_ISR_INLINE ~IsrSpinLocker() { portEXIT_CRITICAL_ISR(spinlock_); }
 private:
  portMUX_TYPE* spinlock_;
};

// No boundary check and un-synchronized ringbuffer. Assumption is that all modifying
// operations has the boundaries checked outside the ring buffer. Limited to 64k size.
class UartRingBuffer {
 public:
  UartRingBuffer(uint8_t* buffer, uint16_t capacity)
      : capacity_(capacity)
      , head_index_(0)
      , used_(0)
      , buffer_(buffer) {}

   inline bool is_empty() const { return used_ == 0; }
   inline bool is_full() const { return used_ == capacity_; }
   inline size_t free_space() const { return capacity_ - used_; }
   inline size_t used_space() const { return used_; }
   // This might return less than the requested_read_size in case the buffer is at the boundary
   uint8_t* read(uint16_t *read_size, uint16_t request_read_size);
   void write(const uint8_t* buffer, uint16_t size);

 private:
  uint16_t capacity_;
  uint16_t head_index_; // Where we currently write
  uint16_t used_; // The number of bytes stored currently
  uint8_t* buffer_;
};

class UartResource;

// Possible optimization: Create a RxTxBuffer that implements the ringbuffer directly. The esp-idf ringbuffer has
// a notable overhead due to features that are not required in this context.
class RxTxBuffer {
 public:
  RxTxBuffer(UartResource* uart, uint8_t* ring_buffer_data, size_t ring_buffer_size)
      : uart_(uart)
      , ring_buffer_data_(ring_buffer_data)
      , ring_buffer_size_(ring_buffer_size) {
    ring_buffer_ = xRingbufferCreateStatic(ring_buffer_size, RINGBUF_TYPE_BYTEBUF,
                                           ring_buffer_data_, &ring_buffer_static_);
  }

  virtual ~RxTxBuffer() {
    free(ring_buffer_data_);
  }

  UART_ISR_INLINE bool is_empty() { return xRingbufferGetCurFreeSize(ring_buffer_) == ring_buffer_size_; }
  size_t available_size() { return ring_buffer_size_ - xRingbufferGetCurFreeSize(ring_buffer_); }
  inline RingbufHandle_t& ring_buffer() { return ring_buffer_; }
  void return_buffer(uint8_t* buffer);
  inline UartResource* uart() { return uart_; }

 private:
  UartResource* uart_;
  RingbufHandle_t ring_buffer_;
  uint8_t* ring_buffer_data_;
  size_t ring_buffer_size_;
  StaticRingbuffer_t ring_buffer_static_{};
};

struct TxTransferHeader {
  uint8_t break_length_;
  uint16_t remaining_data_length_;
};

class TxBuffer : public RxTxBuffer {
 public:
  TxBuffer(UartResource* uart, uint8_t* ring_buffer_data, size_t ring_buffer_size)
      : RxTxBuffer(uart, ring_buffer_data, ring_buffer_size) {}

  uint8_t* read(size_t *received, size_t max_length);
  uint8_t read_break();
  size_t free_size();
  void write(const uint8_t* buffer, uint16_t length, uint8_t break_length);

 private:
  portMUX_TYPE spinlock_{};
  TxTransferHeader transfer_header_{};
};

class RxBuffer : public RxTxBuffer {
 public:
  RxBuffer(UartResource* uart, uint8_t* ring_buffer_data, size_t ring_buffer_size)
      : RxTxBuffer(uart, ring_buffer_data, ring_buffer_size) {}

  size_t UART_ISR_INLINE free_count() { return xRingbufferGetCurFreeSize(ring_buffer()); }
  void UART_ISR_INLINE send(uint8_t* buffer, uint32_t length);
  void read(uint8_t *buffer, uint32_t length);;
};

class UartResource : public EventQueueResource {
public:
  TAG(UartResource);

  UartResource(ResourceGroup* group, uart_port_t port, QueueHandle_t queue, uart_hal_handle_t hal,
               uint8_t* rx_buffer_data, size_t rx_buffer_size, uint8_t* tx_buffer_data, size_t tx_buffer_size)
      : EventQueueResource(group, queue), port_(port), hal_(hal)
      , rx_buffer_(this, rx_buffer_data, rx_buffer_size)
      , tx_buffer_(this, tx_buffer_data, tx_buffer_size) {
    set_state(kWriteState);
  }

  ~UartResource() override;

  uart_port_t port() const { return port_; }
  RxBuffer& rx_buffer() { return rx_buffer_; }
  TxBuffer& tx_buffer() { return tx_buffer_; }

  bool receive_event(word* data) override;

  void set_source_clock(uart_sclk_t source_clock) { uart_toit_hal_set_sclk(hal_, source_clock); }
  void set_baud_rate(uint32_t baud_rate) { uart_toit_hal_set_baudrate(hal_, baud_rate); }
  uint32_t get_baud_rate();
  void uart_set_mode(uart_mode_t mode) { uart_toit_hal_set_mode(hal_, mode); }
  void set_parity(uart_parity_t parity) { uart_toit_hal_set_parity(hal_, parity); }
  void set_word_length(uart_word_length_t word_length) { uart_toit_hal_set_data_bit_num(hal_, word_length); }
  void set_stop_bits(uart_stop_bits_t stop_bits) { uart_toit_hal_set_stop_bits(hal_, stop_bits); }
  void set_transmit_idle_num(uint32_t idle_num) { uart_toit_hal_set_tx_idle_num(hal_, idle_num); }

  void set_hardware_flow_control(uart_hw_flowcontrol_t hardware_flow_control, uint8_t transmit_threshold) {
    uart_toit_hal_set_hw_flow_ctrl(hal_, hardware_flow_control, transmit_threshold);
  }

  void set_line_inverse(uint32_t inverse_mask) { uart_toit_hal_inverse_signal(hal_, inverse_mask); }

  void set_tx_pin(gpio_num_t tx_pin);
  void set_rx_pin(gpio_num_t rx_pin);
  void set_rts_pin(gpio_num_t rts_pin);
  void set_cts_pin(gpio_num_t cts_pin);

  void set_read_fifo_full_interrupt_threshold(uint8_t threshold) {
    uart_toit_hal_set_rxfifo_full_thr(hal_, threshold);
  }

  void set_write_fifo_empty_interrupt_threshold(uint8_t threshold) {
    uart_toit_hal_set_txfifo_empty_thr(hal_, threshold);
  }

  void set_read_fifo_timeout(uint8_t timeout) { uart_toit_hal_set_rx_timeout(hal_, timeout); }
  void clear_rx_fifo() { uart_toit_hal_rxfifo_rst(hal_); }

  void clear_interrupt_index(uart_toit_interrupt_index_t index);
  void clear_interrupt_mask(uint32_t mask);
  void enable_interrupt_index(uart_toit_interrupt_index_t index);
  void disable_interrupt_index(uart_toit_interrupt_index_t index);
  void UART_ISR_INLINE enable_interrupt_index_isr(uart_toit_interrupt_index_t index);
  void UART_ISR_INLINE disable_interrupt_index_isr(uart_toit_interrupt_index_t index);

  void enable_read_interrupts();
  void disable_read_interrupts();
  size_t UART_ISR_INLINE get_tx_fifo_available_count();
  uint32_t UART_ISR_INLINE interrupt_mask(uart_toit_interrupt_index_t toit_interrupt_index) {
    return hal_->interrupt_mask[toit_interrupt_index];
  }
  void set_interrupt_handle(intr_handle_t interrupt_handle) { interrupt_handle_ = interrupt_handle; }
  static void interrupt_handler(void *arg);
  uart_event_types_t interrupt_handler_write();
  uart_event_types_t interrupt_handler_read();

 private:
  void UART_ISR_INLINE disable_interrupt_mask_(uint32_t mask)  {
    uart_toit_hal_disable_intr_mask(hal_, mask);
  }
  void UART_ISR_INLINE enable_interrupt_mask_(uint32_t mask) {
    uart_toit_hal_ena_intr_mask(hal_, mask);
  }
  bool try_set_iomux_pin(gpio_num_t pin, uint32_t iomux_index) const;
  uart_port_t port_;
  uart_hal_handle_t hal_;
  portMUX_TYPE spinlock_{};
  RxBuffer rx_buffer_;
  TxBuffer tx_buffer_;
  intr_handle_t interrupt_handle_ = null;
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

  uint32_t on_event(Resource* r, word data, uint32_t state) override;
};

IRAM_ATTR uint8_t* UartRingBuffer::read(uint16_t* read_size, uint16_t request_read_size) {
  uint8_t* result = buffer_ + head_index_;
  if (head_index_ + request_read_size >= capacity_) {
    *read_size = capacity_-head_index_;
    head_index_ = 0;
  } else {
    *read_size = request_read_size;
    head_index_ += request_read_size;
  }
  used_ -= *read_size;
  return result;
}

IRAM_ATTR void UartRingBuffer::write(const uint8_t* buffer, uint16_t size) {
  uint16_t tail = (head_index_ + used_) % capacity_;
  uint16_t first_read_size = size;
  if (first_read_size > capacity_ - tail) first_read_size = capacity_ - tail;
  memcpy(buffer_ + tail, buffer, first_read_size);
  if (first_read_size != size) {
    memcpy(buffer_, buffer + first_read_size, size - first_read_size);
  }
  used_ += size;
  tail = (tail + size) & capacity_;
}

UART_ISR_INLINE void RxTxBuffer::return_buffer(uint8_t* buffer) {
  BaseType_t ignored;
  // No blocking calls ever on TxBuffer, so ignore last parameter
  vRingbufferReturnItemFromISR(ring_buffer(), buffer, &ignored);
}

void TxBuffer::write(const uint8_t* buffer, uint16_t length, uint8_t break_length) {
  SpinLocker locker(&spinlock_);
  TxTransferHeader header = {
      .break_length_ = static_cast<uint8_t>(break_length),
      .remaining_data_length_ = static_cast<uint16_t>(length)
  };
  if (xRingbufferSend(ring_buffer(), &header, sizeof(TxTransferHeader), 0) == pdFALSE) {
    abort();
  }

  if (xRingbufferSend(ring_buffer(), buffer, length, 0) == pdFALSE) {
    abort();
  }

  uart()->enable_interrupt_index(UART_TOIT_INTR_TXFIFO_EMPTY);
}

UART_ISR_INLINE uint8_t TxBuffer::read_break() {
  IsrSpinLocker locker(&spinlock_);
  uint8_t break_length = transfer_header_.break_length_;
  transfer_header_.break_length_ = 0; // To avoid it being read again and the break continuing...
  return break_length;
}

UART_ISR_INLINE uint8_t* TxBuffer::read(size_t *received, size_t max_length) {
  IsrSpinLocker locker(&spinlock_);
  BaseType_t ignored;
  if (transfer_header_.remaining_data_length_ == 0 && transfer_header_.break_length_ == 0) {
    // No more data in the latest package. Need to read header
    size_t header_received;
    size_t read = 0;
    do { // As the header is multiple bytes, it could be split over the edge of the ring buffer
      void* header_data = xRingbufferReceiveUpToFromISR(ring_buffer(), &header_received, sizeof(TxTransferHeader) - read);
      if (!header_data) {
        // TxBuffer is empty
        return null;
      }
      memcpy(reinterpret_cast<uint8_t*>(&transfer_header_) + read, header_data, header_received);
      // No blocking calls ever on TxBuffer, so ignore last parameter
      vRingbufferReturnItemFromISR(ring_buffer(), header_data, &ignored);
      read += header_received;
    } while (read < sizeof(TxTransferHeader));
  }

  size_t maximum_to_receive = max_length;
  if (transfer_header_.remaining_data_length_ < maximum_to_receive) maximum_to_receive = transfer_header_.remaining_data_length_;

  if (maximum_to_receive == 0) {
    return null;
  }

  auto buffer = static_cast<uint8_t*>(xRingbufferReceiveUpToFromISR(ring_buffer(), received, maximum_to_receive));
  transfer_header_.remaining_data_length_ -= *received;
  return buffer;
}

size_t TxBuffer::free_size() {
  size_t ringbuffer_free = xRingbufferGetCurFreeSize(ring_buffer());
  if (ringbuffer_free < sizeof(TxTransferHeader)) return 0;
  return ringbuffer_free - sizeof(TxTransferHeader);
}

void UART_ISR_INLINE RxBuffer::send(uint8_t* buffer, uint32_t length) {
  BaseType_t ignored; // We are never blocking on the ring buffer
  xRingbufferSendFromISR(ring_buffer(), buffer, length, &ignored);
}

void RxBuffer::read(uint8_t* buffer, uint32_t length) {
  size_t received;
  size_t read = 0;
  do {
    auto from_ring_buffer = static_cast<uint8_t*>(xRingbufferReceiveUpTo(ring_buffer(), &received, 0, length - read));
    memcpy(buffer + read, from_ring_buffer, received);
    return_buffer(from_ring_buffer);
    read += received;
  } while (read < length);
  uart()->enable_read_interrupts();
}

bool UartResource::receive_event(word* data) {
  return xQueueReceive(queue(), data, 0);
}

UartResource::~UartResource() {
  disable_interrupt_index(UART_TOIT_ALL_INTR_MASK);
  if (interrupt_handle_) esp_intr_free(interrupt_handle_);

  vQueueDelete(queue());

  // Empty tx buffer.
  uint32_t len;
  do {
    len = uart_toit_hal_get_txfifo_len(hal_);
  } while (len < SOC_UART_FIFO_LEN);

  uart_toit_hal_deinit(hal_);

  periph_module_disable(uart_periph_signal[port_].module);
}

uint32_t UartResource::get_baud_rate() {
  uint32_t baud_rate;
  uart_toit_hal_get_baudrate(hal_, &baud_rate);
  return baud_rate;
}

void UartResource::set_tx_pin(gpio_num_t tx_pin) {
  if (!try_set_iomux_pin(tx_pin, SOC_UART_TX_PIN_IDX)) {
    gpio_hal_iomux_func_sel(GPIO_PIN_MUX_REG[tx_pin], PIN_FUNC_GPIO);
    gpio_set_level(tx_pin, 1);
    esp_rom_gpio_connect_out_signal(tx_pin, UART_PERIPH_SIGNAL(port_, SOC_UART_TX_PIN_IDX), false, false);
  }
}

void UartResource::set_rx_pin(gpio_num_t rx_pin) {
  if (!try_set_iomux_pin(rx_pin, SOC_UART_RX_PIN_IDX)) {
    gpio_hal_iomux_func_sel(GPIO_PIN_MUX_REG[rx_pin], PIN_FUNC_GPIO);
    gpio_set_pull_mode(rx_pin, GPIO_PULLUP_ONLY);
    gpio_set_direction(rx_pin, GPIO_MODE_INPUT);
    esp_rom_gpio_connect_in_signal(rx_pin, UART_PERIPH_SIGNAL(port_, SOC_UART_RX_PIN_IDX), false);
  }
}

void UartResource::set_rts_pin(gpio_num_t rts_pin) {
  if (!try_set_iomux_pin(rts_pin, SOC_UART_RTS_PIN_IDX)) {
    gpio_hal_iomux_func_sel(GPIO_PIN_MUX_REG[rts_pin], PIN_FUNC_GPIO);
    gpio_set_direction(rts_pin, GPIO_MODE_OUTPUT);
    esp_rom_gpio_connect_out_signal(rts_pin, UART_PERIPH_SIGNAL(port_, SOC_UART_RTS_PIN_IDX), false, false);
  }
}

void UartResource::set_cts_pin(gpio_num_t cts_pin) {
  if (!try_set_iomux_pin(cts_pin, SOC_UART_CTS_PIN_IDX)) {
    gpio_hal_iomux_func_sel(GPIO_PIN_MUX_REG[cts_pin], PIN_FUNC_GPIO);
    gpio_set_pull_mode(cts_pin, GPIO_PULLUP_ONLY);
    gpio_set_direction(cts_pin, GPIO_MODE_INPUT);
    esp_rom_gpio_connect_in_signal(cts_pin, UART_PERIPH_SIGNAL(port_, SOC_UART_CTS_PIN_IDX), false);
  }
}

UART_ISR_INLINE void UartResource::enable_interrupt_index_isr(uart_toit_interrupt_index_t index) {
  IsrSpinLocker locker(&spinlock_);
  enable_interrupt_mask_(interrupt_mask(index));
}

void UartResource::enable_interrupt_index(uart_toit_interrupt_index_t index) {
  SpinLocker locker(&spinlock_);
  enable_interrupt_mask_(interrupt_mask(index));
}

UART_ISR_INLINE void UartResource::disable_interrupt_index_isr(uart_toit_interrupt_index_t index) {
  IsrSpinLocker locker(&spinlock_);
  disable_interrupt_mask_(interrupt_mask(index));
}

UART_ISR_INLINE void UartResource::disable_read_interrupts() {
  disable_interrupt_index_isr(UART_TOIT_INTR_RXFIFO_FULL);
  disable_interrupt_index_isr(UART_TOIT_INTR_RX_TIMEOUT);
}

void UartResource::enable_read_interrupts() {
  enable_interrupt_index(UART_TOIT_INTR_RXFIFO_FULL);
  enable_interrupt_index(UART_TOIT_INTR_RX_TIMEOUT);
}

void UartResource::disable_interrupt_index(uart_toit_interrupt_index_t index) {
  SpinLocker locker(&spinlock_);
  disable_interrupt_mask_(interrupt_mask(index));
}

void UartResource::clear_interrupt_index(uart_toit_interrupt_index_t index) {
  uart_toit_hal_clr_intsts_mask(hal_, interrupt_mask(index));
}

void UartResource::clear_interrupt_mask(uint32_t mask) {
  uart_toit_hal_clr_intsts_mask(hal_, mask);
}

bool UartResource::try_set_iomux_pin(gpio_num_t pin, uint32_t iomux_index) const {
  const uart_periph_sig_t *uart_pin = &uart_periph_signal[port_].pins[iomux_index];
  if (uart_pin->default_gpio == -1 || uart_pin->default_gpio != pin) return false;
  gpio_iomux_out(pin, uart_pin->iomux_func, false);
  if (uart_pin->input) gpio_iomux_in(pin, uart_pin->signal);
  return true;
}

size_t UART_ISR_INLINE UartResource::get_tx_fifo_available_count() {
  return uart_toit_hal_get_txfifo_len(hal_);
}

UART_ISR_INLINE uart_event_types_t UartResource::interrupt_handler_read() {
  size_t read_length = uart_toit_hal_get_rxfifo_len(hal_);
  if (read_length == 0) return UART_EVENT_MAX;

  size_t rx_buffer_free = rx_buffer_.free_count();
  if (rx_buffer_free == 0) {
    disable_read_interrupts();
    return UART_BUFFER_FULL;
  } else {
    if (rx_buffer_free < read_length) read_length = rx_buffer_free;
    uint8_t buffer[read_length];
    uart_toit_hal_read_rxfifo(hal_, buffer, reinterpret_cast<int*>(&read_length));

    rx_buffer().send(buffer, read_length);
    return UART_DATA;
  }
}

UART_ISR_INLINE uart_event_types_t UartResource::interrupt_handler_write() {
  uint32_t tx_fifo_free = get_tx_fifo_available_count();
  size_t received_count;
  uint8_t* buffer = tx_buffer().read(&received_count, tx_fifo_free);
  if (buffer) {
    uint32_t written;
    uart_toit_hal_write_txfifo(hal_, buffer, received_count, &written); // TODO: Is the RS485 workaround necessary here?
    tx_buffer().return_buffer(buffer);
    return UART_TX_EVENT;
  } else {
    int break_number = tx_buffer().read_break();
    if (break_number != 0) {
      uart_toit_hal_tx_break(hal_, break_number);
      enable_interrupt_index_isr(UART_TOIT_INTR_TX_BRK_DONE);
      disable_interrupt_index_isr(UART_TOIT_INTR_TXFIFO_EMPTY);
    } else if (tx_buffer().is_empty()) {
      disable_interrupt_index_isr(UART_TOIT_INTR_TXFIFO_EMPTY);
    }
    return UART_EVENT_MAX;
  }
}

IRAM_ATTR void UartResource::interrupt_handler(void* arg) {
  auto uart = unvoid_cast<UartResource*>(arg);
  uint32_t uart_interrupt_status = uart_toit_hal_get_intsts_mask(uart->hal_);
  if (uart_interrupt_status == 0) return;
  uart_event_types_t event = UART_EVENT_MAX;

  if (uart_interrupt_status & uart->interrupt_mask(UART_TOIT_INTR_TXFIFO_EMPTY)) {
    uart->clear_interrupt_index(UART_TOIT_INTR_TXFIFO_EMPTY);
    event = uart->interrupt_handler_write();
  } else if (uart_interrupt_status & uart->interrupt_mask(UART_TOIT_INTR_TX_BRK_DONE)) {
    uart->disable_interrupt_index_isr(UART_TOIT_INTR_TX_BRK_DONE);
    uart->enable_interrupt_index_isr(UART_TOIT_INTR_TXFIFO_EMPTY);
  } else if (uart_interrupt_status &
      (uart->interrupt_mask(UART_TOIT_INTR_RXFIFO_FULL) |
       uart->interrupt_mask(UART_TOIT_INTR_RX_TIMEOUT)))  {
    if (uart_interrupt_status & uart->interrupt_mask(UART_TOIT_INTR_RXFIFO_FULL))
      uart->clear_interrupt_index(UART_TOIT_INTR_RXFIFO_FULL);
    else
      uart->clear_interrupt_index(UART_TOIT_INTR_RX_TIMEOUT);
    event = uart->interrupt_handler_read();
  } else if (uart_interrupt_status & uart->interrupt_mask(UART_TOIT_INTR_RXFIFO_OVF)) {
    uart->clear_interrupt_index(UART_TOIT_INTR_RXFIFO_OVF);
    uart->disable_read_interrupts();
    event = UART_FIFO_OVF;
  } else {
    uart->clear_interrupt_mask(uart_interrupt_status);
  }

  if (event != UART_EVENT_MAX) {
    portBASE_TYPE hp_task_awoken = 0;
    xQueueSendToBackFromISR(uart->queue(), &event, &hp_task_awoken);
    if (hp_task_awoken) portYIELD_FROM_ISR();
  }
}


uint32_t UartResourceGroup::on_event(Resource* r, word data, uint32_t state) {
  switch (data) {
    case UART_DATA:
      state |= kReadState;
      break;

    case UART_BREAK:
      // Ignore.
      break;

    case UART_TX_EVENT:
      state |= kWriteState;
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

typedef struct {
  QueueHandle_t queue;
  uart_hal_handle_t hal;
  bool hardware_initialized;
  UartResource* uart_resource;
  uart_port_t port;
  uint8_t* rx_buffer;
  uint8_t* tx_buffer;
} uart_initialization_record_t;

void uart_init_cleanup(uart_initialization_record_t& init) {
  if (!init.uart_resource) {
    if (init.queue) vQueueDelete(init.queue);
    if (init.hal) uart_toit_hal_deinit(init.hal);
    if (init.rx_buffer) free(init.rx_buffer);
    if (init.tx_buffer) free(init.tx_buffer);
  } else {
    delete init.uart_resource;
  }

  if (init.hardware_initialized) {
    periph_module_disable(uart_periph_signal[init.port].module);
  }

  uart_ports.put(init.port);
}

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

  uint8_t full_interrupt_threshold;
  uint16_t rx_buffer_size, tx_buffer_size;
  int interrupt_flags = ESP_INTR_FLAG_IRAM | ESP_INTR_FLAG_SHARED;
  if ((options & 8) != 0) {
    // High speed setting.
    interrupt_flags |= ESP_INTR_FLAG_LEVEL3;
    full_interrupt_threshold = 80;
    tx_buffer_size = 1024;
    rx_buffer_size = 2048;
  } else if ((options & 4) != 0) {
    // Medium speed
    interrupt_flags |= ESP_INTR_FLAG_LEVEL2 | ESP_INTR_FLAG_LEVEL3;
    full_interrupt_threshold = 100;
    tx_buffer_size = 512;
    rx_buffer_size = 1024;
  } else {
    // Low speed setting.
    interrupt_flags |= ESP_INTR_FLAG_LEVEL1 | ESP_INTR_FLAG_LEVEL2 | ESP_INTR_FLAG_LEVEL3;
    full_interrupt_threshold = 120;
    tx_buffer_size = 256;
    rx_buffer_size = 512;
  }

  uart_initialization_record_t init = {};
  uart_port_t port = determine_preferred_port(tx, rx, rts, cts);

  port = uart_ports.preferred(port);
  if (port == kInvalidUartPort) OUT_OF_RANGE;
  init.port = port;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) {
    uart_init_cleanup(init);
    ALLOCATION_FAILED;
  }

  init.queue = xQueueCreate(EVENT_QUEUE_SIZE, sizeof(uart_event_types_t));
  if (!init.queue) {
    uart_init_cleanup(init);
    MALLOC_FAILED;
  }

  init.hal = uart_toit_hal_init(port);
  if (!init.hal) {
    uart_init_cleanup(init);
    MALLOC_FAILED;
  }

  init.rx_buffer = static_cast<uint8_t*>(malloc(rx_buffer_size));
  if (!init.rx_buffer) {
    uart_init_cleanup(init);
    MALLOC_FAILED;
  }

  init.tx_buffer = static_cast<uint8_t*>(malloc(tx_buffer_size));
  if (!init.tx_buffer) {
    uart_init_cleanup(init);
    MALLOC_FAILED;
  }

  init.uart_resource = _new UartResource(group, port, init.queue, init.hal,
                                         init.rx_buffer, rx_buffer_size,
                                         init.tx_buffer, tx_buffer_size);
  if (!init.uart_resource) {
    uart_init_cleanup(init);
    MALLOC_FAILED;
  }

  periph_module_enable(uart_periph_signal[port].module);
    // Workaround for ESP32C3: enable core reset
    // before enabling uart module clock
    // to prevent uart output garbage value.
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

  auto uart_data_bits = (uart_word_length_t)(data_bits - 5);
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

  struct {
    intr_handle_t intr_handle;
    uint8_t irq;
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

  // Install the ISR on the SystemEventSource's main thread that runs on core 0, to allocate the interrupts on core 0
  SystemEventSource::instance()->run([&]() -> void {
    args.err = esp_intr_alloc(args.irq, args.interrupt_flags, UartResource::interrupt_handler,
                              args.uart_resource, &args.intr_handle);

  });

  if (args.err != ESP_OK) {
    uart_init_cleanup(init);
    return Primitive::os_error(args.err, process);
  }

  init.uart_resource->set_interrupt_handle(args.intr_handle);

  // Enable read interrupts
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

// Writes the data to the UART.
PRIMITIVE(write) {
  ARGS(UartResource, uart, Blob, data, int, from, int, to, int, break_length)

  const uint8* tx = data.address();
  if (from < 0 || from > to || to > data.length()) OUT_OF_RANGE;
  tx += from;

  if (break_length < 0 || break_length >= 256) OUT_OF_RANGE;
  int size = to - from;


  size_t available = uart->tx_buffer().free_size();
  if (available < size) size = static_cast<int>(available);

  if (size == 0) return Smi::from(0);

  uart->tx_buffer().write(tx, size, break_length);

  return Smi::from(size);
}

PRIMITIVE(wait_tx) {
  ARGS(UartResource, uart)

  if (!uart->tx_buffer().is_empty()) return BOOL(false);

  // Busy wait for the fifo to become empty
  while (uart->get_tx_fifo_available_count() < SOC_UART_FIFO_LEN) ;
  return BOOL(true);
}

PRIMITIVE(read) {
  ARGS(UartResource, uart)

  size_t available = uart->rx_buffer().available_size();

  ByteArray* data = process->allocate_byte_array(static_cast<int>(available), /*force_external*/ available != 0);
  if (data == null) ALLOCATION_FAILED;

  if (available == 0) return data;

  ByteArray::Bytes rx(data);
  uart->rx_buffer().read(rx.address(), rx.length());

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

