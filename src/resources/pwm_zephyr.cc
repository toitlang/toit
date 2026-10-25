// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "../top.h"
#if defined(TOIT_ZEPHYR) && CONFIG_PWM
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "pins_zephyr.h"
#include "pwm_zephyr_data.h"
#include <zephyr/drivers/pinctrl.h>
#include <zephyr/drivers/pwm.h>
#include <zephyr/dt-bindings/pinctrl/nrf-pinctrl.h>
#include <zephyr/pm/device.h>

#define TOIT_PLATFORM DT_COMPAT_GET_ANY_STATUS_OKAY(toit_platform)
#define DECLARE_PWM(node, prop, i) \
  BUILD_ASSERT(DT_NODE_HAS_COMPAT(DT_PHANDLE_BY_IDX(node, prop, i), nordic_nrf_pwm)); \
  PINCTRL_DT_DEV_CONFIG_DECLARE(DT_PHANDLE_BY_IDX(node, prop, i));
DT_FOREACH_PROP_ELEM(TOIT_PLATFORM, pwm_ports, DECLARE_PWM)

namespace toit {
static constexpr unsigned CHANNELS = 4;
struct PwmController {
  PwmController(const device* d, pinctrl_dev_config* p) : dev(d), config(p) {}
  const device* dev;
  pinctrl_dev_config* config;
  bool claimed = false, broken = false;
  pinctrl_soc_pin_t active[CHANNELS], sleep[CHANNELS];
  pinctrl_state states[2];

  int map(const int* pins) {
    for (unsigned i = 0; i < CHANNELS; ++i) {
      active[i] = ((NRF_FUN_PWM_OUT0 + i) << NRF_FUN_POS) |
          (pins[i] < 0 ? NRF_PIN_DISCONNECTED : static_cast<uint32_t>(pins[i]));
      sleep[i] = active[i] | BIT(NRF_LP_POS);
    }
    states[0] = {active, CHANNELS, PINCTRL_STATE_DEFAULT};
    states[1] = {sleep, CHANNELS, PINCTRL_STATE_SLEEP};
    return pinctrl_update_states(config, states, 2);
  }
};
#define PWM_CONTROLLER(node, prop, i) \
  {DEVICE_DT_GET(DT_PHANDLE_BY_IDX(node, prop, i)), PINCTRL_DT_DEV_CONFIG_GET(DT_PHANDLE_BY_IDX(node, prop, i))},
static PwmController controllers[] = {
  DT_FOREACH_PROP_ELEM(TOIT_PLATFORM, pwm_ports, PWM_CONTROLLER)
};

class PwmResource;
class PwmResourceGroup : public ResourceGroup {
 public:
  TAG(PwmResourceGroup);
  PwmResourceGroup(Process* process, PwmController* controller, int frequency, int maximum)
      : ResourceGroup(process), controller_(controller), maximum_(maximum) {
    bool valid = period.set(frequency);
    ASSERT(valid);
    USE(valid);
  }
  ~PwmResourceGroup() override {
    if (powered_) {
      int result = suspend();
      if (result) FATAL("PWM suspend failed: %d", result);
    }
    Locker locker(OS::global_mutex());
    controller_->claimed = false;
  }
  const device* dev() const { return controller_->dev; }
  int maximum() const { return maximum_; }
  int reconfigure();
  PwmResource* channels[CHANNELS] = {};
  ZephyrPwmPeriod period;

