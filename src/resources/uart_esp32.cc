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
#include "esp_log.h"
#include "esp_rom_gpio.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"

#include "../objects_inline.h"
#include "../resource_pool.h"
#include "../event_sources/ev_queue_esp32.h"
#include "../utils.h"

#ifndef FORCE_INLINE
#error "FORCE_INLINE not defined"
#endif
#define UART_ISR_INLINE FORCE_INLINE

// Valid UART port numbers.
#define UART_NUM_0             (static_cast<uart_port_t>(0)) /*!< UART port 0 */
#define UART_NUM_1             (static_cast<uart_port_t>(1)) /*!< UART port 1 */
#if SOC_UART_HP_NUM > 2
#define UART_NUM_2             (static_cast<uart_port_t>(2)) /*!< UART port 2 */
#endif
#if SOC_UART_HP_NUM > 3
#error "SOC_UART_HP_NUM > 3"
#endif
#define UART_NUM_MAX           (SOC_UART_HP_NUM) /*!< UART port max */

namespace toit {

class UartResource;
static void uart_interrupt_handler(void* arg);

const uart_port_t kInvalidUartPort = static_cast<uart_port_t>(-1);

const int kReadState = 1 << 0;
const int kErrorState = 1 << 1;
const int kWriteState = 1 << 2;
const int kBreakState = 1 << 3;

static ResourcePool<uart_port_t, kInvalidUartPort> uart_ports(
#ifndef CONFIG_ESP_CONSOLE_UART
    UART_NUM_0,
    UART_NUM_1
#elif (CONFIG_ESP_CONSOLE_UART_NUM != 0)
    UART_NUM_0
#else
    UART_NUM_1
#endif
#if SOC_UART_HP_NUM > 2
  , UART_NUM_2
#endif
);

class SpinLocker {
 public:
  UART_ISR_INLINE explicit SpinLocker(spinlock_t* spinlock) : spinlock_(spinlock) { portENTER_CRITICAL(spinlock_); }
  UART_ISR_INLINE ~SpinLocker() { portEXIT_CRITICAL(spinlock_); }
  UART_ISR_INLINE spinlock_t* spinlock() const { return spinlock_; }
 private:
  spinlock_t* spinlock_;
};

class UartResourceGroup;

class UartResource : public EventQueueResource {
public:
  TAG(UartResource);

  UartResource(ResourceGroup* group, uart_port_t port, int tx_buffer_size, QueueHandle_t queue)
      : EventQueueResource(group, queue)
      , port_(port)
      , tx_buffer_size_(tx_buffer_size) {
    spinlock_initialize(&spinlock_);
  }

  ~UartResource() override;

  uart_port_t port() const { return port_; }

  UART_ISR_INLINE void increment_errors() { errors_++; }
  int errors() const { return errors_; }

  int tx_buffer_size() const { return tx_buffer_size_; }

 private:
  UART_ISR_INLINE void send_event_to_queue_isr(uart_event_types_t event, int* hp_task_awoken);

  void clear_data_event_in_queue();
  void clear_tx_event_in_queue();

  friend void uart_interrupt_handler(void* arg);
  UART_ISR_INLINE void handle_isr();

  const uart_port_t port_;
  const int tx_buffer_size_;
  spinlock_t spinlock_{};
  bool data_event_in_queue_ = false;
  bool tx_event_in_queue_ = false;
  int64 errors_ = 0;

