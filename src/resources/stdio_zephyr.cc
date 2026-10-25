// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "../top.h"
#ifdef TOIT_ZEPHYR
#include "../event_sources/zephyr.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include <atomic>
#include <zephyr/drivers/uart.h>

namespace toit {
K_SEM_DEFINE(stdin_changed, 0, 1);

// The console is shared by containers. IRQs feed one bounded byte stream;
// each reader is notified, and the first reader consumes the available bytes.
// List and buffer access use the same IRQ exclusion as ZephyrResource::notify.
class StdinResource : public ZephyrResource {
 public:
  TAG(StdinResource);
  explicit StdinResource(ResourceGroup* group) : ZephyrResource(group) {}
  ~StdinResource() override {
    Locker locker(OS::global_mutex());
    unsigned key = irq_lock();
    StdinResource** link = &first_;
    while (*link && *link != this) link = &(*link)->next_;
    if (*link) {
      *link = next_;
    }
    irq_unlock(key);
    if (!first_ && buffer_) {
      // RX_DISABLED follows all buffer-release callbacks. Keep the callback
      // and backing storage alive until DMA has stopped, as on the UART API.
      if (rx_active_.load()) uart_rx_disable(console());
      int64 deadline = k_uptime_get() + 1000;
      while (rx_active_.load()) {
        if (k_uptime_get() >= deadline) FATAL("stdin DMA did not stop");
        k_sem_take(&stdin_changed, K_MSEC(10));
      }
      uart_callback_set(console(), null, null);
      free(buffer_);
      buffer_ = null;
      size_ = head_ = error_ = 0;
    }
  }

  int open() {
    Locker locker(OS::global_mutex());
    if (!device_is_ready(console())) return -ENODEV;
    // Zephyr's line console would otherwise replace our IRQ callback.
    if (IS_ENABLED(CONFIG_CONSOLE_HANDLER)) return -EBUSY;
    uint8_t* buffer = null;
    if (!first_) {
      buffer = static_cast<uint8_t*>(malloc(BUFFER_SIZE));
      if (!buffer) return -ENOMEM;
    }
    if (!first_) {
      int result = uart_callback_set(console(), on_uart, null);
      if (result) {
        free(buffer);
        return result;
      }
      buffer_ = buffer;
      size_ = head_ = error_ = 0;
    }
    unsigned key = irq_lock();
    next_ = first_;
    first_ = this;
    if (size_ || error_) notify(1);
    irq_unlock(key);
    return rx_active_.load() ? 0 : start_rx();
  }

  static int resume() {
    Locker locker(OS::global_mutex());
    return rx_active_.load() ? 0 : start_rx();
  }

  static int available(int* error) {
    unsigned key = irq_lock();
    *error = error_;
    int size = size_;
    if (error_) {
      // A discontinuous byte stream must not look like a successful read.
      // Report the loss once and discard the partial buffered input.
      error_ = size_ = head_ = 0;
      size = 0;
    }
    irq_unlock(key);
    return size;
  }

  static int read(uint8_t* destination, int capacity, int* error) {
    unsigned key = irq_lock();
    *error = error_;
    if (error_) error_ = size_ = head_ = 0;
    int count = Utils::min(capacity, size_);
    // Keep IRQ exclusion short while the next DMA buffer is being received.
    int first = Utils::min(count, BUFFER_SIZE - head_);
    memcpy(destination, buffer_ + head_, first);
    if (count > first) memcpy(destination + first, buffer_, count - first);
    head_ = (head_ + count) % BUFFER_SIZE;
    size_ -= count;
    irq_unlock(key);
    return count;
  }

