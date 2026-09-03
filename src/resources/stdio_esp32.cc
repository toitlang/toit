// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "../top.h"

#ifdef TOIT_ESP32

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

#include "sdkconfig.h"

#ifdef CONFIG_ESP_CONSOLE_UART
#define TOIT_STDIN_UART
#endif
#if defined(CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG) || defined(CONFIG_ESP_CONSOLE_SECONDARY_USB_SERIAL_JTAG)
#define TOIT_STDIN_USB_SERIAL_JTAG
#endif

#ifdef TOIT_STDIN_UART
#include "driver/uart.h"
#include "driver/uart_vfs.h"
#include "uart_console_esp32.h"
#endif

#ifdef TOIT_STDIN_USB_SERIAL_JTAG
#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_select.h"
#include "driver/usb_serial_jtag_vfs.h"
#endif

#include "../event_sources/ev_queue_esp32.h"
#include "../event_sources/system_esp32.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"

namespace toit {

static const word STDIN_READ_EVENT = 1 << 0;
static const int STDIN_BUFFER_SIZE = 1024;
static const int STDIN_QUEUE_SIZE = 4;
static_assert(STDIN_QUEUE_SIZE <= STDIN_EVENT_QUEUE_SIZE,
              "Increase STDIN_EVENT_QUEUE_SIZE");
#ifdef TOIT_STDIN_UART
static const int UART_STDIN_RX_BUFFER_SIZE = 4096;
#endif

// ESP-IDF's console VFS only reads from the primary console. Subscribe to both
// drivers directly so stdin can merge the configured UART and USB Serial/JTAG
// input streams.

#ifdef TOIT_STDIN_UART
static int console_uart_stdin_users = 0;

static esp_err_t acquire_uart_stdin(QueueHandle_t* queue) {
  // Use the largest buffer supported by Port.console so opening that API
  // later never silently weakens its --large-buffers contract.
  esp_err_t err = console_uart_acquire(UART_STDIN_RX_BUFFER_SIZE, 1024, queue);
  if (err != ESP_OK) return err;

  bool failed = false;
  {
    Locker locker(OS::global_mutex());
    if (console_uart_stdin_users++ == 0) {
      uart_vfs_dev_use_driver(CONFIG_ESP_CONSOLE_UART_NUM);
      int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
      if (flags < 0 || fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) < 0) {
        console_uart_stdin_users--;
        uart_vfs_dev_use_nonblocking(CONFIG_ESP_CONSOLE_UART_NUM);
        failed = true;
      }
    }
  }
  if (failed) {
    console_uart_release();
    return ESP_FAIL;
  }
  return ESP_OK;
}

static void release_uart_stdin() {
  {
    Locker locker(OS::global_mutex());
    ASSERT(console_uart_stdin_users > 0);
    if (--console_uart_stdin_users == 0) {
      uart_vfs_dev_use_nonblocking(CONFIG_ESP_CONSOLE_UART_NUM);
    }
  }
  console_uart_release();
}
#endif

#ifdef TOIT_STDIN_USB_SERIAL_JTAG
static int usb_serial_jtag_stdin_users = 0;
static QueueHandle_t usb_serial_jtag_stdin_queue = null;

static void usb_serial_jtag_notify(usj_select_notif_t notification, BaseType_t* task_woken) {
  if (notification != USJ_SELECT_READ_NOTIF || usb_serial_jtag_stdin_queue == null) return;
  word event = STDIN_READ_EVENT;
  xQueueSendFromISR(usb_serial_jtag_stdin_queue, &event, task_woken);
}

static esp_err_t acquire_usb_serial_jtag_stdin(QueueHandle_t* queue) {
  Locker locker(OS::global_mutex());
  if (usb_serial_jtag_stdin_users > 0) {
    usb_serial_jtag_stdin_users++;
    *queue = usb_serial_jtag_stdin_queue;
    return ESP_OK;
  }

  usb_serial_jtag_stdin_queue = xQueueCreate(STDIN_QUEUE_SIZE, sizeof(word));
  if (usb_serial_jtag_stdin_queue == null) return ESP_ERR_NO_MEM;

  usb_serial_jtag_driver_config_t config = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
  esp_err_t err = ESP_FAIL;
  SystemEventSource::instance()->run([&]() -> void {
    err = usb_serial_jtag_driver_install(&config);
  });
  if (err != ESP_OK) {
    vQueueDelete(usb_serial_jtag_stdin_queue);
    usb_serial_jtag_stdin_queue = null;
    return err;
  }

  usb_serial_jtag_vfs_use_driver();
  usb_serial_jtag_set_select_notif_callback(usb_serial_jtag_notify);
  if (usb_serial_jtag_read_ready()) {
    word event = STDIN_READ_EVENT;
    xQueueSend(usb_serial_jtag_stdin_queue, &event, 0);
  }
  usb_serial_jtag_stdin_users = 1;
  *queue = usb_serial_jtag_stdin_queue;
  return ESP_OK;
}

static void release_usb_serial_jtag_stdin() {
  Locker locker(OS::global_mutex());
  ASSERT(usb_serial_jtag_stdin_users > 0);
  if (--usb_serial_jtag_stdin_users != 0) return;

  usb_serial_jtag_set_select_notif_callback(null);
  usb_serial_jtag_vfs_use_nonblocking();
  esp_err_t err = ESP_FAIL;
  SystemEventSource::instance()->run([&]() -> void {
    err = usb_serial_jtag_driver_uninstall();
  });
  if (err != ESP_OK) {
    esp_rom_printf("[stdio] error: failed to uninstall USB Serial/JTAG driver\n");
    ESP_ERROR_CHECK(err);
  }
  vQueueDelete(usb_serial_jtag_stdin_queue);
  usb_serial_jtag_stdin_queue = null;
}
#endif

