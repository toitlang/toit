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

#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "pad_table_ec618.h"

extern "C" {
  #include "clock.h"
  #include "driver_gpio.h"
  #include "ec618.h"
  #include "timer.h"
}

namespace toit {

// PWM on the EC618 rides on the AP TIMER instances: each timer drives ONE
// PWM output, routable to one of (at most) two pads via iomux function 5
// (ALT5). TIMER3 and TIMER5 are reserved by the platform (the SDK's own
// PWM layer, luat_pwm_ec618.c, excludes them), leaving four PWM outputs.
//
// The timer registers are programmed directly (the SDK's TIMER_setupPwm
// is not in the jump table, and its duty cycle is integer-percent only —
// too coarse). The clock plumbing and start/stop go through the
// jump-tabled SDK calls. Timers run from the 26 MHz source, so a period
// is 26e6/frequency ticks and the duty resolution improves as the
// frequency drops (1 kHz -> 1/26000).

static const uint32_t kSrcClockHz = 26 * 1000 * 1000;
static const int kTimerCount = 6;

#define EIGEN_TIMER(n) ((TIMER_TypeDef*)(AP_TIMER0_BASE_ADDR + 0x1000 * (n)))

struct PwmPad {
  uint8_t pad;
  uint8_t timer;
};

// Pad -> timer routing, from the SDK's luat_pwm_ec618.c map (iomux ALT5
// on every entry).
static const PwmPad kPwmPads[] = {
  {16, 0}, {39, 0},
  {17, 1}, {35, 1},
  {31, 2}, {36, 2},
  {33, 4}, {38, 4},
};

static const ClockId_e kPClks[kTimerCount] = {
  PCLK_TIMER0, PCLK_TIMER1, PCLK_TIMER2, PCLK_TIMER3, PCLK_TIMER4, PCLK_TIMER5,
};
static const ClockId_e kFClks[kTimerCount] = {
  FCLK_TIMER0, FCLK_TIMER1, FCLK_TIMER2, FCLK_TIMER3, FCLK_TIMER4, FCLK_TIMER5,
};
static const uint32_t kFClkSel26M[kTimerCount] = {
  FCLK_TIMER0_SEL_26M, FCLK_TIMER1_SEL_26M, FCLK_TIMER2_SEL_26M,
  FCLK_TIMER3_SEL_26M, FCLK_TIMER4_SEL_26M, FCLK_TIMER5_SEL_26M,
};

static bool timer_in_use[kTimerCount] = {};

static int pad_to_timer(int pad) {
  for (size_t i = 0; i < sizeof(kPwmPads) / sizeof(kPwmPads[0]); i++) {
    if (kPwmPads[i].pad == pad) return kPwmPads[i].timer;
  }
  return -1;
}

class PwmResource : public Resource {
 public:
  TAG(PwmResource);
  PwmResource(ResourceGroup* group, int timer, int pad, double factor)
    : Resource(group), timer_(timer), pad_(pad), factor_(factor) {}

  int timer() const { return timer_; }
  int pad() const { return pad_; }
  double factor() const { return factor_; }
  void set_factor(double factor) { factor_ = factor; }

 private:
  int timer_;
  int pad_;
  double factor_;
};

static void program_duty(int timer, uint32_t period, double factor);
static void apply_duty(int timer, uint32_t period, double factor);

class PwmResourceGroup : public ResourceGroup {
 public:
  TAG(PwmResourceGroup);
  PwmResourceGroup(Process* process, uint32_t frequency, uint32_t max_frequency)
    : ResourceGroup(process), frequency_(frequency), max_frequency_(max_frequency) {}

  uint32_t frequency() const { return frequency_; }
  uint32_t max_frequency() const { return max_frequency_; }
  void set_frequency(uint32_t frequency) { frequency_ = frequency; }

  uint32_t period() const { return kSrcClockHz / frequency_; }

  // Reprograms every live channel for the current frequency; the change
  // can glitch one cycle.
  void reprogram_channels() {
    uint32_t p = period();
    for (Resource* r : resources()) {
      PwmResource* channel = static_cast<PwmResource*>(r);
      EIGEN_TIMER(channel->timer())->TMR[1] = p - 1;
      apply_duty(channel->timer(), p, channel->factor());
    }
  }

 protected:
  void on_unregister_resource(Resource* r) override {
    PwmResource* channel = static_cast<PwmResource*>(r);
    TIMER_stop(channel->timer());
    // Return the pad to plain GPIO (left unconfigured = not driven).
    GPIO_IomuxEC618(channel->pad(), 0, 0, 0);
    timer_in_use[channel->timer()] = false;
  }

