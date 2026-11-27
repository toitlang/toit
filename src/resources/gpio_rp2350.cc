// Copyright (C) 2026 Toit contributors.
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

#ifdef TOIT_RP2350

#include "hardware/gpio.h"

#include "../event_sources/gpio_rp2350.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"

namespace toit {

static const uint32_t kEdgeTriggeredState = 1;
static const uint32_t kLevelInterrupts =
    GPIO_IRQ_LEVEL_LOW | GPIO_IRQ_LEVEL_HIGH;

#if NUM_BANK0_GPIOS == 48
static ResourcePool<int, -1> gpio_pins(
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
    10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
    20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
    30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
    40, 41, 42, 43, 44, 45, 46, 47);
#elif NUM_BANK0_GPIOS == 30
static ResourcePool<int, -1> gpio_pins(
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
    10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
    20, 21, 22, 23, 24, 25, 26, 27, 28, 29);
#else
#error "update the RP2350 GPIO resource pool"
#endif

static bool gpio_is_valid(int pin) {
  return pin >= 0 && pin < static_cast<int>(NUM_BANK0_GPIOS);
}

static bool is_restricted_pin(int pin) {
#ifdef PICO_PSRAM_CS_PIN
  // XIP flash has its own QSPI bank. Boards with a second XIP device use a
  // bank-0 GPIO for CS1; changing that pin can break PSRAM accesses.
  if (pin == PICO_PSRAM_CS_PIN) return true;
#endif
  return false;
}

bool gpio_pool_take(int pin) {
  if (!gpio_is_valid(pin)) return false;
  return gpio_pins.take(pin);
}

static void reset_pin(int pin);

void gpio_pool_put(int pin) {
  reset_pin(pin);
  gpio_pins.put(pin);
}

class GpioResource : public Rp2350GpioEventResource {
 public:
  TAG(GpioResource);

  GpioResource(ResourceGroup* group, int pin)
      : Rp2350GpioEventResource(group, pin)
      , input_(false)
      , output_(false)
      , open_drain_(false)
      , output_value_(0) {}

  bool input() const { return input_; }
  bool output() const { return output_; }
  bool open_drain() const { return open_drain_; }
  int output_value() const { return output_value_; }

  void set_configuration(bool input, bool output, bool open_drain,
                         int output_value) {
    input_ = input;
    output_ = output;
    open_drain_ = open_drain;
    output_value_ = output_value;
  }

  void set_open_drain(bool value) { open_drain_ = value; }
  void set_output_value(int value) { output_value_ = value; }

 private:
  bool input_;
  bool output_;
  bool open_drain_;
  int output_value_;
};

class GpioResourceGroup : public ResourceGroup {
 public:
  TAG(GpioResourceGroup);

  GpioResourceGroup(Process* process, Rp2350GpioEventSource* event_source)
      : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    USE(resource);
    USE(data);
    return state | kEdgeTriggeredState;
  }

  void on_unregister_resource(Resource* resource) override;
};

static void apply_output_mode(GpioResource* resource) {
  int pin = resource->pin();
  if (!resource->output()) {
    gpio_set_dir(pin, GPIO_IN);
    return;
  }

  int value = resource->output_value();
  if (resource->open_drain()) {
    if (value == 0) {
      // The SIO latch is always low in open-drain mode. Direction selects
      // between driving low and releasing the line.
      gpio_put(pin, 0);
      gpio_set_dir(pin, GPIO_OUT);
    } else {
      // Release before changing the latch, avoiding a low pulse when a
      // push-pull high output changes to open drain.
      gpio_set_dir(pin, GPIO_IN);
      gpio_put(pin, 0);
    }
  } else {
    // Set the latch before enabling the output to avoid an opposite-level
    // pulse when changing from input to output.
    gpio_put(pin, value);
    gpio_set_dir(pin, GPIO_OUT);
  }
}