 private:
  int suspend() {
    int result = pm_device_action_run(dev(), PM_DEVICE_ACTION_SUSPEND);
    if (!result) powered_ = false;
    return result;
  }
  PwmController* controller_;
  int maximum_;
  bool powered_ = false;
};

class PwmResource : public Resource {
 public:
  TAG(PwmResource);
  PwmResource(PwmResourceGroup* group, unsigned index, double factor)
      : Resource(group), index_(index), factor_(factor) {}
  ~PwmResource() override {
    if (group()->channels[index_] != this) return;
    group()->channels[index_] = null;
    // Retire DMA and disconnect this output before releasing pin ownership.
    int result = group()->reconfigure();
    if (result) FATAL("PWM channel cleanup failed: %d", result);
  }
  PwmResourceGroup* group() const { return static_cast<PwmResourceGroup*>(resource_group()); }
  int open(int encoded) {
    int result = pins_.add(encoded, &pin_);
    if (result) return result;
    return pin_ < 0 ? -EINVAL : 0;
  }
  int pin() const { return pin_; }
  double factor() const { return factor_; }
  int apply(double factor) {
    int result = pwm_set_cycles(group()->dev(), index_, group()->period.cycles,
        group()->period.pulse(factor), PWM_POLARITY_NORMAL);
    if (!result) factor_ = factor <= 0 ? 0 : factor >= 1 ? 1 : factor;
    return result;
  }
 private:
  unsigned index_;
  int pin_ = -1;
  double factor_;
  ZephyrPins pins_;
};

int PwmResourceGroup::reconfigure() {
  // The Nordic driver forbids changing period while another channel is active.
  // Suspending also clears its cached period/mask, and waits for DMA to stop.
  // Pin changes and frequency changes may interrupt one period on other channels.
  if (powered_) {
    int result = suspend();
    if (result) return result;
  }
  int pins[CHANNELS];
  bool any = false;
  for (unsigned i = 0; i < CHANNELS; ++i) {
    pins[i] = channels[i] ? channels[i]->pin() : -1;
    any |= channels[i] != null;
  }
  int result = controller_->map(pins);
  if (result) return result;
  if (!any) {
    // Updating pinctrl's table alone does not write PSEL. Detach every output
    // even when there is no subsequent resume to apply the new mapping.
    return device_is_ready(dev()) ? pinctrl_apply_state(controller_->config, PINCTRL_STATE_SLEEP) : 0;
  }
  if (!device_is_ready(dev())) {
    result = device_init(dev());
    if (result) { controller_->broken = true; return result; }
  } else {
    result = pm_device_action_run(dev(), PM_DEVICE_ACTION_RESUME);
    if (result) return result;
  }
  powered_ = true;
  uint64_t clock;
  result = pwm_get_cycles_per_sec(dev(), 0, &clock);
  if (result) return result;
  if (clock != ZephyrPwmPeriod::CLOCK_HZ) return -ENOTSUP;
  for (auto channel : channels) {
    if (!channel) continue;
    result = channel->apply(channel->factor());
    if (result) return result;
  }
  return 0;
}

MODULE_IMPLEMENTATION(pwm, MODULE_PWM)

PRIMITIVE(init) {
  ARGS(int, frequency, int, max_frequency);
  ZephyrPwmPeriod period;
  if (!period.set(frequency) || !period.set(max_frequency) || frequency > max_frequency) FAIL(INVALID_ARGUMENT);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  PwmController* controller = null;
  {
    Locker locker(OS::global_mutex());
    for (auto& candidate : controllers) {
      if (candidate.claimed || candidate.broken) continue;
      controller = &candidate;
      controller->claimed = true;
      break;
    }
  }
  if (!controller) FAIL(ALREADY_IN_USE);
  auto group = _new PwmResourceGroup(process, controller, frequency, max_frequency);
  if (!group) {
    Locker locker(OS::global_mutex());
    controller->claimed = false;
    FAIL(MALLOC_FAILED);
  }
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
  if (std::isnan(factor)) FAIL(INVALID_ARGUMENT);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  unsigned index = 0;
  while (index < CHANNELS && group->channels[index]) ++index;
  if (index == CHANNELS) FAIL(QUOTA_EXCEEDED);
  auto channel = _new PwmResource(group, index, factor);
  if (!channel) FAIL(MALLOC_FAILED);
  int result = channel->open(pin);
  if (!result) {
    // Borrowed Pin objects bypass the global ownership pool, but cannot drive
    // two channels of this generator through the same pin.
    for (auto other : group->channels) {
      if (other && other->pin() == channel->pin()) result = -EBUSY;
    }
  }
  if (!result) {
    group->channels[index] = channel;
    result = group->reconfigure();
    if (result) {
      group->channels[index] = null;
      int rollback = group->reconfigure();
      if (rollback) FATAL("PWM rollback failed: %d", rollback);
    }
  }
  if (result) {
    delete channel;
    if (result == -EBUSY) FAIL(ALREADY_IN_USE);
    if (result == -EINVAL || result == -EPERM) FAIL(INVALID_ARGUMENT);
    return Primitive::os_error(-result, process);
  }
  group->register_resource(channel);
  proxy->set_external_address(channel);
  return proxy;
}

PRIMITIVE(factor) {
  ARGS(PwmResourceGroup, group, PwmResource, channel);
  if (channel->group() != group) FAIL(INVALID_ARGUMENT);
  return Primitive::allocate_double(static_cast<double>(group->period.pulse(channel->factor())) /
      group->period.cycles, process);
}

PRIMITIVE(set_factor) {
  ARGS(PwmResourceGroup, group, PwmResource, channel, double, factor);
  if (channel->group() != group || std::isnan(factor)) FAIL(INVALID_ARGUMENT);
  int result = channel->apply(factor);
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}

PRIMITIVE(frequency) {
  ARGS(PwmResourceGroup, group);
  return Smi::from(group->period.frequency());
}

PRIMITIVE(set_frequency) {
  ARGS(PwmResourceGroup, group, int, frequency);
  ZephyrPwmPeriod previous = group->period;
  if (frequency > group->maximum() || !group->period.set(frequency)) FAIL(INVALID_ARGUMENT);
  int result = group->reconfigure();
  if (result) {
    group->period = previous;
    int rollback = group->reconfigure();
    if (rollback) FATAL("PWM frequency rollback failed: %d", rollback);
    return Primitive::os_error(-result, process);
  }
  return process->null_object();
}

PRIMITIVE(close_channel) {
  ARGS(PwmResourceGroup, group, PwmResource, channel);
  if (channel->group() != group) FAIL(INVALID_ARGUMENT);
  group->unregister_resource(channel);
  channel_proxy->clear_external_address();
  return process->null_object();
}
}  // namespace toit
#endif