  friend class UartResourceGroup;
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

UartResource::~UartResource() {
  esp_err_t err = uart_driver_delete(port_);
  if (err != ESP_OK) {
    esp_rom_printf("[uart] error: failed to delete UART driver\n");
    ESP_ERROR_CHECK(err);
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

uint32 UartResourceGroup::on_event(Resource* r, word data, uint32 state) {
  switch (data) {
    case UART_DATA:
      state |= kReadState;
      reinterpret_cast<UartResource*>(r)->clear_data_event_in_queue();
      break;

    case UART_BREAK:
      state |= kBreakState;
      break;

    case UART_TX_EVENT:
      state |= kWriteState;
      reinterpret_cast<UartResource*>(r)->clear_tx_event_in_queue();
      break;

    case UART_FIFO_OVF:
    case UART_BUFFER_FULL:
      reinterpret_cast<UartResource*>(r)->signal_dropped_data();
      [[fallthrough]];
    default:
      TODO(florian): get the list of interrupts and put them here.
      state |= kErrorState;
      reinterpret_cast<UartResource*>(r)->increment_errors();
      break;
  }

  return state;
}

MODULE_IMPLEMENTATION(uart, MODULE_UART)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  UartResourceGroup* uart_group = _new UartResourceGroup(process, EventQueueEventSource::instance());
  if (!uart_group) FAIL(MALLOC_FAILED);

  proxy->set_external_address(uart_group);
  return proxy;
}

static uart_port_t determine_preferred_port(int tx, int rx, int rts, int cts) {
  for (int uart = UART_NUM_0; uart < SOC_UART_HP_NUM; uart++) {
    if ((tx == -1 || tx == uart_periph_signal[uart].pins[SOC_UART_TX_PIN_IDX].default_gpio) &&
        (rx == -1 || rx == uart_periph_signal[uart].pins[SOC_UART_RX_PIN_IDX].default_gpio) &&
        (rts == -1 || rts == uart_periph_signal[uart].pins[SOC_UART_RTS_PIN_IDX].default_gpio) &&
        (cts == -1 || cts == uart_periph_signal[uart].pins[SOC_UART_CTS_PIN_IDX].default_gpio)) {
      return static_cast<uart_port_t>(uart);
    }
  }
  return kInvalidUartPort;
}

static inline uart_parity_t int_to_uart_parity(int parity) {
  switch (parity) {
    case 1: return UART_PARITY_DISABLE;
    case 2: return UART_PARITY_EVEN;
    case 3: return UART_PARITY_ODD;
    default: UNREACHABLE(); return UART_PARITY_DISABLE;
  }
}
static uart_word_length_t data_bits_to_uart_word_length(int data_bits) {
  switch (data_bits) {
    case 5: return UART_DATA_5_BITS;
    case 6: return UART_DATA_6_BITS;
    case 7: return UART_DATA_7_BITS;
    case 8: return UART_DATA_8_BITS;
    default: UNREACHABLE();
  }
}

static uart_stop_bits_t int_to_uart_stop_bits(int stop_bits) {
  switch (stop_bits) {
    case 1: return UART_STOP_BITS_1;
    case 2: return UART_STOP_BITS_1_5;
    case 3: return UART_STOP_BITS_2;
    default: UNREACHABLE();
  }
}

static uart_mode_t int_to_uart_mode(int mode) {
  switch (mode) {
    case 0: return UART_MODE_UART;
    case 1: return UART_MODE_RS485_HALF_DUPLEX;
    case 2: return UART_MODE_IRDA;
    default: UNREACHABLE();
  }
}

namespace {  // Anonymous.
struct DriverArgs {
  uart_port_t port;
  uint16_t rx_buffer_size;
  uint16_t tx_buffer_size;
  int interrupt_flags;
  QueueHandle_t* queue;
  size_t queue_size;
};
}  // Anonymous namespace.

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
  if (tx == rx && tx != -1) {
    // It's theoretically possible to share pins for TX and RX, but that could
    // damage the hardware, if the pins aren't configured for open-drain and pull-up.
    // For now we just disallow it.
    UNIMPLEMENTED();
  }
  if (rts >= 0 && !GPIO_IS_VALID_OUTPUT_GPIO(rts)) FAIL(INVALID_ARGUMENT);
  if (cts >= 0 && !GPIO_IS_VALID_GPIO(cts)) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  uint8 full_interrupt_threshold;
  uint16 rx_buffer_size, tx_buffer_size;
  int interrupt_flags = ESP_INTR_FLAG_SHARED;
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

  // Whether the resource object has been created and is thus responsible
  // for returning resources.
  bool handed_to_resource = false;

  uart_port_t port = determine_preferred_port(tx, rx, rts, cts);
  port = uart_ports.preferred(port);
  if (port == kInvalidUartPort) FAIL(ALREADY_IN_USE);
  Defer return_port { [&] { if (!handed_to_resource) uart_ports.put(port); } };

  if (tx == -1) {
    tx_buffer_size = 0;
  }
  if (rx == -1) {
    // The driver still wants the rx-buffer size to be >= the HW FIFO size.
    rx_buffer_size = UART_HW_FIFO_LEN(port);
  }

  esp_err_t err;
  QueueHandle_t* queue;
  DriverArgs args = {
    .port = port,
    .rx_buffer_size = rx_buffer_size,
    .tx_buffer_size = tx_buffer_size,
    .interrupt_flags = interrupt_flags,
    .queue = &queue,
    .queue_size = UART_QUEUE_SIZE,
  };
  // Install the ISR on the SystemEventSource's main thread that runs on core 0,
  // to allocate the interrupts on core 0.
  SystemEventSource::instance()->run([&]() -> void {
    err = uart_driver_install(args.port,
                              args.rx_buffer_size,
                              args.tx_buffer_size,
                              args.queue_size,
                              args.queue,
                              args.interrupt_flags);
  });
  if (err != ESP_OK) return Primitive::os_error(err, process);
  Defer uninstall_driver { [&] { if (!handed_to_resource) uart_driver_delete(port); } };

  int interrupt_mask = UART_INTR_RXFIFO_FULL |
                       UART_INTR_RXFIFO_TOUT |
                       UART_INTR_BRK_DET |
                       UART_INTR_TX_DONE;

  uart_intr_config_t uart_intr = {
    .intr_enable_mask = interrupt_mask,
    .rx_timeout_thresh = 10,
    // Unused as we don't have the TXFIFO_EMPTY interrupt.
    .txfifo_empty_intr_thresh = 0,
    .rxfifo_full_thresh = full_interrupt_threshold,
  };
  err = uart_intr_config(port, &uart_intr);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  err = uart_set_mode(port, int_to_uart_mode(mode));
  if (err != ESP_OK) return Primitive::os_error(err, process);

  uart_config_t uart_config = {
    .baud_rate = baud_rate,
    .data_bits = data_bits_to_uart_word_length(data_bits),
    .parity = int_to_uart_parity(parity),
    .stop_bits = int_to_uart_stop_bits(stop_bits),
    .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
    // Unused if flow_ctrl is disabled, but 122 seems to be a common default, otherwise.
    .rx_flow_ctrl_thresh = 122,
    .source_clk = UART_SCLK_DEFAULT,
#if (SOC_UART_LP_NUM >= 1)
    .lp_source_clk = UART_LP_SCLK_DEFAULT,
#endif
    .flags = {
      .allow_pd = 0,
      .backup_before_sleep = 0,
    },
  };

  err = uart_param_config(port, &uart_config);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  err = uart_set_pin(port, tx, rx, rts, cts);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  auto resource = _new UartResource(group, port, tx_buffer_size, queue);
  if (!resource) FAIL(MALLOC_FAILED);
  handed_to_resource = true;

  group->register_resource(init.uart);
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
  uint32_t result;
  esp_err_t err = uart_get_baudrate(uart->port(), &result);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return Primitive::integer(result, process);
}

PRIMITIVE(set_baud_rate) {
  ARGS(UartResource, uart, uint32, baud_rate)
  esp_err_t err = uart_set_baudrate(uart->port(), baud_rate);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->null_object();
}

PRIMITIVE(write) {
  ARGS(UartResource, uart, Blob, data, int, from, int, to, int, break_length)

  if (from < 0 || from > to || to > data.length()) FAIL(OUT_OF_RANGE);
  if (break_length < 0 || break_length >= 256) FAIL(OUT_OF_RANGE);

  size_t available;
  esp_err_t err = uart_get_tx_buffer_free_size(uart->port(), &available);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  size_t to_write = to - from;
  if (to_write > available) to_write = available;
  if (to_write > 0) {
    err = uart_write_bytes(uart->port(), reinterpret_cast<const char*>(data.address() + from), to_write);
    if (err < 0) return Primitive::os_error(err, process);
  }
  return Smi::from(to_write);
}

PRIMITIVE(wait_tx) {
  ARGS(UartResource, uart)

  size_t available;
  esp_err_t err = uart_get_tx_buffer_free_size(uart->port(), &available);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  if (available != uart->tx_buffer_size()) return BOOL(false);

  err = uart_wait_tx_done(uart->port(), pdMS_TO_TICKS(10));
  if (err == ESP_ERR_TIMEOUT) return BOOL(false);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return BOOL(true);
}

PRIMITIVE(read) {
  ARGS(UartResource, uart)

#ifdef CONFIG_TOIT_REPORT_UART_DATA_LOSS
  if (buffer->has_dropped_data() && !buffer->has_reported_dropped_data()) {
    buffer->set_has_reported_dropped_data();
    ESP_LOGE("uart", "dropped data; no further warnings will be issued");
  }
#endif

  auto port = uart->port();

  size_t available;
  esp_err_t err = uart_get_buffered_data_len(port, &available);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  if (available == 0) return process->null_object();

  ByteArray* data = process->allocate_byte_array(available);
  if (data == null) FAIL(ALLOCATION_FAILED);

  ByteArray::Bytes rx(data);
  err = uart_read_bytes(port, rx.address(), static_cast<uint32_t>(available), 0);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return data;
}

PRIMITIVE(set_control_flags) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(get_control_flags) {
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(errors) {
  ARGS(UartResource, uart)
  return Primitive::integer(uart->errors(), process);
}

} // namespace toit

#endif // TOIT_ESP32
