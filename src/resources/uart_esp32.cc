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

#include <driver/uart.h>
#include <hal/uart_types.h>

#include "../objects_inline.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../vm.h"
#include "../event_sources/uart_esp32.h"
#include "../event_sources/system_esp32.h"


#ifdef __riscv
    #define UART_PORT UART_NUM_1
#else
    #define UART_PORT UART_NUM_2
#endif

namespace toit {

const uart_port_t kInvalidUARTPort = uart_port_t(-1);

const int kReadState = 1 << 0;
const int kErrorState = 1 << 1;

ResourcePool<uart_port_t, kInvalidUARTPort> uart_ports(
  // UART_NUM_0 is reserved serial communication (stdout).
#ifndef __riscv
  UART_NUM_2,
#endif
  UART_NUM_1
);

class UARTResourceGroup : public ResourceGroup {
 public:
  TAG(UARTResourceGroup);
  UARTResourceGroup(Process* process, EventSource* event_source)
    : ResourceGroup(process, event_source){ }

  virtual void on_unregister_resource(Resource* r) {
    UARTResource* uart_res = static_cast<UARTResource*>(r);
    SystemEventSource::instance()->run([&]() -> void {
      FATAL_IF_NOT_ESP_OK(uart_driver_delete(uart_res->port()));
    });
    uart_ports.put(uart_res->port());
  }

  uint32_t on_event(Resource* r, word data, uint32_t state) {
    switch (data) {
      case UART_DATA:
        state |= kReadState;
        break;

      case UART_BREAK:
        // Ignore.
        break;

      default:
        state |= kErrorState;
        break;
    }

    return state;
  }
};

MODULE_IMPLEMENTATION(uart, MODULE_UART);

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) {
    ALLOCATION_FAILED;
  }
  UARTResourceGroup* uart = _new UARTResourceGroup(process, UARTEventSource::instance());
  if (!uart) MALLOC_FAILED;

  proxy->set_external_address(uart);
  return proxy;
}

PRIMITIVE(create) {
  ARGS(UARTResourceGroup, group, int, tx, int, rx, int, rts, int, cts,
       int, baud_rate, int, data_bits, int, stop_bits, int, parity,
       int, options);

  if (data_bits < 5 || data_bits > 8) INVALID_ARGUMENT;
  if (stop_bits < 1 || stop_bits > 3) INVALID_ARGUMENT;
  if (parity < 1 || parity > 3) INVALID_ARGUMENT;
  if (options < 0 || options > 3) INVALID_ARGUMENT;

  uart_port_t port = kInvalidUARTPort;

  // Check if there is a preferred device.
  if ((tx == -1 || tx == 17) &&
      (rx == -1 || rx == 16) &&
      (rts == -1 || rts == 7) &&
      (cts == -1 || cts == 8)) {
    port = UART_PORT;
  }
  if ((tx == -1 || tx == 10) &&
      (rx == -1 || rx == 9) &&
      (rts == -1 || rts == 11) &&
      (cts == -1 || cts == 6)) {
    port = UART_NUM_1;
  }
  if ((tx == -1 || tx == 1) &&
      (rx == -1 || rx == 3) &&
      (rts == -1 || rts == 22) &&
      (cts == -1 || cts == 19)) {
    port = UART_NUM_0;
  }
  port = uart_ports.preferred(port);
  if (port == kInvalidUARTPort) OUT_OF_RANGE;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) {
    uart_ports.put(port);
    ALLOCATION_FAILED;
  }

  int flow_ctrl = 0;
  if (rts != -1) flow_ctrl += UART_HW_FLOWCTRL_RTS;
  if (cts != -1) flow_ctrl += UART_HW_FLOWCTRL_CTS;

  uart_config_t uart_config = {
    .baud_rate = baud_rate,
    .data_bits = (uart_word_length_t)(data_bits - 5),
    .parity = UART_PARITY_DISABLE,
    .stop_bits = UART_STOP_BITS_1,
    .flow_ctrl = (uart_hw_flowcontrol_t)flow_ctrl,
    .rx_flow_ctrl_thresh = 122,
  };


  switch (stop_bits) {
    case 2: uart_config.stop_bits = UART_STOP_BITS_1_5; break;
    case 3: uart_config.stop_bits = UART_STOP_BITS_2; break;
  }

  switch (parity) {
    case 2: uart_config.parity = UART_PARITY_EVEN; break;
    case 3: uart_config.parity = UART_PARITY_ODD; break;
  }

  esp_err_t err = uart_param_config(port, &uart_config);

  if (err == ESP_OK) {
    err = uart_set_pin(port, tx, rx, rts, cts);
  }

  struct {
    QueueHandle_t queue;
    int options;
    esp_err_t err;
  } args;

  if (err == ESP_OK) {
    args.options = options;
    SystemEventSource::instance()->run([&]() -> void {
      int buffer_size = 2 * 1024;
      // Initialize using default priority.
      args.err = uart_driver_install(port, buffer_size, buffer_size, 32, &args.queue, ESP_INTR_FLAG_IRAM);
      if (args.err == ESP_OK) {
        int flags = 0;
        if ((args.options & 1) != 0) flags |= UART_SIGNAL_TXD_INV;
        if ((args.options & 2) != 0) flags |= UART_SIGNAL_RXD_INV;
        args.err = uart_set_line_inverse(port, flags);
      }
    });
    err = args.err;
  }

  if (err != ESP_OK) {
    uart_ports.put(port);
    return Primitive::os_error(err, process);
  }

  UARTResource* res = _new UARTResource(group, port, args.queue);
  if (!res) {
    SystemEventSource::instance()->run([&]() -> void {
      FATAL_IF_NOT_ESP_OK(uart_driver_delete(port));
    });
    uart_ports.put(port);
    MALLOC_FAILED;
  }
  group->register_resource(res);

  proxy->set_external_address(res);

  uart_flush_input(port);

  return proxy;
}

