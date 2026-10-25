// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "../top.h"
#ifdef TOIT_ZEPHYR
#include "../event_sources/zephyr.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "pins_zephyr.h"
#include <atomic>
#include <zephyr/drivers/uart.h>
#include <zephyr/drivers/pinctrl.h>
#include <zephyr/pm/device.h>
#include <zephyr/dt-bindings/pinctrl/nrf-pinctrl.h>
#include <zephyr/drivers/clock_control/nrf_clock_control.h>
#include <zephyr/sys/onoff.h>

#define TOIT_PLATFORM DT_COMPAT_GET_ANY_STATUS_OKAY(toit_platform)
#define DECLARE_UART(node, prop, i) PINCTRL_DT_DEV_CONFIG_DECLARE(DT_PHANDLE_BY_IDX(node, prop, i));
DT_FOREACH_PROP_ELEM(TOIT_PLATFORM, uart_ports, DECLARE_UART)

namespace toit {
static const uint32_t READ_READY = 1, UART_ERROR = 2, WRITE_READY = 4, UART_BREAK_STATE = 8;
struct UartController {
  UartController(const device* d, pinctrl_dev_config* p) : dev(d), config(p) {}
  const device* dev;
  pinctrl_dev_config* config;
  bool claimed = false;
  bool broken = false;
  pinctrl_soc_pin_t active[4];
  pinctrl_soc_pin_t sleep[4];
  pinctrl_state states[2];

