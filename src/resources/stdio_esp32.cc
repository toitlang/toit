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
#include "driver/uart.h"
#include "driver/uart_vfs.h"
#include "uart_console_esp32.h"
#endif

#ifdef CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
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
static const int UART_STDIN_RX_BUFFER_SIZE = 4096;

enum StdinBackend {
  STDIN_BACKEND_UART,
  STDIN_BACKEND_USB_SERIAL_JTAG,
};

#ifdef CONFIG_ESP_CONSOLE_UART
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

#ifdef CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
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
  int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
  if (flags < 0 || fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) < 0) {
    usb_serial_jtag_vfs_use_nonblocking();
    SystemEventSource::instance()->run([&]() -> void {
      err = usb_serial_jtag_driver_uninstall();
    });
    vQueueDelete(usb_serial_jtag_stdin_queue);
    usb_serial_jtag_stdin_queue = null;
    return ESP_FAIL;
  }

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

  StdinResource(ResourceGroup* group, QueueHandle_t queue, StdinBackend backend)
      : EventQueueResource(group, queue)
      , backend_(backend) {}

  ~StdinResource() override {
    switch (backend_) {
#ifdef CONFIG_ESP_CONSOLE_UART
      case STDIN_BACKEND_UART:
        release_uart_stdin();
        return;
#endif
#ifdef CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
      case STDIN_BACKEND_USB_SERIAL_JTAG:
        release_usb_serial_jtag_stdin();
        return;
#endif
      default:
        UNREACHABLE();
    }
  }

  bool receive_event(word* data) override {
    switch (backend_) {
#ifdef CONFIG_ESP_CONSOLE_UART
      case STDIN_BACKEND_UART: {
        uart_event_t event;
        if (!xQueueReceive(queue(), &event, 0)) return false;
        *data = event.type;
        return true;
      }
#endif
#ifdef CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
      case STDIN_BACKEND_USB_SERIAL_JTAG:
        return xQueueReceive(queue(), data, 0);
#endif
      default:
        UNREACHABLE();
    }
  }

  StdinBackend backend() const { return backend_; }

 private:
  const StdinBackend backend_;
};

class StdinResourceGroup : public ResourceGroup {
 public:
  TAG(StdinResourceGroup);

  StdinResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
#ifdef CONFIG_ESP_CONSOLE_UART
    auto stdin_resource = static_cast<StdinResource*>(resource);
    if (stdin_resource->backend() == STDIN_BACKEND_UART) {
      // Error events do not carry data, but must still wake a pending read so
      // it can retry instead of waiting indefinitely.
      return state | STDIN_READ_EVENT;
    }
#else
    USE(resource);
#endif
    return state | static_cast<uint32_t>(data);
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

#if !defined(CONFIG_ESP_CONSOLE_UART) && !defined(CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG)
  FAIL(UNSUPPORTED);
#else
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  QueueHandle_t queue = null;
  StdinBackend backend;
  esp_err_t err;
#ifdef CONFIG_ESP_CONSOLE_UART
  backend = STDIN_BACKEND_UART;
  err = acquire_uart_stdin(&queue);
#else
  backend = STDIN_BACKEND_USB_SERIAL_JTAG;
  err = acquire_usb_serial_jtag_stdin(&queue);
#endif
  if (err != ESP_OK) return Primitive::os_error(err, process);

  bool handed_to_resource = false;
  Defer release_backend { [&] {
    if (handed_to_resource) return;
#ifdef CONFIG_ESP_CONSOLE_UART
    release_uart_stdin();
#else
    release_usb_serial_jtag_stdin();
#endif
  } };

  auto resource = _new StdinResource(group, queue, backend);
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

#if !defined(CONFIG_ESP_CONSOLE_UART) && !defined(CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG)
  FAIL(UNSUPPORTED);
#else
  ByteArray* result = process->allocate_byte_array(STDIN_BUFFER_SIZE, true);
  if (result == null) FAIL(ALLOCATION_FAILED);

  ByteArray::Bytes bytes(result);
  int read_count = ::read(STDIN_FILENO, bytes.address(), STDIN_BUFFER_SIZE);
  if (read_count < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) return Smi::from(-1);
    return Primitive::os_error(errno, process);
  }
  if (read_count == 0) return process->null_object();
  if (read_count < STDIN_BUFFER_SIZE) result->resize_external(process, read_count);
  return result;
#endif
}

}  // namespace toit

#endif  // TOIT_ESP32