PRIMITIVE(close) {
  ARGS(UARTResourceGroup, uart, UARTResource, res);
  uart->unregister_resource(res);
  res_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(set_baud_rate) {
  ARGS(UARTResource, uart, int, baud_rate);

  esp_err_t err = uart_set_baudrate(uart->port(), baud_rate);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  return process->program()->null_object();
}

PRIMITIVE(write) {
  ARGS(UARTResource, uart, Blob, data, int, from, int, to, int, break_length, bool, wait);

  const uint8* tx = data.address();
  if (from < 0 || from > to || to > data.length()) OUT_OF_RANGE;
  tx += from;

  if (break_length < 0) OUT_OF_RANGE;

  int wrote;
  if (break_length > 0) {
    wrote = uart_write_bytes_with_break(uart->port(), reinterpret_cast<const char*>(tx), to - from, break_length);
  } else {
    wrote = uart_write_bytes(uart->port(), reinterpret_cast<const char*>(tx), to - from);
  }
  if (wrote == -1) {
    OUT_OF_RANGE;
  }

  if (wait) {
    esp_err_t err = uart_wait_tx_done(uart->port(), portMAX_DELAY);
    if (err != ESP_OK) {
      return Primitive::os_error(err, process);
    }
  }

  return Smi::from(wrote);
}

PRIMITIVE(read) {
  ARGS(UARTResource, uart);

  size_t available = 0;
  esp_err_t err = uart_get_buffered_data_len(uart->port(), &available);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  // The uart_get_buffered_data_len is not thread safe, so it's not guaranteed that
  // we get an updated value. As false negatives can lead to deadlock, we don't trust
  // when it returns 0. To work around this, we instead try to read 8 bytes, whenever
  // we are suggested 0; it is always safe to try to read too much, so this is only a
  // performance issue.
  size_t capacity = Utils::max(available, (size_t)8);

  Error* error = null;
  ByteArray* data = process->allocate_byte_array(capacity, &error);
  if (data == null) return error;

  ByteArray::Bytes rx(data);
  int read = uart_read_bytes(uart->port(), rx.address(), rx.length(), 0);
  if (read == -1) {
    OUT_OF_RANGE;
  }

  if (read < available) {
    return process->allocate_string_or_error("broken UART read");
  }

  data->resize(read);

  return data;
}

} // namespace toit

#endif // TOIT_FREERTOS
