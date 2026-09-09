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
#include "../os.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "pad_table_ec618.h"

extern "C" {
  #include "driver_gpio.h"
  #include "gpio.h"
  #include "ic.h"
  #include "pad.h"
  // slpman.h: AON IO LDO power (the AON-domain GPIOs, pads 40..48, are
  // dead until it is on) and wakeup-pad configuration. These calls resolve
  // directly against the selected base.
  #include "slpman.h"
}

namespace toit {

// Pin numbers from Toit are PAD indices on the EC618. Each PAD has its
// own iomux configuration; multiple PADs may share a GPIO controller bit
// (e.g. PAD27 and PAD11 are both GPIO12). Plain-GPIO read/write goes
// through the controller bit, while iomux affects the physical pad.

// Each SDK GPIO instance uses uint16_t masks for its 16 pins.
static const int kPinsPerGpioPort = 16;
static const int kGpioBitCount = GPIO_INSTANCE_NUM * kPinsPerGpioPort;

static uint32_t to_port(int gpio_bit) { return gpio_bit / kPinsPerGpioPort; }
static uint16_t to_pin_index(int gpio_bit) { return gpio_bit % kPinsPerGpioPort; }
static uint16_t to_pin_mask(int gpio_bit) { return 1 << to_pin_index(gpio_bit); }

static bool pad_is_wakeup(int pad);
static void wakeup_pad_set(int pad, bool wakeup_en,
                           bool pull_up, bool pull_down);

// Applies (or clears) a pad's pull resistor. Use the low-level PAD operation for
// an explicit direction: it directly selects the internal resistor while
// clearing the opposite one. The higher-level GPIO_PullConfig helper is kept
// for disabling both during cleanup. At most one of pull_up/pull_down is set
// (the Toit gpio library enforces it).
static void apply_pull(int pad, bool pull_up, bool pull_down) {
  // PAD40..42 are AON wake pads. Their documented programmable pulls live in
  // the wake-pad block, and GPIO reads remain available while that input path
  // is enabled. The ordinary PAD pull has no usable software effect here.
  if (pad_is_wakeup(pad)) {
    wakeup_pad_set(pad, pull_up || pull_down, pull_up, pull_down);
    return;
  }
  if (pull_up) {
    PAD_setPinPullConfig(pad, PAD_INTERNAL_PULL_UP);
  } else if (pull_down) {
    PAD_setPinPullConfig(pad, PAD_INTERNAL_PULL_DOWN);
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
static volatile uint32_t last_edge_seq[kGpioBitCount] = {};

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

  // Runs on both the explicit close (the unuse primitive) and the forced
  // teardown of a killed container — the pin must not keep driving or
  // stay muxed once its resource is gone.
  void on_unregister_resource(Resource* r) override;
};

// GPIO ISR handler — dispatches events for all triggered pins.
static void gpio_isr_handler() {
  for (uint32_t port = 0; port < GPIO_INSTANCE_NUM; port++) {
    uint16_t flags = GPIO_getInterruptFlags(port);
    if (flags == 0) continue;
    for (int bit = 0; bit < kPinsPerGpioPort; bit++) {
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

// A gpio.Pin reserves both its physical PAD and GPIO controller bit. Native
// peripherals reserve only their PADs, so sibling PADs that share a controller
// bit may still serve different peripherals. Two GPIO pins can never alias the
// same direction/data/interrupt registers.
static_assert(kMaxPadIndex == 48, "update the EC618 pad resource pool");
static ResourcePool<int, -1> pads(
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
    11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
    21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
    31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
    41, 42, 43, 44, 45, 46, 47, 48);
static_assert(kGpioBitCount == 32, "update the EC618 GPIO resource pool");
static ResourcePool<int, -1> gpio_bits(
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
    10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
    20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31);
static bool gpio_aon_powered[kMaxPadIndex + 1] = {};
static int aon_power_users = 0;

bool pad_pool_take(int pad) {
  return pads.take(pad);
}

PadGpioLock::PadGpioLock(int first_pad, int second_pad)
  : locker_(OS::global_mutex())
  , available_(false) {
  int first_bit = pad_to_gpio(first_pad);
  if (first_bit < 0 || gpio_bits.is_taken(locker_, first_bit)) return;
  if (second_pad >= 0) {
    int second_bit = pad_to_gpio(second_pad);
    if (second_bit < 0 || gpio_bits.is_taken(locker_, second_bit)) return;
  }
  available_ = true;
}

static bool is_open_drain(int pad) {
  Locker locker(OS::global_mutex());
  return (open_drain_pads >> pad) & 1;
}

static void set_open_drain_state(int pad, bool enabled) {
  Locker locker(OS::global_mutex());
  if (enabled) {
    open_drain_pads |= 1ULL << pad;
  } else {
    open_drain_pads &= ~(1ULL << pad);
  }
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

// Pads 40..42 are the GPIO-muxed wakeup pads (WAKEUP_PAD_3..5; the board
// "AGPIOWU" pins). The wakeup function owns the pad's output path while
// enabled — GPIO writes never reach the wire (reads work; both functions
// see the pad). It is enabled at boot (the wakeup mask idles 0b111111),
// so opening one of these pads as GPIO must release it first.
static bool pad_is_wakeup(int pad) {
  return 40 <= pad && pad <= 42;
}

static void wakeup_pad_set(int pad, bool wakeup_en,
                           bool pull_up, bool pull_down) {
  APmuWakeupPadSettings_t cfg = {};
  cfg.pullUpEn = pull_up;
  cfg.pullDownEn = pull_down;
  slpManSetWakeupPadCfg(
      static_cast<APmuWakeupPad_e>(WAKEUP_PAD_3 + (pad - 40)),
      wakeup_en, &cfg);
}

static void aon_power_acquire_locked() {
  if (aon_power_users++ == 0) {
    slpManAONIOPowerOn();
    slpManAONIOVoltSet(IOVOLT_3_30V);
  }
}

static void aon_power_release_locked() {
  ASSERT(aon_power_users > 0);
  if (--aon_power_users == 0) slpManAONIOPowerOff();
}

void pad_aon_power_acquire() {
  Locker locker(OS::global_mutex());
  aon_power_acquire_locked();
}

void pad_aon_power_release() {
  Locker locker(OS::global_mutex());
  aon_power_release_locked();
}

static void gpio_aon_power_acquire(int pad) {
  if (!pad_is_aon(pad)) return;
  Locker locker(OS::global_mutex());
  if (gpio_aon_powered[pad]) return;
  gpio_aon_powered[pad] = true;
  aon_power_acquire_locked();
}

static void gpio_aon_power_release(int pad) {
  if (!pad_is_aon(pad)) return;
  Locker locker(OS::global_mutex());
  if (!gpio_aon_powered[pad]) return;
  gpio_aon_powered[pad] = false;
  aon_power_release_locked();
}

// See pad_table_ec618.h. Lives here because this is the file with the SDK
// GPIO includes; all pad-muxing drivers (GPIO, I2C, SPI, PWM) share it.
static void pad_release_locked(const Locker& locker, int pad,
                               bool reset_gpio_bit) {
  // Keep both ownership pools stable until every controller-register and mux
  // transition is complete. Otherwise a sibling could claim the shared GPIO
  // bit after the owner check but before this cleanup made the bit an input.
  int gpio_bit = pad_to_gpio(pad);
  if (gpio_bit >= 0) {
    // Do not disturb a sibling that currently owns the shared GPIO bit.
    if (reset_gpio_bit || !gpio_bits.is_taken(locker, gpio_bit)) {
      GPIO_interruptConfig(to_port(gpio_bit), to_pin_index(gpio_bit),
                           GPIO_INTERRUPT_DISABLED);
      GpioPinConfig_t config;
      memset(&config, 0, sizeof(config));
      config.pinDirection = GPIO_DIRECTION_INPUT;
      GPIO_pinConfig(to_port(gpio_bit), to_pin_index(gpio_bit), &config);
    }
    // Disconnect a shared PAD on close so later use of its sibling cannot
    // also reach this physical pin through the same controller bit.
    int mux = pad_gpio_is_shared(pad)
        ? (pad_gpio_mux(pad) == 0 ? 4 : 0)
        : pad_gpio_mux(pad);
    GPIO_IomuxEC618(pad, mux, 0, 0);
  }
  GPIO_PullConfig(pad, 0, 0);
  // Hand the wakeup-capable pads back to wakeup duty in their boot state
  // (wakeup input, pull-up — no wake edges armed).
  if (pad_is_wakeup(pad)) wakeup_pad_set(pad, true, true, false);
}

void pad_reset(int pad) {
  Locker locker(OS::global_mutex());
  pad_release_locked(locker, pad, false);
}

void pad_pool_put(int pad) {
  Locker locker(OS::global_mutex());
  pad_release_locked(locker, pad, false);
  pads.put(locker, pad);
}

void pad_emergency_high(int pad) {
  int gpio_bit = pad_to_gpio(pad);
  if (gpio_bit < 0) return;
  GPIO_IomuxEC618(pad, pad_gpio_mux(pad), 0, 0);
  GpioPinConfig_t config;
  memset(&config, 0, sizeof(config));
  config.pinDirection = GPIO_DIRECTION_OUTPUT;
  config.misc.initOutput = 1;
  GPIO_pinConfig(to_port(gpio_bit), to_pin_index(gpio_bit), &config);
}

void GpioResourceGroup::on_unregister_resource(Resource* r) {
  GpioResource* resource = static_cast<GpioResource*>(r);
  Locker locker(OS::global_mutex());
  open_drain_pads &= ~(1ULL << resource->pad());
  pad_release_locked(locker, resource->pad(), true);
  gpio_aon_power_release(resource->pad());
  gpio_bits.put(locker, resource->gpio_bit());
  pads.put(locker, resource->pad());
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
  {
    // A GPIO pin owns both namespaces or neither. In particular, a sibling
    // PAD cannot claim the same controller bit between the two reservations.
    Locker locker(OS::global_mutex());
    if (!pads.take(locker, pad)) FAIL(ALREADY_IN_USE);
    if (!gpio_bits.take(locker, gpio_bit)) {
      pads.put(locker, pad);
      FAIL(ALREADY_IN_USE);
    }
  }

  GpioResource* resource = _new GpioResource(group, pad, gpio_bit);
  if (resource == null) {
    Locker locker(OS::global_mutex());
    gpio_bits.put(locker, gpio_bit);
    pads.put(locker, pad);
    FAIL(MALLOC_FAILED);
  }

  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(unuse) {
  ARGS(GpioResourceGroup, group, GpioResource, resource);
  // The pad cleanup happens in on_unregister_resource, shared with the
  // killed-container teardown path.
  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(config) {
  ARGS(GpioResource, resource, bool, pull_up, bool, pull_down, bool, input,
       bool, output, bool, open_drain, int, value);

  int pad = resource->pad();
  int gpio_bit = resource->gpio_bit();
  if (pull_up && pull_down) FAIL(INVALID_ARGUMENT);
  if (value < -1 || value > 1) FAIL(INVALID_ARGUMENT);

  // AON-domain pads sit behind the AON IO LDO. Wake-only pins don't need
  // this rail, so acquire it when the pin is first configured as GPIO.
  gpio_aon_power_acquire(pad);

  // Release the GPIO-muxed wakeup pads from wakeup duty. The SDK describes
  // this as selecting between "wakeup pad" and "aonio"; pad_release restores
  // wakeup duty. The AON supply above is set to 3.3 V so both input and output
  // levels reach the board net.
  if (pad_is_wakeup(pad)) wakeup_pad_set(pad, false, false, false);

  // Program the controller while the pad is still disconnected from its GPIO
  // function. Muxing first can expose the previous direction/data latch for a
  // few instructions and produce an opposite-level pulse at output startup.
  if (open_drain) {
    set_open_drain_state(pad, true);
    apply_open_drain_level(gpio_bit, (value == -1) ? 0 : value);
  } else {
    set_open_drain_state(pad, false);
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

  // Connect the fully configured controller to the pad. Enable the input
  // buffer for inputs and open-drain pins so reads observe the wire. AutoPull
  // stays off because apply_pull above selects the resistor explicitly.
  GPIO_IomuxEC618(pad, pad_gpio_mux(pad), 0, (input || open_drain) ? 1 : 0);

  return process->null_object();
}

PRIMITIVE(get) {
  ARGS(GpioResource, resource);
  int gpio_bit = resource->gpio_bit();
  return Smi::from(GPIO_pinRead(to_port(gpio_bit), to_pin_index(gpio_bit)) ? 1 : 0);
}

PRIMITIVE(set) {
  ARGS(GpioResource, resource, int, value);
  int pad = resource->pad();
  int gpio_bit = resource->gpio_bit();
  if (value != 0 && value != 1) FAIL(INVALID_ARGUMENT);
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
  if (value != 0 && value != 1) FAIL(INVALID_ARGUMENT);
  // Capture the trigger sequence before arming: an interrupt firing
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
  ARGS(GpioResource, resource, bool, value);
  int pad = resource->pad();
  int gpio_bit = resource->gpio_bit();
  if (value == is_open_drain(pad)) return process->null_object();
  if (value) {
    // Carry the pin's current line level into the emulation (the input
    // buffer must be on before we can trust the read).
    GPIO_IomuxEC618(pad, pad_gpio_mux(pad), 0, 1);
    int level = GPIO_pinRead(to_port(gpio_bit), to_pin_index(gpio_bit)) ? 1 : 0;
    set_open_drain_state(pad, true);
    apply_open_drain_level(gpio_bit, level);
  } else {
    // Back to push-pull, driving the current line level.
    int level = GPIO_pinRead(to_port(gpio_bit), to_pin_index(gpio_bit)) ? 1 : 0;
    set_open_drain_state(pad, false);
    GpioPinConfig_t config;
    memset(&config, 0, sizeof(config));
    config.pinDirection = GPIO_DIRECTION_OUTPUT;
    config.misc.initOutput = level;
    GPIO_pinConfig(to_port(gpio_bit), to_pin_index(gpio_bit), &config);
  }
  return process->null_object();
}

PRIMITIVE(set_pull) {
  ARGS(GpioResource, resource, int, value);
  // value: 1 pull-up, -1 pull-down, 0 none.
  int pad = resource->pad();
  if (value < -1 || value > 1) FAIL(INVALID_ARGUMENT);
  apply_pull(pad, value > 0, value < 0);
  return process->null_object();
}

}  // namespace toit

#endif  // TOIT_EC618
