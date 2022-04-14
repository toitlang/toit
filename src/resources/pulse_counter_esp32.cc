// Copyright (C) 2022 Toitware ApS.
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

#include <driver/pcnt.h>

#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../vm.h"


namespace toit {

class PcntResource : public Resource {
 public:
  TAG(PcntResource);
  PWMResource(ResourceGroup* group, pcnt_unit_t unit)
    : Resource(group)
    , _unit(unit) {
  }

  pcnt_unit_t unit() { return _unit; }

 private:
  pcnt_unit_t _unit;
};

class PcntResourceGroup : public ResourceGroup {
 public:
  TAG(PcntResourceGroup);
  PcntResourceGroup(Process* process, pcnt_unit_t counter)
     : ResourceGroup(process)
     , _timer(timer)
     , _max_value(max_value) {}

  ~PWMResourceGroup() {
    ledc_timer_rst(SPEED_MODE, _timer);
    ledc_timers.put(_timer);
  }

  ledc_timer_t timer() { return _timer; }
  uint32 max_value() { return _max_value; }

 protected:
  virtual void on_unregister_resource(Resource* r) {
    PWMResource* pwm = reinterpret_cast<PWMResource*>(r);
    ledc_stop(SPEED_MODE, pwm->channel(), 0);
    ledc_channels.put(pwm->channel());
  }

 private:
  ledc_timer_t _timer;
  uint32 _max_value;
};

uint32 msb(uint32 n){
  return 31 - Utils::clz(n);
}

MODULE_IMPLEMENTATION(pwm, MODULE_PWM)

PRIMITIVE(init) {
  ARGS(int64, frequency)

  if (frequency <= 0 || frequency > 40000000) OUT_OF_BOUNDS;

  uint32 bits = msb(frequency << 1);
  uint32 resolution_bits = kMaxFrequencyBits - bits;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  ledc_timer_t timer = ledc_timers.any();
  if (timer == kInvalidLedcTimer) OUT_OF_RANGE;

  ledc_timer_config_t config = {
    .speed_mode = SPEED_MODE,
    .duty_resolution = (ledc_timer_bit_t)resolution_bits,
    .timer_num = timer,
    .freq_hz = uint32(frequency),
    .clk_cfg = LEDC_AUTO_CLK,
  };

  esp_err_t err = ledc_timer_config(&config);
  if (err != ESP_OK) {
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
    .timer_sel = resource_group->timer(),
    .duty = compute_duty_factor(resource_group, factor),
    .hpoint = 0,
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

PRIMITIVE(close_channel) {
  ARGS(PWMResourceGroup, resource_group, PWMResource, resource);

  resource_group->unregister_resource(resource);

  resource_proxy->clear_external_address();

  return process->program()->null_object();
}

} // namespace toit

#endif // TOIT_FREERTOS
