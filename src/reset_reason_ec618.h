// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once

#include <reset.h>
#include "reset_reason.h"

namespace toit {

// Normalize the vendor enum for system.power. The existing EC618 API keeps
// returning the original enum so callers can distinguish all detailed causes.
inline uint32_t ec618_reset_reason_flags(LastResetState_e reason) {
  switch (reason) {
    case LAST_RESET_POR: return ResetReason::POWER_ON;
    case LAST_RESET_NORMAL: return ResetReason::LOW_POWER_WAKE;
    case LAST_RESET_SWRESET:
    case LAST_RESET_FOTA:
      return ResetReason::SOFTWARE;
    case LAST_RESET_HARDFAULT:
    case LAST_RESET_ASSERT:
    case LAST_RESET_CPRESET:
      return ResetReason::HARDWARE;
    case LAST_RESET_WDTSW:
    case LAST_RESET_WDTHW:
    case LAST_RESET_AONWDT:
      return ResetReason::WATCHDOG;
    case LAST_RESET_LOCKUP: return ResetReason::CPU_LOCKUP;
    case LAST_RESET_BATLOW: return ResetReason::BROWNOUT;
    case LAST_RESET_TEMPHI: return ResetReason::TEMPERATURE;
    default: return ResetReason::UNKNOWN;
  }
}

}  // namespace toit
