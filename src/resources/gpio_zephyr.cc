// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "../top.h"
#ifdef TOIT_ZEPHYR
#include "../event_sources/zephyr.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "pins_zephyr.h"
#include <zephyr/drivers/gpio.h>

namespace toit {
static uint32_t edge_sequence = 0;
static const uint32_t sequence_mask = 0x3fffffff;

class GpioResource : public ZephyrResource {
 public:
  TAG(GpioResource);
  GpioResource(ResourceGroup* group, int num)
      : ZephyrResource(group), num_(num), port_(zephyr_gpio_port(num)) {
    callback_.owner = this;
    gpio_init_callback(&callback_.callback, interrupt, BIT(pin()));
  }
  ~GpioResource() {
    // This backend currently runs on one core. Removing the callback after
    // disabling the interrupt guarantees it cannot race resource deletion.
    gpio_pin_interrupt_configure(port_, pin(), GPIO_INT_DISABLE);
    gpio_remove_callback(port_, &callback_.callback);
    zephyr_pin_release(num_);
  }
  int init() { return gpio_add_callback(port_, &callback_.callback); }
  const device* port() const { return port_; }
  int pin() const { return num_ % 32; }
  uint32_t last_edge() const {
    unsigned key = irq_lock();
    uint32_t result = last_edge_;
    irq_unlock(key);
    return result;
  }
  int configure(gpio_flags_t flags) {
    if (listeners_ && !(flags & GPIO_INPUT)) return -EBUSY;
    int before = listeners_ ? gpio_pin_get_raw(port_, pin()) : -1;
    int result = gpio_pin_configure(port_, pin(), flags);
    if (listeners_) {
      int interrupt_result = gpio_pin_interrupt_configure(port_, pin(), GPIO_INT_EDGE_BOTH);
      if (!result) result = interrupt_result;
      if (before >= 0 && gpio_pin_get_raw(port_, pin()) != before) record_edge();
    }
    return result;
  }
  int configure_interrupt(bool enable, uint32_t* timestamp) {
    unsigned key = irq_lock();
    *timestamp = ++edge_sequence & sequence_mask;
    irq_unlock(key);
    if (enable) {
      gpio_flags_t flags;
      int result = gpio_pin_get_config(port_, pin(), &flags);
      if (result) return result;
      if (!(flags & GPIO_INPUT)) return -EINVAL;
      if (listeners_ == 0) {
        result = gpio_pin_interrupt_configure(port_, pin(), GPIO_INT_EDGE_BOTH);
        if (result) return result;
      }
      listeners_++;
    } else {
      if (listeners_ <= 0) return -EINVAL;
      if (listeners_ == 1) {
        int result = gpio_pin_interrupt_configure(port_, pin(), GPIO_INT_DISABLE);
        if (result) return result;
      }
      listeners_--;
    }
    return 0;
  }
 private:
  struct Callback {
    struct gpio_callback callback;
    GpioResource* owner;
  } callback_;
  static void interrupt(const device*, struct gpio_callback* callback, gpio_port_pins_t) {
    CONTAINER_OF(callback, Callback, callback)->owner->record_edge();
  }
  void record_edge() {
    unsigned key = irq_lock();
    last_edge_ = ++edge_sequence & sequence_mask;
    irq_unlock(key);
    notify(1);
  }
  int num_;
  const device* port_;
  int listeners_ = 0;
  uint32_t last_edge_ = sequence_mask;
};
class GpioResourceGroup : public ResourceGroup {
 public:
  TAG(GpioResourceGroup);
  explicit GpioResourceGroup(Process* process)
      : ResourceGroup(process, ZephyrEventSource::instance()) {}
  uint32_t on_event(Resource*, word data, uint32_t state) override { return state | data; }
};

MODULE_IMPLEMENTATION(gpio, MODULE_GPIO)
PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  auto group = _new GpioResourceGroup(process);
  if (group == null) FAIL(MALLOC_FAILED);
  proxy->set_external_address(group);
  return proxy;
}
PRIMITIVE(use) {
  ARGS(GpioResourceGroup, group, int, num, bool, allow_restricted);
  if (zephyr_gpio_port(num) == null) FAIL(INVALID_ARGUMENT);
  if (!allow_restricted && zephyr_pin_is_restricted(num)) FAIL(PERMISSION_DENIED);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  int result = zephyr_pin_claim(num);
  if (result == -EBUSY) FAIL(ALREADY_IN_USE);
  if (result) return Primitive::os_error(-result, process);
  auto resource = _new GpioResource(group, num);
  if (resource == null) { zephyr_pin_release(num); FAIL(MALLOC_FAILED); }
  result = resource->init();
  if (result) { delete resource; return Primitive::os_error(-result, process); }
  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}