  int map(int tx, int rx, int rts, int cts) {
    // Pin encoding is the Nordic-specific part of this Zephyr backend.
    const int pins[] = {tx, rx, rts, cts};
    const uint32_t functions[] = {NRF_FUN_UART_TX, NRF_FUN_UART_RX, NRF_FUN_UART_RTS, NRF_FUN_UART_CTS};
    for (int i = 0; i < 4; i++) {
      active[i] = (functions[i] << NRF_FUN_POS) |
          (pins[i] < 0 ? NRF_PIN_DISCONNECTED : static_cast<uint32_t>(pins[i]));
      sleep[i] = active[i] | BIT(NRF_LP_POS);
      if (i == 1 || i == 3) active[i] |= NRF_PULL_UP << NRF_PULL_POS;
    }
    states[0] = {active, 4, PINCTRL_STATE_DEFAULT};
    states[1] = {sleep, 4, PINCTRL_STATE_SLEEP};
    return pinctrl_update_states(config, states, 2);
  }
};
#define UART_CONTROLLER(node, prop, i) {DEVICE_DT_GET(DT_PHANDLE_BY_IDX(node, prop, i)), PINCTRL_DT_DEV_CONFIG_GET(DT_PHANDLE_BY_IDX(node, prop, i))},
static UartController controllers[] = {
  DT_FOREACH_PROP_ELEM(TOIT_PLATFORM, uart_ports, UART_CONTROLLER)
};
static UartController* claim_controller() {
  Locker locker(OS::global_mutex());
  for (auto& controller : controllers) {
    if (!controller.claimed && !controller.broken) { controller.claimed = true; return &controller; }
  }
  return null;
}

class UartResource : public ZephyrResource {
 public:
  TAG(UartResource);
  UartResource(ResourceGroup* group, int size) : ZephyrResource(group), ring_size_(size) {
    ring_ = static_cast<uint8_t*>(malloc(size));
    k_sem_init(&changed_, 0, 1);
  }
  ~UartResource() {
    closing_.store(true);
    if (callback_set_) {
      if (rx_enabled_.load()) uart_rx_disable(dev());
      if (tx_busy_.load()) uart_tx_abort(dev());
      int64 deadline = k_uptime_get() + 1000;
      while (rx_enabled_.load() || tx_busy_.load()) {
        if (k_uptime_get() >= deadline) FATAL("UART DMA did not stop");
        k_sem_take(&changed_, K_MSEC(10));
      }
      uart_callback_set(dev(), null, null);
    }
    if (active_) {
      int result = pm_device_action_run(dev(), PM_DEVICE_ACTION_SUSPEND);
      if (result) FATAL("UART suspend failed: %d", result);
    }
    if (clock_) onoff_release(clock_);
    pins.release();
    if (controller_) {
      Locker locker(OS::global_mutex());
      controller_->claimed = false;
    }
    free(ring_);
  }
  bool allocated() const { return ring_ != null; }
  const device* dev() const { return controller_->dev; }
  int start(int tx, int rx, int rts, int cts, const uart_config& config) {
    tx_pin_ = tx;
    rx_pin_ = rx;
    flow_control_ = config.flow_ctrl == UART_CFG_FLOW_CTRL_RTS_CTS;
    controller_ = claim_controller();
    if (!controller_) return -EBUSY;
    // UARTE does not request HFXO itself. Hold the accurate clock while the
    // port is open, including receive-only operation.
    auto manager = z_nrf_clock_control_get_onoff(CLOCK_CONTROL_NRF_SUBSYS_HF);
    if (!manager) return -ENODEV;
    onoff_client client = {};
    sys_notify_init_spinwait(&client.notify);
    int request = onoff_request(manager, &client);
    if (request < 0) return request;
    int clock_result;
    int64 deadline = k_uptime_get() + 1000;
    while (sys_notify_fetch_result(&client.notify, &clock_result) == -EAGAIN) {
      if (k_uptime_get() >= deadline) {
        onoff_cancel_or_release(manager, &client);
        return -ETIMEDOUT;
      }
      k_sleep(K_MSEC(1));
    }
    if (clock_result < 0) return clock_result;
    clock_ = manager;
    int result = controller_->map(tx, rx, rts, cts);
    if (result) return result;
    if (!device_is_ready(dev())) {
      result = device_init(dev());
      if (result) { controller_->broken = true; return result; }
    } else {
      result = pm_device_action_run(dev(), PM_DEVICE_ACTION_RESUME);
      if (result) return result;
    }
    active_ = true;
    result = uart_configure(dev(), &config);
    if (result) return result;
    result = uart_callback_set(dev(), callback, this);
    if (result) return result;
    callback_set_ = true;
    return start_rx();
  }
  int start_rx() {
    if (rx_pin_ < 0) return 0;
    // Reserve space for both DMA buffers, including bytes not yet reported by
    // RX_RDY. With flow control, leaving RX stopped deasserts RTS until the VM
    // drains the ring. Without it, retain overflow accounting and reception.
    if (flow_control_ && !room_for_rx()) return 0;
    used_[0] = true;
    used_[1] = false;
    rx_enabled_.store(true);
    uart_config config;
    int result = uart_config_get(dev(), &config);
    if (result) { rx_enabled_.store(false); return result; }
    // Keep the idle timeout longer than a few characters at low baud rates.
    int timeout = Utils::max(1000, static_cast<int>(48000000 / config.baudrate));
    result = uart_rx_enable(dev(), dma_[0], sizeof(dma_[0]), timeout);
    if (result) rx_enabled_.store(false);
    return result;
  }
  void service() {
    if (!closing_.load() && !pause_rx_.load() && !rx_enabled_.load() && rx_pin_ >= 0) {
      if (start_rx()) errors_.fetch_add(1);
    }
  }
  int set_baud(uint32_t baud) {
    Locker locker(resource_group()->event_source()->mutex());
    if (tx_busy_.load()) return -EBUSY;
    uart_config config;
    int result = uart_config_get(dev(), &config);
    if (result) return result;
    pause_rx_.store(true);
    if (rx_enabled_.load()) {
      result = uart_rx_disable(dev());
      if (result && result != -EFAULT) { pause_rx_.store(false); return result; }
      int64 deadline = k_uptime_get() + 1000;
      while (rx_enabled_.load()) {
        if (k_uptime_get() >= deadline) { pause_rx_.store(false); return -ETIMEDOUT; }
        k_sem_take(&changed_, K_MSEC(10));
      }
    }
    config.baudrate = baud;
    result = uart_configure(dev(), &config);
    // RX_BUF_REQUEST may interrupt uart_rx_enable before it returns. Accept
    // the second DMA buffer immediately; the event-source lock still excludes
    // the worker's recovery path until this operation finishes.
    pause_rx_.store(false);
    int restart = start_rx();
    return result ? result : restart;
  }
  int write(const uint8_t* bytes, int length) {
    if (tx_pin_ < 0) return -EINVAL;
    if (tx_busy_.load()) return 0;
    int count = Utils::min(length, static_cast<int>(sizeof(tx_)));
    if (count == 0) return 0;
    memcpy(tx_, bytes, count);
    tx_busy_.store(true);
    int result = uart_tx(dev(), tx_, count, SYS_FOREVER_US);
    if (result) { tx_busy_.store(false); return result; }
    return count;
  }
  bool tx_idle() const { return !tx_busy_.load(); }
  uint32_t errors() const { return errors_.load(); }
  uint32_t available() const { return head_.load() - tail_.load(); }
  void read(uint8_t* bytes, uint32_t count) {
    uint32_t tail = tail_.load();
    uint32_t first = Utils::min(count, ring_size_ - (tail % ring_size_));
    memcpy(bytes, ring_ + tail % ring_size_, first);
    memcpy(bytes + first, ring_, count - first);
    tail_.store(tail + count);
    // A full flow-controlled receiver has no further interrupts to wake the
    // event worker. Draining it must explicitly schedule the restart there.
    if (flow_control_ && !rx_enabled_.load()) notify(READ_READY);
  }
  ZephyrPins pins;
 private:
  bool room_for_rx() const {
    // A concurrent consumer may advance tail between available()'s atomic
    // loads. Treat an inconsistent, wrapped count as full, never as credit.
    return available() <= ring_size_ - sizeof(dma_);
  }
  static void callback(const device*, uart_event* event, void* context) {
    static_cast<UartResource*>(context)->event(event);
  }
  void event(uart_event* event) {
    switch (event->type) {
      case UART_TX_ABORTED:
        if (!closing_.load()) { errors_.fetch_add(1); notify(UART_ERROR); }
        // Fall through: an aborted transfer also releases the staging buffer.
      case UART_TX_DONE:
        tx_busy_.store(false);
        notify(WRITE_READY);
        k_sem_give(&changed_);
        break;
      case UART_RX_RDY: {
        uint32_t head = head_.load();
        size_t count = Utils::min(event->data.rx.len, static_cast<size_t>(ring_size_ - (head - tail_.load())));
        const uint8_t* data = event->data.rx.buf + event->data.rx.offset;
        for (size_t i = 0; i < count; i++) ring_[(head + i) % ring_size_] = data[i];
        head_.store(head + count);
        if (count != event->data.rx.len) { errors_.fetch_add(event->data.rx.len - count); notify(UART_ERROR); }
        if (count) notify(READ_READY);
        break;
      }
      case UART_RX_BUF_REQUEST:
        if (!closing_.load() && !pause_rx_.load() &&
            (!flow_control_ || room_for_rx())) {
          for (int i = 0; i < 2; i++) if (!used_[i]) {
            used_[i] = true;
            if (uart_rx_buf_rsp(dev(), dma_[i], sizeof(dma_[i]))) used_[i] = false;
            break;
          }
        }
        break;
      case UART_RX_BUF_RELEASED:
        for (int i = 0; i < 2; i++) if (event->data.rx_buf.buf == dma_[i]) used_[i] = false;
        break;
      case UART_RX_STOPPED:
        errors_.fetch_add(1);
        notify(UART_ERROR | ((event->data.rx_stop.reason & ::UART_BREAK) ? UART_BREAK_STATE : 0));
        break;
      case UART_RX_DISABLED:
        rx_enabled_.store(false);
        // For flow control, this can be an intentional buffer-space pause.
        notify(flow_control_ ? READ_READY : UART_ERROR);
        k_sem_give(&changed_);
        break;
    }
  }
  UartController* controller_ = null;
  onoff_manager* clock_ = null;
  int tx_pin_ = -1, rx_pin_ = -1;
  bool active_ = false, callback_set_ = false, flow_control_ = false;
  uint8_t* ring_;
  uint32_t ring_size_;
  std::atomic<uint32_t> head_{0}, tail_{0}, errors_{0};
  std::atomic<bool> rx_enabled_{false}, tx_busy_{false}, closing_{false}, pause_rx_{false};
  bool used_[2] = {};
  alignas(4) uint8_t dma_[2][256];
  alignas(4) uint8_t tx_[1024];
  struct k_sem changed_;
};
class UartResourceGroup : public ResourceGroup {
 public:
  TAG(UartResourceGroup);
  explicit UartResourceGroup(Process* process) : ResourceGroup(process, ZephyrEventSource::instance()) {}
  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    static_cast<UartResource*>(resource)->service();
    return state | data;
  }
};

