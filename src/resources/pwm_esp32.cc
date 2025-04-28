// Copyright (C) 2021 Toitware ApS.
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

#ifdef TOIT_ESP32

#include <driver/ledc.h>
#include <esp_clk_tree.h>

#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../vm.h"


#if SOC_LEDC_SUPPORT_HS_MODE
    #define SPEED_MODE LEDC_HIGH_SPEED_MODE
#else
    #define SPEED_MODE LEDC_LOW_SPEED_MODE
#endif

namespace toit {

// On the ESP32, the PWM module is exposed by the LEDC library:
//
//  "The LED control (LEDC) peripheral is primarily designed to control
//   the intensity of LEDs, although it can also be used to generate PWM
//   signals for other purposes as well."

const ledc_timer_t kInvalidLedcTimer = ledc_timer_t(-1);
static ResourcePool<ledc_timer_t, kInvalidLedcTimer> ledc_timers(
    LEDC_TIMER_0, LEDC_TIMER_1, LEDC_TIMER_2, LEDC_TIMER_3
);

#ifndef SOC_LEDC_CHANNEL_NUM
#error "SOC_LEDC_CHANNEL_NUM not defined"
#endif

const ledc_channel_t kInvalidLedcChannel = ledc_channel_t(-1);
static ResourcePool<ledc_channel_t, kInvalidLedcChannel> ledc_channels(
    LEDC_CHANNEL_0,
    LEDC_CHANNEL_1,
    LEDC_CHANNEL_2,
    LEDC_CHANNEL_3,
    LEDC_CHANNEL_4,
    LEDC_CHANNEL_5
#if SOC_LEDC_CHANNEL_NUM > 6
  , LEDC_CHANNEL_6,
    LEDC_CHANNEL_7
#endif
);

#if CONFIG_IDF_TARGET_ESP32
const ledc_clk_cfg_t kDefaultClk = LEDC_USE_APB_CLK;
#else
const ledc_clk_cfg_t kDefaultClk = LEDC_USE_RC_FAST_CLK;
#endif

class PwmResource : public Resource {
 public:
  TAG(PwmResource);
  PwmResource(ResourceGroup* group, ledc_channel_t channel, gpio_num_t num)
    : Resource(group)
    , channel_(channel)
    , num_(num) {}

  ledc_channel_t channel() const { return channel_; }
  gpio_num_t num() const { return num_; }

 private:
  ledc_channel_t channel_;
  gpio_num_t num_;
};

class PwmResourceGroup : public ResourceGroup {
 public:
  TAG(PwmResourceGroup);
  PwmResourceGroup(Process* process, ledc_timer_t timer, uint32 max_value)
     : ResourceGroup(process)
     , timer_(timer)
     , max_value_(max_value) {}

  ~PwmResourceGroup() {
    ledc_timer_rst(SPEED_MODE, timer_);
    ledc_timers.put(timer_);
  }

  ledc_timer_t timer() { return timer_; }
  uint32 max_value() { return max_value_; }

 protected:
  virtual void on_unregister_resource(Resource* r) {
    PwmResource* pwm = reinterpret_cast<PwmResource*>(r);
    ledc_stop(SPEED_MODE, pwm->channel(), 0);
    gpio_config_t cfg = {
        .pin_bit_mask = BIT64(pwm->num()),
        .mode = GPIO_MODE_DISABLE,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&cfg);
    ledc_channels.put(pwm->channel());
  }