 private:
  static const device* console() { return DEVICE_DT_GET(DT_CHOSEN(zephyr_console)); }
  static int start_rx() {
    used_[0] = true;
    used_[1] = false;
    rx_active_.store(true);
    // Full blocks are published during continuous input; idle input is
    // delivered after 1 ms. This avoids allocating a Toit object per byte.
    int result = uart_rx_enable(console(), dma_[0], sizeof(dma_[0]), 1000);
    if (result) rx_active_.store(false);
    return result;
  }
  static void on_uart(const device* dev, uart_event* event, void*) {
    unsigned key = irq_lock();
    bool changed = false;
    switch (event->type) {
      case UART_RX_RDY: {
        if (!first_) break;
        int count = Utils::min(static_cast<int>(event->data.rx.len), BUFFER_SIZE - size_);
        int tail = (head_ + size_) % BUFFER_SIZE;
        int first = Utils::min(count, BUFFER_SIZE - tail);
        const uint8_t* bytes = event->data.rx.buf + event->data.rx.offset;
        memcpy(buffer_ + tail, bytes, first);
        if (count > first) memcpy(buffer_, bytes + first, count - first);
        size_ += count;
        if (count != static_cast<int>(event->data.rx.len)) error_ = EOVERFLOW;
        changed = true;
        break;
      }
      case UART_RX_BUF_REQUEST:
        if (first_) {
          for (int i = 0; i < 2; i++) if (!used_[i]) {
            used_[i] = true;
            if (uart_rx_buf_rsp(dev, dma_[i], sizeof(dma_[i]))) used_[i] = false;
            break;
          }
        }
        break;
      case UART_RX_BUF_RELEASED:
        for (int i = 0; i < 2; i++) if (event->data.rx_buf.buf == dma_[i]) used_[i] = false;
        break;
      case UART_RX_STOPPED:
        error_ = event->data.rx_stop.reason & UART_ERROR_OVERRUN ? EOVERFLOW : EIO;
        changed = true;
        break;
      case UART_RX_DISABLED:
        rx_active_.store(false);
        if (first_ && !error_) error_ = EIO;
        changed = true;
        k_sem_give(&stdin_changed);
        break;
      default:
        break;  // Output remains owned by Zephyr's polling console.
    }
    if (changed && first_) {
      for (auto reader = first_; reader; reader = reader->next_) reader->notify(1);
    }
    irq_unlock(key);
  }
  static const int BUFFER_SIZE = 4096;
  static StdinResource* first_;
  static uint8_t* buffer_;
  static int head_, size_, error_;
  static std::atomic<bool> rx_active_;
  static bool used_[2];
  alignas(4) static uint8_t dma_[2][256];
  StdinResource* next_ = null;
};

StdinResource* StdinResource::first_ = null;
uint8_t* StdinResource::buffer_ = null;
int StdinResource::head_ = 0;
int StdinResource::size_ = 0;
int StdinResource::error_ = 0;
std::atomic<bool> StdinResource::rx_active_{false};
bool StdinResource::used_[2] = {};
alignas(4) uint8_t StdinResource::dma_[2][256];

class StdinResourceGroup : public ResourceGroup {
 public:
  TAG(StdinResourceGroup);
  explicit StdinResourceGroup(Process* process)
      : ResourceGroup(process, ZephyrEventSource::instance()) {}
  uint32_t on_event(Resource*, word data, uint32_t state) override {
    return state | data;
  }
};

MODULE_IMPLEMENTATION(stdio, MODULE_STDIO)

PRIMITIVE(stdin_init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  auto group = _new StdinResourceGroup(process);
  if (!group) FAIL(MALLOC_FAILED);
  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(stdin_open) {
  ARGS(StdinResourceGroup, group);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  auto resource = _new StdinResource(group);
  if (!resource) FAIL(MALLOC_FAILED);
  group->register_resource(resource);
  AutoUnregisteringResource<StdinResource> cleanup(group, resource);
  int result = resource->open();
  if (result == -ENOMEM) FAIL(MALLOC_FAILED);
  if (result) return Primitive::os_error(-result, process);
  cleanup.set_external_address(proxy);
  return proxy;
}

PRIMITIVE(stdin_read) {
  ARGS(StdinResource, resource);
  USE(resource);
  int resumed = StdinResource::resume();
  if (resumed) return Primitive::os_error(-resumed, process);
  int error = 0;
  int size = StdinResource::available(&error);
  if (error) return Primitive::os_error(error, process);
  if (!size) return Smi::from(-1);  // Wait; a UART has no EOF indication.
  size = Utils::min(size, 1024);
  ByteArray* result = process->allocate_byte_array(size, true);
  if (!result) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes bytes(result);
  int count = StdinResource::read(bytes.address(), size, &error);
  if (error) return Primitive::os_error(error, process);
  if (!count) return Smi::from(-1);
  if (count < size) result->resize_external(process, count);
  return result;
}
}  // namespace toit
#endif