PRIMITIVE(unuse) {
  ARGS(GpioResourceGroup, group, GpioResource, resource);
  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}
PRIMITIVE(config) {
  ARGS(GpioResource, resource, bool, pull_up, bool, pull_down, bool, input,
       bool, output, bool, open_drain, int, value);
  if (value < -1 || value > 1 || (pull_up && pull_down)) FAIL(INVALID_ARGUMENT);
  gpio_flags_t flags = (input ? GPIO_INPUT : 0) | (output ? GPIO_OUTPUT : 0) |
      (pull_up ? GPIO_PULL_UP : 0) | (pull_down ? GPIO_PULL_DOWN : 0) |
      (open_drain ? GPIO_OPEN_DRAIN : 0);
  if (output && value >= 0) flags |= value ? GPIO_OUTPUT_INIT_HIGH : GPIO_OUTPUT_INIT_LOW;
  int result = resource->configure(flags);
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}
PRIMITIVE(config_interrupt) {
  ARGS(GpioResource, resource, bool, enable, int, value);
  USE(value);  // Both edges are required by gpio.Pin.wait-for.
  uint32_t timestamp;
  int result = resource->configure_interrupt(enable, &timestamp);
  if (result) return Primitive::os_error(-result, process);
  return Smi::from(timestamp);
}
PRIMITIVE(last_edge_trigger_timestamp) {
  ARGS(GpioResource, resource);
  return Smi::from(resource->last_edge());
}
PRIMITIVE(get) {
  ARGS(GpioResource, resource);
  int value = gpio_pin_get_raw(resource->port(), resource->pin());
  if (value < 0) return Primitive::os_error(-value, process);
  return Smi::from(value);
}
PRIMITIVE(set) {
  ARGS(GpioResource, resource, int, value);
  if (value != 0 && value != 1) FAIL(INVALID_ARGUMENT);
  int result = gpio_pin_set_raw(resource->port(), resource->pin(), value);
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}
PRIMITIVE(set_pull) {
  ARGS(GpioResource, resource, int, direction);
  if (direction < -1 || direction > 1) FAIL(INVALID_ARGUMENT);
  gpio_flags_t flags;
  int result = gpio_pin_get_config(resource->port(), resource->pin(), &flags);
  if (result) return Primitive::os_error(-result, process);
  flags &= ~(GPIO_PULL_UP | GPIO_PULL_DOWN);
  if (direction) flags |= direction > 0 ? GPIO_PULL_UP : GPIO_PULL_DOWN;
  result = resource->configure(flags);
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}
PRIMITIVE(set_open_drain) {
  ARGS(GpioResource, resource, bool, enable);
  gpio_flags_t flags;
  int result = gpio_pin_get_config(resource->port(), resource->pin(), &flags);
  if (result) return Primitive::os_error(-result, process);
  flags &= ~(GPIO_SINGLE_ENDED | GPIO_LINE_OPEN_DRAIN);
  if (enable) flags |= GPIO_OPEN_DRAIN;
  result = resource->configure(flags);
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}
}  // namespace toit
#endif