 private:
  ledc_timer_t timer_;
  uint32 max_value_;
};

MODULE_IMPLEMENTATION(pwm, MODULE_PWM)

PRIMITIVE(init) {
  ARGS(int, frequency, int, max_frequency)

  uint32 src_clk_frequency = 0;
  esp_err_t err = esp_clk_tree_src_get_freq_hz(static_cast<soc_module_clk_t>(kDefaultClk),
                                               ESP_CLK_TREE_SRC_FREQ_PRECISION_EXACT,
                                               &src_clk_frequency);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  // The max frequency is half the source clock frequency. At that frequency there are
  // only three duty-factors left: 0%, 50% and 100%.
  if (frequency <= 0 || frequency > max_frequency || max_frequency > (src_clk_frequency >> 1)) {
    FAIL(OUT_OF_BOUNDS);
  }

  auto resolution_bits = ledc_find_suitable_duty_resolution(src_clk_frequency, max_frequency);
  if (resolution_bits == 0) FAIL(OUT_OF_BOUNDS);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  ledc_timer_t timer = ledc_timers.any();
  if (timer == kInvalidLedcTimer) FAIL(ALREADY_IN_USE);

  ledc_timer_config_t config = {
    .speed_mode = SPEED_MODE,
    .duty_resolution = static_cast<ledc_timer_bit_t>(resolution_bits),
    .timer_num = timer,
    // Start with the max_frequency, so that the clocks are correctly chosen.
    .freq_hz = static_cast<uint32>(max_frequency),
    .clk_cfg = kDefaultClk,
    .deconfigure = false,
  };

  err = ledc_timer_config(&config);
  if (err != ESP_OK) {
    ledc_timers.put(timer);
    return Primitive::os_error(err, process);
  }

  err = ledc_set_freq(SPEED_MODE, timer, frequency);
  if (err != ESP_OK) {
    ledc_timer_rst(SPEED_MODE, timer);
    ledc_timers.put(timer);
    return Primitive::os_error(err, process);
  }

  PwmResourceGroup* gpio = _new PwmResourceGroup(process, timer, (1 << resolution_bits) - 1);
  if (!gpio) {
    ledc_timer_rst(SPEED_MODE, timer);
    ledc_timers.put(timer);
    FAIL(MALLOC_FAILED);
  }
  proxy->set_external_address(gpio);

  return proxy;
}

PRIMITIVE(close) {
  ARGS(PwmResourceGroup, resource_group);

  resource_group->tear_down();

  resource_group_proxy->clear_external_address();

  return process->null_object();
}

static uint32 compute_duty_factor(PwmResourceGroup* pwm, double factor) {
  factor = Utils::max(Utils::min(factor, 1.0), 0.0);
  return uint32(factor * pwm->max_value());
}

PRIMITIVE(start) {
  ARGS(PwmResourceGroup, resource_group, int, pin, double, factor);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  ledc_channel_t channel = ledc_channels.any();
  if (channel == kInvalidLedcChannel) FAIL(ALREADY_IN_USE);

  ledc_channel_config_t config = {
    .gpio_num = pin,
    .speed_mode = SPEED_MODE,
    .channel = channel,
    .intr_type = LEDC_INTR_DISABLE,
    .timer_sel = resource_group->timer(),
    .duty = compute_duty_factor(resource_group, factor),
    .hpoint = 0,
    .flags{},
  };
  esp_err_t err = ledc_channel_config(&config);
  if (err != ESP_OK) {
    ledc_channels.put(channel);
    return Primitive::os_error(err, process);
  }

  PwmResource* pwm = _new PwmResource(resource_group, channel, static_cast<gpio_num_t>(pin));
  if (!pwm) {
    ledc_stop(SPEED_MODE, channel, 0);
    ledc_channels.put(channel);
    FAIL(MALLOC_FAILED);
  }

  resource_group->register_resource(pwm);

  proxy->set_external_address(pwm);

  return proxy;
}

PRIMITIVE(factor) {
  ARGS(PwmResourceGroup, resource_group, PwmResource, resource);

  uint32 duty = ledc_get_duty(SPEED_MODE, resource->channel());
  if (duty == LEDC_ERR_DUTY) {
    return Primitive::os_error(LEDC_ERR_DUTY, process);
  }

  return Primitive::allocate_double(duty / double(resource_group->max_value()), process);
}

PRIMITIVE(set_factor) {
  ARGS(PwmResourceGroup, resource_group, PwmResource, resource, double, factor);

  uint32 duty = compute_duty_factor(resource_group, factor);
  esp_err_t err = ledc_set_duty(SPEED_MODE, resource->channel(), duty);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  err = ledc_update_duty(SPEED_MODE, resource->channel());
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  return process->null_object();
}

PRIMITIVE(frequency) {
  ARGS(PwmResourceGroup, resource_group);

  uint32 frequency = ledc_get_freq(SPEED_MODE, resource_group->timer());
  if (frequency == 0) FAIL(ERROR);

  return Smi::from(static_cast<word>(frequency));
}

PRIMITIVE(set_frequency) {
  ARGS(PwmResourceGroup, resource_group, int, frequency);

  if (frequency <= 0 || frequency > resource_group->max_value()) FAIL(OUT_OF_BOUNDS);

  esp_err_t err = ledc_set_freq(SPEED_MODE, resource_group->timer(), static_cast<uint32>(frequency));
  if (err != ESP_OK) {
    // This can happen if the max frequency for this timer was set too low or too high.
    return Primitive::os_error(err, process);
  }

  return process->null_object();
}

PRIMITIVE(close_channel) {
  ARGS(PwmResourceGroup, resource_group, PwmResource, resource);

  resource_group->unregister_resource(resource);

  resource_proxy->clear_external_address();

  return process->null_object();
}

} // namespace toit

#endif // TOIT_ESP32
