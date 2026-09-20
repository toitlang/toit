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

#include "hardware/clocks.h"
#include "hardware/gpio.h"
#include "hardware/pwm.h"

#include "../objects_inline.h"
#include "../os.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../utils.h"

namespace toit {

// Shared GPIO ownership is implemented by gpio_rp2350.cc. PWM accepts only
// non-negative numeric GP identifiers and owns each pin until channel close.
bool gpio_pool_take(int pin);
void gpio_pool_put(int pin);

static const uint32_t kMaximumApiFrequency = 40000000;
static const uint32_t kMaximumPeriod = 65536;
static const uint32_t kMinimumDivider16 = 16;
static const uint32_t kMaximumDivider16 = 255 * 16 + 15;

class PwmResourceGroup;

struct SliceLease {
  PwmResourceGroup* owner;
  uint8_t channels;
};

static SliceLease slice_leases[NUM_PWM_SLICES] = {};

struct PwmTiming {
  uint32_t divider16;
};

static bool compute_timing(uint32_t source_hz, uint32_t period,
                           uint32_t frequency, PwmTiming* result) {
  if (frequency == 0 || period < 2 || period > kMaximumPeriod) return false;
  uint64_t denominator = uint64_t{frequency} * period;
  uint64_t divider16 = (uint64_t{source_hz} * 16 + denominator / 2) /
      denominator;
  if (divider16 < kMinimumDivider16 ||
      divider16 > kMaximumDivider16) return false;
  result->divider16 = static_cast<uint32_t>(divider16);
  return true;
}

static void apply_timing(int slice, uint32_t period,
                         const PwmTiming& timing, bool initialize) {
  uint32_t divider_integer = timing.divider16 >> 4;
  uint32_t divider_fraction = timing.divider16 & 0xf;
  if (initialize) {
    pwm_config config = pwm_get_default_config();
    pwm_config_set_wrap(&config, static_cast<uint16_t>(period - 1));
    pwm_config_set_clkdiv_int_frac4(
        &config, divider_integer, divider_fraction);
    pwm_init(slice, &config, true);
  } else {
    pwm_set_clkdiv_int_frac4(slice, divider_integer, divider_fraction);
  }
}

static bool is_valid_pin(int pin) {
  return pin >= 0 && pin < static_cast<int>(NUM_BANK0_GPIOS);
}

static bool is_restricted_pin(int pin) {
#ifdef PICO_PSRAM_CS_PIN
  return pin == PICO_PSRAM_CS_PIN;
#else
  USE(pin);
  return false;
#endif
}

class PwmResource : public Resource {
 public:
  TAG(PwmResource);

  PwmResource(ResourceGroup* group, int pin, int slice, int channel,
              double factor)
      : Resource(group)
      , pin_(pin)
      , slice_(slice)
      , channel_(channel)
      , factor_(factor) {}

  int pin() const { return pin_; }
  int slice() const { return slice_; }
  int channel() const { return channel_; }
  double factor() const { return factor_; }
  void set_factor(double factor) { factor_ = factor; }

 private:
  int pin_;
  int slice_;
  int channel_;
  double factor_;
};

class PwmResourceGroup : public ResourceGroup {
 public:
  TAG(PwmResourceGroup);

  PwmResourceGroup(Process* process, uint32_t source_hz, uint32_t period,
                   uint32_t frequency, uint32_t max_frequency,
                   const PwmTiming& timing)
      : ResourceGroup(process)
      , source_hz_(source_hz)
      , period_(period)
      , frequency_(frequency)
      , max_frequency_(max_frequency)
      , timing_(timing) {}

  uint32_t period() const { return period_; }
  uint32_t frequency() const { return frequency_; }
  uint32_t max_frequency() const { return max_frequency_; }
  const PwmTiming& timing() const { return timing_; }

  bool timing_for(uint32_t frequency, PwmTiming* result) const {
    return frequency <= max_frequency_ &&
        compute_timing(source_hz_, period_, frequency, result);
  }

  void set_frequency(uint32_t frequency, const PwmTiming& timing) {
    uint32_t updated = 0;
    for (Resource* resource : resources()) {
      int slice = static_cast<PwmResource*>(resource)->slice();
      uint32_t bit = uint32_t{1} << slice;
      if ((updated & bit) != 0) continue;
      apply_timing(slice, period_, timing, false);
      updated |= bit;
    }
    frequency_ = frequency;
    timing_ = timing;
  }

 protected:
  void on_unregister_resource(Resource* resource) override;

