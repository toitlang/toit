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
#include "pad_table_ec618.h"

extern "C" {
  #include "driver_gpio.h"
  #include "gpio.h"
  #include "ic.h"
}

namespace toit {

// Pin numbers from Toit are PAD indices on the EC618. Each PAD has its
// own iomux configuration; multiple PADs may share a GPIO controller bit
// (e.g. PAD22 and PAD26 are both GPIO11). Plain-GPIO read/write goes
// through the controller bit, while iomux affects the physical pad.

// GPIO controller bit decomposition: port = bit / 16, index = bit % 16.
static uint32_t to_port(int gpio_bit) { return gpio_bit >> 4; }
static uint16_t to_pin_index(int gpio_bit) { return gpio_bit & 0xf; }
static uint16_t to_pin_mask(int gpio_bit) { return 1 << (gpio_bit & 0xf); }

// Applies (or clears) a pad's pull resistor. On the EC618 a pull is a pad-level
// property set through GPIO_PullConfig(pad, enable, is_up); calling it also
// turns off the iomux "auto pull", so our explicit choice wins. At most one of
// pull_up/pull_down is set (the Toit gpio library enforces it).
static void apply_pull(int pad, bool pull_up, bool pull_down) {
  if (pull_up) {
    GPIO_PullConfig(pad, 1, 1);
  } else if (pull_down) {
    GPIO_PullConfig(pad, 1, 0);
  } else {
    GPIO_PullConfig(pad, 0, 0);
  }
}

class GpioResource : public EventResource {
 public:
  TAG(GpioResource);
  GpioResource(ResourceGroup* group, int pad, int gpio_bit)
    : EventResource(group, Event::gpio_type(gpio_bit))
    , pad_(pad)
    , gpio_bit_(gpio_bit) {}

  int pad() const { return pad_; }
  int gpio_bit() const { return gpio_bit_; }

 private:
  int pad_;
  int gpio_bit_;
};

// Matches GPIO-STATE-EDGE-TRIGGERED_ in lib/gpio/gpio.toit.
static const uint32_t kEdgeTriggeredState = 1;

// The wait-for protocol: the gpio library treats the values returned by
// the config_interrupt and last_edge_trigger_timestamp primitives as
// timestamps from ONE clock — an interrupt only counts if it happened at
// or after the arming. There is no convenient hardware timestamp here, so
// both sides share a global trigger sequence number: arming captures it,
// the ISR advances it and records it per GPIO bit.
static volatile uint32_t edge_sequence = 0;
static volatile uint32_t last_edge_seq[32] = {};

class GpioResourceGroup : public ResourceGroup {
 public:
  TAG(GpioResourceGroup);
  explicit GpioResourceGroup(Process* process, EventSource* event_source)
    : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* r, word data, uint32_t state) override {
    USE(r);
    USE(data);
    return state | kEdgeTriggeredState;
  }
};

// GPIO ISR handler — dispatches events for all triggered pins.
static void gpio_isr_handler() {
  for (uint32_t port = 0; port < 2; port++) {
    uint16_t flags = GPIO_getInterruptFlags(port);
    if (flags == 0) continue;
    for (int bit = 0; bit < 16; bit++) {
      if (flags & (1 << bit)) {
        int gpio_bit = (port << 4) | bit;
        // Disable further interrupts on this pin (level-triggered would
        // re-trigger immediately otherwise). The next wait-for re-arms.
        GPIO_interruptConfig(port, bit, GPIO_INTERRUPT_DISABLED);
        uint32_t seq = ++edge_sequence;
        last_edge_seq[gpio_bit] = seq;
        Ec618EventSource::send_event_from_isr(
            Event::gpio_type(gpio_bit), seq);
      }
    }
    GPIO_clearInterruptFlags(port, flags);
  }
}

