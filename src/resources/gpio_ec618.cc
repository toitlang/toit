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

#ifdef TOIT_EC618

#include "../event_sources/uart_ec618.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"

extern "C" {
  #include "gpio.h"
  #include "ic.h"
}

namespace toit {

// GPIO port/pin decomposition: port = pin / 16, pin_index = pin % 16.
static uint32_t to_port(int pin) { return pin >> 4; }
static uint16_t to_pin_index(int pin) { return pin & 0xf; }
static uint16_t to_pin_mask(int pin) { return 1 << (pin & 0xf); }

class GpioResource : public EventResource {
 public:
  TAG(GpioResource);
  GpioResource(ResourceGroup* group, int pin)
    : EventResource(group, Event::gpio_type(pin))
    , pin_(pin) {}

  int pin() const { return pin_; }

 private:
  int pin_;
};

class GpioResourceGroup : public ResourceGroup {
 public:
  TAG(GpioResourceGroup);
  explicit GpioResourceGroup(Process* process, EventSource* event_source)
    : ResourceGroup(process, event_source) {}
};

// GPIO ISR handler — dispatches events for all triggered pins.
static void gpio_isr_handler() {
  for (uint32_t port = 0; port < 2; port++) {
    uint16_t flags = GPIO_getInterruptFlags(port);
    if (flags == 0) continue;
    for (int bit = 0; bit < 16; bit++) {
      if (flags & (1 << bit)) {
        int pin = (port << 4) | bit;
        // Disable further interrupts on this pin (level-triggered would
        // re-trigger immediately otherwise).
        GPIO_interruptConfig(port, bit, GPIO_INTERRUPT_DISABLED);
        static uint32_t counter = 0;
        UartQcx216EventSource::send_event_from_isr(
            Event::gpio_type(pin), counter++);
      }
    }
    GPIO_clearInterruptFlags(port, flags);
  }
}

static bool isr_installed = false;

static void ensure_isr() {
  if (isr_installed) return;
  XIC_SetVector(PXIC1_GPIO_IRQn, gpio_isr_handler);
  XIC_EnableIRQ(PXIC1_GPIO_IRQn);
  isr_installed = true;
}

MODULE_IMPLEMENTATION(gpio, MODULE_GPIO)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  UartQcx216EventSource* event_source = UartQcx216EventSource::instance();
  if (event_source == null) FAIL(ALREADY_CLOSED);

  GpioResourceGroup* group = _new GpioResourceGroup(process, event_source);
  if (group == null) FAIL(MALLOC_FAILED);

  ensure_isr();

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(use) {
  ARGS(GpioResourceGroup, group, int, num, bool, allow_restricted);
  USE(allow_restricted);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  if (num < 0 || num > 31) FAIL(OUT_OF_RANGE);

  GpioResource* resource = _new GpioResource(group, num);
  if (resource == null) FAIL(MALLOC_FAILED);

  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(unuse) {
  ARGS(GpioResourceGroup, group, GpioResource, resource);
  int pin = resource->pin();
  GPIO_interruptConfig(to_port(pin), to_pin_index(pin), GPIO_INTERRUPT_DISABLED);
  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(config) {
  ARGS(int, num, bool, pull_up, bool, pull_down, bool, input,
       bool, output, bool, open_drain, int, value);
  USE(pull_up); USE(pull_down); USE(open_drain);

  GpioPinConfig_t config;
  memset(&config, 0, sizeof(config));
  if (output) {
    config.pinDirection = GPIO_DIRECTION_OUTPUT;
    config.misc.initOutput = (value == -1) ? 0 : value;
  } else {
    config.pinDirection = GPIO_DIRECTION_INPUT;
  }
  GPIO_pinConfig(to_port(num), to_pin_index(num), &config);

  return process->null_object();
}

PRIMITIVE(get) {
  ARGS(int, num);
  return Smi::from(GPIO_pinRead(to_port(num), to_pin_index(num)) ? 1 : 0);
}

PRIMITIVE(set) {
  ARGS(int, num, int, value);
  uint16_t mask = to_pin_mask(num);
  GPIO_pinWrite(to_port(num), mask, value ? mask : 0);
  return process->null_object();
}

PRIMITIVE(config_interrupt) {
  ARGS(GpioResource, resource, bool, enable, int, value);
  int pin = resource->pin();
  if (enable) {
    GpioInterruptConfig_e int_config = value
        ? GPIO_INTERRUPT_HIGH_LEVEL
        : GPIO_INTERRUPT_LOW_LEVEL;
    GPIO_interruptConfig(to_port(pin), to_pin_index(pin), int_config);
  } else {
    GPIO_interruptConfig(to_port(pin), to_pin_index(pin), GPIO_INTERRUPT_DISABLED);
  }
  static uint32_t counter = 0;
  return Smi::from((counter++) & 0x3FFFFFFF);
}

PRIMITIVE(last_edge_trigger_timestamp) {
  ARGS(GpioResource, resource);
  USE(resource);
  return Smi::from(0);
}

PRIMITIVE(set_open_drain) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(set_pull) { FAIL(UNIMPLEMENTED); }

}  // namespace toit

#endif  // TOIT_EC618