class StdinResource : public EventQueueResource {
 public:
  TAG(StdinResource);

  StdinResource(ResourceGroup* group, QueueHandle_t uart_queue, QueueHandle_t usb_queue)
      : EventQueueResource(group,
                           uart_queue != null ? uart_queue : usb_queue,
                           uart_queue != null ? usb_queue : null)
      , uart_queue_(uart_queue)
      , usb_queue_(usb_queue) {}

  ~StdinResource() override {
#ifdef TOIT_STDIN_UART
    release_uart_stdin();
#endif
#ifdef TOIT_STDIN_USB_SERIAL_JTAG
    release_usb_serial_jtag_stdin();
#endif
  }

  bool receive_event(QueueHandle_t queue, word* data) override {
#ifdef TOIT_STDIN_UART
    if (queue == uart_queue_) {
      uart_event_t event;
      if (!xQueueReceive(queue, &event, 0)) return false;
      // Preserve the UART event type because Port.console may share this
      // queue and receives the same dispatched event.
      *data = event.type;
      return true;
    }
#endif
#ifdef TOIT_STDIN_USB_SERIAL_JTAG
    ASSERT(queue == usb_queue_);
    return xQueueReceive(queue, data, 0);
#else
    UNREACHABLE();
#endif
  }

  bool read_uart_first() const { return read_uart_first_; }
  void alternate_read_order() { read_uart_first_ = !read_uart_first_; }

 private:
  const QueueHandle_t uart_queue_;
  const QueueHandle_t usb_queue_;
  bool read_uart_first_ = true;
};

class StdinResourceGroup : public ResourceGroup {
 public:
  TAG(StdinResourceGroup);

  StdinResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    USE(resource);
    USE(data);
    // Error events do not carry data, but must still wake a pending read so it
    // can retry instead of waiting indefinitely.
    return state | STDIN_READ_EVENT;
  }
};

MODULE_IMPLEMENTATION(stdio, MODULE_STDIO)

PRIMITIVE(stdin_init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto group = _new StdinResourceGroup(process, EventQueueEventSource::instance());
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(stdin_open) {
  ARGS(StdinResourceGroup, group)

#if !defined(TOIT_STDIN_UART) && !defined(TOIT_STDIN_USB_SERIAL_JTAG)
  FAIL(UNSUPPORTED);
#else
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  QueueHandle_t uart_queue = null;
  QueueHandle_t usb_queue = null;
#ifdef TOIT_STDIN_UART
  esp_err_t err = acquire_uart_stdin(&uart_queue);
  if (err != ESP_OK) return Primitive::os_error(err, process);
#endif
#ifdef TOIT_STDIN_USB_SERIAL_JTAG
  esp_err_t usb_err = acquire_usb_serial_jtag_stdin(&usb_queue);
  if (usb_err != ESP_OK) {
#ifdef TOIT_STDIN_UART
    release_uart_stdin();
#endif
    return Primitive::os_error(usb_err, process);
  }
#endif

  bool handed_to_resource = false;
  Defer release_backend { [&] {
    if (handed_to_resource) return;
#ifdef TOIT_STDIN_UART
    release_uart_stdin();
#endif
#ifdef TOIT_STDIN_USB_SERIAL_JTAG
    release_usb_serial_jtag_stdin();
#endif
  } };

  auto resource = _new StdinResource(group, uart_queue, usb_queue);
  if (resource == null) FAIL(MALLOC_FAILED);
  handed_to_resource = true;
  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
#endif
}

PRIMITIVE(stdin_read) {
  ARGS(StdinResource, resource)
  USE(resource);

#if !defined(TOIT_STDIN_UART) && !defined(TOIT_STDIN_USB_SERIAL_JTAG)
  FAIL(UNSUPPORTED);
#else
  ByteArray* result = process->allocate_byte_array(STDIN_BUFFER_SIZE, true);
  if (result == null) FAIL(ALLOCATION_FAILED);

  ByteArray::Bytes bytes(result);
  int read_count = 0;
  int read_error = 0;
  bool uart_eof = false;
#ifdef TOIT_STDIN_UART
  auto read_uart = [&]() -> int {
    int count = ::read(STDIN_FILENO, bytes.address(), STDIN_BUFFER_SIZE);
    if (count < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
      read_error = errno;
      return -1;
    }
    if (count == 0) uart_eof = true;
    return count;
  };
#endif
#ifdef TOIT_STDIN_USB_SERIAL_JTAG
  auto read_usb = [&]() -> int {
    return usb_serial_jtag_read_bytes(bytes.address(), STDIN_BUFFER_SIZE, 0);
  };
#endif

#if defined(TOIT_STDIN_UART) && defined(TOIT_STDIN_USB_SERIAL_JTAG)
  if (resource->read_uart_first()) {
    read_count = read_uart();
    if (read_count == 0) read_count = read_usb();
  } else {
    read_count = read_usb();
    if (read_count == 0) read_count = read_uart();
  }
  if (read_count > 0) resource->alternate_read_order();
#elif defined(TOIT_STDIN_UART)
  read_count = read_uart();
#else
  read_count = read_usb();
#endif

  if (read_count < 0) return Primitive::os_error(read_error, process);
  if (read_count == 0) {
#if defined(TOIT_STDIN_UART) && !defined(TOIT_STDIN_USB_SERIAL_JTAG)
    if (uart_eof) return process->null_object();
#else
    USE(uart_eof);
#endif
    return Smi::from(-1);
  }
  if (read_count < STDIN_BUFFER_SIZE) result->resize_external(process, read_count);
  return result;
#endif
}

}  // namespace toit

#endif  // TOIT_ESP32