// The EC618 GPIO controller has no native open-drain (the pad/iomux has
// no open-drain bit). Open-drain is emulated by making the pin DIRECTION
// track the value: output-low for 0, input/high-Z for 1 (an internal or
// external pull-up supplies the high level). Which pads are in that mode
// is pad-level state, because `set` only receives the pad number.
static uint64_t open_drain_pads = 0;

static bool is_open_drain(int pad) {
  return (open_drain_pads >> pad) & 1;
}

// Applies an emulated open-drain level: 0 drives, anything else releases.
static void apply_open_drain_level(int gpio_bit, int value) {
  GpioPinConfig_t config;
  memset(&config, 0, sizeof(config));
  if (value == 0) {
    config.pinDirection = GPIO_DIRECTION_OUTPUT;
    config.misc.initOutput = 0;
  } else {
    config.pinDirection = GPIO_DIRECTION_INPUT;
  }
  GPIO_pinConfig(to_port(gpio_bit), to_pin_index(gpio_bit), &config);
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

  Ec618EventSource* event_source = Ec618EventSource::instance();
  if (event_source == null) FAIL(ALREADY_CLOSED);

  GpioResourceGroup* group = _new GpioResourceGroup(process, event_source);
  if (group == null) FAIL(MALLOC_FAILED);

  ensure_isr();

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(use) {
  ARGS(GpioResourceGroup, group, int, pad, bool, allow_restricted);
  USE(allow_restricted);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  if (pad <= 0 || pad > kMaxPadIndex) FAIL(OUT_OF_RANGE);
  int gpio_bit = pad_to_gpio(pad);
  if (gpio_bit < 0) FAIL(INVALID_ARGUMENT);

  GpioResource* resource = _new GpioResource(group, pad, gpio_bit);
  if (resource == null) FAIL(MALLOC_FAILED);

  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(unuse) {
  ARGS(GpioResourceGroup, group, GpioResource, resource);
  int gpio_bit = resource->gpio_bit();
  open_drain_pads &= ~(1ULL << resource->pad());
  GPIO_interruptConfig(to_port(gpio_bit), to_pin_index(gpio_bit), GPIO_INTERRUPT_DISABLED);
  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(config) {
  ARGS(int, pad, bool, pull_up, bool, pull_down, bool, input,
       bool, output, bool, open_drain, int, value);

  if (pad <= 0 || pad > kMaxPadIndex) FAIL(OUT_OF_RANGE);
  int gpio_bit = pad_to_gpio(pad);
  if (gpio_bit < 0) FAIL(INVALID_ARGUMENT);

  // Switch the pad's iomux to plain-GPIO (function 0). Without this, the pad
  // would stay in whatever role a previous peripheral left it in, and the
  // controller bit's reads/writes would have no effect on the wire. Enable the
  // pad input buffer for input pins so reads see the live pad level (without it
  // the read path is disconnected from the pin). Open-drain pins get it too:
  // `get` on an open-drain pin must read the WIRE (someone else may be pulling
  // it low). AutoPull off — we set the pull explicitly below, and
  // GPIO_PullConfig overrides the iomux auto-pull anyway.
  GPIO_IomuxEC618(pad, 0, 0, (input || open_drain) ? 1 : 0);

  if (open_drain) {
    open_drain_pads |= 1ULL << pad;
    apply_open_drain_level(gpio_bit, (value == -1) ? 0 : value);
  } else {
    open_drain_pads &= ~(1ULL << pad);
    GpioPinConfig_t config;
    memset(&config, 0, sizeof(config));
    if (output) {
      config.pinDirection = GPIO_DIRECTION_OUTPUT;
      config.misc.initOutput = (value == -1) ? 0 : value;
    } else {
      config.pinDirection = GPIO_DIRECTION_INPUT;
    }
    GPIO_pinConfig(to_port(gpio_bit), to_pin_index(gpio_bit), &config);
  }

  apply_pull(pad, pull_up, pull_down);

  return process->null_object();
}

PRIMITIVE(get) {
  ARGS(int, pad);
  if (pad <= 0 || pad > kMaxPadIndex) FAIL(OUT_OF_RANGE);
  int gpio_bit = pad_to_gpio(pad);
  if (gpio_bit < 0) FAIL(INVALID_ARGUMENT);
  return Smi::from(GPIO_pinRead(to_port(gpio_bit), to_pin_index(gpio_bit)) ? 1 : 0);
}

PRIMITIVE(set) {
  ARGS(int, pad, int, value);
  if (pad <= 0 || pad > kMaxPadIndex) FAIL(OUT_OF_RANGE);
  int gpio_bit = pad_to_gpio(pad);
  if (gpio_bit < 0) FAIL(INVALID_ARGUMENT);
  if (is_open_drain(pad)) {
    apply_open_drain_level(gpio_bit, value);
  } else {
    uint16_t mask = to_pin_mask(gpio_bit);
    GPIO_pinWrite(to_port(gpio_bit), mask, value ? mask : 0);
  }
  return process->null_object();
}

PRIMITIVE(config_interrupt) {
  ARGS(GpioResource, resource, bool, enable, int, value);
  int gpio_bit = resource->gpio_bit();
  // Capture the trigger sequence BEFORE arming: an interrupt firing
  // between the arming and the return then still reads as "after".
  uint32_t seq = edge_sequence;
  if (enable) {
    GpioInterruptConfig_e int_config = value
        ? GPIO_INTERRUPT_HIGH_LEVEL
        : GPIO_INTERRUPT_LOW_LEVEL;
    GPIO_interruptConfig(to_port(gpio_bit), to_pin_index(gpio_bit), int_config);
  } else {
    GPIO_interruptConfig(to_port(gpio_bit), to_pin_index(gpio_bit), GPIO_INTERRUPT_DISABLED);
  }
  return Smi::from(seq & 0x3FFFFFFF);
}

PRIMITIVE(last_edge_trigger_timestamp) {
  ARGS(GpioResource, resource);
  return Smi::from(last_edge_seq[resource->gpio_bit()] & 0x3FFFFFFF);
}

PRIMITIVE(set_open_drain) {
  ARGS(int, pad, bool, value);
  if (pad <= 0 || pad > kMaxPadIndex) FAIL(OUT_OF_RANGE);
  int gpio_bit = pad_to_gpio(pad);
  if (gpio_bit < 0) FAIL(INVALID_ARGUMENT);
  if (value == is_open_drain(pad)) return process->null_object();
  if (value) {
    // Carry the pin's current line level into the emulation (the input
    // buffer must be on before we can trust the read).
    GPIO_IomuxEC618(pad, 0, 0, 1);
    int level = GPIO_pinRead(to_port(gpio_bit), to_pin_index(gpio_bit)) ? 1 : 0;
    open_drain_pads |= 1ULL << pad;
    apply_open_drain_level(gpio_bit, level);
  } else {
    // Back to push-pull, driving the current line level.
    int level = GPIO_pinRead(to_port(gpio_bit), to_pin_index(gpio_bit)) ? 1 : 0;
    open_drain_pads &= ~(1ULL << pad);
    GpioPinConfig_t config;
    memset(&config, 0, sizeof(config));
    config.pinDirection = GPIO_DIRECTION_OUTPUT;
    config.misc.initOutput = level;
    GPIO_pinConfig(to_port(gpio_bit), to_pin_index(gpio_bit), &config);
  }
  return process->null_object();
}

PRIMITIVE(set_pull) {
  ARGS(int, pad, int, value);  // value: 1 pull-up, -1 pull-down, 0 none.
  if (pad <= 0 || pad > kMaxPadIndex) FAIL(OUT_OF_RANGE);
  if (pad_to_gpio(pad) < 0) FAIL(INVALID_ARGUMENT);
  apply_pull(pad, value > 0, value < 0);
  return process->null_object();
}

}  // namespace toit

#endif  // TOIT_EC618