MODULE_IMPLEMENTATION(uart, MODULE_UART)
PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  auto group = _new UartResourceGroup(process);
  if (!group) FAIL(MALLOC_FAILED);
  proxy->set_external_address(group);
  return proxy;
}
PRIMITIVE(create) {
  ARGS(UartResourceGroup, group, int, tx, int, rx, int, rts, int, cts,
       int, baud, int, bits, int, stop, int, parity, int, options, int, mode);
  if (baud <= 0 || bits < 5 || bits > 8 || stop < 1 || stop > 3 || parity < 1 || parity > 3 ||
      options < 0 || (options & ~24) || mode != 0 || (tx == -1 && rx == -1) ||
      ((rts == -1) != (cts == -1))) FAIL(INVALID_ARGUMENT);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  auto resource = _new UartResource(group, options & 16 ? 16384 : 4096);
  if (!resource) FAIL(MALLOC_FAILED);
  group->register_resource(resource);
  AutoUnregisteringResource<UartResource> cleanup(group, resource);
  if (!resource->allocated()) FAIL(MALLOC_FAILED);
  int encoded[] = {tx, rx, rts, cts};
  int decoded[4];
  for (int i = 0; i < 4; i++) {
    int result = resource->pins.add(encoded[i], &decoded[i]);
    if (result == -EBUSY) FAIL(ALREADY_IN_USE);
    if (result == -EPERM) FAIL(PERMISSION_DENIED);
    if (result) FAIL(INVALID_ARGUMENT);
  }
  uart_config config = {};
  config.baudrate = baud;
  config.data_bits = static_cast<uart_config_data_bits>(UART_CFG_DATA_BITS_5 + bits - 5);
  config.stop_bits = stop == 1 ? UART_CFG_STOP_BITS_1 : stop == 2 ? UART_CFG_STOP_BITS_1_5 : UART_CFG_STOP_BITS_2;
  config.parity = parity == 1 ? UART_CFG_PARITY_NONE : parity == 2 ? UART_CFG_PARITY_EVEN : UART_CFG_PARITY_ODD;
  config.flow_ctrl = rts == -1 ? UART_CFG_FLOW_CTRL_NONE : UART_CFG_FLOW_CTRL_RTS_CTS;
  int result = resource->start(decoded[0], decoded[1], decoded[2], decoded[3], config);
  if (result == -EBUSY) FAIL(ALREADY_IN_USE);
  if (result) return Primitive::os_error(-result, process);
  cleanup.set_external_address(proxy);
  return proxy;
}
PRIMITIVE(create_path) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(create_console) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(close) {
  ARGS(UartResourceGroup, group, UartResource, resource);
  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}