static void reset_pin(int pin) {
  gpio_set_irq_enabled(pin, kLevelInterrupts, false);
  gpio_set_dir(pin, GPIO_IN);
  // Peripheral users such as UART can apply signal inversion through the
  // GPIO override fields. Reset every override before returning the pin to
  // the shared pool so the next owner sees normal SIO semantics.
  gpio_set_inover(pin, GPIO_OVERRIDE_NORMAL);
  gpio_set_outover(pin, GPIO_OVERRIDE_NORMAL);
  gpio_set_oeover(pin, GPIO_OVERRIDE_NORMAL);
  gpio_set_irqover(pin, GPIO_OVERRIDE_NORMAL);
  gpio_disable_pulls(pin);
  gpio_set_input_enabled(pin, false);
  gpio_put(pin, 0);
  gpio_deinit(pin);
}

void GpioResourceGroup::on_unregister_resource(Resource* resource) {
  int pin = static_cast<GpioResource*>(resource)->pin();
  gpio_pool_put(pin);
}

MODULE_IMPLEMENTATION(gpio, MODULE_GPIO)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  Rp2350GpioEventSource* event_source = Rp2350GpioEventSource::instance();
  if (event_source == null) FAIL(ALREADY_CLOSED);

  GpioResourceGroup* group = _new GpioResourceGroup(process, event_source);
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(use) {
  ARGS(GpioResourceGroup, group, int, pin, bool, allow_restricted);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  if (!gpio_is_valid(pin)) FAIL(OUT_OF_RANGE);
  if (!allow_restricted && is_restricted_pin(pin)) FAIL(PERMISSION_DENIED);
  if (!gpio_pool_take(pin)) FAIL(ALREADY_IN_USE);

  GpioResource* resource = _new GpioResource(group, pin);
  if (resource == null) {
    gpio_pool_put(pin);
    FAIL(MALLOC_FAILED);
  }

  // gpio_init starts in high impedance with a cleared output latch and selects
  // SIO. No physical level is driven before config chooses an output mode.
  gpio_init(pin);
  gpio_disable_pulls(pin);
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

  if (pull_up && pull_down) FAIL(INVALID_ARGUMENT);
  if (value < -1 || value > 1) FAIL(INVALID_ARGUMENT);

  int output_value = value < 0 ? resource->output_value() : value;
  resource->set_configuration(input, output, open_drain, output_value);

  int pin = resource->pin();
  gpio_set_irq_enabled(pin, kLevelInterrupts, false);
  gpio_set_pulls(pin, pull_up, pull_down);
  gpio_set_input_enabled(pin, input);
  apply_output_mode(resource);
  return process->null_object();
}

PRIMITIVE(config_interrupt) {
  ARGS(GpioResource, resource, bool, enable, int, value);
  if (value != 0 && value != 1) FAIL(INVALID_ARGUMENT);

  uint32_t timestamp = Rp2350GpioEventSource::arm_timestamp();
  int pin = resource->pin();
  gpio_set_irq_enabled(pin, kLevelInterrupts, false);
  if (enable) {
    uint32_t level = value ? GPIO_IRQ_LEVEL_HIGH : GPIO_IRQ_LEVEL_LOW;
    gpio_set_irq_enabled(pin, level, true);
  }
  return Smi::from(timestamp & 0x3fffffff);
}

PRIMITIVE(last_edge_trigger_timestamp) {
  ARGS(GpioResource, resource);
  uint32_t timestamp =
      Rp2350GpioEventSource::last_timestamp(resource->pin());
  return Smi::from(timestamp & 0x3fffffff);
}

PRIMITIVE(get) {
  ARGS(GpioResource, resource);
  return Smi::from(gpio_get(resource->pin()) ? 1 : 0);
}

PRIMITIVE(set) {
  ARGS(GpioResource, resource, int, value);
  if (value != 0 && value != 1) FAIL(INVALID_ARGUMENT);

  resource->set_output_value(value);
  apply_output_mode(resource);
  return process->null_object();
}

PRIMITIVE(set_open_drain) {
  ARGS(GpioResource, resource, bool, value);
  if (resource->open_drain() == value) return process->null_object();

  resource->set_open_drain(value);
  apply_output_mode(resource);
  return process->null_object();
}

PRIMITIVE(set_pull) {
  ARGS(GpioResource, resource, int, value);
  if (value < -1 || value > 1) FAIL(INVALID_ARGUMENT);

  gpio_set_pulls(resource->pin(), value > 0, value < 0);
  return process->null_object();
}

}  // namespace toit

#endif  // TOIT_RP2350
