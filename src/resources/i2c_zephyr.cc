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
#include <zephyr/drivers/i2c.h>
#include <zephyr/drivers/pinctrl.h>
#include <zephyr/pm/device.h>
#include <zephyr/dt-bindings/pinctrl/nrf-pinctrl.h>

#define TOIT_PLATFORM DT_COMPAT_GET_ANY_STATUS_OKAY(toit_platform)
#define DECLARE_I2C(node, prop, i) PINCTRL_DT_DEV_CONFIG_DECLARE(DT_PHANDLE_BY_IDX(node, prop, i));
DT_FOREACH_PROP_ELEM(TOIT_PLATFORM, i2c_ports, DECLARE_I2C)

namespace toit {
struct I2cController {
  I2cController(const device* d, pinctrl_dev_config* p) : dev(d), config(p) {}
  const device* dev;
  pinctrl_dev_config* config;
  bool claimed = false, broken = false;
  pinctrl_soc_pin_t active[2], sleep[2];
  pinctrl_state states[2];

  int map(int sda, int scl, bool pullup) {
    const int pins[] = {sda, scl};
    const uint32_t functions[] = {NRF_FUN_TWIM_SDA, NRF_FUN_TWIM_SCL};
    for (int i = 0; i < 2; i++) {
      active[i] = (functions[i] << NRF_FUN_POS) | pins[i];
      sleep[i] = active[i] | BIT(NRF_LP_POS);
      if (pullup) active[i] |= NRF_PULL_UP << NRF_PULL_POS;
    }
    states[0] = {active, 2, PINCTRL_STATE_DEFAULT};
    states[1] = {sleep, 2, PINCTRL_STATE_SLEEP};
    return pinctrl_update_states(config, states, 2);
  }
};
#define I2C_CONTROLLER(node, prop, i) {DEVICE_DT_GET(DT_PHANDLE_BY_IDX(node, prop, i)), PINCTRL_DT_DEV_CONFIG_GET(DT_PHANDLE_BY_IDX(node, prop, i))},
static I2cController controllers[] = {
  DT_FOREACH_PROP_ELEM(TOIT_PLATFORM, i2c_ports, I2C_CONTROLLER)
};
static I2cController* claim_controller() {
  Locker locker(OS::global_mutex());
  for (auto& controller : controllers) {
    if (!controller.claimed && !controller.broken) { controller.claimed = true; return &controller; }
  }
  return null;
}

class I2cDeviceResource;

// Zephyr's Nordic I2C API blocks until the IRQ completes the transfer. A
// dedicated worker keeps the VM runnable while owning all DMA buffers until
// completion. Cancellation waits for driver retirement before freeing them.
class I2cBusResource : public ZephyrResource, public Thread {
 public:
  TAG(I2cBusResource);
  explicit I2cBusResource(ResourceGroup* group) : ZephyrResource(group), Thread("I2C") {
    k_sem_init(&request_, 0, 1);
    k_sem_init(&finished_, 0, 1);
  }
  ~I2cBusResource() override {
    ASSERT(device_count_ == 0);
    abort();
    if (thread_started_) {
      stopping_.store(true);
      k_sem_give(&request_);
      join();
    }
    if (powered_) {
      int result = pm_device_action_run(controller_->dev, PM_DEVICE_ACTION_SUSPEND);
      if (result) FATAL("I2C suspend failed: %d", result);
    }
    pins.release();
    if (controller_) {
      Locker locker(OS::global_mutex());
      controller_->claimed = false;
    }
  }
  int open(int sda, int scl, bool pullup) {
    controller_ = claim_controller();
    if (!controller_) return -EBUSY;
    int result = controller_->map(sda, scl, pullup);
    if (result) return result;
    if (!device_is_ready(controller_->dev)) {
      result = device_init(controller_->dev);
      if (result) { controller_->broken = true; return result; }
    } else {
      result = pm_device_action_run(controller_->dev, PM_DEVICE_ACTION_RESUME);
      if (result) return result;
    }
    powered_ = true;
    if (!spawn()) return -ENOMEM;
    thread_started_ = true;
    return 0;
  }
  int start(I2cDeviceResource* owner, int address, int speed, const uint8_t* tx, int tx_length, int rx_length) {
    Locker locker(resource_group()->event_source()->mutex());
    if (active_job_) return -EBUSY;
    // A non-null TX buffer is also used for address-only probes.
    int tx_size = Utils::max(1, tx_length);
    buffer_ = static_cast<uint8_t*>(malloc(tx_size + rx_length));
    if (!buffer_) return -ENOMEM;
    if (tx_length) memcpy(buffer_, tx, tx_length);
    rx_ = buffer_ + tx_size;
    tx_length_ = tx_length;
    rx_length_ = rx_length;
    owner_ = owner;
    address_ = address;
    speed_ = speed;
    done_.store(false);
    take_pending();
    active_job_ = true;
    k_sem_give(&request_);
    return 0;
  }
  void abort() {
    // Job ownership changes only on the VM thread. Wait without holding the
    // shared event-source lock, so other peripherals can still dispatch IRQs.
    if (!active_job_) return;
    k_sem_take(&finished_, K_FOREVER);
    Locker locker(resource_group()->event_source()->mutex());
    retire_locked();
  }
  bool completed() const { return active_job_ && done_.load(); }
  bool belongs_to(I2cDeviceResource* owner) const { return active_job_ && owner_ == owner; }
  int rx_length() const { return rx_length_; }
  int finish_locked(uint8_t* output) {
    ASSERT(completed());
    int result = result_;
    if (result == 0 && output && rx_length_) memcpy(output, rx_, rx_length_);
    k_sem_take(&finished_, K_FOREVER);
    retire_locked();
    return result;
  }
  int device_count() const { return device_count_; }
  void retain_device() { device_count_++; }
  void release_device() { ASSERT(device_count_ > 0); device_count_--; }
  ZephyrPins pins;
 private:
  void retire_locked() {
    // finished_ follows notify, so no old completion can be published after
    // pending flags are cleared or the next job has been submitted.
    active_job_ = false;
    done_.store(false);
    take_pending();
    free(buffer_);
    buffer_ = rx_ = null;
    owner_ = null;
  }
  void entry() override {
    for (;;) {
      k_sem_take(&request_, K_FOREVER);
      if (stopping_.load()) return;
      int result = i2c_configure(controller_->dev, I2C_MODE_CONTROLLER | I2C_SPEED_SET(speed_));
      if (!result) {
        i2c_msg messages[2] = {};
        int count = 0;
        if (tx_length_ || !rx_length_) {
          messages[count++] = {buffer_, static_cast<uint32_t>(tx_length_),
              static_cast<uint8_t>(rx_length_ ? I2C_MSG_WRITE : I2C_MSG_WRITE | I2C_MSG_STOP)};
        }
        if (rx_length_) {
          messages[count] = {rx_, static_cast<uint32_t>(rx_length_),
              static_cast<uint8_t>(I2C_MSG_READ | I2C_MSG_STOP | (count ? I2C_MSG_RESTART : 0))};
          count++;
        }
        result = i2c_transfer(controller_->dev, messages, count, address_);
      }
      result_ = result;
      done_.store(true);
      notify(1);
      k_sem_give(&finished_);
    }
  }
  I2cController* controller_ = null;
  I2cDeviceResource* owner_ = null;
  bool powered_ = false, thread_started_ = false, active_job_ = false;
  std::atomic<bool> stopping_{false}, done_{false};
  k_sem request_, finished_;
  uint8_t* buffer_ = null;
  uint8_t* rx_ = null;
  int tx_length_ = 0, rx_length_ = 0, address_ = 0, speed_ = 0, result_ = 0;
  int device_count_ = 0;
};

class I2cDeviceResource : public ZephyrResource {
 public:
  TAG(I2cDeviceResource);
  I2cDeviceResource(ResourceGroup* group, I2cBusResource* bus, int address, int speed)
      : ZephyrResource(group), bus_(bus), address_(address), speed_(speed) { bus_->retain_device(); }
  ~I2cDeviceResource() override {
    if (bus_->belongs_to(this)) bus_->abort();
    bus_->release_device();
  }
  I2cBusResource* bus() const { return bus_; }
  int address() const { return address_; }
  int speed() const { return speed_; }
 private:
  I2cBusResource* bus_;
  int address_, speed_;
};
class I2cResourceGroup : public ResourceGroup {
 public:
  TAG(I2cResourceGroup);
  explicit I2cResourceGroup(Process* process) : ResourceGroup(process, ZephyrEventSource::instance()) {}
  uint32_t on_event(Resource* resource, word, uint32_t state) override {
    // Only buses publish events; device resources are synchronous metadata.
    return static_cast<I2cBusResource*>(resource)->completed() ? state | 1 : state;
  }
};

MODULE_IMPLEMENTATION(i2c, MODULE_I2C)
PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  auto group = _new I2cResourceGroup(process);
  if (!group) FAIL(MALLOC_FAILED);
  proxy->set_external_address(group);
  return proxy;
}
PRIMITIVE(bus_create) {
  ARGS(I2cResourceGroup, group, int, sda, int, scl, bool, pullup);
  if (sda == -1 || scl == -1) FAIL(INVALID_ARGUMENT);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  auto bus = _new I2cBusResource(group);
  if (!bus) FAIL(MALLOC_FAILED);
  group->register_resource(bus);
  AutoUnregisteringResource<I2cBusResource> cleanup(group, bus);
  int decoded[2];
  int encoded[] = {sda, scl};
  for (int i = 0; i < 2; i++) {
    int result = bus->pins.add(encoded[i], &decoded[i]);
    if (result == -EBUSY) FAIL(ALREADY_IN_USE);
    if (result == -EPERM) FAIL(PERMISSION_DENIED);
    if (result) FAIL(INVALID_ARGUMENT);
  }
  int result = bus->open(decoded[0], decoded[1], pullup);
  if (result == -EBUSY) FAIL(ALREADY_IN_USE);
  if (result == -ENOMEM) FAIL(MALLOC_FAILED);
  if (result) return Primitive::os_error(-result, process);
  cleanup.set_external_address(proxy);
  return proxy;
}
PRIMITIVE(bus_close) {
  ARGS(I2cBusResource, bus);
  if (bus->device_count()) FAIL(ALREADY_IN_USE);
  bus->resource_group()->unregister_resource(bus);
  bus_proxy->clear_external_address();
  return process->null_object();
}
PRIMITIVE(bus_probe) {
  ARGS(I2cBusResource, bus, uint16, address, int, timeout_ms);
  if (address > 127 || timeout_ms <= 0) FAIL(INVALID_ARGUMENT);
  // The Toit library bounds its wait with timeout_ms. The blocking driver has
  // a separate build-time timeout; abort retires it before freeing buffers.
  int result = bus->start(null, address, I2C_SPEED_STANDARD, null, 0, 0);
  if (result == -EBUSY) FAIL(ALREADY_IN_USE);
  if (result == -ENOMEM) FAIL(MALLOC_FAILED);
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}
PRIMITIVE(bus_probe_finish) {
  ARGS(I2cBusResource, bus);
  Locker locker(bus->resource_group()->event_source()->mutex());
  if (!bus->belongs_to(null) || !bus->completed()) FAIL(INVALID_STATE);
  return BOOL(bus->finish_locked(null) == 0);
}
PRIMITIVE(bus_abort_controller_operation) {
  ARGS(I2cBusResource, bus);
  bus->abort();
  return process->null_object();
}
PRIMITIVE(device_create) {
  ARGS(I2cBusResource, bus, int, address_bits, uint16, address, uint32, frequency,
       uint32, timeout_us, bool, disable_ack_check);
  if (address_bits != 7 || address > 127 || disable_ack_check) FAIL(INVALID_ARGUMENT);
  if (timeout_us) FAIL(UNIMPLEMENTED);
  if (frequency != 100000 && frequency != 400000) FAIL(INVALID_ARGUMENT);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  auto device = _new I2cDeviceResource(bus->resource_group(), bus, address,
      frequency == 100000 ? I2C_SPEED_STANDARD : I2C_SPEED_FAST);
  if (!device) FAIL(MALLOC_FAILED);
  bus->resource_group()->register_resource(device);
  proxy->set_external_address(device);
  return proxy;
}
PRIMITIVE(device_close) {
  ARGS(I2cDeviceResource, device);
  device->resource_group()->unregister_resource(device);
  device_proxy->clear_external_address();
  return process->null_object();
}
PRIMITIVE(device_transfer_start) {
  ARGS(I2cDeviceResource, device, Blob, tx, int, rx_length);
  if (rx_length < 0 || rx_length > 65535 || tx.length() > 65535) FAIL(OUT_OF_RANGE);
  if (!rx_length && !tx.length()) FAIL(INVALID_ARGUMENT);
  int result = device->bus()->start(device, device->address(), device->speed(), tx.address(), tx.length(), rx_length);
  if (result == -EBUSY) FAIL(ALREADY_IN_USE);
  if (result == -ENOMEM) FAIL(MALLOC_FAILED);
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}
PRIMITIVE(device_transfer_finish) {
  ARGS(I2cDeviceResource, device, MutableBlob, output, int, length);
  auto bus = device->bus();
  Locker locker(bus->resource_group()->event_source()->mutex());
  if (!bus->belongs_to(device) || !bus->completed()) FAIL(INVALID_STATE);
  if (length < bus->rx_length() || length > output.length()) FAIL(OUT_OF_BOUNDS);
  int result = bus->finish_locked(output.address());
  // The pinned Nordic driver maps address/data NACK events to -EIO.
  return Smi::from(result == 0 ? 0 : result == -EIO ? 1 : result == -ETIMEDOUT ? 2 : 3);
}
PRIMITIVE(target_init) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(target_create) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(target_close) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(target_receive) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(target_write) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(target_set_write_pending) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(target_set_handler_mode) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(target_take_request_count) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(target_dropped_receive_count) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(register_target_create) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(register_target_close) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(register_target_get) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(register_target_set) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(register_target_read) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(register_target_write) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(register_target_dropped_write_count) { FAIL(UNIMPLEMENTED); }
}  // namespace toit
#endif
