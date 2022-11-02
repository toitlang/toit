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

#ifdef TOIT_FREERTOS

#include <driver/ledc.h>

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
ResourcePool<ledc_timer_t, kInvalidLedcTimer> ledc_timers(
    LEDC_TIMER_0, LEDC_TIMER_1, LEDC_TIMER_2, LEDC_TIMER_3
);

const ledc_channel_t kInvalidLedcChannel = ledc_channel_t(-1);
ResourcePool<ledc_channel_t, kInvalidLedcChannel> ledc_channels(
    LEDC_CHANNEL_0,
    LEDC_CHANNEL_1,
    LEDC_CHANNEL_2,
    LEDC_CHANNEL_3,
    LEDC_CHANNEL_4,
    LEDC_CHANNEL_5
#if SOC_LEDC_CHANNEL_NUM > 6
    ,
    LEDC_CHANNEL_6,
    LEDC_CHANNEL_7
#endif
);

const uint32_t kMaxFrequencyBits = 26;
const uint32_t kMaxFrequency = 40000000;  // 40MHz with duty resolution of 1 bit.

class PWMResource : public Resource {
 public:
  TAG(PWMResource);
  PWMResource(ResourceGroup* group, ledc_channel_t channel)
    : Resource(group)
    , channel_(channel) {
  }

  ledc_channel_t channel() { return channel_; }

 private:
  ledc_channel_t channel_;
};

class PWMResourceGroup : public ResourceGroup {
 public:
  TAG(PWMResourceGroup);
  PWMResourceGroup(Process* process, ledc_timer_t timer, uint32 max_value)
     : ResourceGroup(process)
     , timer_(timer)
     , max_value_(max_value) {}

  ~PWMResourceGroup() {
    ledc_timer_rst(SPEED_MODE, timer_);
    ledc_timers.put(timer_);
  }

  ledc_timer_t timer() { return timer_; }
  uint32 max_value() { return max_value_; }

 protected:
  virtual void on_unregister_resource(Resource* r) {
    PWMResource* pwm = reinterpret_cast<PWMResource*>(r);
    ledc_stop(SPEED_MODE, pwm->channel(), 0);
    ledc_channels.put(pwm->channel());
  }

 private:
  ledc_timer_t timer_;
  uint32 max_value_;
};

uint32 msb(uint32 n){
  return 31 - Utils::clz(n);
}

MODULE_IMPLEMENTATION(pwm, MODULE_PWM)

PRIMITIVE(init) {
  ARGS(int, frequency, int, max_frequency)

  if (frequency <= 0 || frequency > max_frequency || max_frequency > kMaxFrequency) OUT_OF_BOUNDS;

  uint32 bits = msb(max_frequency << 1);
  uint32 resolution_bits = kMaxFrequencyBits - bits;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  ledc_timer_t timer = ledc_timers.any();
  if (timer == kInvalidLedcTimer) ALREADY_IN_USE;

  ledc_timer_config_t config = {
    .speed_mode = SPEED_MODE,
    .duty_resolution = (ledc_timer_bit_t)resolution_bits,
    .timer_num = timer,
    // Start with the max_frequency, so that the clocks are correctly chosen.
    .freq_hz = static_cast<uint32>(max_frequency),
    .clk_cfg = LEDC_AUTO_CLK,
  };

  esp_err_t err = ledc_timer_config(&config);
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

  PWMResourceGroup* gpio = _new PWMResourceGroup(process, timer, (1 << resolution_bits) - 1);
  if (!gpio) {
    ledc_timer_rst(SPEED_MODE, timer);
    ledc_timers.put(timer);
    MALLOC_FAILED;
  }
  proxy->set_external_address(gpio);

  return proxy;
}

PRIMITIVE(close) {
  ARGS(PWMResourceGroup, resource_group);

  resource_group->tear_down();

  resource_group_proxy->clear_external_address();

  return process->program()->null_object();
}

static uint32 compute_duty_factor(PWMResourceGroup* pwm, double factor) {
  factor = Utils::max(Utils::min(factor, 1.0), 0.0);
  return uint32(factor * pwm->max_value());
}

PRIMITIVE(start) {
  ARGS(PWMResourceGroup, resource_group, int, pin, double, factor);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  ledc_channel_t channel = ledc_channels.any();
  if (channel == kInvalidLedcChannel) OUT_OF_RANGE;

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

  PWMResource* pwm = _new PWMResource(resource_group, channel);
  if (!pwm) {
    ledc_stop(SPEED_MODE, channel, 0);
    ledc_channels.put(channel);
    MALLOC_FAILED;
  }

  resource_group->register_resource(pwm);

  proxy->set_external_address(pwm);

  return proxy;
}

PRIMITIVE(factor) {
  ARGS(PWMResourceGroup, resource_group, PWMResource, resource);

  uint32 duty = ledc_get_duty(SPEED_MODE, resource->channel());
  if (duty == LEDC_ERR_DUTY) {
    return Primitive::os_error(LEDC_ERR_DUTY, process);
  }

  return Primitive::allocate_double(duty / double(resource_group->max_value()), process);
}

PRIMITIVE(set_factor) {
  ARGS(PWMResourceGroup, resource_group, PWMResource, resource, double, factor);

  uint32 duty = compute_duty_factor(resource_group, factor);
  esp_err_t err = ledc_set_duty(SPEED_MODE, resource->channel(), duty);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  err = ledc_update_duty(SPEED_MODE, resource->channel());
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  return process->program()->null_object();
}

PRIMITIVE(frequency) {
  ARGS(PWMResourceGroup, resource_group);

  uint32 frequency = ledc_get_freq(SPEED_MODE, resource_group->timer());
  if (frequency == 0) OTHER_ERROR;

  ASSERT(frequency <= kMaxFrequency);
  return Smi::from(static_cast<word>(frequency));
}

PRIMITIVE(set_frequency) {
  ARGS(PWMResourceGroup, resource_group, int, frequency);

  if (frequency <= 0 || frequency > kMaxFrequency) OUT_OF_BOUNDS;

  esp_err_t err = ledc_set_freq(SPEED_MODE, resource_group->timer(), static_cast<uint32>(frequency));
  if (err != ESP_OK) {
    // This can happen if the max frequency for this timer was set too low or too high.
    return Primitive::os_error(err, process);
  }

  return process->program()->null_object();
}

PRIMITIVE(close_channel) {
  ARGS(PWMResourceGroup, resource_group, PWMResource, resource);

  resource_group->unregister_resource(resource);

  resource_proxy->clear_external_address();

  return process->program()->null_object();
}

} // namespace toit

#endif // TOIT_FREERTOS