 private:
  uint32_t frequency_;
  uint32_t max_frequency_;
};

// Programs the duty threshold. The hardware holds the output low for
// counts [0..TMR[0]] and high until the period register TMR[1]
// (mode MCS=2, as in the SDK's TIMER_setupPwm). TMR[0] > TMR[1] gives a
// constant low. The SDK's TMR[0] == TMR[1] "constant high" trick does
// NOT work: measured on hardware it yields constant LOW (the two
// matches apparently cancel), and TMR[0] == 0 is constant low as well
// (the match collides with the period reset). A 1.0 duty factor is
// therefore programmed as the closest the mode can express — high with
// a two-source-tick (77 ns) low notch per period.
static void program_duty(int timer, uint32_t period, double factor) {
  uint32_t high_ticks = (uint32_t)(period * factor + 0.5);
  uint32_t tmr0;
  if (high_ticks == 0) {
    tmr0 = period;               // Constant low.
  } else if (high_ticks >= period - 1) {
    tmr0 = 1;                    // Maximum expressible high time.
  } else {
    tmr0 = period - high_ticks - 1;
  }
  EIGEN_TIMER(timer)->TMR[0] = tmr0;
}

// Updates the duty threshold of a RUNNING timer. The constant-low state
// is a one-way trap when written live: with TMR[0] > TMR[1] the match0
// event never fires, and the hardware apparently latches compare-register
// writes on the match event — so a new TMR[0] never takes effect and the
// output stays low forever (measured; the SDK's TIMER_updatePwmDutyCycle
// has the same trap). Leaving that state needs a timer restart, which is
// just the TCCR enable bit (config and period are retained).
static void apply_duty(int timer, uint32_t period, double factor) {
  TIMER_TypeDef* t = EIGEN_TIMER(timer);
  bool wedged = t->TMR[0] > t->TMR[1];
  program_duty(timer, period, factor);
  if (wedged) {
    TIMER_stop(timer);
    TIMER_start(timer);
  }
}

static void program_pwm(int timer, uint32_t period, double factor) {
  EIGEN_TIMER(timer)->TMR[1] = period - 1;
  program_duty(timer, period, factor);
  EIGEN_TIMER(timer)->TIVR = 0;
  EIGEN_TIMER(timer)->TCTLR =
      (EIGEN_TIMER(timer)->TCTLR & ~TIMER_TCTLR_MCS_Msk) |
      EIGEN_VAL2FLD(TIMER_TCTLR_MCS, 2u) | TIMER_TCTLR_PWMOUT_Msk;
}

MODULE_IMPLEMENTATION(pwm, MODULE_PWM)

PRIMITIVE(init) {
  ARGS(int, frequency, int, max_frequency);
  // A period needs at least 2 ticks of the 26 MHz source.
  if (frequency <= 0 || max_frequency <= 0) FAIL(INVALID_ARGUMENT);
  if (frequency > max_frequency) FAIL(INVALID_ARGUMENT);
  if ((uint32_t)max_frequency > kSrcClockHz / 2) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  PwmResourceGroup* group = _new PwmResourceGroup(process, frequency, max_frequency);
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
  ARGS(PwmResourceGroup, group, int, pad, double, factor);
  int timer = pad_to_timer(pad);
  if (timer < 0) FAIL(INVALID_ARGUMENT);
  if (timer_in_use[timer]) FAIL(ALREADY_IN_USE);
  if (factor < 0.0 || factor > 1.0) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  PwmResource* channel = _new PwmResource(group, timer, pad, factor);
  if (channel == null) FAIL(MALLOC_FAILED);

  CLOCK_setClockSrc(kFClks[timer], (ClockSelect_e)kFClkSel26M[timer]);
  CLOCK_setClockDiv(kFClks[timer], 1);
  CLOCK_clockEnable(kPClks[timer]);
  CLOCK_clockEnable(kFClks[timer]);
  TIMER_driverInit();

  GPIO_IomuxEC618(pad, 5, 0, 0);  // ALT5 = the timer's PWM output.
  program_pwm(timer, group->period(), factor);
  TIMER_start(timer);

  timer_in_use[timer] = true;
  group->register_resource(channel);
  proxy->set_external_address(channel);
  return proxy;
}

PRIMITIVE(factor) {
  ARGS(PwmResourceGroup, group, PwmResource, channel);
  USE(group);
  return Primitive::allocate_double(channel->factor(), process);
}

PRIMITIVE(set_factor) {
  ARGS(PwmResourceGroup, group, PwmResource, channel, double, factor);
  if (factor < 0.0 || factor > 1.0) FAIL(INVALID_ARGUMENT);
  apply_duty(channel->timer(), group->period(), factor);
  channel->set_factor(factor);
  return process->null_object();
}

PRIMITIVE(frequency) {
  ARGS(PwmResourceGroup, group);
  return Primitive::integer(group->frequency(), process);
}

PRIMITIVE(set_frequency) {
  ARGS(PwmResourceGroup, group, int, frequency);
  if (frequency <= 0 || (uint32_t)frequency > group->max_frequency()) {
    FAIL(INVALID_ARGUMENT);
  }
  group->set_frequency(frequency);
  group->reprogram_channels();
  return process->null_object();
}

PRIMITIVE(close_channel) {
  ARGS(PwmResourceGroup, group, PwmResource, channel);
  group->unregister_resource(channel);
  channel_proxy->clear_external_address();
  return process->null_object();
}

}  // namespace toit

#endif  // TOIT_EC618
