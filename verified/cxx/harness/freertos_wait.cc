// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "os.h"

using namespace toit;

// EC618 application-core FreeRTOSConfig.h and the GCC portmacro.h select
// 1 kHz and 32-bit ticks. Only wait_ticks and its RTOS operations are modeled.
constexpr uint32 portTICK_PERIOD_MS = 1;
constexpr uint32 portMAX_DELAY = UINT32_MAX;

class Wait {
 public:
#include "freertos_wait.inc"

  bool wait_ticks(uint32 ticks) {
    CXXV_ASSERT(!called && ticks > 0 && ticks < portMAX_DELAY, "use a finite, positive tick count");
    called = true;
    duration = 1000LL * portTICK_PERIOD_MS * ticks;
    return signaled;
  }

  bool called = false;
  bool signaled;
  int64 duration = 0;
};

int main() {
  static_assert(WORD_BIT_SIZE == 32, "EC618 word width");
  Wait wait;
  wait.signaled = nondet_bool();
  int64 us = nondet_int64();
  bool result = wait.wait_us(us);
  CXXV_ASSERT(wait.called == (us > 0) && result == (us > 0 && wait.signaled),
              "skip expired waits and propagate the RTOS result for positive waits");
  if (us > 0) {
    int64 max_duration = 1000LL * portTICK_PERIOD_MS * (portMAX_DELAY - 1);
    int64 requested = us < OS::MAX_WAIT_US ? us : OS::MAX_WAIT_US;
    if (requested > max_duration) requested = max_duration;
    CXXV_ASSERT(wait.duration >= requested && wait.duration - requested < 1000LL * portTICK_PERIOD_MS,
                "round the capped delay to the smallest representable whole tick");
  }
}