PRIMITIVE(get_baud_rate) {
  ARGS(UartResource, resource);
  uart_config config;
  int result = uart_config_get(resource->dev(), &config);
  if (result) return Primitive::os_error(-result, process);
  return Primitive::integer(config.baudrate, process);
}
PRIMITIVE(set_baud_rate) {
  ARGS(UartResource, resource, uint32, baud);
  if (baud == 0) FAIL(INVALID_ARGUMENT);
  int result = resource->set_baud(baud);
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}
PRIMITIVE(write) {
  ARGS(UartResource, resource, Blob, bytes, int, from, int, to, int, break_length);
  if (from < 0 || from > to || to > bytes.length()) FAIL(OUT_OF_RANGE);
  if (break_length != 0) FAIL(UNIMPLEMENTED);
  int count = resource->write(bytes.address() + from, to - from);
  if (count < 0) return Primitive::os_error(-count, process);
  return Smi::from(count);
}
PRIMITIVE(wait_tx) { ARGS(UartResource, resource); return BOOL(resource->tx_idle()); }
PRIMITIVE(read) {
  ARGS(UartResource, resource);
  uint32_t count = resource->available();
  if (!count) return process->null_object();
  ByteArray* bytes = process->allocate_byte_array(count);
  if (!bytes) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes data(bytes);
  resource->read(data.address(), count);
  return bytes;
}
PRIMITIVE(errors) { ARGS(UartResource, resource); return Primitive::integer(resource->errors(), process); }
PRIMITIVE(set_control_flags) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(get_control_flags) { FAIL(UNIMPLEMENTED); }
}  // namespace toit
#endif