 private:
  uint32_t source_hz_;
  uint32_t period_;
  uint32_t frequency_;
  uint32_t max_frequency_;
  PwmTiming timing_;
};

static bool reserve_slice_channel(PwmResourceGroup* group, int slice,
                                  int channel, bool* initialize) {
  Locker locker(OS::global_mutex());
  SliceLease* lease = &slice_leases[slice];
  uint8_t bit = uint8_t{1} << channel;
  if (lease->owner != null && lease->owner != group) return false;
  if ((lease->channels & bit) != 0) return false;
  *initialize = lease->channels == 0;
  lease->owner = group;
  lease->channels |= bit;
  return true;
}

static void release_slice_channel(PwmResourceGroup* group, int slice,
                                  int channel) {
  Locker locker(OS::global_mutex());
  SliceLease* lease = &slice_leases[slice];
  uint8_t bit = uint8_t{1} << channel;
  ASSERT(lease->owner == group && (lease->channels & bit) != 0);
  lease->channels &= ~bit;
  if (lease->channels == 0) {
    // Reset the slice before publishing it as available to another group.
    pwm_set_enabled(slice, false);
    pwm_config config = pwm_get_default_config();
    pwm_init(slice, &config, false);
    lease->owner = null;
  }
}

static double clamp_factor(double factor) {
  return Utils::max(0.0, Utils::min(factor, 1.0));
}

static void apply_factor(PwmResource* resource, uint32_t period,
                         double factor) {
  int pin = resource->pin();
  if (factor <= 0.0) {
    gpio_set_outover(pin, GPIO_OVERRIDE_LOW);
  } else if (factor >= 1.0) {
    gpio_set_outover(pin, GPIO_OVERRIDE_HIGH);
  } else {
    uint32_t level = static_cast<uint32_t>(period * factor + 0.5);
    if (level == 0) level = 1;
    if (level >= period) level = period - 1;
    pwm_set_chan_level(resource->slice(), resource->channel(),
                       static_cast<uint16_t>(level));
    gpio_set_outover(pin, GPIO_OVERRIDE_NORMAL);
  }
  resource->set_factor(factor);
}

void PwmResourceGroup::on_unregister_resource(Resource* resource) {
  PwmResource* channel = static_cast<PwmResource*>(resource);
  gpio_set_outover(channel->pin(), GPIO_OVERRIDE_LOW);
  pwm_set_chan_level(channel->slice(), channel->channel(), 0);
  gpio_pool_put(channel->pin());
  release_slice_channel(this, channel->slice(), channel->channel());
}

MODULE_IMPLEMENTATION(pwm, MODULE_PWM)

PRIMITIVE(init) {
  ARGS(int, frequency, int, max_frequency);
  if (frequency <= 0 || max_frequency <= 0 || frequency > max_frequency ||
      static_cast<uint32_t>(max_frequency) > kMaximumApiFrequency) {
    FAIL(INVALID_ARGUMENT);
  }

  uint32_t source_hz = clock_get_hz(clk_sys);
  uint32_t period = source_hz / static_cast<uint32_t>(max_frequency);
  if (period > kMaximumPeriod) period = kMaximumPeriod;
  PwmTiming timing;
  if (!compute_timing(source_hz, period, frequency, &timing)) {
    FAIL(INVALID_ARGUMENT);
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  PwmResourceGroup* group = _new PwmResourceGroup(
      process, source_hz, period, frequency, max_frequency, timing);
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(PwmResourceGroup, group);
  group->tear_down();
  group_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(start) {
  ARGS(PwmResourceGroup, group, int, pin, double, factor);
  if (factor != factor) FAIL(INVALID_ARGUMENT);  // NaN cannot be clamped.
  if (pin < 0) FAIL(INVALID_ARGUMENT);  // Reject encoded gpio.Pin values.
  if (!is_valid_pin(pin)) FAIL(OUT_OF_RANGE);
  if (is_restricted_pin(pin)) FAIL(PERMISSION_DENIED);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  if (!gpio_pool_take(pin)) FAIL(ALREADY_IN_USE);

  int slice = pwm_gpio_to_slice_num(pin);
  int channel = pwm_gpio_to_channel(pin);
  bool initialize;
  if (!reserve_slice_channel(group, slice, channel, &initialize)) {
    gpio_pool_put(pin);
    FAIL(ALREADY_IN_USE);
  }

  double clamped = clamp_factor(factor);
  PwmResource* resource = _new PwmResource(
      group, pin, slice, channel, clamped);
  if (resource == null) {
    release_slice_channel(group, slice, channel);
    gpio_pool_put(pin);
    FAIL(MALLOC_FAILED);
  }

  if (initialize) apply_timing(slice, group->period(), group->timing(), true);
  gpio_init(pin);
  gpio_disable_pulls(pin);
  gpio_set_input_enabled(pin, false);
  // Prepare the compare value or static override before PWM takes the pad.
  apply_factor(resource, group->period(), clamped);
  gpio_set_function(pin, GPIO_FUNC_PWM);

  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(factor) {
  ARGS(PwmResourceGroup, group, PwmResource, channel);
  USE(group);
  return Primitive::allocate_double(channel->factor(), process);
}

PRIMITIVE(set_factor) {
  ARGS(PwmResourceGroup, group, PwmResource, channel, double, factor);
  if (factor != factor) FAIL(INVALID_ARGUMENT);
  apply_factor(channel, group->period(), clamp_factor(factor));
  return process->null_object();
}

PRIMITIVE(frequency) {
  ARGS(PwmResourceGroup, group);
  return Primitive::integer(group->frequency(), process);
}

PRIMITIVE(set_frequency) {
  ARGS(PwmResourceGroup, group, int, frequency);
  if (frequency <= 0) FAIL(INVALID_ARGUMENT);
  PwmTiming timing;
  if (!group->timing_for(frequency, &timing)) FAIL(INVALID_ARGUMENT);
  group->set_frequency(frequency, timing);
  return process->null_object();
}

PRIMITIVE(close_channel) {
  ARGS(PwmResourceGroup, group, PwmResource, channel);
  group->unregister_resource(channel);
  channel_proxy->clear_external_address();
  return process->null_object();
}

}  // namespace toit

#endif  // TOIT_RP2350
